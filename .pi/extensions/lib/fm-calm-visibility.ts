import {
  getMarkdownTheme,
  type ExtensionAPI,
  UserMessageComponent,
} from "@earendil-works/pi-coding-agent";
export const CALM_TRANSCRIPT_CLASSES = [
  "genuine-user-prompt",
  "genuine-agent-response",
  "assistant-working-note",
  "routine-supervision-note",
  "assistant-thinking",
  "assistant-tool-call",
  "tool-result",
  "tool-image",
  "user-bash",
  "skill-invocation",
  "custom-message",
  "custom-entry",
  "compaction-summary",
  "branch-summary",
  "working-status",
  "command-status",
  "system-notice",
  "cache-notice",
  "project-trust-warning",
  "synthetic-user",
  "synthetic-assistant",
  "unknown",
] as const;

export type CalmTranscriptClass = (typeof CALM_TRANSCRIPT_CLASSES)[number];

// Calm is on or off. Distinct streamed thinking lines are kept as display-only content
// on the active assistant row; the assistant layout separately retains ownership of
// thinking Calm has suppressed so toggling off cannot reveal superseded planning history.
const CALM_VISIBLE_CLASSES = new Set<CalmTranscriptClass>([
  "genuine-user-prompt",
  "genuine-agent-response",
  "assistant-working-note",
  "working-status",
]);

// Legacy session entries from Calm versions before 2026-07-23 retain this
// presentation type. New operational input stays user-role and is never rerouted.
export const FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE = "firstmate-synthetic-input-presentation";
export const FIRSTMATE_CALM_PRESENTATION_EVENT = "firstmate:calm-presentation";

export type CalmPresentationState = {
  active: boolean;
  stockExportRendering: boolean;
};

export const FIRSTMATE_SYNTHETIC_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "from-firstmate",
  "launch-brief",
  "legacy-operational",
] as const;

export type FirstmateSyntheticKind = (typeof FIRSTMATE_SYNTHETIC_KINDS)[number];
type FirstmateSyntheticPresentation = {
  content: string;
  kind: FirstmateSyntheticKind;
};

let calm = false;
let stockExportRendering = false;
let calmRunActive = false;
let calmSteps: string[] = [];
let calmActivity: string[] = [];
let calmTickerOffset = 0;
let calmTickerWidth = 0;
let calmTickerTimer: ReturnType<typeof setInterval> | undefined;
const calmPresentationSubscribers = new Set<() => void>();
let calmRenderRequester: (() => void) | undefined;
const CALM_MAX_ACTIVITY = 12;

const notifyCalmPresentation = (): void => {
  for (const subscriber of calmPresentationSubscribers) subscriber();
  calmRenderRequester?.();
};

const stopCalmTicker = (): void => {
  if (calmTickerTimer !== undefined) clearInterval(calmTickerTimer);
  calmTickerTimer = undefined;
  calmTickerOffset = 0;
};

const calmActivityNeedsTicker = (width: number): boolean => {
  const joined = calmActivity.join("  ·  ");
  return calmRunActive && calm && joined.length > width && width > 0;
};

const startCalmTicker = (): void => {
  if (calmTickerTimer !== undefined) return;
  calmTickerTimer = setInterval(() => {
    if (!calmActivityNeedsTicker(calmTickerWidth)) {
      stopCalmTicker();
      return;
    }
    calmTickerOffset += 1;
    notifyCalmPresentation();
  }, 420);
  (calmTickerTimer as unknown as { unref?: () => void }).unref?.();
};

export function subscribeCalmPresentation(subscriber: () => void): () => void {
  calmPresentationSubscribers.add(subscriber);
  return () => calmPresentationSubscribers.delete(subscriber);
}

export function setCalmRenderRequester(requester: (() => void) | undefined): void {
  calmRenderRequester = requester;
}

export function setCalmRunActive(active: boolean): void {
  calmRunActive = active;
  if (!active) {
    calmActivity = [];
    stopCalmTicker();
    calmRenderRequester = undefined;
  }
  notifyCalmPresentation();
}

export function currentCalmSteps(): readonly string[] {
  return calmSteps;
}

export function appendCalmStep(step: string): void {
  const normalized = step.trim().replace(/\s+/g, " ");
  if (normalized === "" || calmSteps.includes(normalized)) return;
  calmSteps = [...calmSteps, normalized];
  calmActivity = [];
  stopCalmTicker();
  notifyCalmPresentation();
}

export function clearCalmSteps(): void {
  calmSteps = [];
  calmActivity = [];
  stopCalmTicker();
  calmRenderRequester = undefined;
  notifyCalmPresentation();
}

export function appendCalmActivity(activity: string): void {
  if (!calmRunActive || !calm || activity === "" || calmActivity.includes(activity)) return;
  calmActivity = [...calmActivity, activity].slice(-CALM_MAX_ACTIVITY);
  calmTickerOffset = 0;
  notifyCalmPresentation();
}

export function currentCalmActivity(): readonly string[] {
  return calmActivity;
}

export function calmTickerText(width: number): string {
  calmTickerWidth = width;
  const joined = calmActivity.join("  ·  ");
  if (!calmActivityNeedsTicker(width)) {
    stopCalmTicker();
    return joined;
  }
  startCalmTicker();
  const cycle = `${joined}   `;
  const start = calmTickerOffset % cycle.length;
  return `${cycle}${cycle}`.slice(start, start + width);
}

const CALM_SENSITIVE_TEXT = /(?:api[_-]?key|auth(?:orization)?|credential(?:s)?|password|secret|token)(?:$|[._/\\-])/i;

function safePath(value: unknown, cwd: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  let path = value.trim().replace(/[\\\x00-\x1f\x7f]+/g, "").replace(/[\\]+/g, "/");
  if (path === "") return "<redacted>";
  if (/^(?:\/private)?\/tmp(?:\/|$)|^\/var\/folders(?:\/|$)/i.test(path)) {
    return `<temp>/${path.split("/").filter(Boolean).at(-1) ?? "item"}`;
  }
  if (CALM_SENSITIVE_TEXT.test(path)) return "<redacted>";
  const base = typeof cwd === "string" ? cwd.replace(/[\\]+/g, "/").replace(/\/+$/, "") : "";
  if (base && (path === base || path.startsWith(`${base}/`))) path = path.slice(base.length).replace(/^\/+/, "");
  else if (path.startsWith("/")) {
    const parts = path.split("/").filter(Boolean);
    path = parts.length > 2 ? `…/${parts.slice(-2).join("/")}` : `…/${parts.join("/")}`;
  }
  return path.slice(0, 160);
}

function commandLabel(value: unknown): string {
  if (typeof value !== "string") return "command";
  const tokens = value.replace(/[\x00-\x1f\x7f]+/g, " ").trim().split(/\s+/).filter(Boolean);
  while (tokens[0]?.includes("=") && !tokens[0].startsWith("=")) tokens.shift();
  const command = tokens[0]?.split("/").at(-1) ?? "command";
  const subcommand = tokens[1] && /^[a-z][a-z0-9._-]*$/i.test(tokens[1]) ? ` ${tokens[1]}` : "";
  return `${command}${subcommand}`.slice(0, 48);
}

export function calmActivityForTool(toolName: unknown, args: unknown, cwd?: unknown): string {
  const name = typeof toolName === "string" ? toolName.toLowerCase() : "tool";
  const input = args && typeof args === "object" ? args as Record<string, unknown> : {};
  if (name === "bash" || name === "powershell") return `${name} · ${commandLabel(input.command)}`;
  const path = safePath(input.path ?? input.searchDir, cwd);
  if (path !== undefined && /^(?:read|edit|write|grep|find|ls)$/.test(name)) return `${name} · ${path}`;
  return name;
}

export function calmTranscriptClassIsVisible(itemClass: CalmTranscriptClass): boolean {
  return CALM_VISIBLE_CLASSES.has(itemClass);
}

export function setCalmPresentation(active: boolean): void {
  calm = active;
  if (!active) {
    calmActivity = [];
    stopCalmTicker();
    calmRenderRequester = undefined;
  }
}

export function setCalmStockExportRendering(active: boolean): void {
  stockExportRendering = active;
}

export function calmPresentationIsActive(): boolean {
  return calm;
}

export function calmPresentationHides(itemClass: CalmTranscriptClass): boolean {
  return calm && !stockExportRendering && !calmTranscriptClassIsVisible(itemClass);
}

export function calmStockExportRenderingIsActive(): boolean {
  return stockExportRendering;
}

export function registerFirstmateSyntheticPresentation(pi: ExtensionAPI): void {
  pi.registerEntryRenderer<FirstmateSyntheticPresentation>(
    FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
    (entry) => {
      if (calmPresentationHides("synthetic-user")) return undefined;
      const data = entry.data;
      if (!data || typeof data.content !== "string") return undefined;
      return new UserMessageComponent(data.content, getMarkdownTheme());
    },
  );
}
