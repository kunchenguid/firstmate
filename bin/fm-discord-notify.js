#!/usr/bin/env node
/** Post and bind one proactive decision message using the self-hosted Discord bot. */
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const retryPending = process.argv[2] === "--retry-pending";
const reportMode = process.argv[2] === "--report";
const [trigger, taskId, key, summary, recommendation, channelId, statusTaskId, ...options] = process.argv.slice(retryPending ? 3 : reportMode ? 3 : 2);
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
		"Approve once": "이 1회만 허용",
		"Approve once and remember this": "허용하고 이 경로를 기억",
		"Reject the request": "요청 거부",
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
		content: [
			`**결정 필요** - 작업: ${record.task_id}`,
			"",
			`왜 연락했나: ${localize(record.summary)}`,
			"",
			`**필요한 결정: ${decisionPrompt(record.trigger)}**`,
			"",
			"**선택지**",
			...record.options.map(localize).map((option, index) => `${index + 1}. ${option}`),
			"",
			`**권장안: ${localize(record.recommendation || record.options[0])}**`,
			"",
			"↩️ 답장으로 선택해 주세요.",
		].join("\n"),
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

// Post one plain message, split into Discord's 2000-character limit. A nonce
// rides the first chunk only, so it identifies the whole post for the read-back
// in priorMessage() without making each chunk a separate event.
async function postPlain(channelId, message, nonce) {
	let receipt = null;
	for (let offset = 0; offset < message.length;) {
		let end = Math.min(offset + 2000, message.length);
		if (end < message.length && /[\uD800-\uDBFF]/.test(message[end - 1])) end--;
		const body = { content: message.slice(offset, end), allowed_mentions: { parse: [] } };
		if (offset === 0 && nonce) {
			body.nonce = nonce;
			body.enforce_nonce = true;
		}
		const response = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
			method: "POST",
			headers: { ...apiHeaders, "Content-Type": "application/json" },
			body: JSON.stringify(body),
			signal: AbortSignal.timeout(10000),
		});
		if (!response.ok) throw new Error(`Discord API returned HTTP ${response.status}`);
		receipt = await response.json();
		if (typeof receipt.id !== "string" || receipt.channel_id !== channelId) {
			throw new Error("Discord API returned an invalid report receipt");
		}
		offset = end;
	}
	return receipt.id;
}

// Post one completed-task outcome through the same durable identity contract a
// decision uses: a content-addressed outbox record written with an exclusive
// create before the POST, and a nonce Discord itself deduplicates. That is what
// makes a completion land exactly once across a replayed status line, two
// concurrent senders, a failed delivery, and a crash between the POST and its
// receipt - the read-back in priorMessage() then adopts the message that did
// land instead of posting a second one.
async function postCompletion(recordPath, record, botId, recover) {
	if (recover) {
		const message = await priorMessage(record, botId);
		if (message) {
			saveRecord(recordPath, { ...record, state: "sent", message_id: message.id });
			return message.id;
		}
	}
	const sending = { ...record, state: "sending", attempted_at: Math.floor(Date.now() / 1000) };
	saveRecord(recordPath, sending);
	try {
		const messageId = await postPlain(record.channel_id, record.message, record.nonce);
		saveRecord(recordPath, { ...sending, state: "sent", message_id: messageId });
		return messageId;
	} catch (error) {
		saveRecord(recordPath, { ...sending, state: "failed" });
		throw error;
	}
}

function decisionPrompt(trigger) {
	return ({
		"captain-hold": "보류된 작업을 어떻게 진행할지",
		"ask-user": "제안된 변경을 승인할지",
		"pr-ready": "풀 리퀘스트를 병합할지",
		"perm-ask": "OpenCode 요청에 권한을 줄지",
	})[trigger] || "어떻게 진행할지";
}

async function main() {
  if (reportMode) {
    const [reportChannelId, reportMessage, reportEventId] = process.argv.slice(3);
    if (!token || !/^\d+$/.test(reportChannelId || "") || !reportMessage) {
      throw new Error("report requires a bot token, numeric channel id, and a non-empty message");
    }
    // An event id makes this a completion outcome, which gets the durable
    // exactly-once contract above. Without one the caller wants a fresh
    // one-off post every time (the on-demand fleet snapshot), so it stays a
    // plain delivery.
    if (reportEventId) {
      if (!existsSync(contextDir)) mkdirSync(contextDir, { recursive: true, mode: 0o700 });
      const eventId = `completion\0${reportEventId}`;
      const digest = createHash("sha256").update(eventId).digest("hex");
      const recordPath = join(contextDir, `discord-completion-${digest}.json`);
      const nonce = digest.slice(0, 25);
      // The exclusive create is the concurrency claim: exactly one sender wins
      // it and owns the delivery, so a racing sender never posts a second copy.
      // A record that already exists belongs to someone else - sent, in flight,
      // or awaiting the retry sweep - and is left to that owner.
      let created = false;
      try {
        writeFileSync(recordPath, JSON.stringify({
          schema: "fm-discord-completion-notification.v1",
          kind: "completion-notification",
          state: "pending",
          event_id: digest,
          event: reportEventId,
          message: reportMessage,
          channel_id: reportChannelId,
          nonce,
          recorded_at: Math.floor(Date.now() / 1000),
        }), { flag: "wx", mode: 0o600 });
        created = true;
      } catch (error) {
        if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
      }
      let record;
      try {
        record = JSON.parse(readFileSync(recordPath, "utf8"));
      } catch {
        throw new Error("existing completion notification record is unreadable");
      }
      if (!created) {
        console.log(record.message_id || record.nonce);
        return;
      }
      console.log(await postCompletion(recordPath, record, await getBotId(), false));
      return;
    }
    console.log(await postPlain(reportChannelId, reportMessage));
    return;
  }
  if (retryPending) {
		if (!existsSync(contextDir)) return;
		const pending = [];
		for (const name of readdirSync(contextDir)) {
			if (!name.startsWith("discord-notify-") && !name.startsWith("discord-completion-")) continue;
			if (!name.endsWith(".json")) continue;
			const path = join(contextDir, name);
			try {
				const record = JSON.parse(readFileSync(path, "utf8"));
				const completion = record.schema === "fm-discord-completion-notification.v1";
				if (!completion && record.schema !== "fm-discord-decision-notification.v1") continue;
				if (!["pending", "failed", "sending"].includes(record.state)) continue;
				if (!record.nonce || !record.channel_id) continue;
				if (!completion && !Array.isArray(record.options)) continue;
				if (record.state === "sending" && Date.now() - Number(record.attempted_at || record.recorded_at) * 1000 < staleSendingMs) continue;
				pending.push([path, record, completion]);
			} catch (error) {
				console.error(`fm-discord-notify: ${error instanceof Error ? error.message : "Discord retry failed"}`);
				process.exitCode = 1;
			}
		}
		if (pending.length === 0) return;
		const botId = await getBotId();
		for (const [path, record, completion] of pending) {
			try {
				if (completion) await postCompletion(path, record, botId, true);
				else await sendRecord(path, record, botId, true);
			} catch (error) {
				console.error(`fm-discord-notify: ${error instanceof Error ? error.message : "Discord retry failed"}`);
				process.exitCode = 1;
			}
		}
		return;
	}
	if (!token || !trigger || !taskId || !key || !summary || !recommendation || !channelId || !statusTaskId || options.length === 0) {
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
		recommendation,
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
