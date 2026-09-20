#!/usr/bin/env node
/**
 * Self-hosted Discord connector reply helper.
 * Posts reply messages directly to Discord API using native Node 22 fetch.
 */
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const token = process.env.FM_DISCORD_BOT_TOKEN || process.env.FM_DISCORD_TOKEN;
const fmHome = process.env.FM_HOME || process.env.FM_ROOT || ".";
const stateDir = process.env.FM_STATE_OVERRIDE || join(fmHome, "state");
const contextDir = join(stateDir, "x-context");
const outboxDir = join(stateDir, "x-outbox");
const scriptDir = dirname(fileURLToPath(import.meta.url));
const xLib = join(scriptDir, "fm-x-lib.sh");

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
		const contextRecord = readPrivate(contextDir, `${reqId}.json`);
		if (contextRecord) {
			try {
				const ctx = JSON.parse(contextRecord);
				channelId = channelId || ctx.channel_id;
				messageId = messageId || ctx.message_id;
			} catch (_err) {
				process.exit(1);
			}
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
		publishPrivate(outboxDir, `${reqId}.json`, JSON.stringify(outboxRecord, null, 2), 600);
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
