import {
  getMarkdownTheme,
  type ExtensionAPI,
  UserMessageComponent,
} from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { Container, type Component } from "@earendil-works/pi-tui";
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

type CalmSyntheticChatContainer = {
  children: Component[];
  addChild(component: Component): void;
  removeChild(component: Component): void;
};

type CalmSyntheticMode = {
  chatContainer: CalmSyntheticChatContainer;
};

type CalmSyntheticEntry = {
  customType?: unknown;
};

type CalmAddCustomEntry = (this: CalmSyntheticMode, entry: CalmSyntheticEntry) => void;

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_SYNTHETIC_PLACEHOLDER_PATCH = Symbol.for(
  "firstmate:calm-synthetic-entry-placeholder:pi-0.85.1",
);

// Pi mounts a custom entry only when its renderer yields a component, so a synthetic
// row hidden at restore or arrival time would have nothing to repaint on toggle and
// stay missing after toggling Calm off. The placeholder holds that row's place at
// zero height until an expansion round-trip swaps the real row back in.
class CalmSyntheticEntryPlaceholder extends Container {
  private readonly mode: CalmSyntheticMode;
  private readonly entry: CalmSyntheticEntry;
  private readonly addOriginal: CalmAddCustomEntry;

  constructor(mode: CalmSyntheticMode, entry: CalmSyntheticEntry, addOriginal: CalmAddCustomEntry) {
    super();
    this.mode = mode;
    this.entry = entry;
    this.addOriginal = addOriginal;
  }

  // Pi's setToolsExpanded round-trip reaches every expandable chat row on toggle.
  // Re-run Pi's own add path so the row is built by the same code that builds it at
  // restore; when Calm still hides it nothing is built and this placeholder stays.
  setExpanded(_expanded: boolean): void {
    const children = this.mode.chatContainer.children;
    const index = children.indexOf(this);
    if (index === -1) return;
    const known = new Set(children);
    this.addOriginal.call(this.mode, this.entry);
    const added = children.filter((child) => !known.has(child));
    const [first] = added;
    if (first === undefined) return;
    this.mode.chatContainer.removeChild(this);
    this.mode.chatContainer.removeChild(first);
    children.splice(Math.min(index, children.length), 0, first);
  }
}

export function installCalmSyntheticEntryPlaceholder(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: boolean | undefined;
  };
  if (registry[CALM_SYNTHETIC_PLACEHOLDER_PATCH]) return;
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as {
    addCustomEntryToChat?: unknown;
  };
  const original = prototype.addCustomEntryToChat as CalmAddCustomEntry | undefined;
  if (typeof original !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addCustomEntryToChat");
  }
  prototype.addCustomEntryToChat = function (this: CalmSyntheticMode, entry: CalmSyntheticEntry): void {
    if (!entry || entry.customType !== FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE) {
      original.call(this, entry);
      return;
    }
    const before = this.chatContainer.children.length;
    original.call(this, entry);
    if (this.chatContainer.children.length !== before) return;
    this.chatContainer.addChild(new CalmSyntheticEntryPlaceholder(this, entry, original));
  };
  registry[CALM_SYNTHETIC_PLACEHOLDER_PATCH] = true;
}
