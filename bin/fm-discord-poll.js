#!/usr/bin/env node
/**
 * Self-hosted Discord connector poll helper.
 * Uses native Node 22 fetch to poll Discord REST API for bot mentions.
 */
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const token = process.env.FM_DISCORD_BOT_TOKEN || process.env.FM_DISCORD_TOKEN;
if (!token) {
	process.exit(0);
}

const fmHome = process.env.FM_HOME || process.env.FM_ROOT || ".";
const stateDir = process.env.FM_STATE_OVERRIDE || join(fmHome, "state");
const inboxDir = join(stateDir, "x-inbox");
const contextDir = join(stateDir, "x-context");
const cursorDir = join(stateDir, "x-discord");
const scriptDir = dirname(fileURLToPath(import.meta.url));
const xLib = join(scriptDir, "fm-x-lib.sh");
const apiBase = (process.env.FM_DISCORD_API_BASE || "https://discord.com/api/v10").replace(/\/$/, "");
const allowDms = !["0", "false", "no", "off"].includes((process.env.FM_DISCORD_ALLOW_DMS || "true").toLowerCase());

const channelIds = (process.env.FM_DISCORD_CHANNELS || process.env.FM_DISCORD_CHANNEL_ID || "")
	.split(",")
	.map((s) => s.trim())
	.filter(Boolean);

const excludeIds = (process.env.FM_DISCORD_EXCLUDES || process.env.FM_DISCORD_EXCLUDE_CHANNELS || "1551134713727426570")
	.split(",")
	.map((s) => s.trim())
	.filter(Boolean);

const apiHeaders = {
	Authorization: `Bot ${token}`,
	"User-Agent": "FirstmateDiscordSelfHosted/1.0",
};

function publishPrivate(dir, base, content, mode) {
	const result = spawnSync(
		"bash",
		["-c", '. "$1"; fmx_private_artifact_publish_stdin "$2" "$3" "$4"', "fm-discord-publish", xLib, dir, base, String(mode)],
		{ input: content, stdio: ["pipe", "ignore", "ignore"] },
	);
	if (result.status !== 0) throw new Error(`private artifact publication failed for ${dir}/${base}`);
}

function readPrivate(dir, base) {
	const result = spawnSync(
		"bash",
		["-c", '. "$1"; fmx_private_artifact_file_valid "$2" "$3" 600 || exit 1; cat -- "$2/$3"', "fm-discord-read", xLib, dir, base],
		{ encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
	);
	return result.status === 0 ? result.stdout : "";
}

function claimOffer(requestId) {
	const result = spawnSync(
		"bash",
		["-c", '. "$1"; fmx_offer_registry_claim "$2" "$3"', "fm-discord-offer", xLib, stateDir, requestId],
		{ stdio: ["ignore", "ignore", "ignore"] },
	);
	if (result.status === 1) return false;
	if (result.status !== 0) throw new Error(`offer publication failed for ${requestId}`);
	return true;
}

function readCursor(channelId) {
	const record = readPrivate(cursorDir, `${channelId}.json`);
	if (!record) return "";
	try {
		const messageId = JSON.parse(record).message_id;
		return /^\d+$/.test(String(messageId)) ? String(messageId) : "";
	} catch (_err) {
		return "";
	}
}

function writeCursor(channelId, messageId) {
	publishPrivate(
		cursorDir,
		`${channelId}.json`,
		JSON.stringify({ channel_id: channelId, message_id: messageId, recorded_at: Math.floor(Date.now() / 1000) }),
		600,
	);
}

async function main() {
	try {
		// 1. Get bot user profile
		const meRes = await fetch(`${apiBase}/users/@me`, { headers: apiHeaders });
		if (!meRes.ok) {
			if ([401, 403].includes(meRes.status)) {
				console.log(`x-mode-error self-hosted Discord HTTP ${meRes.status}`);
			}
			process.exit(0);
		}
		const me = await meRes.json();
		const botId = me.id;

		// 2. Resolve channels to scan
		let targetChannels = [...channelIds];
		if (targetChannels.length === 0) {
			// If no channel is explicitly listed, try fetching bot's guilds and their channels
			const guildsRes = await fetch(`${apiBase}/users/@me/guilds`, { headers: apiHeaders });
			if (guildsRes.ok) {
				const guilds = await guildsRes.json();
				for (const guild of guilds.slice(0, 5)) {
					const chRes = await fetch(`${apiBase}/guilds/${guild.id}/channels`, { headers: apiHeaders });
					if (chRes.ok) {
						const channels = await chRes.json();
						for (const ch of channels) {
							if ([0, 5, 11, 12].includes(ch.type) && !excludeIds.includes(ch.id)) {
								targetChannels.push(ch.id);
							}
						}
					}
				}
			}
		}

		// 3. Poll each target channel
		for (const chId of targetChannels) {
			if (excludeIds.includes(chId)) continue;
			const query = new URLSearchParams({ limit: "10" });
			const cursor = readCursor(chId);
			if (cursor) query.set("after", cursor);
			const msgsRes = await fetch(`${apiBase}/channels/${chId}/messages?${query}`, { headers: apiHeaders });
			if (!msgsRes.ok) continue;
			const msgs = await msgsRes.json();
			if (!Array.isArray(msgs)) continue;
			msgs.sort((left, right) => (BigInt(left.id) < BigInt(right.id) ? -1 : 1));

			for (const msg of msgs) {
				if (!/^\d+$/.test(String(msg.id))) continue;
				if (msg.author?.bot) {
					writeCursor(chId, String(msg.id));
					continue;
				}

				// Check if mentioned or DM
				const isDM = !msg.guild_id;
				if (isDM && !allowDms) continue;
				const isMentioned = Array.isArray(msg.mentions) && msg.mentions.some((m) => m.id === botId);
				const contentHasBotMention = msg.content && (msg.content.includes(`<@${botId}>`) || msg.content.includes(`<@!${botId}>`));

				if (!isDM && !isMentioned && !contentHasBotMention) {
					writeCursor(chId, String(msg.id));
					continue;
				}
				if (isDM && !allowDms) {
					writeCursor(chId, String(msg.id));
					continue;
				}

				const reqId = `discord-sh-${msg.id}`;

				// Clean text
				let text = msg.content || "";
				text = text.replace(new RegExp(`<@!?${botId}>`, "g"), "").trim();

				if (!text && (!msg.attachments || msg.attachments.length === 0)) {
					writeCursor(chId, String(msg.id));
					continue;
				}

				const payload = {
					request_id: reqId,
					text: text || "[attachment]",
					author_handle: msg.author?.global_name || msg.author?.username || "user",
					platform: "discord",
					source: "discord-selfhosted",
					reply_max_chars: 1900,
					tweet_id: `discord:${msg.channel_id}:${msg.id}`,
					channel_id: msg.channel_id,
					message_id: msg.id,
					guild_id: msg.guild_id || null,
					in_reply_to: msg.referenced_message
						? {
								author_handle: msg.referenced_message.author?.global_name || msg.referenced_message.author?.username || "user",
								text: msg.referenced_message.content || "",
						  }
						: null,
					in_reply_to_chain: msg.referenced_message
						? [
								{
									author_handle: msg.referenced_message.author?.global_name || msg.referenced_message.author?.username || "user",
									text: msg.referenced_message.content || "",
									kind: "reply",
								},
						  ]
						: [],
					attachments: Array.isArray(msg.attachments) ? msg.attachments.map((a) => ({ url: a.url })) : [],
				};

				const contextRecord = {
					request_id: reqId,
					platform: "discord",
					source: "discord-selfhosted",
					channel_id: msg.channel_id,
					message_id: msg.id,
					reply_max_chars: "1900",
					recorded_at: Math.floor(Date.now() / 1000),
				};

				publishPrivate(inboxDir, `${reqId}.json`, JSON.stringify(payload, null, 2), 600);
				publishPrivate(contextDir, `${reqId}.json`, JSON.stringify(contextRecord, null, 2), 600);
				if (!claimOffer(reqId)) {
					writeCursor(chId, String(msg.id));
					continue;
				}

				writeCursor(chId, String(msg.id));
				console.log(`x-mention ${reqId}`);
				return;
			}
		}
	} catch (_err) {
		// Silent on transient network error
	}
}

main();
