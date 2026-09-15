// OMP 18.2 renders advisor cards and TODO chrome outside native tool activity.
// Adapt only the live mode instance; never modify messages or shared prototypes.
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
  const isFirstmateMessage = (message: ObjectLike): boolean => {
    if (!message || (message.role !== "custom" && message.customType === undefined && message.type !== "custom")) return false;
    const type = String(message.customType ?? "");
    const content = typeof message.content === "string" ? message.content :
      typeof message.text === "string" ? message.text : "";
    return type.startsWith("fm-") || type.startsWith("firstmate-") ||
      /^\s*FIRSTMATE(?:_OP| WATCHER| SUPERVISION)/.test(content);
  };
  const wrapCard = (card: ObjectLike): void => {
    if (cards.has(card) || typeof card.render !== "function") return;
    const message = card.message ?? card.entry ?? card.data ?? card;
    if (!isFirstmateMessage(message)) return;
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
      if (message?.role === "custom" && (message.customType === "advisor" || isFirstmateMessage(message))) {
        for (const card of container.children.slice(start)) {
          if (message.customType === "advisor") {
            const render = card.render;
            patch(card, "render", function (this: ObjectLike, width: number) {
              return isHidden() ? [] : render.call(this, width);
            });
            cards.add(card);
          } else {
            wrapCard(card);
          }
        }
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
    // Do not synchronously rebuild while an agent_start hook is running: OMP's
    // rebuild awaits filesystem/session work and can deadlock the turn. Startup
    // replay occurs after session_start; subsequent advisor cards are wrapped as
    // they are added. Existing cards are intentionally left untouched.
    live.resetDisplay();
    return dispose;
  } catch (error) {
    dispose();
    throw error;
  }
}
