// Firstmate pi-cursor-sdk integration for cursor/* models.
// Loads before fm-calm.ts so Calm cannot claim read/bash/edit/write/grep/find/ls before
// pi-cursor-sdk registers native replay tools.
// Applies default Pi tuning env, strips noisy Cursor lifecycle thinking lines, and hides Calm
// replay tool rows.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  AssistantMessageComponent,
  ToolExecutionComponent,
} from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./lib/fm-calm-visibility.ts";
import {
  wrapCursorReplayToolExecute,
} from "./lib/fm-cursor-replay-execute.ts";

const DEFAULT_PI_TUNING_ENV: Readonly<Record<string, string>> = {
  FM_SESSION_START_STATUS_TAIL: "2",
  FM_SESSION_START_BACKLOG_LIMIT: "25",
  FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT: "8",
  PI_CURSOR_TOOL_MANIFEST: "0",
};

applyDefaultPiTuningEnv();

const CALM_BUILTIN_TOOL_NAMES = new Set([
  "read",
  "bash",
  "edit",
  "write",
  "grep",
  "find",
  "ls",
]);

const CURSOR_SDK_EXTENSION_TOOL_NAMES = new Set([
  "cursor",
  "cursor_ask_question",
  "cursor_activate_skill",
]);

const CURSOR_LIFECYCLE_LINE =
  /^Cursor (?:shell|mcp|subagent|semantic search|web search|web fetch|plan|todos|image generation|screen recording|delete|diagnostics|activity|write|edit|read|grep|find|ls|task):/i;
const CURSOR_INCOMPLETE_LINE = /^Cursor .+ did not complete\b/i;

type ToolExecutionInternals = {
  toolName: string;
  toolCallId?: string;
  args?: Record<string, unknown>;
  result?: { isError?: boolean };
  toolDefinition?: unknown;
  builtInToolDefinition?: unknown;
};

type CalmToolLayoutPatch = {
  hidesToolRows: () => boolean;
};

type AssistantMessage = Parameters<AssistantMessageComponent["updateContent"]>[0];

const ITERM_IMAGE_MARKER = "\x1b]1337;File=";
const KITTY_IMAGE_MARKER = "\x1b_G";
const CALM_TOOL_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-tool-layout:pi-0.81.1",
);
const CURSOR_LIFECYCLE_QUIET_PATCH = Symbol.for(
  "firstmate:cursor-lifecycle-quiet:pi-0.81.1",
);

function applyDefaultPiTuningEnv(): void {
  for (const [key, value] of Object.entries(DEFAULT_PI_TUNING_ENV)) {
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

function stripCursorLifecycleThinkingText(text: string): string {
  const kept = text
    .split("\n")
    .filter((line) => {
      const trimmed = line.trim();
      return !CURSOR_LIFECYCLE_LINE.test(trimmed) && !CURSOR_INCOMPLETE_LINE.test(trimmed);
    })
    .join("\n");
  return kept.replace(/\n{3,}/g, "\n\n").trim();
}

function filterThinkingBlocksForPresentation<
  T extends { type: string; thinking?: string },
>(content: readonly T[]): T[] {
  const filtered: T[] = [];
  for (const block of content) {
    if (block.type !== "thinking" || typeof block.thinking !== "string") {
      filtered.push(block);
      continue;
    }
    const stripped = stripCursorLifecycleThinkingText(block.thinking);
    if (!stripped) continue;
    filtered.push({ ...block, thinking: stripped } as T);
  }
  return filtered;
}

function isCalmBuiltinWrapper(definition: { name: string; renderShell?: string }): boolean {
  return CALM_BUILTIN_TOOL_NAMES.has(definition.name) && definition.renderShell === "self";
}

function disclosedImageLine(line: string): boolean {
  return line.includes(ITERM_IMAGE_MARKER) || line.includes(KITTY_IMAGE_MARKER);
}

function isCursorSdkReplayCall(instance: ToolExecutionInternals): boolean {
  return (
    typeof instance.toolCallId === "string" && instance.toolCallId.startsWith("cursor-replay-")
  );
}

function isCursorSdkIncompleteOrErrorReplay(instance: ToolExecutionInternals): boolean {
  if (!isCursorSdkReplayCall(instance)) return false;
  if (instance.args?.incomplete === true) return true;
  if (instance.result?.isError === true) return true;
  return false;
}

function calmShouldHideToolExecutionRow(instance: ToolExecutionInternals): boolean {
  if (isCursorSdkIncompleteOrErrorReplay(instance)) return true;
  if (isCursorSdkReplayCall(instance) && calmPresentationHides("assistant-tool-call")) return true;
  if (!calmPresentationHides("assistant-tool-call")) return false;
  if (instance.toolName === "fm_watch_arm_pi") return true;
  if (instance.toolName.startsWith("pi__")) return true;
  if (CURSOR_SDK_EXTENSION_TOOL_NAMES.has(instance.toolName)) return true;
  if (instance.builtInToolDefinition) return true;
  return false;
}

function installCalmToolLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmToolLayoutPatch | undefined;
  };
  const hidesToolRows = (): boolean => calmPresentationHides("assistant-tool-call");
  const installed = registry[CALM_TOOL_LAYOUT_PATCH];
  if (installed) {
    installed.hidesToolRows = hidesToolRows;
    return;
  }

  const patch: CalmToolLayoutPatch = { hidesToolRows };
  const originalRender = ToolExecutionComponent.prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error("Firstmate Calm cursor-sdk shim requires Pi ToolExecutionComponent.render");
  }

  ToolExecutionComponent.prototype.render = function (width: number): string[] {
    const instance = this as unknown as ToolExecutionInternals;
    if (isCursorSdkIncompleteOrErrorReplay(instance)) {
      return [];
    }
    if (!patch.hidesToolRows() || !calmShouldHideToolExecutionRow(instance)) {
      return originalRender.call(this, width);
    }

    const lines = originalRender.call(this, width);
    const imageLines = lines.filter(disclosedImageLine);
    if (imageLines.length > 0) return imageLines;
    return [];
  };

  registry[CALM_TOOL_LAYOUT_PATCH] = patch;
}

function installCursorLifecycleQuiet(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: boolean | undefined;
  };
  if (registry[CURSOR_LIFECYCLE_QUIET_PATCH]) return;

  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error(
      "Firstmate cursor lifecycle quiet requires Pi AssistantMessageComponent.updateContent",
    );
  }

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
    isStreaming?: boolean,
  ): void {
    const hasThinking = message.content.some((block) => block.type === "thinking");
    if (!hasThinking) {
      if (typeof isStreaming === "boolean") {
        originalUpdateContent.call(this, message, isStreaming);
      } else {
        originalUpdateContent.call(this, message);
      }
      return;
    }
    const presentationMessage = {
      ...message,
      content: filterThinkingBlocksForPresentation(message.content),
    };
    if (typeof isStreaming === "boolean") {
      originalUpdateContent.call(this, presentationMessage, isStreaming);
    } else {
      originalUpdateContent.call(this, presentationMessage);
    }
  };

  registry[CURSOR_LIFECYCLE_QUIET_PATCH] = true;
}

function guardCalmBuiltinRegistration(pi: ExtensionAPI): void {
  const registerTool = pi.registerTool.bind(pi);
  pi.registerTool = (definition) => {
    if (isCalmBuiltinWrapper(definition)) return;
    // Replay complete keys off cursor-replay-* tool ids, not names. MCP and other
    // replay surfaces hang the same way; a name allowlist left those spinning.
    if (typeof definition.execute === "function") {
      definition.execute = wrapCursorReplayToolExecute(definition.execute);
    }
    return registerTool(definition);
  };
}

export default function (pi: ExtensionAPI): void {
  guardCalmBuiltinRegistration(pi);
  installCalmToolLayout();
  installCursorLifecycleQuiet();
}
