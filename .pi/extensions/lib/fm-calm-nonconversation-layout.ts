// Verified against Pi 0.82.1, which exports BashExecutionComponent,
// SkillInvocationMessageComponent, CompactionSummaryMessageComponent,
// BranchSummaryMessageComponent, and CustomMessageComponent, and which builds every
// remaining non-conversation transcript row through InteractiveMode.addMessageToChat,
// InteractiveMode.addCustomEntryToChat, and InteractiveMode.addCacheMissNotice. Each
// installer below probes the exact export or prototype method it patches and throws if one
// is missing; fm-calm.ts catches that and skips only that adapter with a diagnostic instead
// of blocking Calm or Pi.
//
// These rows are policy-hidden in fm-calm-visibility.ts (user-bash, skill-invocation,
// compaction-summary, branch-summary, custom-message, custom-entry, cache-notice) because
// they are neither a genuine captain prompt nor a normal assistant reply. The adapters read
// that policy at render time, so a loaded transcript redraws immediately on /calm, stock
// export and share rendering keeps every row, and Calm off restores Pi's own output.
//
// A skill invocation carries the captain's own trailing message as a separate
// UserMessageComponent, which stays visible; only the expanded skill block is removed.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import * as PiTui from "@earendil-works/pi-tui";
import { calmPresentationHides, type CalmTranscriptClass } from "./fm-calm-visibility.ts";

type CalmRow = {
  render(width: number): string[];
  invalidate(): void;
  setExpanded?: (expanded: boolean) => void;
};

type CalmRowConstructor = new (...args: never[]) => CalmRow;

type CalmComponentPatch = {
  hides: () => boolean;
};

type CalmHostRowPatch = {
  hides: () => boolean;
};

// Every render adapter publishes the class it hides here so the leading-spacer adapter can
// suppress the spacer Pi adds beside a hidden row without probing those exports twice, and
// so a render adapter that failed to install leaves its own spacer alone.
type CalmHiddenRowRegistry = {
  classes: Map<string, { rowClass: CalmRowConstructor; hides: () => boolean }>;
};

type CalmChatContainer = {
  children: CalmRow[];
};

type InteractiveModeChat = {
  chatContainer: CalmChatContainer;
};

// Keep the introduction-version symbols stable so a compatible upgrade cannot double-patch
// a live process.
const CALM_HIDDEN_ROW_CLASSES = Symbol.for("firstmate:calm-hidden-row-classes:pi-0.82.1");
const CALM_LEADING_SPACER_PATCH = Symbol.for("firstmate:calm-leading-spacer:pi-0.82.1");
const CALM_CUSTOM_ENTRY_PATCH = Symbol.for("firstmate:calm-custom-entry:pi-0.82.1");
const CALM_CACHE_NOTICE_PATCH = Symbol.for("firstmate:calm-cache-notice:pi-0.82.1");

function calmRegistry<T>(key: symbol): { get: () => T | undefined; set: (value: T) => void } {
  const registry = globalThis as typeof globalThis & { [entry: symbol]: T | undefined };
  return {
    get: () => registry[key],
    set: (value: T) => {
      registry[key] = value;
    },
  };
}

function calmHiddenRowClasses(): CalmHiddenRowRegistry {
  const registry = calmRegistry<CalmHiddenRowRegistry>(CALM_HIDDEN_ROW_CLASSES);
  let entry = registry.get();
  if (!entry) {
    entry = { classes: new Map() };
    registry.set(entry);
  }
  return entry;
}

function calmHidesRow(row: CalmRow): (() => boolean) | undefined {
  for (const entry of calmHiddenRowClasses().classes.values()) {
    if (row instanceof entry.rowClass) return entry.hides;
  }
  return undefined;
}

function calmConditionalRow(row: CalmRow, hides: () => boolean): CalmRow {
  const wrapper: CalmRow = {
    render: (width: number) => (hides() ? [] : row.render(width)),
    invalidate: () => {
      row.invalidate();
    },
  };
  if (typeof row.setExpanded === "function") {
    wrapper.setExpanded = (expanded: boolean) => row.setExpanded?.(expanded);
  }
  return wrapper;
}

// Replaces the transcript rows a host method just contributed - appended, or spliced in ahead
// of a streaming component - with Calm-aware wrappers, so the same rows redraw on each toggle.
function wrapAddedRows(
  chat: CalmChatContainer,
  before: ReadonlySet<CalmRow>,
  hides: () => boolean,
): void {
  const { children } = chat;
  for (let index = 0; index < children.length; index += 1) {
    const child = children[index];
    if (!child || before.has(child)) continue;
    children[index] = calmConditionalRow(child, hides);
  }
}

function installCalmRowRender(
  exportName: string,
  itemClass: CalmTranscriptClass,
  patchKey: symbol,
): void {
  const registry = calmRegistry<CalmComponentPatch>(patchKey);
  const hides = (): boolean => calmPresentationHides(itemClass);
  const exported = (PiCodingAgent as unknown as Record<string, unknown>)[exportName];
  if (typeof exported !== "function") {
    throw new Error(`Firstmate Calm requires Pi ${exportName}`);
  }
  const rowClass = exported as unknown as CalmRowConstructor;

  const installed = registry.get();
  if (installed) {
    installed.hides = hides;
    calmHiddenRowClasses().classes.set(exportName, { rowClass, hides });
    return;
  }

  const prototype = rowClass.prototype as unknown as Record<string, unknown>;
  const originalRender = prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error(`Firstmate Calm requires Pi ${exportName}.render`);
  }
  const render = originalRender as (this: CalmRow, width: number) => string[];

  const patch: CalmComponentPatch = { hides };
  prototype.render = function (this: CalmRow, width: number): string[] {
    if (patch.hides()) return [];
    return render.call(this, width);
  };

  registry.set(patch);
  calmHiddenRowClasses().classes.set(exportName, { rowClass, hides });
}

export function installCalmUserBashLayout(): void {
  installCalmRowRender(
    "BashExecutionComponent",
    "user-bash",
    Symbol.for("firstmate:calm-user-bash-layout:pi-0.82.1"),
  );
}

export function installCalmSkillInvocationLayout(): void {
  installCalmRowRender(
    "SkillInvocationMessageComponent",
    "skill-invocation",
    Symbol.for("firstmate:calm-skill-invocation-layout:pi-0.82.1"),
  );
}

export function installCalmCompactionSummaryLayout(): void {
  installCalmRowRender(
    "CompactionSummaryMessageComponent",
    "compaction-summary",
    Symbol.for("firstmate:calm-compaction-summary-layout:pi-0.82.1"),
  );
}

export function installCalmBranchSummaryLayout(): void {
  installCalmRowRender(
    "BranchSummaryMessageComponent",
    "branch-summary",
    Symbol.for("firstmate:calm-branch-summary-layout:pi-0.82.1"),
  );
}

export function installCalmCustomMessageLayout(): void {
  installCalmRowRender(
    "CustomMessageComponent",
    "custom-message",
    Symbol.for("firstmate:calm-custom-message-layout:pi-0.82.1"),
  );
}

// Pi adds a standalone Spacer beside a compaction summary, a branch summary, and a skill
// invocation, so hiding the row alone would leave a stray blank line. That spacer is replaced
// with a Calm-aware one that follows the row it belongs to. Rows that own their spacer, such
// as user bash and custom messages, need no adjustment.
export function installCalmLeadingSpacerLayout(): void {
  const registry = calmRegistry<{ installed: true }>(CALM_LEADING_SPACER_PATCH);
  if (registry.get()) return;

  const Spacer = PiTui.Spacer;
  if (typeof Spacer !== "function") {
    throw new Error("Firstmate Calm requires Pi TUI Spacer");
  }
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as Record<string, unknown>;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addMessageToChat");
  }
  const addMessageToChat = originalAddMessageToChat as (
    this: InteractiveModeChat,
    message: unknown,
    options?: unknown,
  ) => void;

  prototype.addMessageToChat = function (
    this: InteractiveModeChat,
    message: unknown,
    options?: unknown,
  ): void {
    const before = this.chatContainer.children.length;
    addMessageToChat.call(this, message, options);
    const { children } = this.chatContainer;
    for (let index = before; index < children.length - 1; index += 1) {
      const spacer = children[index];
      const row = children[index + 1];
      if (!spacer || !row || !(spacer instanceof Spacer)) continue;
      const rowHides = calmHidesRow(row);
      if (!rowHides) continue;
      children[index] = calmConditionalRow(spacer, rowHides);
    }
  };

  registry.set({ installed: true });
}

// Custom session entries from unrelated extensions render through a host component Pi does
// not export, so the rows themselves are wrapped as the host contributes them.
export function installCalmCustomEntryLayout(): void {
  const registry = calmRegistry<CalmHostRowPatch>(CALM_CUSTOM_ENTRY_PATCH);
  const hides = (): boolean => calmPresentationHides("custom-entry");
  const installed = registry.get();
  if (installed) {
    installed.hides = hides;
    return;
  }

  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as Record<string, unknown>;
  const originalAddCustomEntryToChat = prototype.addCustomEntryToChat;
  if (typeof originalAddCustomEntryToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addCustomEntryToChat");
  }
  const addCustomEntryToChat = originalAddCustomEntryToChat as (
    this: InteractiveModeChat,
    entry: unknown,
  ) => void;

  const patch: CalmHostRowPatch = { hides };
  prototype.addCustomEntryToChat = function (this: InteractiveModeChat, entry: unknown): void {
    const before = new Set(this.chatContainer.children);
    addCustomEntryToChat.call(this, entry);
    wrapAddedRows(this.chatContainer, before, () => patch.hides());
  };

  registry.set(patch);
}

// Cache-miss notices are plain host text rather than a component class, so the adapter wraps
// exactly the rows this one host method contributes instead of touching shared text rows.
export function installCalmCacheNoticeLayout(): void {
  const registry = calmRegistry<CalmHostRowPatch>(CALM_CACHE_NOTICE_PATCH);
  const hides = (): boolean => calmPresentationHides("cache-notice");
  const installed = registry.get();
  if (installed) {
    installed.hides = hides;
    return;
  }

  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as Record<string, unknown>;
  const originalAddCacheMissNotice = prototype.addCacheMissNotice;
  if (typeof originalAddCacheMissNotice !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addCacheMissNotice");
  }
  const addCacheMissNotice = originalAddCacheMissNotice as (
    this: InteractiveModeChat,
    miss: unknown,
  ) => void;

  const patch: CalmHostRowPatch = { hides };
  prototype.addCacheMissNotice = function (this: InteractiveModeChat, miss: unknown): void {
    const before = new Set(this.chatContainer.children);
    addCacheMissNotice.call(this, miss);
    wrapAddedRows(this.chatContainer, before, () => patch.hides());
  };

  registry.set(patch);
}
