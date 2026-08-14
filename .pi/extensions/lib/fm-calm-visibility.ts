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
  // The assistant's own reply to a turn whose input was a hidden operational message.
  // Deliberately absent from the allowlist below: the captain asked not to see internal
  // messages in chat, and an internal turn's bare acknowledgement is the other half of
  // that same internal exchange.
  "operational-turn-reply",
  "unknown",
] as const;

export type CalmTranscriptClass = (typeof CALM_TRANSCRIPT_CLASSES)[number];

// Calm is on or off. "assistant-working-note" is deliberately absent from the allowlist:
// Calm hides mid-turn assistant working notes, keeping the genuine final reply.
const CALM_VISIBLE_CLASSES = new Set<CalmTranscriptClass>([
  "genuine-user-prompt",
  "genuine-agent-response",
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
// Whether the most recent chat input was a hidden Firstmate operational message. The
// operational-user layout sets it as it decides how to render that input, and the
// assistant layout reads it to recognise that turn's reply. This is presentation state
// only: it is derived from what was rendered, never consulted by delivery, and it
// changes no message, no model context, no session entry, and no execution semantics.
let operationalTurn = false;

export function setCalmOperationalTurn(active: boolean): void {
  operationalTurn = active;
}

export function calmOperationalTurnIsActive(): boolean {
  return operationalTurn;
}

// The reply that says nothing the captain needs, matched against the exact wording
// AGENTS.md prescribes for a routine no-action operational update rather than guessed at.
//
// An earlier revision hid any short single-line reply. A focused test caught that hiding
// a genuine one-line escalation, which is the failure that matters here: showing the
// captain one line of chatter is a nuisance, hiding one decision or blocker is a fault.
// So this matches the contract phrase and nothing else, and everything unrecognised
// stays on screen. The cost is that a reply which ignores that contract and improvises
// its own no-action wording still shows, because presentation cannot tell such a reply
// apart from a real outcome without reading intent that is not in the text. Text with no
// words is not that phrase either, so it does not match.
const CALM_NO_ACTION_REPLY = "captain, shipshape";

export function calmReplyIsBareAcknowledgement(text: string): boolean {
  const reply = text.trim();
  if (!reply) return false;
  const normalised = reply.replace(/\s+/g, " ").replace(/[.!\s]+$/, "").toLowerCase();
  return normalised === CALM_NO_ACTION_REPLY;
}

export function calmTranscriptClassIsVisible(itemClass: CalmTranscriptClass): boolean {
  return CALM_VISIBLE_CLASSES.has(itemClass);
}

export function setCalmPresentation(active: boolean): void {
  calm = active;
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
