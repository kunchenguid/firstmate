// OMP presentation adapter that zero-height-renders Firstmate operational
// ceremony tool rows (FIRSTMATE_OP / watcher / drain) while Calm is on.
//
// Verified against omp 18.1.17, which exports ToolExecutionComponent with
// render, updateArgs, and updateResult from @oh-my-pi/pi-coding-agent. OMP
// keeps the tool name and arguments in private fields, so this adapter matches
// the invocation through the public seams that carry it: updateArgs carries the
// bash command arguments and updateResult carries the toolResult message's
// toolName. It never inspects a row's rendered result output, so an ordinary
// tool whose output merely mentions a Firstmate script stays visible. It
// changes presentation only: tool execution, arguments, results, model context,
// and session storage stay untouched, and Calm off restores every row.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmPresentationHides } from "../../../.pi/extensions/lib/fm-calm-visibility-core.ts";

type ToolExecutionArgs = { command?: unknown };

type ToolExecutionResult = { toolName?: unknown };

type ToolExecutionComponentLike = {
  render(width: number): string[];
  updateArgs(args: ToolExecutionArgs, id?: unknown): void;
  updateResult(result: ToolExecutionResult, isPartial?: unknown, id?: unknown): void;
};

type InvocationState = {
  toolName?: string;
  command?: string;
};

type CalmOperationalToolPatch = {
  hidesOperationalTool: () => boolean;
};

const CALM_OPERATIONAL_TOOL_PATCH = Symbol.for(
  "firstmate:calm-operational-tool:omp-18.1.17",
);

const OPERATIONAL_TOOL_NAMES = new Set(["fm_watch_arm_omp"]);
const OPERATIONAL_OP_MARKER = /\bFIRSTMATE_OP\b/;
const OPERATIONAL_SCRIPT_AT_COMMAND =
  /(?:^|[\n;&|(])\s*(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)*(?:(?:bash|sh)\s+)?(?:\.?\/)?(?:[\w.-]+\/)*fm-(?:wake-drain|watch(?:-arm)?)\.sh(?:\s|$|["';&|)])/;

function commandIsOperational(command: unknown): boolean {
  if (typeof command !== "string") return false;
  return OPERATIONAL_OP_MARKER.test(command) || OPERATIONAL_SCRIPT_AT_COMMAND.test(command);
}

function invocationIsOperational(state: InvocationState | undefined): boolean {
  if (state?.toolName !== undefined && OPERATIONAL_TOOL_NAMES.has(state.toolName)) return true;
  return commandIsOperational(state?.command);
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
  const stockUpdateResult = prototype.updateResult;
  if (typeof stockUpdateResult !== "function") {
    throw new Error("Firstmate Calm requires OMP ToolExecutionComponent.updateResult");
  }

  const patch: CalmOperationalToolPatch = { hidesOperationalTool };
  const states = new WeakMap<object, InvocationState>();
  const stateFor = (component: ToolExecutionComponentLike): InvocationState => {
    let state = states.get(component);
    if (!state) {
      state = {};
      states.set(component, state);
    }
    return state;
  };

  prototype.updateArgs = function (this: ToolExecutionComponentLike, args, id) {
    if (typeof args?.command === "string") stateFor(this).command = args.command;
    return stockUpdateArgs.call(this, args, id);
  };
  prototype.updateResult = function (this: ToolExecutionComponentLike, result, isPartial, id) {
    if (typeof result?.toolName === "string") stateFor(this).toolName = result.toolName;
    return stockUpdateResult.call(this, result, isPartial, id);
  };
  prototype.render = function (this: ToolExecutionComponentLike, width: number): string[] {
    if (patch.hidesOperationalTool() && invocationIsOperational(states.get(this))) {
      return [];
    }
    return stockRender.call(this, width);
  };

  registry[CALM_OPERATIONAL_TOOL_PATCH] = patch;
}
