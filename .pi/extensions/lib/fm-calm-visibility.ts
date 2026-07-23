import {
  getMarkdownTheme,
  type ExtensionAPI,
  UserMessageComponent,
} from "@earendil-works/pi-coding-agent";

export const CALM_TRANSCRIPT_CLASSES = [
  "genuine-user-prompt",
  "genuine-agent-response",
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

const CALM_VISIBLE_CLASSES = new Set<CalmTranscriptClass>([
  "genuine-user-prompt",
  "genuine-agent-response",
]);

const FIRSTMATE_SESSIONSTART_NUDGE =
  "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.";
const FIRSTMATE_WATCHER_PREFIX = "FIRSTMATE WATCHER WAKE: ";
const FIRSTMATE_WATCHER_SUFFIX =
  "\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";
const FIRSTMATE_TURNEND_PREFIX =
  "TURN WOULD END BLIND - supervision is off. " +
  "The watcher cycle is missing, failed, or unhealthy. " +
  "Follow the harness recovery instruction below before ending the turn.\n\n";
const FM_INJECT_MARK = "\u2063";
const FM_FROMFIRST_MARK = "[fm-from-firstmate]\u2063";

export const FIRSTMATE_SYNTHETIC_CONTEXT_TYPE = "firstmate-synthetic-input";
export const FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE = "firstmate-synthetic-input-presentation";
export const FIRSTMATE_CALM_PRESENTATION_EVENT = "firstmate:calm-presentation";
export const FIRSTMATE_PI_LAUNCH_BRIEF_ENV = "FM_FIRSTMATE_PI_LAUNCH_BRIEF";

export type CalmPresentationState = {
  active: boolean;
  stockExportRendering: boolean;
};

export type FirstmateSyntheticKind =
  | "session-start"
  | "watcher"
  | "turn-end-guard"
  | "away-supervisor"
  | "from-firstmate"
  | "launch-brief";

type SyntheticDeliveryOptions = {
  deliverAs?: "steer" | "followUp" | "nextTurn";
  redrawPresentation?: () => void;
  triggerTurn?: boolean;
};

type FirstmateSyntheticPresentation = {
  content: string;
  kind: FirstmateSyntheticKind;
};

let calm = false;
let mountingSyntheticPresentation = false;
let stockExportRendering = false;

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

export function classifyFirstmateSyntheticInput(
  content: string,
  launchBriefContent?: string,
): FirstmateSyntheticKind | undefined {
  if (launchBriefContent !== undefined && content === launchBriefContent) return "launch-brief";
  if (content === FIRSTMATE_SESSIONSTART_NUDGE) return "session-start";
  if (content.startsWith(FM_INJECT_MARK)) return "away-supervisor";
  if (content.startsWith(FM_FROMFIRST_MARK) && content.length > FM_FROMFIRST_MARK.length) {
    return "from-firstmate";
  }
  if (
    content.startsWith(FIRSTMATE_WATCHER_PREFIX) &&
    content.endsWith(FIRSTMATE_WATCHER_SUFFIX) &&
    content.length > FIRSTMATE_WATCHER_PREFIX.length + FIRSTMATE_WATCHER_SUFFIX.length
  ) {
    return "watcher";
  }
  if (
    content.startsWith(FIRSTMATE_TURNEND_PREFIX) &&
    content.length > FIRSTMATE_TURNEND_PREFIX.length
  ) {
    return "turn-end-guard";
  }
  return undefined;
}

export function registerFirstmateSyntheticPresentation(pi: ExtensionAPI): void {
  pi.registerEntryRenderer<FirstmateSyntheticPresentation>(
    FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
    (entry) => {
      if (
        calmPresentationHides("synthetic-user") &&
        !mountingSyntheticPresentation
      ) {
        return undefined;
      }
      const data = entry.data;
      if (!data || typeof data.content !== "string") return undefined;
      return new UserMessageComponent(data.content, getMarkdownTheme());
    },
  );
}

export function deliverFirstmateSyntheticInput(
  pi: ExtensionAPI,
  content: string,
  kind: FirstmateSyntheticKind,
  options: SyntheticDeliveryOptions = {},
): void {
  const mountForRedraw =
    calmPresentationHides("synthetic-user") &&
    options.redrawPresentation !== undefined;
  mountingSyntheticPresentation = mountForRedraw;
  try {
    pi.appendEntry<FirstmateSyntheticPresentation>(FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE, {
      content,
      kind,
    });
  } finally {
    mountingSyntheticPresentation = false;
  }
  if (mountForRedraw) options.redrawPresentation?.();
  pi.sendMessage(
    {
      customType: FIRSTMATE_SYNTHETIC_CONTEXT_TYPE,
      content,
      display: false,
      details: { kind },
    },
    options,
  );
}
