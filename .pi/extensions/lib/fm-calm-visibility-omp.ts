// omp copy of fm-calm-visibility.ts, package-free.
// The omp watcher needs only the pure-logic exports (CalmPresentationState,
// calmTranscriptClassIsVisible, FIRSTMATE_CALM_PRESENTATION_EVENT). The Pi
// registerFirstmateSyntheticPresentation renderer is omitted because it depends
// on Pi-family UI components the omp port does not wire here; the Pi extension
// keeps its own copy for genuine Pi sessions.
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

// Calm is on or off. "assistant-working-note" is deliberately absent from the allowlist:
// Calm hides mid-turn assistant working notes, keeping the genuine final reply.
const CALM_VISIBLE_CLASSES: Partial<Record<CalmTranscriptClass, true>> = {
  "genuine-user-prompt": true,
  "genuine-agent-response": true,
  "working-status": true,
};

export const FIRSTMATE_CALM_PRESENTATION_EVENT = "firstmate:calm-presentation";

export type CalmPresentationState = {
  active: boolean;
  stockExportRendering: boolean;
};

export function calmTranscriptClassIsVisible(itemClass: CalmTranscriptClass): boolean {
  return CALM_VISIBLE_CLASSES[itemClass] === true;
}
