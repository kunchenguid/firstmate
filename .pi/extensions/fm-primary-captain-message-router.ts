import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
	appendFileSync,
	existsSync,
	mkdirSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
	AgentEndEvent,
	ExtensionAPI,
	InputEvent,
	MessageStartEvent,
} from "@earendil-works/pi-coding-agent";
import { classifyFirstmateOperationalText } from "./lib/fm-operational-input.ts";

// Captain-message continuity router hook wiring - Pi primary only.
// Thin trigger layer: bin/fm-captain-message-router.sh owns scoping,
// classification, briefs, ephemeral router spawn, verdict logging, and pending
// handoff staging. This file only feeds settle/submit text, an optional session
// id, and a bounded redacted recent-chat excerpt, then observes the
// machine-readable verdict line.
//
// NOT watcher continuity: unrelated to fm-primary-pi-watch.ts, the turn-end
// guard, or bin/fm-continuity-*. See docs/captain-message-router.md.
//
// Submit is synchronous so the hook can observe the verdict and so bash can
// stage pending routes before the primary turn proceeds. Settle is synchronous
// so session replacement cannot overtake its publication. Fail-open:
// spawn/parse errors never block the captain.
// Submit always reaches the configured router model; bash owns the bound and
// the fail-open fallback.
// Cross-session compact+inject is not implemented; this hook does not spend
// primary context on continuity and never asks the primary agent to run it.

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const router = `${root}/bin/fm-captain-message-router.sh`;
const sessionLockLib = `${root}/bin/fm-session-lock-lib.sh`;
const hookLogDir = `${state}/captain-router`;
const hookLog = `${hookLogDir}/hook.log`;
const marker = `${state}/.pi-captain-router-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const HISTORY_MAX_TURNS = 12;
const HISTORY_MAX_CHARS = 6000;

function rememberHookNote(note: string): void {
	try {
		mkdirSync(hookLogDir, { recursive: true });
		appendFileSync(hookLog, `${new Date().toISOString()}\t${note}\n`);
	} catch {
		// Fail-open: never let hook bookkeeping impede the captain.
	}
}

function sessionArgs(sessionId: string | undefined): string[] {
	if (!sessionId || !/^[A-Za-z0-9._-]+$/.test(sessionId)) return [];
	return ["--session-id", sessionId];
}

type LockOwnership = "owned" | "missing" | "other";

function parentPid(pid: string): string {
	const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], {
		encoding: "utf8",
	});
	if (result.status !== 0) return "";
	return String(result.stdout ?? "").trim();
}

function pidAlive(pid: string): boolean {
	try {
		process.kill(Number(pid), 0);
		return true;
	} catch {
		return false;
	}
}

function lockOwnership(): LockOwnership {
	let lockPid = "";
	try {
		lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
	} catch {
		return "missing";
	}
	if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
	let pid = String(process.pid);
	for (let i = 0; i < 8; i += 1) {
		if (pid === lockPid) return "owned";
		pid = parentPid(pid);
		if (!pid || pid === "1") break;
	}
	return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
	try {
		if (!existsSync(state) || lockOwnership() === "other") return;
		writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
	} catch {
		return;
	}
}

function sessionLockOwned(): boolean {
	try {
		const result = spawnSync(
			"bash",
			[
				"-c",
				'. "$1"; fm_session_lock_owned_by_self "$2"',
				"fm-captain-router-lock-check",
				sessionLockLib,
				state,
			],
			{ stdio: "ignore" },
		);
		return result.status === 0;
	} catch {
		return false;
	}
}

// Synchronous settle path (anchors + brief refresh). stdout discarded.
function runRouterSettle(text: string, sessionId?: string): void {
	if (!text.trim()) return;
	try {
		spawnSync(router, ["--on-settle", ...sessionArgs(sessionId)], {
			input: text,
			stdio: ["pipe", "ignore", "ignore"],
		});
	} catch {
		// Fail-open.
	}
}

// Synchronous submit path: capture the one verdict line. Always fail-open.
function runRouterSubmit(
	text: string,
	sessionId: string | undefined,
	recentChatHistory: string,
): string {
	if (!text.trim()) return "";
	let historyFile = "";
	try {
		if (recentChatHistory) {
			historyFile = join(
				tmpdir(),
				`fm-captain-router-history-${process.pid}-${Date.now()}.txt`,
			);
			writeFileSync(historyFile, recentChatHistory, { mode: 0o600 });
		}
	} catch {
		historyFile = "";
	}
	try {
		const result = spawnSync(
			router,
			[
				"--on-submit",
				...sessionArgs(sessionId),
				...(historyFile ? ["--chat-history-file", historyFile] : []),
			],
			{ input: text, encoding: "utf8" },
		);
		if (result.error) {
			rememberHookNote(`submit-spawn-error ${result.error.message}`);
			return "";
		}
		return String(result.stdout ?? "").trim();
	} catch (error) {
		rememberHookNote(
			`submit-exception ${error instanceof Error ? error.message : "unknown"}`,
		);
		return "";
	} finally {
		if (historyFile) {
			try {
				rmSync(historyFile, { force: true });
			} catch {
				// Fail-open.
			}
		}
	}
}

function parseVerdict(stdout: string): {
	verdict: string;
	target: string;
	confidence: string;
} | null {
	const line = stdout
		.split(/\r?\n/)
		.map((entry) => entry.trim())
		.find((entry) =>
			/^verdict=(same|reroute|new)\s+target=\S+\s+confidence=(det|model)$/.test(
				entry,
			),
		);
	if (!line) return null;
	const verdict = line.match(/^verdict=(\S+)/)?.[1] ?? "";
	const target = line.match(/\btarget=(\S+)/)?.[1] ?? "";
	const confidence = line.match(/\bconfidence=(\S+)/)?.[1] ?? "";
	if (!verdict || !target || !confidence) return null;
	return { verdict, target, confidence };
}

// Surface a durable hook-side pointer for later cross-session delivery without
// injecting into the primary prompt (bash already stages pending/*.route).
function surfaceHandoff(
	verdict: string,
	target: string,
	confidence: string,
): void {
	try {
		mkdirSync(hookLogDir, { recursive: true });
		writeFileSync(
			`${hookLogDir}/last-handoff.txt`,
			[
				`verdict=${verdict}`,
				`target=${target}`,
				`confidence=${confidence}`,
				`staged_at=${new Date().toISOString()}`,
				"note=classification staged; cross-session delivery is not implemented",
				"",
			].join("\n"),
		);
		rememberHookNote(`handoff ${verdict} target=${target} conf=${confidence}`);
	} catch {
		// Fail-open.
	}
}

function contextSessionId(context: unknown): string | undefined {
	try {
		const sessionId = (
			context as {
				sessionManager?: { getSessionId?: () => unknown };
			}
		).sessionManager?.getSessionId?.();
		return typeof sessionId === "string" && sessionId.trim()
			? sessionId.trim()
			: undefined;
	} catch {
		return undefined;
	}
}

// Flatten one message's text blocks. Non-text blocks (tool calls, images) are
// dropped: the router judges the conversation, not the tool traffic.
function messageText(message: unknown): string {
	const content = (message as { content?: unknown })?.content;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.flatMap((block) => {
			const typed = block as { type?: unknown; text?: unknown };
			return typed?.type === "text" && typeof typed.text === "string"
				? [typed.text]
				: [];
		})
		.join("\n");
}

// Bounded recent transcript for the router prompt: the newest user/assistant
// turns only, capped by turn count and characters. Firstmate's own operational
// injections are dropped here and bash redacts again on its side.
function recentTranscript(event: AgentEndEvent): string {
	const messages = event.messages ?? [];
	const lines: string[] = [];
	for (let i = messages.length - 1; i >= 0; i -= 1) {
		if (lines.length >= HISTORY_MAX_TURNS) break;
		const role = (messages[i] as { role?: unknown }).role;
		if (role !== "user" && role !== "assistant") continue;
		const text = messageText(messages[i]).trim();
		if (!text) continue;
		if (
			role === "user" &&
			classifyFirstmateOperationalText(text) !== undefined
		) {
			continue;
		}
		lines.unshift(`${role}: ${text}`);
	}
	const joined = lines.join("\n\n");
	return joined.length > HISTORY_MAX_CHARS
		? joined.slice(joined.length - HISTORY_MAX_CHARS)
		: joined;
}
// Text of the newest assistant message in an agent_end payload. Returns ""
// when there is no assistant text (e.g. a tool-only turn).
function newestAssistantText(event: AgentEndEvent): string {
	const messages = event.messages ?? [];
	for (let i = messages.length - 1; i >= 0; i -= 1) {
		const message = messages[i] as { role?: unknown };
		if (message?.role !== "assistant") continue;
		return messageText(messages[i]);
	}
	return "";
}

export default function (pi: ExtensionAPI) {
	type RunState = {
		sessionId: string | undefined;
		generation: number;
		hasCaptainInput: boolean;
		hasOperationalInput: boolean;
		intakeRecords: Array<{
			prompt: string;
			sessionId: string | undefined;
			generation: number;
			operational: boolean;
		}>;
		fallbackPrompts: Set<string>;
		candidateAssistantText: string;
		candidateRecentChatHistory: string;
	};

	let activeSessionId: string | undefined;
	let sessionBound = false;
	let nextRunGeneration = 0;
	let activeRunGeneration = 0;
	let currentRun: RunState | undefined;
	let recentChatHistory = "";

	function newRun(sessionId: string | undefined): RunState {
		nextRunGeneration += 1;
		activeRunGeneration = nextRunGeneration;
		return {
			sessionId,
			generation: nextRunGeneration,
			hasCaptainInput: false,
			hasOperationalInput: false,
			intakeRecords: [],
			fallbackPrompts: new Set(),
			candidateAssistantText: "",
			candidateRecentChatHistory: "",
		};
	}

	function bindSession(
		context: unknown,
		allowReplacement = false,
	): string | undefined {
		const sessionId = contextSessionId(context);
		if (!sessionBound || (allowReplacement && sessionId !== activeSessionId)) {
			activeSessionId = sessionId;
			currentRun = undefined;
			recentChatHistory = "";
			sessionBound = true;
		}
		return sessionId;
	}

	function runForInput(
		sessionId: string | undefined,
		streamingBehavior: unknown,
	): RunState {
		if (
			!currentRun ||
			currentRun.sessionId !== sessionId ||
			(streamingBehavior === undefined && currentRun.hasCaptainInput)
		) {
			currentRun = newRun(sessionId);
		}
		return currentRun;
	}

	function markOperational(run: RunState): void {
		run.hasOperationalInput = true;
		run.candidateAssistantText = "";
		run.candidateRecentChatHistory = "";
	}

	function classifyCaptainInput(
		prompt: string,
		sessionId: string | undefined,
		run: RunState,
	): void {
		run.hasCaptainInput = true;
		const stdout = runRouterSubmit(prompt, sessionId, recentChatHistory);
		const parsed = parseVerdict(stdout);
		if (!parsed) {
			if (stdout)
				rememberHookNote(`unparseable-verdict ${stdout.slice(0, 200)}`);
			return;
		}
		if (parsed.verdict === "same") return;
		surfaceHandoff(parsed.verdict, parsed.target, parsed.confidence);
	}

	pi.on?.("session_start", (_event, context) => {
		bindSession(context, true);
		markLoaded();
	});

	pi.on("message_start", (event, context) => {
		const message = (event as MessageStartEvent).message as {
			role?: unknown;
			customType?: unknown;
			details?: { kind?: unknown };
		};
		if (
			message.role !== "custom" ||
			message.customType !== "firstmate-sessionstart-nudge" ||
			message.details?.kind !== "session-start"
		) {
			return;
		}
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId || !sessionLockOwned()) return;
		const run = currentRun?.sessionId === sessionId
			? currentRun
			: (currentRun = newRun(sessionId));
		markOperational(run);
	});

	pi.on("input", (event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId) return { action: "continue" };
		const input = event as InputEvent;
		const prompt = String(input.text ?? "");
		if (!prompt.trim()) return { action: "continue" };
		if (!sessionLockOwned()) return { action: "continue" };
		const run = runForInput(sessionId, input.streamingBehavior);
		const operational = classifyFirstmateOperationalText(prompt) !== undefined;
		run.intakeRecords.push({
			prompt,
			sessionId,
			generation: run.generation,
			operational,
		});
		if (operational) {
			markOperational(run);
			return { action: "continue" };
		}
		classifyCaptainInput(prompt, sessionId, run);
		return { action: "continue" };
	});

	// Fallback for a genuine accepted prompt path that did not emit `input`.
	// Ordinary idle input is deduplicated by exact prompt within the run.
	pi.on("before_agent_start", (event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId) return;
		const prompt = String((event as { prompt?: unknown }).prompt ?? "");
		if (!prompt.trim()) return;
		if (!sessionLockOwned()) return;
		const run = currentRun?.sessionId === sessionId
			? currentRun
			: (currentRun = newRun(sessionId));
		if (run.intakeRecords.length > 0 || run.fallbackPrompts.has(prompt)) return;
		run.fallbackPrompts.add(prompt);
		if (classifyFirstmateOperationalText(prompt) !== undefined) {
			markOperational(run);
			return;
		}
		classifyCaptainInput(prompt, sessionId, run);
	});

	pi.on("agent_end", (event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId) return;
		const run = currentRun;
		if (!run || run.sessionId !== sessionId) return;
		if (!run.hasCaptainInput || run.hasOperationalInput) return;
		if (!sessionLockOwned()) {
			currentRun = undefined;
			return;
		}
		run.candidateAssistantText = newestAssistantText(event as AgentEndEvent);
		run.candidateRecentChatHistory = recentTranscript(event as AgentEndEvent);
	});

	pi.on("agent_settled", (_event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId) return;
		const run = currentRun;
		if (!run || run.sessionId !== sessionId) return;
		const generation = run.generation;
		currentRun = undefined;
		if (!run.hasCaptainInput || run.hasOperationalInput) return;
		if (!sessionLockOwned()) return;
		if (activeSessionId !== sessionId || activeRunGeneration !== generation) return;
		runRouterSettle(run.candidateAssistantText, sessionId);
		recentChatHistory = run.candidateRecentChatHistory;
	});

	markLoaded();
}
