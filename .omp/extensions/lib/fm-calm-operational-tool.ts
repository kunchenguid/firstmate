// OMP presentation adapter that zero-height-renders Firstmate operational
// ceremony tool rows (FIRSTMATE_OP / watcher / drain) while Calm is on.
//
// Verified against omp 18.1.17, which exports ToolExecutionComponent with
// render, updateArgs, setArgsComplete, setExecutionStarted, and updateResult
// from @oh-my-pi/pi-coding-agent. OMP keeps the tool name and arguments in
// private constructor fields and, on the live InteractiveMode path, calls
// updateResult with { ...result, isError } (no toolName), so neither the
// constructor nor updateResult carries the invocation to an adapter. The
// unfiltered assistant message does: its toolCall blocks hold id, name, and
// arguments, and both the extension message events and
// InteractiveMode.addMessageToChat receive it. This adapter records
// toolCallId -> { name, command } there and binds a row as soon as OMP hands it
// the toolCallId (setArgsComplete / setExecutionStarted, which the live tool
// start calls before the row is added, and updateArgs / updateResult), so a
// running row is hidden from its first render and rebuilt rows classify
// identically. It never inspects a row's rendered result output, so an ordinary
// tool whose output merely mentions a Firstmate script stays visible. It
// changes presentation only: tool execution, arguments, results, model context,
// and session storage stay untouched, and Calm off restores every row.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmPresentationHides } from "../../../.pi/extensions/lib/fm-calm-visibility-core.ts";

type ToolExecutionArgs = { command?: unknown };

type ToolExecutionComponentLike = {
  render(width: number): string[];
  updateArgs(args: ToolExecutionArgs, id?: unknown): void;
  setArgsComplete(id?: unknown): void;
  setExecutionStarted(id?: unknown): void;
  updateResult(result: unknown, isPartial?: unknown, id?: unknown): void;
};

type ToolCallBlock = {
  type?: unknown;
  id?: unknown;
  name?: unknown;
  arguments?: unknown;
};

type ToolInvocation = {
  toolName?: string;
  command?: string;
};

type ComponentState = {
  operational: boolean;
};

type CalmOperationalToolPatch = {
  hidesOperationalTool: () => boolean;
  invocations: Map<string, ToolInvocation>;
};

const CALM_OPERATIONAL_TOOL_PATCH = Symbol.for(
  "firstmate:calm-operational-tool:omp-18.1.17",
);

const OPERATIONAL_TOOL_NAMES = new Set(["fm_watch_arm_omp"]);
const OPERATIONAL_OP_MARKER = /\bFIRSTMATE_OP\b/;
const OPERATIONAL_SCRIPT_AT_COMMAND =
  /(?:^|[\n;&|(])\s*(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)*(?:(?:bash|sh)\s+)?(?:\.?\/)?(?:[\w.-]+\/)*fm-(?:wake-drain|watch(?:-arm)?)\.sh(?:\s|$|["';&|)])/;

function commandOf(args: unknown): string | undefined {
  if (typeof args !== "object" || args === null) return undefined;
  const command = (args as { command?: unknown }).command;
  return typeof command === "string" ? command : undefined;
}

function commandIsOperational(command: unknown): boolean {
  if (typeof command !== "string") return false;
  return OPERATIONAL_OP_MARKER.test(command) || OPERATIONAL_SCRIPT_AT_COMMAND.test(command);
}

function invocationIsOperational(invocation: ToolInvocation | undefined): boolean {
  if (invocation === undefined) return false;
  if (invocation.toolName !== undefined && OPERATIONAL_TOOL_NAMES.has(invocation.toolName)) {
    return true;
  }
  return commandIsOperational(invocation.command);
}

function recordToolCalls(patch: CalmOperationalToolPatch, message: unknown): void {
  if (typeof message !== "object" || message === null) return;
  const candidate = message as { role?: unknown; content?: unknown };
  if (candidate.role !== undefined && candidate.role !== "assistant") return;
  if (!Array.isArray(candidate.content)) return;
  for (const block of candidate.content) {
    if (typeof block !== "object" || block === null) continue;
    const call = block as ToolCallBlock;
    if (call.type !== "toolCall" || typeof call.id !== "string") continue;
    patch.invocations.set(call.id, {
      toolName: typeof call.name === "string" ? call.name : undefined,
      command: commandOf(call.arguments),
    });
  }
}

/**
 * Record the invocations OMP announces on the unfiltered assistant message, so
 * a tool row's constructor-supplied name and arguments can be recovered from
 * the toolCallId OMP later passes to updateArgs/setArgsComplete/
 * setExecutionStarted/updateResult.
 */
export function rememberOmpCalmToolCalls(message: unknown): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalToolPatch | undefined;
  };
  const patch = registry[CALM_OPERATIONAL_TOOL_PATCH];
  if (patch) recordToolCalls(patch, message);
}

export function installOmpCalmOperationalToolLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalToolPatch | undefined;
  };
  const hidesOperationalTool = (): boolean =>
    calmPresentationHides("assistant-tool-call") || calmPresentationHides("tool-result");
  const installed = registry[CALM_OPERATIONAL_TOOL_PATCH];
  if (installed) {
    installed.hidesOperationalTool = hidesOperationalTool;
    return;
  }

  const ToolExecutionComponent = (OmpCodingAgent as { ToolExecutionComponent?: unknown })
    .ToolExecutionComponent;
  if (typeof ToolExecutionComponent !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent");
  }
  const prototype = (ToolExecutionComponent as { prototype: ToolExecutionComponentLike })
    .prototype;
  const stockRender = prototype.render;
  if (typeof stockRender !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent.render");
  }
  const stockUpdateArgs = prototype.updateArgs;
  if (typeof stockUpdateArgs !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent.updateArgs");
  }
  const stockSetArgsComplete = prototype.setArgsComplete;
  if (typeof stockSetArgsComplete !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent.setArgsComplete");
  }
  const stockSetExecutionStarted = prototype.setExecutionStarted;
  if (typeof stockSetExecutionStarted !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent.setExecutionStarted");
  }
  const stockUpdateResult = prototype.updateResult;
  if (typeof stockUpdateResult !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent.updateResult");
  }

  const InteractiveMode = (OmpCodingAgent as { InteractiveMode?: unknown }).InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires OMP InteractiveMode");
  }
  const interactivePrototype = (
    InteractiveMode as {
      prototype: {
        addMessageToChat?: (message: unknown, options?: unknown) => unknown;
      };
    }
  ).prototype;
  const stockAddMessageToChat = interactivePrototype.addMessageToChat;
  if (typeof stockAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires OMP InteractiveMode.addMessageToChat");
  }

  const patch: CalmOperationalToolPatch = { hidesOperationalTool, invocations: new Map() };
  const states = new WeakMap<object, ComponentState>();
  const stateFor = (component: ToolExecutionComponentLike): ComponentState => {
    let state = states.get(component);
    if (!state) {
      state = { operational: false };
      states.set(component, state);
    }
    return state;
  };
  const bindInvocation = (component: ToolExecutionComponentLike, id: unknown): void => {
    if (typeof id !== "string") return;
    if (invocationIsOperational(patch.invocations.get(id))) stateFor(component).operational = true;
  };

  interactivePrototype.addMessageToChat = function (
    this: unknown,
    message: unknown,
    options?: unknown,
  ): unknown {
    recordToolCalls(patch, message);
    return stockAddMessageToChat.call(this, message, options);
  };
  prototype.updateArgs = function (this: ToolExecutionComponentLike, args, id) {
    const command = commandOf(args);
    if (command !== undefined && typeof id === "string") {
      const existing = patch.invocations.get(id);
      patch.invocations.set(id, { toolName: existing?.toolName, command });
    }
    if (commandIsOperational(command)) stateFor(this).operational = true;
    bindInvocation(this, id);
    return stockUpdateArgs.call(this, args, id);
  };
  prototype.setArgsComplete = function (this: ToolExecutionComponentLike, id) {
    bindInvocation(this, id);
    return stockSetArgsComplete.call(this, id);
  };
  prototype.setExecutionStarted = function (this: ToolExecutionComponentLike, id) {
    bindInvocation(this, id);
    return stockSetExecutionStarted.call(this, id);
  };
  prototype.updateResult = function (this: ToolExecutionComponentLike, result, isPartial, id) {
    bindInvocation(this, id);
    if (typeof id === "string" && isPartial !== true) patch.invocations.delete(id);
    return stockUpdateResult.call(this, result, isPartial, id);
  };
  prototype.render = function (this: ToolExecutionComponentLike, width: number): string[] {
    if (patch.hidesOperationalTool() && states.get(this)?.operational === true) return [];
    return stockRender.call(this, width);
  };

  registry[CALM_OPERATIONAL_TOOL_PATCH] = patch;
}
