#!/usr/bin/env node
/** Post and bind one proactive decision message using the self-hosted Discord bot. */
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const retryPending = process.argv[2] === "--retry-pending";
const [trigger, taskId, key, summary, channelId, statusTaskId, ...options] = process.argv.slice(retryPending ? 3 : 2);
const token = process.env.FM_DISCORD_BOT_TOKEN;
const home = process.env.FM_HOME || process.env.FM_ROOT || ".";
const stateDir = process.env.FM_STATE_OVERRIDE || join(home, "state");
const contextDir = join(stateDir, "x-context");
const staleSendingMs = 30000;
const apiHeaders = { Authorization: `Bot ${token}`, "User-Agent": "FirstmateDiscordSelfHosted/1.0" };

function saveRecord(path, record) {
	const temporary = `${path}.${process.pid}.tmp`;
	writeFileSync(temporary, JSON.stringify(record), { mode: 0o600 });
	renameSync(temporary, path);
}

async function getBotId() {
	const response = await fetch("https://discord.com/api/v10/users/@me", { headers: apiHeaders, signal: AbortSignal.timeout(10000) });
	if (!response.ok) throw new Error(`Discord profile returned HTTP ${response.status}`);
	return (await response.json()).id;
}

async function priorMessage(record, botId) {
	let before = "";
	const since = Number(record.recorded_at) * 1000;
	for (;;) {
		const query = new URLSearchParams({ limit: "100" });
		if (before) query.set("before", before);
		const response = await fetch(`https://discord.com/api/v10/channels/${record.channel_id}/messages?${query}`, { headers: apiHeaders });
		if (!response.ok) throw new Error(`Discord history returned HTTP ${response.status}`);
		const messages = await response.json();
		if (!Array.isArray(messages)) throw new Error("Discord history returned an invalid response");
		if (messages.some((message) => message.author?.id === botId && message.nonce === record.nonce)) {
			return messages.find((message) => message.author?.id === botId && message.nonce === record.nonce);
		}
		if (messages.length === 0) return null;
		const oldest = messages[messages.length - 1];
		if (!oldest?.id || Date.parse(oldest.timestamp) < since) return null;
		before = oldest.id;
	}
}

function localize(value) {
	if (value.startsWith("A pull request is ready for your review.")) {
		return `풀 리퀘스트 검토가 필요합니다.${value.slice("A pull request is ready for your review.".length)}`;
	}
	return ({
		"A proposed change needs your decision.": "제안된 변경 사항에 대한 결정이 필요합니다.",
		"A task is waiting for your decision.": "작업에 대한 결정이 필요합니다.",
		"Approve the proposed change": "제안된 변경 사항 승인",
		"Keep the current behavior": "현재 동작 유지",
		"Merge": "병합",
		"Leave it open": "열린 상태로 두기",
		"Continue with the request": "요청대로 계속 진행",
		"Leave it on hold": "보류 상태로 두기",
	})[value] || value;
}

async function sendRecord(path, record, botId, recover) {
	if (recover) {
		const message = await priorMessage(record, botId);
		if (message) {
			saveRecord(path, { ...record, state: "sent", message_id: message.id });
			return;
		}
	}
	const sending = { ...record, state: "sending", attempted_at: Math.floor(Date.now() / 1000) };
	saveRecord(path, sending);
	const payload = {
		content: `작업: ${record.task_id}\n${localize(record.summary)}\n선택지: ${record.options.map(localize).join(" / ")}\n이 메시지에 바로 답장해 주세요.`,
		allowed_mentions: { parse: [] },
		nonce: record.nonce,
		enforce_nonce: true,
	};
	try {
		const response = await fetch(`https://discord.com/api/v10/channels/${record.channel_id}/messages`, {
			method: "POST",
			headers: { Authorization: `Bot ${token}`, "Content-Type": "application/json", "User-Agent": "FirstmateDiscordSelfHosted/1.0" },
			body: JSON.stringify(payload),
			signal: AbortSignal.timeout(10000),
		});
		if (!response.ok) throw new Error(`Discord API returned HTTP ${response.status}`);
		const message = await response.json();
		if (typeof message.id !== "string" || message.channel_id !== record.channel_id) {
			throw new Error("Discord API returned an invalid notification receipt");
		}
		saveRecord(path, { ...sending, state: "sent", message_id: message.id });
	} catch (error) {
		saveRecord(path, { ...sending, state: "failed" });
		throw error;
	}
}

async function main() {
	if (retryPending) {
		if (!existsSync(contextDir)) return;
		const pending = [];
		for (const name of readdirSync(contextDir)) {
			if (!name.startsWith("discord-notify-") || !name.endsWith(".json")) continue;
			const path = join(contextDir, name);
			try {
				const record = JSON.parse(readFileSync(path, "utf8"));
				if (record.schema !== "fm-discord-decision-notification.v1" || !["pending", "failed", "sending"].includes(record.state)) continue;
				if (!record.nonce || !record.channel_id || !Array.isArray(record.options)) continue;
				if (record.state === "sending" && Date.now() - Number(record.attempted_at || record.recorded_at) * 1000 < staleSendingMs) continue;
				pending.push([path, record]);
			} catch (error) {
				console.error(`fm-discord-notify: ${error instanceof Error ? error.message : "Discord retry failed"}`);
				process.exitCode = 1;
			}
		}
		if (pending.length === 0) return;
		const botId = await getBotId();
		for (const [path, record] of pending) {
			try {
				await sendRecord(path, record, botId, true);
			} catch (error) {
				console.error(`fm-discord-notify: ${error instanceof Error ? error.message : "Discord retry failed"}`);
				process.exitCode = 1;
			}
		}
		return;
	}
	if (!token || !trigger || !taskId || !key || !summary || !channelId || !statusTaskId || options.length === 0) {
		console.error("fm-discord-notify: required configuration or notification data is missing");
		process.exitCode = 2;
		return;
	}
	if (!existsSync(contextDir)) mkdirSync(contextDir, { recursive: true, mode: 0o700 });
	const eventId = `${trigger}\0${taskId}\0${key}`;
	const digest = createHash("sha256").update(eventId).digest("hex");
	const recordPath = join(contextDir, `discord-notify-${digest}.json`);
	const nonce = digest.slice(0, 25);
	if (existsSync(recordPath)) {
		let prior;
		try {
			prior = JSON.parse(readFileSync(recordPath, "utf8"));
		} catch {
			console.error("fm-discord-notify: existing notification record is unreadable");
			process.exitCode = 1;
			return;
		}
		if (prior.state === "sent" || prior.state === "sending" && Date.now() - Number(prior.attempted_at || prior.recorded_at) * 1000 < staleSendingMs) {
			console.log(key);
			return;
		}
		const botId = await getBotId();
		await sendRecord(recordPath, prior, botId, true);
		console.log(key);
		return;
	}

	const initialRecord = {
		schema: "fm-discord-decision-notification.v1",
		kind: "decision-notification",
		state: "pending",
		event_id: digest,
		trigger,
		task_id: taskId,
		key,
		status_task_id: statusTaskId,
		summary,
		options,
		channel_id: channelId,
		nonce,
		recorded_at: Math.floor(Date.now() / 1000),
	};
	try {
		writeFileSync(recordPath, JSON.stringify(initialRecord), { flag: "wx", mode: 0o600 });
	} catch (error) {
		if (error instanceof Error && "code" in error && error.code === "EEXIST") {
			console.log(key);
			return;
		}
		throw error;
	}

	const botId = await getBotId();
	await sendRecord(recordPath, initialRecord, botId, false);
	console.log(key);
}

main().catch((error) => {
	console.error(`fm-discord-notify: ${error instanceof Error ? error.message : "Discord send failed"}`);
	process.exitCode = 1;
});
