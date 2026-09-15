// OMP 18.2 renders advisor cards and TODO chrome outside native tool activity.
// Adapt only the live mode instance; never modify messages or shared prototypes.
import { classifyFirstmateCurrentOperationalText } from "../../../.pi/extensions/lib/fm-operational-input.ts";

type ObjectLike = Record<string, any>;
type Patch = { target: WeakRef<ObjectLike>; key: string; original?: PropertyDescriptor; replacement: Function };
export function findCalmOmpMode(tui: unknown): ObjectLike | undefined {
  const queue: unknown[] = [tui], seen = new Set<unknown>();
  while (queue.length && seen.size < 4096) {
    const node = queue.shift() as ObjectLike | undefined;
    if (!node || typeof node !== "object" || seen.has(node)) continue;
    seen.add(node);
    if (node.mode?.todoContainer === node) return node.mode;
    if (Array.isArray(node.children)) queue.push(...node.children);
  }
  return undefined;
}

export function installCalmOmpPresentation(tui: unknown, hidden: () => boolean): () => void {
  const live = tui as ObjectLike;
  const mode = findCalmOmpMode(tui);
  if (!mode || typeof mode.addMessageToChat !== "function" ||
      typeof mode.todoContainer?.render !== "function" ||
      typeof mode.renderCompactStatusLine !== "function" ||
      !Array.isArray(mode.chatContainer?.children) ||
      typeof live?.resetDisplay !== "function") {
    throw new Error("OMP's live advisor/TODO presentation hooks are unavailable");
  }

  const patches: Patch[] = [];
  const cards = new WeakSet<object>();
  const shouldHideMessage = (message: ObjectLike): boolean => {
    if (message?.role === "custom") return message.customType === "advisor";
    if (message?.role !== "user") return false;
    // Attachments and ordinary captain prose stay visible. The shared protocol
    // owner decides provenance; renderer code never guesses from body wording.
    const parts = message.content;
    if (Array.isArray(parts) && parts.some((part: ObjectLike) => part?.type !== "text" || typeof part.text !== "string")) return false;
    const text = typeof parts === "string" ? parts :
      Array.isArray(parts) ? parts.map((part: ObjectLike) => part.text).join("") : "";
    if (!text.includes("\u2063")) return false;
    return classifyFirstmateCurrentOperationalText(text) !== undefined;
  };
  const wrapCard = (card: ObjectLike): void => {
    if (!card || cards.has(card) || typeof card.render !== "function") return;
    const render = card.render;
    patch(card, "render", function (this: ObjectLike, width: number) {
      return isHidden() ? [] : render.call(this, width);
    });
    cards.add(card);
  };
  let active = true;
  const isHidden = (): boolean => active && hidden();
  const patch = (target: ObjectLike, key: string, replacement: Function): void => {
    const original = Object.getOwnPropertyDescriptor(target, key);
    Object.defineProperty(target, key, { configurable: true, writable: true, value: replacement });
    patches.push({ target: new WeakRef(target), key, original, replacement });
  };
  const dispose = (): void => {
    if (!active) return;
    active = false;
    for (const entry of patches.reverse()) {
      const target = entry.target.deref();
      // Another extension may have replaced our wrapper; never undo its work.
      if (!target || target[entry.key] !== entry.replacement) continue;
      if (entry.original) Object.defineProperty(target, entry.key, entry.original);
      else delete target[entry.key];
    }
    patches.length = 0;
    live.resetDisplay();
  };

  try {
    const originalAdd = mode.addMessageToChat;
    patch(mode, "addMessageToChat", function (this: ObjectLike, message: ObjectLike, ...args: unknown[]) {
      // History rebuilds temporarily replace chatContainer with a staging tree.
      const container = this.chatContainer;
      const start = container.children.length;
      const result = originalAdd.call(this, message, ...args);
      if (shouldHideMessage(message)) {
        for (const card of container.children.slice(start)) wrapCard(card);
      }
      return result;
    });
    const renderTodo = mode.todoContainer.render;
    patch(mode.todoContainer, "render", function (this: ObjectLike, width: number) {
      return isHidden() ? [] : renderTodo.call(this, width);
    });
    const renderCompact = mode.renderCompactStatusLine;
    patch(mode, "renderCompactStatusLine", function (this: ObjectLike, width: number, childLines: readonly string[]) {
      return isHidden() ? childLines : renderCompact.call(this, width, childLines);
    });
    // OMP keeps user rows in this identity map, not on the component itself.
    // Inspect existing rows without rebuilding or changing persisted messages.
    for (const message of mode.viewSession?.messages ?? []) {
      if (shouldHideMessage(message)) wrapCard(mode.transcriptMessageComponents?.get(message));
    }
    for (const card of mode.chatContainer.children) {
      if (shouldHideMessage(card.message ?? {})) wrapCard(card);
    }
    live.resetDisplay();
    return dispose;
  } catch (error) {
    dispose();
    throw error;
  }
}
