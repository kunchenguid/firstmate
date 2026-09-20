#!/usr/bin/env node
/**
 * Self-hosted Discord connector reply helper.
 * Posts reply messages directly to Discord API using native Node 22 fetch.
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const token = process.env.FM_DISCORD_BOT_TOKEN || process.env.FM_DISCORD_TOKEN;
const fmHome = process.env.FM_HOME || process.env.FM_ROOT || ".";
const stateDir = process.env.FM_STATE_OVERRIDE || join(fmHome, "state");
const contextDir = join(stateDir, "x-context");
const outboxDir = join(stateDir, "x-outbox");

const args = process.argv.slice(2);
if (args.length < 2) {
	console.error("usage: fm-discord-reply.js <request_id> <payload_json_file> [endpoint] [image_path]");
	process.exit(2);
}

const reqId = args[0];
const payloadFile = args[1];
const endpoint = args[2] || "answer";
const imagePath = args[3] || "";

const dryRun = ["1", "true", "yes"].includes((process.env.FMX_DRY_RUN || "").toLowerCase());

async function main() {
	let reqPayload = {};
	try {
		reqPayload = JSON.parse(readFileSync(payloadFile, "utf8"));
	} catch (e) {
		console.error(`fm-discord-reply: cannot read payload file: ${payloadFile}`);
		process.exit(1);
	}

	let channelId = reqPayload.channel_id;
	let messageId = reqPayload.message_id;

	if (!channelId || !messageId) {
		const contextFile = join(contextDir, `${reqId}.json`);
		if (existsSync(contextFile)) {
			try {
				const ctx = JSON.parse(readFileSync(contextFile, "utf8"));
				channelId = channelId || ctx.channel_id;
				messageId = messageId || ctx.message_id;
			} catch (_) {}
		}
	}

	if (dryRun && !channelId) {
		channelId = "dry-run-channel";
	}

	if (!channelId) {
		console.error(`fm-discord-reply: channel_id missing for ${reqId}`);
		process.exit(1);
	}

	const text = reqPayload.text || (Array.isArray(reqPayload.texts) ? reqPayload.texts.join("\n\n") : "");
	const chunks = Array.isArray(reqPayload.texts) && reqPayload.texts.length > 0 ? reqPayload.texts : [text];

	if (dryRun) {
		if (!existsSync(outboxDir)) mkdirSync(outboxDir, { recursive: true, mode: 0o700 });
		const outboxRecord = {
			request_id: reqId,
			platform: "discord",
			source: "discord-selfhosted",
			text: text,
			texts: chunks,
			endpoint: endpoint,
		};
		if (imagePath) {
			outboxRecord.image = { source_path: imagePath };
		}
		writeFileSync(join(outboxDir, `${reqId}.json`), JSON.stringify(outboxRecord, null, 2), { mode: 0o600 });
		console.error(`fm-discord-reply: DRY RUN - would POST reply to Discord channel ${channelId} (recorded: state/x-outbox/${reqId}.json)`);
		console.log(reqId);
		process.exit(0);
	}

	if (!token) {
		console.error("fm-discord-reply: self-hosted Discord mode not configured (no FM_DISCORD_BOT_TOKEN)");
		process.exit(1);
	}

	const apiHeaders = {
		Authorization: `Bot ${token}`,
		"User-Agent": "FirstmateDiscordSelfHosted/1.0",
	};

	let lastMsgId = messageId;
	for (let i = 0; i < chunks.length; i++) {
		const chunkText = chunks[i];
		const isFirst = i === 0;

		const msgPayload = {
			content: chunkText,
			message_reference: lastMsgId
				? {
						message_id: lastMsgId,
						fail_if_not_exists: false,
				  }
				: undefined,
		};

		let res;
		if (isFirst && imagePath && existsSync(imagePath)) {
			const formData = new FormData();
			formData.append("payload_json", JSON.stringify(msgPayload));
			const fileBuffer = readFileSync(imagePath);
			const fileName = imagePath.split("/").pop() || "image.png";
			formData.append("files[0]", new Blob([fileBuffer]), fileName);

			res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
				method: "POST",
				headers: apiHeaders,
				body: formData,
			});
		} else {
			res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
				method: "POST",
				headers: { ...apiHeaders, "Content-Type": "application/json" },
				body: JSON.stringify(msgPayload),
			});
		}

		if (!res.ok) {
			const errText = await res.text();
			console.error(`fm-discord-reply: Discord API returned HTTP ${res.status}: ${errText}`);
			process.exit(1);
		}

		const sentMsg = await res.json();
		if (sentMsg && sentMsg.id) {
			lastMsgId = sentMsg.id;
		}
	}

	console.log(reqId);
}

main();
