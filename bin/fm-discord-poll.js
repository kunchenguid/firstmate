#!/usr/bin/env node
/**
 * Self-hosted Discord connector poll helper.
 * Uses native Node 22 fetch to poll Discord REST API for bot mentions.
 */
import { writeFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync } from "node:fs";
import { join } from "node:path";

const token = process.env.FM_DISCORD_BOT_TOKEN || process.env.FM_DISCORD_TOKEN;
if (!token) {
	process.exit(0);
}

const fmHome = process.env.FM_HOME || process.env.FM_ROOT || ".";
const stateDir = process.env.FM_STATE_OVERRIDE || join(fmHome, "state");
const inboxDir = join(stateDir, "x-inbox");
const contextDir = join(stateDir, "x-context");

const channelIds = (process.env.FM_DISCORD_CHANNELS || process.env.FM_DISCORD_CHANNEL_ID || "")
	.split(",")
	.map((s) => s.trim())
	.filter(Boolean);

const excludeIds = (process.env.FM_DISCORD_EXCLUDES || process.env.FM_DISCORD_EXCLUDE_CHANNELS || "1551134713727426570")
	.split(",")
	.map((s) => s.trim())
	.filter(Boolean);

const allowDMs = (process.env.FM_DISCORD_ALLOW_DMS || process.env.FM_DISCORD_DMS || "true").toLowerCase() !== "false";
const authorizedUserIds = new Set((process.env.FM_DISCORD_AUTHORIZED_USER_IDS || "").split(",").map((s) => s.trim()).filter(Boolean));

const cursorDir = join(stateDir, "x-context");
function cursorFile(chId) {
	return join(cursorDir, `discord-cursor-${chId}.json`);
}
function readCursor(chId) {
	try {
		const raw = readFileSync(cursorFile(chId), "utf8");
		return JSON.parse(raw).last_id || null;
	} catch (_err) {
		return null;
	}
}
function writeCursor(chId, lastId) {
	if (!existsSync(cursorDir)) mkdirSync(cursorDir, { recursive: true, mode: 0o700 });
	writeFileSync(cursorFile(chId), JSON.stringify({ last_id: lastId }), { mode: 0o600 });
}

function readDecisionNotifications() {
	const byMessageId = new Map();
	if (!existsSync(contextDir)) return byMessageId;
	for (const name of readdirSync(contextDir)) {
		if (!name.startsWith("discord-notify-") || !name.endsWith(".json")) continue;
		const path = join(contextDir, name);
		try {
			const record = JSON.parse(readFileSync(path, "utf8"));
			if (
				record.schema === "fm-discord-decision-notification.v1" &&
				record.kind === "decision-notification" &&
				record.state === "sent" &&
				typeof record.message_id === "string" &&
				typeof record.channel_id === "string" &&
				typeof record.task_id === "string" &&
				typeof record.key === "string"
			) {
				byMessageId.set(record.message_id, { path, record });
			}
		} catch {}
	}
	return byMessageId;
}

function persistDecisionReply(notification, msg, reqId) {
	if (!existsSync(inboxDir)) mkdirSync(inboxDir, { recursive: true, mode: 0o700 });
	if (!existsSync(contextDir)) mkdirSync(contextDir, { recursive: true, mode: 0o700 });
	const inboxFile = join(inboxDir, `${reqId}.json`);
	const contextFile = join(contextDir, `${reqId}.json`);
	const offeredFile = join(contextDir, `${reqId}.offered.json`);
	if (existsSync(offeredFile)) return false;
	const payload = {
		request_id: reqId,
		text: msg.content.trim(),
		author_handle: msg.author?.global_name || msg.author?.username || "captain",
		platform: "discord",
		source: "discord-selfhosted-decision",
		reply_max_chars: 1900,
		tweet_id: `discord:${msg.channel_id}:${msg.id}`,
		channel_id: msg.channel_id,
		message_id: msg.id,
		guild_id: msg.guild_id || null,
		decision: {
			task_id: notification.record.task_id,
			status_task_id: notification.record.status_task_id || notification.record.task_id,
			key: notification.record.key,
			trigger: notification.record.trigger,
			options: notification.record.options,
		},
		replied_to: {
			channel_id: notification.record.channel_id,
			message_id: notification.record.message_id,
			content: `Task: ${notification.record.task_id} | ${notification.record.summary}`,
		},
	};
	const context = {
		request_id: reqId,
		platform: "discord",
		source: "discord-selfhosted",
		channel_id: msg.channel_id,
		message_id: msg.id,
		reply_max_chars: "1900",
		recorded_at: Math.floor(Date.now() / 1000),
	};
	if (existsSync(inboxFile)) {
		try {
			const captured = JSON.parse(readFileSync(inboxFile, "utf8"));
			if (
				captured.request_id !== reqId ||
				captured.source !== "discord-selfhosted-decision" ||
				captured.message_id !== msg.id ||
				captured.channel_id !== msg.channel_id ||
				captured.decision?.task_id !== notification.record.task_id ||
				captured.decision?.key !== notification.record.key
			) return false;
		} catch {
			return false;
		}
	} else {
		writeFileSync(inboxFile, JSON.stringify(payload, null, 2), { flag: "wx", mode: 0o600 });
	}
	if (!existsSync(contextFile)) {
		try {
			writeFileSync(contextFile, JSON.stringify(context, null, 2), { flag: "wx", mode: 0o600 });
		} catch (error) {
			if (error.code !== "EEXIST") throw error;
		}
	}
	try {
		writeFileSync(offeredFile, JSON.stringify({ request_id: reqId, recorded_at: Math.floor(Date.now() / 1000) }), { flag: "wx", mode: 0o600 });
	} catch (error) {
		if (error.code === "EEXIST") return false;
		throw error;
	}
	const updated = {
		...notification.record,
		replied_to: { message_id: msg.id, author_id: msg.author?.id || "", recorded_at: Math.floor(Date.now() / 1000) },
	};
	const temporary = `${notification.path}.${process.pid}.tmp`;
	writeFileSync(temporary, JSON.stringify(updated), { mode: 0o600 });
	renameSync(temporary, notification.path);
	notification.record = updated;
	return true;
}

const apiHeaders = {
	Authorization: `Bot ${token}`,
	"User-Agent": "FirstmateDiscordSelfHosted/1.0",
};

async function main() {
	try {
		// 1. Get bot user profile
		const meRes = await fetch("https://discord.com/api/v10/users/@me", { headers: apiHeaders });
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
			const guildsRes = await fetch("https://discord.com/api/v10/users/@me/guilds", { headers: apiHeaders });
			if (guildsRes.ok) {
				const guilds = await guildsRes.json();
				for (const guild of guilds.slice(0, 5)) {
					const chRes = await fetch(`https://discord.com/api/v10/guilds/${guild.id}/channels`, { headers: apiHeaders });
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
			if (allowDMs) {
				const dmsRes = await fetch("https://discord.com/api/v10/users/@me/channels", { headers: apiHeaders });
				if (dmsRes.ok) {
					const dms = await dmsRes.json();
					if (Array.isArray(dms)) {
						for (const dm of dms) {
							if ([1, 3].includes(dm.type) && typeof dm.id === "string" && !excludeIds.includes(dm.id)) {
								targetChannels.push(dm.id);
							}
						}
					}
				}
			}
		}

		// 3. Poll each target channel
		const decisionNotifications = readDecisionNotifications();
		for (const chId of targetChannels) {
			if (excludeIds.includes(chId)) continue;
			const cursor = readCursor(chId);
			const url = cursor
				? `https://discord.com/api/v10/channels/${chId}/messages?after=${cursor}&limit=100`
				: `https://discord.com/api/v10/channels/${chId}/messages?limit=10`;
			const msgsRes = await fetch(url, { headers: apiHeaders });
			if (!msgsRes.ok) continue;
			const msgs = await msgsRes.json();
			if (!Array.isArray(msgs)) continue;

			// Discord returns newest-first; process oldest-first so the cursor
			// only advances past messages actually handled.
			const ordered = [...msgs].reverse();

			for (const msg of ordered) {
				if (msg.author?.bot) continue;
				const referencedMessageId = msg.message_reference?.message_id;
				const notification = referencedMessageId ? decisionNotifications.get(referencedMessageId) : undefined;
				if (notification) {
					if (!authorizedUserIds.has(msg.author?.id) || notification.record.channel_id !== msg.channel_id || notification.record.replied_to) continue;
					if (typeof msg.content !== "string" || !msg.content.trim()) continue;
					const reqId = `discord-sh-${msg.id}`;
					if (persistDecisionReply(notification, msg, reqId)) console.log(`x-mention ${reqId}`);
					continue;
				}

				// Check if mentioned or DM
				const isDM = !msg.guild_id;
				if (isDM && !allowDMs) continue;
				const isMentioned = Array.isArray(msg.mentions) && msg.mentions.some((m) => m.id === botId);
				const contentHasBotMention = msg.content && (msg.content.includes(`<@${botId}>`) || msg.content.includes(`<@!${botId}>`));

				if (!isDM && !isMentioned && !contentHasBotMention) {
					continue;
				}

				const reqId = `discord-sh-${msg.id}`;
				const offeredFile = join(contextDir, `${reqId}.offered.json`);
				if (existsSync(offeredFile)) {
					continue;
				}

				// Clean text
				let text = msg.content || "";
				text = text.replace(new RegExp(`<@!?${botId}>`, "g"), "").trim();

				if (!text && (!msg.attachments || msg.attachments.length === 0)) {
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

				if (!existsSync(inboxDir)) mkdirSync(inboxDir, { recursive: true, mode: 0o700 });
				if (!existsSync(contextDir)) mkdirSync(contextDir, { recursive: true, mode: 0o700 });

				const inboxFile = join(inboxDir, `${reqId}.json`);
				const contextFile = join(contextDir, `${reqId}.json`);

				writeFileSync(inboxFile, JSON.stringify(payload, null, 2), { mode: 0o600 });
				writeFileSync(contextFile, JSON.stringify(contextRecord, null, 2), { mode: 0o600 });
				writeFileSync(offeredFile, JSON.stringify({ request_id: reqId, recorded_at: Math.floor(Date.now() / 1000) }), { mode: 0o600 });

				console.log(`x-mention ${reqId}`);
			}
			if (ordered.length > 0) {
				writeCursor(chId, ordered[ordered.length - 1].id);
			}
		}
	} catch (_err) {
		// Silent on transient network error
	}
}

main();
