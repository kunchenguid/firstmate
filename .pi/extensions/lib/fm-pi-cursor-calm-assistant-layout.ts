// Verified against Pi 0.81.1 and 0.82.0, which export AssistantMessageComponent with an
// updateContent method. installCalmAssistantLayout() probes that exact method and throws
// if it is missing; fm-calm.ts catches that and skips only this adapter with a diagnostic
// instead of blocking Calm or Pi.
// This layout removes collapsed thinking and mid-turn assistant text blocks classified
// as "assistant-working-note" from a shallow presentation copy, but only after a later
// same-turn assistant message that already has visible text.
// Stop-reason and widget identity are not enough: an empty next row, pending or already
// labeled toolUse, is not a later answer. Treating it as last hid the recap and left
// the surface blank. The last tools-tagged recap stays visible, including while that
// turn is still in flight: Pi leaves stopReason as toolUse when the loop exits after
// tools, so hiding every tools-tagged row flashed the reply and then left it empty.
// The message itself, model context, session storage, and export rendering are never
// touched. ./fm-calm-visibility.ts owns which classes Calm hides.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
  noteUserTurn: () => void;
};

let patchedUpdateContent:
  | ((this: unknown, message: AssistantMessage, isStreaming?: boolean) => void)
  | undefined;

function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall")
  );
}

// Same Cursor noise fm-0 strips from thinking. A later row whose only "text"
// is that noise is not a successor recap; treating it as one hid the real reply.
const CURSOR_LIFECYCLE_LINE =
  /^Cursor (?:shell|mcp|subagent|semantic search|web search|web fetch|plan|todos|image generation|screen recording|delete|diagnostics|activity|write|edit|read|grep|find|ls|task):/i;
const CURSOR_INCOMPLETE_LINE = /^Cursor .+ did not complete\b/i;
const CURSOR_INCOMPLETE_REASON_LINE =
  /^(?:missing completion|aborted|SDK run failed|run ended during drain)$/i;

function textCountsAsCalmRecap(text: string): boolean {
  const kept = text
    .split("\n")
    .filter((line) => {
      const trimmed = line.trim();
      if (trimmed === "") return false;
      if (CURSOR_LIFECYCLE_LINE.test(trimmed)) return false;
      if (CURSOR_INCOMPLETE_LINE.test(trimmed)) return false;
      if (CURSOR_INCOMPLETE_REASON_LINE.test(trimmed)) return false;
      return true;
    })
    .join("\n")
    .trim();
  return kept !== "";
}

function messageHasVisibleAssistantText(message: AssistantMessage): boolean {
  return message.content.some(
    (block) =>
      block.type === "text" &&
      typeof block.text === "string" &&
      textCountsAsCalmRecap(block.text),
  );
}

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);

function getPatch(): CalmAssistantLayoutPatch | undefined {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  return registry[CALM_ASSISTANT_LAYOUT_PATCH];
}

export function noteCalmAssistantUserTurn(): void {
  getPatch()?.noteUserTurn();
}

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean => calmPresentationHides("assistant-working-note");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    return;
  }

  let userTurnId = 0;
  let nextRowSeq = 0;
  let relayouting = false;
  const turnByRow = new WeakMap<object, number>();
  const seqByRow = new WeakMap<object, number>();
  const lastVisibleRowByTurn = new Map<number, object>();

  const relayoutRow = (row: object): void => {
    if (!patchedUpdateContent || relayouting) return;
    const state = row as AssistantMessagePresentationState;
    if (!state.lastMessage) return;
    relayouting = true;
    try {
      patchedUpdateContent.call(
        row,
        state.lastMessage,
        (row as { isStreaming?: boolean }).isStreaming,
      );
    } finally {
      relayouting = false;
    }
  };

  const noteUserTurn = (): void => {
    userTurnId += 1;
  };

  const patch: CalmAssistantLayoutPatch = {
    hidesThinking,
    hidesWorkingNote,
    noteUserTurn,
  };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }

  patchedUpdateContent = function (
    this: unknown,
    message: AssistantMessage,
    isStreaming?: boolean,
  ): void {
    const row = this as object;
    const state = this as AssistantMessagePresentationState;
    let turn = turnByRow.get(row);
    if (turn === undefined) {
      turn = userTurnId;
      turnByRow.set(row, turn);
      seqByRow.set(row, nextRowSeq);
      nextRowSeq += 1;
    }
    if (messageHasVisibleAssistantText(message)) {
      const seq = seqByRow.get(row) ?? -1;
      const previousVisible = lastVisibleRowByTurn.get(turn);
      const previousSeq = previousVisible === undefined ? -1 : (seqByRow.get(previousVisible) ?? -1);
      if (seq > previousSeq) {
        lastVisibleRowByTurn.set(turn, row);
        if (previousVisible) relayoutRow(previousVisible);
      }
    }
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() &&
      isMidTurnAssistantMessage(message) &&
      message.stopReason !== "pending" &&
      lastVisibleRowByTurn.get(turn) !== row;
    const presentationMessage =
      hideThinking || hideWorkingNote
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(hideThinking && block.type === "thinking") &&
                !(hideWorkingNote && block.type === "text"),
            ),
          }
        : message;

    if (typeof isStreaming === "boolean") {
      originalUpdateContent.call(this, presentationMessage, isStreaming);
    } else {
      originalUpdateContent.call(this, presentationMessage);
    }
    // Pi stores the argument as lastMessage. Keep the unfiltered original so
    // a later same-turn successor can classify from the real text, not a copy.
    state.lastMessage = message;
  };

  AssistantMessageComponent.prototype.updateContent = patchedUpdateContent;

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
