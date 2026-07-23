// Firstmate bridge for durable external-turn adoption into the active Pi session.

import { VERSION, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  ActiveSessionBridge,
  BRIDGE_INPUT_CHANNEL,
  BRIDGE_OUTPUT_CHANNEL,
} from "./fm-primary-telegram-bridge-core.ts";

export default function (pi: ExtensionAPI) {
  let bridge: ActiveSessionBridge | undefined;
  let removeInputHandler: (() => void) | undefined;

  pi.on("session_start", (_event, ctx) => {
    removeInputHandler?.();
    bridge?.shutdown("SESSION_REBOUND");

    const current = new ActiveSessionBridge({
      piVersion: VERSION,
      emit: (output) => pi.events.emit(BRIDGE_OUTPUT_CHANNEL, output),
    });
    bridge = current;
    removeInputHandler = pi.events.on(BRIDGE_INPUT_CHANNEL, (input) => current.handle(input));
    current.start(ctx.sessionManager.getSessionId(), {
      getEntries: () => ctx.sessionManager.getEntries(),
      isPersisted: () => ctx.sessionManager.getSessionFile() !== undefined,
      isIdle: () => ctx.isIdle(),
      sendMessage: (message, options) => pi.sendMessage(message, options),
    });
  });

  pi.on("message_end", (event) => {
    bridge?.onMessageEnd(event.message);
  });

  pi.on("agent_settled", () => {
    bridge?.onAgentSettled();
  });

  pi.on("session_shutdown", (event) => {
    removeInputHandler?.();
    removeInputHandler = undefined;
    bridge?.shutdown(`SESSION_${event.reason.toUpperCase()}`);
    bridge = undefined;
  });
}
