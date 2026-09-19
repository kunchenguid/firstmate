// OMP presentation adapter that zero-height-renders canonically classified
// Firstmate operational user rows while Calm is on.
//
// Verified against omp 18.1.17, which exports InteractiveMode.addMessageToChat
// and UserMessageComponent from @oh-my-pi/pi-coding-agent. This adapter probes
// those exact seams and throws if either is missing so fm-calm.ts can skip only
// this adapter with a diagnostic. It changes presentation only: message
// delivery, model context, and session storage stay untouched.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmPresentationHides } from "../../../.pi/extensions/lib/fm-calm-visibility-core.ts";
import { classifyFirstmateCurrentOperationalText } from "../../../.pi/extensions/lib/fm-operational-input.ts";

type UserMessageLike = {
  role: string;
  content: unknown;
  synthetic?: boolean;
};

type AddMessageOptions = {
  reuseSettledComponent?: boolean;
  imageLinks?: unknown;
};

type InteractiveModePresentation = {
  ctx?: {
    chatContainer: {
      addChild(component: unknown): void;
    };
    getUserMessageText(message: UserMessageLike): string;
    transcriptMessageComponents: {
      get(message: UserMessageLike): unknown;
      set(message: UserMessageLike, component: unknown): void;
    };
  };
  chatContainer?: {
    addChild(component: unknown): void;
  };
  getUserMessageText?: (message: UserMessageLike) => string;
  transcriptMessageComponents?: {
    get(message: UserMessageLike): unknown;
    set(message: UserMessageLike, component: unknown): void;
  };
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

const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:omp-18.1.17",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string",
  );
}

export function installOmpCalmOperationalUserLayout(): void {
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
  const InteractiveMode = (OmpCodingAgent as { InteractiveMode?: unknown }).InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires OMP InteractiveMode");
  }
  const prototype = (InteractiveMode as { prototype: InteractiveModePrototype }).prototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires OMP InteractiveMode.addMessageToChat");
  }

  const UserMessageComponent = (OmpCodingAgent as { UserMessageComponent?: unknown })
    .UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires OMP UserMessageComponent");
  }

  class CalmOperationalUserMessageComponent extends (
    UserMessageComponent as new (
      text: string,
      synthetic?: boolean,
      imageLinks?: unknown,
    ) => { render(width: number): string[] }
  ) {
    override render(width: number): string[] {
      if (patch.hidesOperationalInput()) return [];
      return super.render(width);
    }
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): unknown {
    if (
      (message.role !== "user" && message.role !== "developer") ||
      !contentIsTextOnly(message.content)
    ) {
      return originalAddMessageToChat.call(this, message, options);
    }

    const receiver = this as InteractiveModePresentation;
    const context = receiver.ctx ?? receiver;
    const getUserMessageText =
      context.getUserMessageText ?? receiver.getUserMessageText;
    const chatContainer = context.chatContainer ?? receiver.chatContainer;
    const transcriptMessageComponents =
      context.transcriptMessageComponents ?? receiver.transcriptMessageComponents;
    if (
      typeof getUserMessageText !== "function" ||
      !chatContainer ||
      !transcriptMessageComponents
    ) {
      return originalAddMessageToChat.call(this, message, options);
    }

    const text = getUserMessageText.call(context, message);
    if (!text || !patch.isOperationalInput(text)) {
      return originalAddMessageToChat.call(this, message, options);
    }

    const reused = options?.reuseSettledComponent
      ? transcriptMessageComponents.get(message)
      : undefined;
    const component =
      reused instanceof CalmOperationalUserMessageComponent
        ? reused
        : new CalmOperationalUserMessageComponent(
            text,
            message.role === "developer" ? true : message.synthetic ?? false,
            options?.imageLinks,
          );
    transcriptMessageComponents.set(message, component);
    chatContainer.addChild(component);
    return undefined;
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
