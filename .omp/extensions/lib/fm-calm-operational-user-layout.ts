// omp operational-user transcript adapter for Calm.
// Patches InteractiveMode.addMessageToChat from @oh-my-pi/pi-coding-agent so Firstmate
// operational user rows render at zero height while Calm is on, without changing
// delivery or persistence. omp builds the row; this adapter gates that row's render,
// so it depends on no omp constructor shape or theme accessor.
// ../../../.pi/extensions/lib/fm-operational-input.ts owns the operational-input
// classifier, and ./fm-calm-visibility.ts owns which classes Calm hides.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { classifyFirstmateCurrentOperationalText } from "../../../.pi/extensions/lib/fm-operational-input.ts";

type UserMessageLike = {
  role: string;
  content: unknown;
};
type AddMessageOptions = {
  populateHistory?: boolean;
  reuseSettledComponent?: boolean;
};
type RenderableComponent = {
  render(width: number): string[];
};
type ChatContainer = {
  children?: RenderableComponent[];
};
type InteractiveModePresentation = {
  chatContainer?: ChatContainer;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): unknown;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:omp-18",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      "type" in block &&
      block.type === "text" &&
      "text" in block &&
      typeof block.text === "string",
  );
}

const calmPatchedRows = new WeakSet<RenderableComponent>();

function userMessageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  let text = "";
  for (const block of content) {
    if (
      block &&
      typeof block === "object" &&
      "text" in block &&
      typeof block.text === "string"
    ) {
      text += block.text;
    }
  }
  return text;
}

export function installCalmOperationalUserLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const isOperationalInput = (text: string): boolean => {
    if (!text.includes("\u2063")) return false;
    return (
      classifyFirstmateCurrentOperationalText(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
    );
  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
  };
  if (typeof OmpCodingAgent.InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires omp InteractiveMode");
  }
  // omp ships no type package; assert the runtime prototype shape probed below.
  const prototype = OmpCodingAgent.InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires omp InteractiveMode.addMessageToChat");
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): unknown {
    const children = this.chatContainer?.children;
    const before = children?.length ?? 0;
    const result = originalAddMessageToChat.call(this, message, options);
    if (message.role !== "user" || !contentIsTextOnly(message.content)) return result;
    const text = userMessageText(message.content);
    if (!text || !patch.isOperationalInput(text)) return result;
    if (!children || children.length <= before) return result;
    const component = children[children.length - 1];
    if (!component || typeof component.render !== "function") return result;
    if (calmPatchedRows.has(component)) return result;
    calmPatchedRows.add(component);
    const originalRender = component.render.bind(component);
    component.render = (width: number): string[] =>
      patch.hidesOperationalInput() ? [] : originalRender(width);
    return result;
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
