// Shared Pi producer for the optional fm-captain-event.v1 outbox.
//
// The Pi turn_end boundary is deliberate: message_end runs before Pi persists
// the assistant message, while turn_end runs after persistence and can bind the
// event to the stable session-entry id.  Only visible assistant text blocks are
// summarized.  Prompts, thinking blocks, tool calls/results, diagnostics, raw
// provider data, terminal output, and environment values never enter the CLI.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const SUMMARY_MAX = 600;
const ANSI_PATTERN = /\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))/g;
const SECRET_PATTERNS: ReadonlyArray<RegExp> = [
  /-----BEGIN [A-Z0-9 ]{0,48}PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]{0,48}PRIVATE KEY-----|$)/gi,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/g,
  /\bsk-[A-Za-z0-9_-]{20,}\b/g,
  /\b(?:Bearer|Authorization\s*:\s*Bearer)\s+[A-Za-z0-9._~+/=-]{12,}/gi,
  /\b(?=[A-Z][A-Z0-9_]{1,127}\s*=)(?=[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|CREDENTIAL|API_KEY|ACCESS_KEY|PRIVATE_KEY))[A-Z][A-Z0-9_]{1,127}\s*=\s*(?:"[^"]{0,4096}"|'[^']{0,4096}'|[^\s,;]{1,4096})/g,
  /\b(?:password|passwd|api[_ -]?key|access[_ -]?token|pairing[_ -]?token|token|secret)\s*[:=]\s*[^\s,;]{6,}/gi,
];

type SourceRole = "primary" | "worker";
type PublisherOptions = {
  fmHome: string;
  fmRoot: string;
  state: string;
  config: string;
  sourceRole: SourceRole;
  taskId?: string;
  incarnation?: string;
};
type PreparedSummary = { text: string; truncated: boolean };
type CommandResult = { ok: boolean; detail: string };
type PublisherRegistration = {
  options: PublisherOptions;
  publication: Promise<void>;
};

const PUBLISHERS = new WeakMap<ExtensionAPI, PublisherRegistration>();

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function visibleAssistantText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .filter((part): part is { type: "text"; text: string } => (
      !!part && typeof part === "object"
      && (part as { type?: unknown }).type === "text"
      && typeof (part as { text?: unknown }).text === "string"
    ))
    .map((part) => part.text)
    .join("\n");
}

function prepareSummary(raw: string): PreparedSummary | null {
  let text = raw.normalize("NFC").replace(ANSI_PATTERN, "");
  text = [...text].map((character) => (
    /[\p{C}\p{Zl}\p{Zp}]/u.test(character) ? " " : character
  )).join("");
  text = text.replace(/\s+/gu, " ").trim();
  for (const pattern of SECRET_PATTERNS) text = text.replace(pattern, "[REDACTED]");
  text = text.replace(/\s+/gu, " ").trim();
  if (!text) return null;
  const codepoints = [...text];
  const truncated = codepoints.length > SUMMARY_MAX;
  return {
    text: codepoints.slice(0, SUMMARY_MAX).join(""),
    truncated,
  };
}

function sourceHomeIdentity(fmHome: string): string {
  const marker = join(fmHome, ".fm-secondmate-home");
  try {
    const info = lstatSync(marker);
    if (info.isSymbolicLink() || !info.isFile() || info.nlink !== 1 || info.size < 2 || info.size > 129) {
      return "invalid-secondmate-home";
    }
    const stored = readFileSync(marker, "utf8");
    if (!/^(?!\.)[A-Za-z0-9][A-Za-z0-9._-]{0,127}\n$/.test(stored)) return "invalid-secondmate-home";
    return `secondmate:${stored.slice(0, -1)}`;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return "main";
    return "invalid-secondmate-home";
  }
}

function activationCandidate(config: string): boolean {
  const flag = join(config, "captain-event-outbox");
  try {
    lstatSync(flag);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== "ENOENT";
  }
}

function run(script: string, args: string[], options: PublisherOptions): Promise<CommandResult> {
  return new Promise((resolve) => {
    execFile("bash", [script, ...args], {
      cwd: options.fmRoot,
      env: {
        ...process.env,
        FM_HOME: options.fmHome,
        FM_ROOT_OVERRIDE: options.fmRoot,
        FM_STATE_OVERRIDE: options.state,
        FM_CONFIG_OVERRIDE: options.config,
      },
      maxBuffer: 64 * 1024,
    }, (error, stdout, stderr) => {
      if (!error) {
        resolve({ ok: true, detail: "" });
        return;
      }
      const diagnostic = (stderr || stdout || error.message).trim();
      resolve({ ok: false, detail: diagnostic || `captain-event emitter exited ${error.code ?? "unknown"}` });
    });
  });
}

function currentEntryId(context: ExtensionContext, message: {
  timestamp?: unknown;
  stopReason?: unknown;
  content?: unknown;
}): string | null {
  const entries = context.sessionManager.getEntries();
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index] as {
      id?: unknown;
      type?: unknown;
      message?: { role?: unknown; timestamp?: unknown; stopReason?: unknown; content?: unknown };
    };
    if (entry.type !== "message" || entry.message?.role !== "assistant") continue;
    if (entry.message.timestamp !== message.timestamp || entry.message.stopReason !== message.stopReason) continue;
    if (visibleAssistantText(entry.message.content) !== visibleAssistantText(message.content)) continue;
    return typeof entry.id === "string" && entry.id ? entry.id : null;
  }
  return null;
}

// Install one producer.  A local promise chain preserves this session's call
// order; the CLI's home-local lock supplies ordering across primary and worker
// processes.  A failed emitter process is retried once with the same identity;
// its pending record makes a simultaneous parent crash recoverable later.
export function installCaptainEventPublisher(pi: ExtensionAPI, options: PublisherOptions): void {
  const existing = PUBLISHERS.get(pi);
  if (existing) {
    if (existing.options.sourceRole === "primary" && options.sourceRole === "worker") {
      existing.options = options;
    }
    return;
  }
  const publisher: PublisherRegistration = { options, publication: Promise.resolve() };
  PUBLISHERS.set(pi, publisher);

  const enqueue = (operation: () => Promise<void>): Promise<void> => {
    const next = publisher.publication.then(operation, operation);
    publisher.publication = next.catch(() => undefined);
    return next;
  };

  pi.on("session_start", () => {
    const active = publisher.options;
    if (!activationCandidate(active.config)) return;
    return enqueue(async () => {
      const script = join(active.fmRoot, "bin", "fm-captain-event.sh");
      const recovered = await run(script, ["recover"], active);
      if (!recovered.ok) throw new Error(`captain-event recovery failed: ${recovered.detail}`);
    });
  });

  pi.on("turn_end", (event, context) => {
    const active = publisher.options;
    const message = event.message;
    if (!message || message.role !== "assistant") return;
    if (["error", "aborted", "deferred", "pending"].includes(message.stopReason)) return;
    if (!activationCandidate(active.config)) return;
    const summary = prepareSummary(visibleAssistantText(message.content));
    if (!summary) return;

    const script = join(active.fmRoot, "bin", "fm-captain-event.sh");
    const sourceHome = sourceHomeIdentity(active.fmHome);
    const sessionId = context.sessionManager.getSessionId();
    const entryId = currentEntryId(context, message);
    if (!entryId) throw new Error("captain-event publisher could not bind the persisted Pi session entry");
    const harnessEventId = `pi:${digest(`${sessionId}\u001fentry:${entryId}`)}`;
    const incarnation = active.sourceRole === "primary"
      ? `pi-session:${digest(sessionId).slice(0, 32)}`
      : active.incarnation;
    if (!incarnation) throw new Error("captain-event worker publisher has no spawn incarnation");
    const kind = `${active.sourceRole}.${message.stopReason === "stop" ? "final" : "message"}`;
    const args = [
      "append",
      "--source", sourceHome,
      "--source-role", active.sourceRole,
      "--incarnation", incarnation,
      "--producer", "pi",
      "--harness-event-id", harnessEventId,
      "--audience", "captain",
      "--kind", kind,
      "--summary", summary.text,
      "--summary-truncated", String(summary.truncated),
      "--occurred-at-ms", String(message.timestamp),
    ];
    if (active.taskId) args.push("--task", active.taskId);

    return enqueue(async () => {
      let emitted = await run(script, args, active);
      if (!emitted.ok) emitted = await run(script, args, active);
      if (!emitted.ok) throw new Error(`captain-event publication failed: ${emitted.detail}`);
    });
  });
}
