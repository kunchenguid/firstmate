import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { classifyFirstmateCurrentOperationalText } from "./lib/fm-operational-input.ts";
import {
  captureCaptainResponse,
  resolveCaptainInboxPaths,
} from "./lib/fm-captain-inbox-store.mjs";

// Captain's Inbox capture is intentionally an in-process Pi-only integration.
// message_end supplies a finalized assistant message, while agent_settled proves
// no retry, tool loop, compaction retry, or queued continuation remains. The
// guard below permits only TUI input entered by the captain and drops all
// Firstmate operational envelopes before a response becomes a capture candidate.
const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const paths = resolveCaptainInboxPaths({ home: fmHome, state, config });

type Candidate = {
  body: string;
  completedAt: string;
  sessionId: string;
};

type TextPart = { type?: unknown; text?: unknown };

type AssistantMessage = {
  role?: unknown;
  content?: unknown;
  stopReason?: unknown;
  timestamp?: unknown;
};

function operationalInput(text: unknown): boolean {
  if (typeof text !== "string" || !text.startsWith("\u2063FIRSTMATE_OP: ")) return false;
  return Boolean(classifyFirstmateCurrentOperationalText(text));
}

function finalizedText(message: AssistantMessage): string | undefined {
  if (message.role !== "assistant" || message.stopReason !== "stop" || !Array.isArray(message.content)) {
    return undefined;
  }
  const text = message.content
    .filter((part): part is TextPart => Boolean(part) && typeof part === "object")
    .filter((part) => part.type === "text" && typeof part.text === "string")
    .map((part) => part.text as string)
    .join("\n");
  return text.trim() ? text : undefined;
}

function completedAt(message: AssistantMessage): string | undefined {
  if (typeof message.timestamp !== "number" || !Number.isFinite(message.timestamp)) return undefined;
  const value = new Date(message.timestamp);
  return Number.isNaN(value.valueOf()) ? undefined : value.toISOString();
}

function sessionId(ctx: unknown): string | undefined {
  const value = (ctx as { sessionManager?: { getSessionId?: () => unknown } })
    ?.sessionManager?.getSessionId?.();
  return typeof value === "string" && value ? value : undefined;
}

export default function (pi: ExtensionAPI) {
  const pendingInputEligibility: boolean[] = [];
  let activeRunEligible = false;
  let candidate: Candidate | undefined;

  pi.on("input", (event) => {
    const input = event as { source?: unknown; text?: unknown };
    pendingInputEligibility.push(input.source === "interactive" && !operationalInput(input.text));
  });

  pi.on("before_agent_start", (event) => {
    const prompt = (event as { prompt?: unknown }).prompt;
    activeRunEligible = (pendingInputEligibility.shift() ?? false) && !operationalInput(prompt);
    candidate = undefined;
  });

  pi.on("message_end", (event, ctx) => {
    if (!activeRunEligible) return;
    const message = (event as { message?: AssistantMessage }).message;
    if (!message) return;
    const body = finalizedText(message);
    const timestamp = completedAt(message);
    const currentSessionId = sessionId(ctx);
    if (!body || !timestamp || !currentSessionId) return;
    candidate = { body, completedAt: timestamp, sessionId: currentSessionId };
  });

  pi.on("agent_settled", (_event, ctx) => {
    const settled = ctx as { isIdle?: () => boolean; mode?: unknown };
    const completed = candidate;
    candidate = undefined;
    if (
      !completed ||
      settled.mode !== "tui" ||
      (typeof settled.isIdle === "function" && !settled.isIdle())
    ) {
      return;
    }

    const harness = process.env.FM_PI_HARNESS === "pi-signed" ? "pi-signed" : "pi";
    // Never await local persistence here. Pi's existing turn-end guard also
    // observes agent_settled, and capture must not delay its supervision path.
    void captureCaptainResponse(paths, {
      harness,
      sessionId: completed.sessionId,
      completedAt: completed.completedAt,
      body: completed.body,
    }).catch(() => {
      // Inbox persistence is optional and must never interrupt the primary session.
    });
  });
}
