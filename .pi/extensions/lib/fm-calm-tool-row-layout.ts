// Calm's Pi built-in tool-row presentation adapter.
//
// Pi hands every ToolExecutionComponent its renderers through one
// InteractiveMode method, getRegisteredToolDefinition, which is present on the Pi
// versions Calm records evidence for (0.81.1, 0.84.4, and 0.85.1). Calm patches that
// method instead of re-registering a built-in name through pi.registerTool(), because
// Pi resolves same-name tool registrations by first registration in extension load
// order, keeps the winner, and discards the loser's definition outright. A Calm-owned
// built-in name therefore both enters Pi's own tool registry and silently replaces a
// later extension's override of that built-in, including its execution, which is not
// a presentation concern Calm has any business deciding.
//
// The seven names below are the main-session built-ins Calm presents; every other
// tool row, built-in or custom, is left exactly as Pi draws it. Calm keeps its own
// copy of each row's renderers, so hiding a row costs nothing and restoring it
// delegates to the definition Pi supplied, whichever extension owns that. Nothing
// here writes to Pi's tool registry, so another extension that overrides a built-in
// keeps its execution and its own renderers while Calm is off.
//
// The whole adapter is probed and degradable: installCalmToolRowLayout throws when the
// seam is missing, and fm-calm.ts catches that and skips only this adapter with a
// diagnostic. A definition without both render slots is passed through untouched
// rather than throwing inside Pi's row construction.
// ./fm-calm-visibility.ts owns which classes Calm hides.
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { Box, Container, type Component } from "@earendil-works/pi-tui";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  calmPresentationStocksExportRendering,
  type CalmTranscriptClass,
} from "./fm-calm-visibility.ts";

type CalmToolDefinition = ToolDefinition<any, any, any>;
type RenderContext = Parameters<NonNullable<CalmToolDefinition["renderCall"]>>[2];
type RenderArgs = Parameters<NonNullable<CalmToolDefinition["renderCall"]>>[0];
type RenderTheme = Parameters<NonNullable<CalmToolDefinition["renderCall"]>>[1];
type RenderResult = Parameters<NonNullable<CalmToolDefinition["renderResult"]>>[0];
type RenderResultOptions = Parameters<NonNullable<CalmToolDefinition["renderResult"]>>[1];

type StandardShellState = {
  shell?: Box;
  call?: Component;
  result?: Component;
};

const CALM_BUILTIN_TOOL_NAMES = new Set([
  "bash",
  "edit",
  "find",
  "grep",
  "ls",
  "read",
  "write",
]);

type CalmToolRowLayoutPatch = {
  // Re-bound on every install: Pi re-imports extension modules on /reload, so the
  // adapter that runs later holds a fresh copy of the visibility policy while the
  // patched seam and its row definitions would otherwise keep reading the module
  // instance that first installed them.
  hides: (itemClass: CalmTranscriptClass) => boolean;
  isActive: () => boolean;
  stocksExportRendering: () => boolean;
  // Every on-screen built-in tool row Calm currently presents, keyed by the row-local
  // state Pi hands its render slots, so Calm can repaint exactly those rows without
  // touching Pi's transcript. Pi can re-render a row at any time - the built-in edit
  // row invalidates itself once its diff is ready - so a row can be redrawn during the
  // window where /export forces stock rendering and keep that stock content
  // afterwards. Rows Pi's exporter renders are excluded: those use throwaway state and
  // never appear on screen. Cleared per session lifetime, which rebuilds the rows.
  repaints: Map<object, () => void>;
  warned: boolean;
};

type InteractiveModePrototype = {
  getRegisteredToolDefinition(
    this: unknown,
    toolName: string,
  ): CalmToolDefinition | undefined;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_TOOL_ROW_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-tool-row-layout:pi-0.85.1",
);

const calmToolRowLayoutRegistry = globalThis as typeof globalThis & {
  [key: symbol]: CalmToolRowLayoutPatch | undefined;
};

// The row is hidden by making both renderer slots contribute no content, and
// renderShell: "self" is what lets that remove the row's height too: with Pi's default
// shell the empty renderers would still be wrapped in a padded Box. When the row is
// visible Calm rebuilds Pi's standard shell around the same components, so an
// untouched Calm renders byte-identically to Pi's own default shell. An original that
// renders its own shell is delegated to whole.
function calmToolDefinition(
  definition: CalmToolDefinition | undefined,
  patch: CalmToolRowLayoutPatch,
): CalmToolDefinition | undefined {
  const originalRenderCall = definition?.renderCall;
  const originalRenderResult = definition?.renderResult;
  if (!definition || !originalRenderCall || !originalRenderResult) {
    if (definition && !patch.warned) {
      patch.warned = true;
      console.error(
        `Firstmate Calm: Pi supplied no renderer slots for built-in tool "${definition.name}", so its rows will not hide.`,
      );
    }
    return definition;
  }

  const originalSelfShell = definition.renderShell === "self";
  const standardShells = new WeakMap<object, StandardShellState>();

  const rememberRow = (context: RenderContext): void => {
    if (!patch.isActive() || patch.stocksExportRendering()) return;
    if (typeof context.invalidate === "function") {
      patch.repaints.set(context.state as object, context.invalidate as () => void);
    }
  };

  const shellStateFor = (context: RenderContext): StandardShellState => {
    const rowState = context.state as object;
    let shellState = standardShells.get(rowState);
    if (!shellState) {
      shellState = {};
      standardShells.set(rowState, shellState);
    }
    return shellState;
  };

  const refreshStandardShell = (
    state: StandardShellState,
    theme: RenderTheme,
    context: RenderContext,
  ): Box => {
    const background = context.isPartial
      ? (text: string) => theme.bg("toolPendingBg", text)
      : context.isError
        ? (text: string) => theme.bg("toolErrorBg", text)
        : (text: string) => theme.bg("toolSuccessBg", text);
    const shell = state.shell ?? new Box(1, 1, background);
    state.shell = shell;
    shell.setBgFn(background);
    shell.clear();
    if (state.call) shell.addChild(state.call);
    if (state.result) shell.addChild(state.result);
    return shell;
  };

  return {
    ...definition,
    renderShell: "self",

    renderCall(
      args: RenderArgs,
      theme: RenderTheme,
      context: RenderContext,
    ): Component {
      rememberRow(context);
      if (patch.hides("assistant-tool-call")) return new Container();
      if (originalSelfShell) return originalRenderCall(args, theme, context);

      const state = shellStateFor(context);
      state.call = originalRenderCall(args, theme, {
        ...context,
        lastComponent: state.call,
      });
      return refreshStandardShell(state, theme, context);
    },

    renderResult(
      result: RenderResult,
      options: RenderResultOptions,
      theme: RenderTheme,
      context: RenderContext,
    ): Component {
      rememberRow(context);
      if (patch.hides("tool-result")) return new Container();
      if (originalSelfShell) return originalRenderResult(result, options, theme, context);

      const state = shellStateFor(context);
      state.result = originalRenderResult(result, options, theme, {
        ...context,
        lastComponent: state.result,
      });
      refreshStandardShell(state, theme, context);
      return new Container();
    },
  };
}

export function installCalmToolRowLayout(): void {
  const installed = calmToolRowLayoutRegistry[CALM_TOOL_ROW_LAYOUT_PATCH];
  if (installed) {
    installed.hides = calmPresentationHides;
    installed.isActive = calmPresentationIsActive;
    installed.stocksExportRendering = calmPresentationStocksExportRendering;
    return;
  }

  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalGetRegisteredToolDefinition = prototype.getRegisteredToolDefinition;
  if (typeof originalGetRegisteredToolDefinition !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.getRegisteredToolDefinition");
  }

  const patch: CalmToolRowLayoutPatch = {
    hides: calmPresentationHides,
    isActive: calmPresentationIsActive,
    stocksExportRendering: calmPresentationStocksExportRendering,
    repaints: new Map(),
    warned: false,
  };
  prototype.getRegisteredToolDefinition = function (
    toolName: string,
  ): CalmToolDefinition | undefined {
    const definition = originalGetRegisteredToolDefinition.call(this, toolName);
    if (!CALM_BUILTIN_TOOL_NAMES.has(toolName)) return definition;
    return calmToolDefinition(definition, patch);
  };

  calmToolRowLayoutRegistry[CALM_TOOL_ROW_LAYOUT_PATCH] = patch;
}

export function clearCalmToolRowRepaints(): void {
  calmToolRowLayoutRegistry[CALM_TOOL_ROW_LAYOUT_PATCH]?.repaints.clear();
}

export function repaintCalmToolRows(): void {
  const patch = calmToolRowLayoutRegistry[CALM_TOOL_ROW_LAYOUT_PATCH];
  if (!patch) return;
  for (const invalidate of patch.repaints.values()) invalidate();
}
