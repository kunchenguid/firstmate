// Pi 0.85.1 has no supported pending-row renderer. Probe its presentation seams,
// retain stock components, and change only their rendered height. In particular,
// getAllQueuedMessages() drops images, so text alone must never authorize hiding.
// Read the agent's full pending messages at render time: Pi emits queue_update
// BEFORE adding the full message. Never mutate, drain, or replace either queue.
import * as Pi from "@earendil-works/pi-coding-agent";
import { Spacer, TruncatedText, type Component } from "@earendil-works/pi-tui";
import { classifyFirstmateCurrentOperationalText } from "./fm-operational-input.ts";

type Queues = { steering: string[]; followUp: string[] };
type Mode = {
  pendingMessagesContainer: { children: Component[] };
  getAllQueuedMessages(): Queues;
  session: { agent: unknown };
  ui: { requestRender(): void };
};
type Prototype = {
  updatePendingMessagesDisplay(this: Mode): void;
  createExtensionUIContext(this: Mode): unknown;
};
type Patch = {
  owner: symbol;
  active: boolean;
  modes: Set<WeakRef<Mode>>;
  refresh(mode: Mode): void;
};
const PATCH = Symbol.for("firstmate:pending-notification-layout:v1");

// Structural extraction only; the operational protocol remains owned by the
// canonical parser. Unknown roles/content and image-bearing inputs stay visible.
function userText(message: unknown): { text: string; textOnly: boolean } | undefined {
  if (!message || typeof message !== "object") return undefined;
  const { role, content } = message as { role?: unknown; content?: unknown };
  if (role !== "user") return undefined;
  if (typeof content === "string") return { text: content, textOnly: true };
  if (!Array.isArray(content)) return undefined;
  const texts = content.filter((block) => block?.type === "text" && typeof block.text === "string");
  return { text: texts.map((block) => block.text).join("\n"), textOnly: texts.length > 0 && texts.length === content.length };
}

export function installPendingNotificationLayout(): { refresh(): void; dispose(): void } {
  const registry = globalThis as typeof globalThis & { [key: symbol]: Patch | undefined };
  const owner = Symbol();
  let patch = registry[PATCH];
  if (!patch) {
    const prototype = Pi.InteractiveMode?.prototype as unknown as Prototype | undefined;
    if (!prototype || typeof prototype.updatePendingMessagesDisplay !== "function" ||
        typeof prototype.createExtensionUIContext !== "function") {
      throw new Error(`Pi ${Pi.VERSION ?? "unknown"} requires InteractiveMode.updatePendingMessagesDisplay and createExtensionUIContext`);
    }
    const originalUpdate = prototype.updatePendingMessagesDisplay;
    const originalContext = prototype.createExtensionUIContext;
    const seen = new WeakSet<Mode>();
    const decorated = new WeakSet<Component>();
    const diagnostics = new Set<string>();
    // Bound cached parser results; repeated repaints must not spawn per-row shells.
    const classifications = new Map<string, boolean>();
    const diagnostic = (reason: string): void => {
      if (diagnostics.has(reason)) return;
      diagnostics.add(reason);
      console.error(`Firstmate: pending-notification presentation adapter unavailable, keeping stock rows. Pi ${Pi.VERSION ?? "unknown"}: ${reason}`);
    };
    const state: Patch = {
      owner, active: true, modes: new Set(),
      refresh(mode) {
        if (!seen.has(mode)) {
          seen.add(mode);
          state.modes.add(new WeakRef(mode));
        }
        try {
          const children = mode.pendingMessagesContainer?.children;
          const queues = mode.getAllQueuedMessages();
          if (!Array.isArray(children) || !Array.isArray(queues.steering) || !Array.isArray(queues.followUp)) {
            throw new Error("Pi pending container or queue snapshot changed");
          }
          const rows = [
            ...queues.steering.map((text) => ({ text, kind: "steering" as const })),
            ...queues.followUp.map((text) => ({ text, kind: "followUp" as const })),
          ];
          if (!rows.length || decorated.has(children[0])) return;
          if (children.length < rows.length + 2 || !(children[0] instanceof Spacer) ||
              !children.slice(1, rows.length + 2).every((child) => child instanceof TruncatedText)) {
            throw new Error("Pi pending row/spacer/hint layout changed");
          }
          const operational = rows.map(({ text }) => {
            if (typeof text !== "string") throw new Error("Pi pending text shape changed");
            if (!text.includes("\u2063")) return false;
            if (!classifications.has(text)) {
              if (classifications.size >= 256) classifications.clear();
              classifications.set(text, classifyFirstmateCurrentOperationalText(text) !== undefined);
            }
            return classifications.get(text)!;
          });
          // Bind each row to its exact snapshot before hiding anything. A vendor
          // reorder with the same component classes must also degrade visibly.
          rows.forEach((row, index) => {
            const formatted = (children[index + 1] as unknown as { text?: unknown }).text;
            const label = row.kind === "steering" ? "Steering" : "Follow-up";
            if (typeof formatted !== "string" ||
                formatted.replace(/^(?:\x1b\[[0-9;]*m)+/, "").replace(/(?:\x1b\[[0-9;]*m)+$/, "") !== `${label}: ${row.text}`) {
              throw new Error("Pi pending row identity changed");
            }
          });
          const hidden = (index: number): boolean => {
            if (!state.active || !operational[index]) return false;
            const row = rows[index];
            const agent = mode.session.agent as Record<string, { messages?: unknown }>;
            const messages = agent?.[`${row.kind}Queue`]?.messages;
            if (!Array.isArray(messages)) {
              diagnostic("Pi agent pending message metadata unavailable");
              return false;
            }
            const matches = messages.map(userText).filter((item) => item?.text === row.text);
            // Duplicate text plus an image is deliberately ambiguous: keep all
            // matching previews. Missing/in-flight and compaction-only rows stay.
            return matches.length === rows.filter((item) => item.kind === row.kind && item.text === row.text).length &&
              matches.every((item) => item!.textOnly);
          };
          const collapse = (component: Component, hide: () => boolean): void => {
            const render = component.render;
            component.render = function (width): string[] {
              try { if (hide()) return []; }
              catch { diagnostic("Pi pending metadata shape changed"); }
              return render.call(this, width);
            };
            decorated.add(component);
          };
          rows.forEach((_row, index) => collapse(children[index + 1], () => hidden(index)));
          const allHidden = (): boolean => state.active && rows.every((_row, index) => hidden(index));
          collapse(children[0], allHidden);
          collapse(children[rows.length + 1], allHidden);
        } catch (error) {
          diagnostic(String(error));
        }
      },
    };
    prototype.updatePendingMessagesDisplay = function (): void {
      originalUpdate.call(this);
      state.refresh(this);
    };
    prototype.createExtensionUIContext = function (): unknown {
      const context = originalContext.call(this);
      state.refresh(this);
      return context;
    };
    registry[PATCH] = patch = state;
  }
  patch.owner = owner;
  patch.active = true;
  const current = patch;
  const refresh = (): void => {
    if (current.owner !== owner) return;
    for (const ref of current.modes) {
      const mode = ref.deref();
      if (!mode) { current.modes.delete(ref); continue; }
      current.refresh(mode);
      mode.ui.requestRender();
    }
  };
  refresh();
  return {
    refresh() {
      if (current.owner !== owner) return;
      current.active = true;
      refresh();
    },
    dispose() {
      if (current.owner !== owner) return;
      current.active = false;
      refresh();
    },
  };
}
