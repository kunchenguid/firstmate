import {
  getMarkdownTheme,
  type ExtensionAPI,
  UserMessageComponent,
} from "@earendil-works/pi-coding-agent";
export const CALM_TRANSCRIPT_CLASSES = [
  "genuine-user-prompt",
  "genuine-agent-response",
  "assistant-working-note",
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

// Calm's presentation is a level, not a boolean: "off" is stock Pi, "on" is Calm, and
// "max" is Calm plus the classes in CALM_MAX_HIDDEN_CLASSES below.
export const CALM_PRESENTATION_LEVELS = ["off", "on", "max"] as const;

export type CalmPresentationLevel = (typeof CALM_PRESENTATION_LEVELS)[number];

const CALM_VISIBLE_CLASSES = new Set<CalmTranscriptClass>([
  "genuine-user-prompt",
  "genuine-agent-response",
  "assistant-working-note",
  "working-status",
]);

// Classes ordinary Calm keeps but the "max" level also hides.
const CALM_MAX_HIDDEN_CLASSES = new Set<CalmTranscriptClass>([
  "assistant-working-note",
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

let calmLevel: CalmPresentationLevel = "off";
let stockExportRendering = false;

export function calmTranscriptClassIsVisible(
  itemClass: CalmTranscriptClass,
  level: CalmPresentationLevel = calmLevel,
): boolean {
  if (!CALM_VISIBLE_CLASSES.has(itemClass)) return false;
  return level !== "max" || !CALM_MAX_HIDDEN_CLASSES.has(itemClass);
}

export function setCalmPresentation(level: CalmPresentationLevel): void {
  calmLevel = level;
}

export function calmPresentationLevel(): CalmPresentationLevel {
  return calmLevel;
}

export function setCalmStockExportRendering(active: boolean): void {
  stockExportRendering = active;
}

export function calmPresentationIsActive(): boolean {
  return calmLevel !== "off";
}

export function calmPresentationHides(itemClass: CalmTranscriptClass): boolean {
  return (
    calmLevel !== "off" &&
    !stockExportRendering &&
    !calmTranscriptClassIsVisible(itemClass, calmLevel)
  );
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
