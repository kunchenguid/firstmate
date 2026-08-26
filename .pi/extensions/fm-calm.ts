// Firstmate's home-persistent Pi transcript presentation toggle.
//
// Pi exposes built-in ToolDefinitions, per-slot renderers, renderShell: "self",
// session_start replacement reasons, agent_start and agent_settled,
// ExtensionUIContext.setToolsExpanded(), setWorkingVisible(), setWidget() with a
// disposable component factory, and setHiddenThinkingLabel().
// ./lib/fm-calm-working-ship.ts owns the animated working presentation this file
// installs. The focused tests pin those assumptions but never reject a
// newer Pi solely for its version. The collapsed-thinking and operational-user
// presentation adapters probe the exact API they patch and degrade independently with a
// diagnostic (see installCalmPresentationAdapter below) if a future Pi removes it; Pi
// still exposes no global renderer for arbitrary built-in or custom rows.
// docs/configuration.md owns the home-local Calm preference contract.
//
// Pi has one first-registration-wins ToolDefinition per tool name, with no merge or
// unregister operation, and Pi 0.84 rejects duplicate extension-owned names at startup.
// Register Calm's wrappers only after the extension runtime is bound, when getAllTools()
// can identify foreign owners, and leave every contested name untouched.
// docs/calm-mode-feasibility.md owns the version-scoped Pi evidence, and docs/calm.md
// owns the user-facing behavior and restored-row presentation bound.
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionUIContext,
  ToolDefinition,
  ToolInfo,
  ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";
import {
  createBashToolDefinition,
  createEditToolDefinition,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { Box, Container, getKeybindings, type Component } from "@earendil-works/pi-tui";
import type { TSchema } from "typebox";
import { installCalmAssistantLayout } from "./lib/fm-calm-assistant-layout.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
import {
  CALM_WORKING_SHIP_WIDGET_KEY,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} from "./lib/fm-calm-working-ship.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  registerFirstmateSyntheticPresentation,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./lib/fm-calm-visibility.ts";

type DefinitionFactory<TParams extends TSchema, TDetails, TState> = (
  cwd: string,
) => ToolDefinition<TParams, TDetails, TState>;

type RenderContext<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[2];

type RenderArgs<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[0];

type RenderTheme<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[1];

type RenderResult<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderResult"]>
>[0];

type StandardShellState = {
  shell?: Box;
  call?: Component;
  result?: Component;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

// Resolves symlinks before comparing tool-ownership identity below: sourceInfo.path
// values come from independent path-resolution code paths (this module's own
// import.meta.url vs. Pi's extension loader), and macOS alone symlinks /tmp and /var
// to /private/..., so lexical string comparison alone spuriously reads a symlinked
// self-path as a foreign one. Falls back to the raw path for synthetic, non-file
// sourceInfo paths such as "<builtin:read>" or "<inline>", which realpathSync rejects.
const realpathOrSelf = (path: string): string => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};
const extensionRealFile = realpathOrSelf(extensionFile);

// Each presentation adapter probes the exact Pi API it patches. If a future Pi removes
// that API, only the affected adapter degrades; the rest of Calm keeps working.
function installCalmPresentationAdapter(name: string, install: () => void): void {
  try {
    install();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`Firstmate Calm: ${name} presentation adapter unavailable, skipping. ${reason}`);
  }
}

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  // One logical agent run, tracked from agent_start through agent_settled rather than
  // from turns or tool calls, so the boat never flickers between tool calls, automatic
  // continuations, retries, or compaction that stay inside the same run.
  let agentRunActive = false;
  let workingShipShown = false;
  // One animation instance per extension lifetime. Hiding the working widget freezes
  // this state; the next working period resumes it. session_start resets it so a fresh
  // Pi session starts at the normal initial position. Never module-global.
  const workingShipAnimation = createCalmWorkingShipAnimation();

  // Single owner of Calm's working-row presentation choice. The widget is only created
  // or removed on a real transition, so repeated starts cannot duplicate its timer.
  const applyWorkingPresentation = (
    ui: ExtensionUIContext,
    forceStockVisibility = false,
  ): void => {
    const showShip = agentRunActive && calmPresentationIsActive();
    if (showShip !== workingShipShown) {
      workingShipShown = showShip;
      ui.setWidget(
        CALM_WORKING_SHIP_WIDGET_KEY,
        showShip
          ? (tui) => createCalmWorkingShipWidget(tui, workingShipAnimation)
          : undefined,
      );
      ui.setWorkingVisible(!showShip);
    } else if (forceStockVisibility && !showShip) {
      ui.setWorkingVisible(true);
    }
  };

  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");
  // "max" is the legacy value written by the removed third presentation level, whose
  // behavior is now ordinary Calm; a home upgraded from it restores as on rather than
  // dropping to off. docs/configuration.md owns the persisted value schema.
  const loadCalmPreference = (): boolean => {
    let stored: string;
    try {
      stored = readFileSync(calmPreferencePath, "utf8").trim();
    } catch {
      return false;
    }
    return stored === "on" || stored === "max";
  };
  const persistCalmPreference = (active: boolean): void => {
    mkdirSync(dirname(calmPreferencePath), { recursive: true });
    const temporaryPath = `${calmPreferencePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporaryPath, active ? "on\n" : "off\n", {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      renameSync(temporaryPath, calmPreferencePath);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  };

  const publishPresentationState = (): void => {
    pi.events.emit(FIRSTMATE_CALM_PRESENTATION_EVENT, {
      active: calmPresentationIsActive(),
      stockExportRendering: exportRendering,
    });
  };

  registerFirstmateSyntheticPresentation(pi);

  // Every on-screen tool row Calm currently presents, keyed by the row-local state Pi
  // hands its render slots, so Calm can repaint exactly those rows without touching
  // Pi's transcript. Pi can re-render a row at any time - the built-in edit row
  // invalidates itself once its diff is ready - so a row can be redrawn during the
  // window where /export forces stock rendering and keep that stock content
  // afterwards. Rows Pi's exporter renders are excluded: those use throwaway state
  // and never appear on screen. Cleared per session lifetime, which rebuilds the rows.
  const calmToolRowRepaints = new Map<object, () => void>();
  const rememberCalmToolRow = (state: object, invalidate: unknown): void => {
    if (exportRendering || typeof invalidate !== "function") return;
    calmToolRowRepaints.set(state, invalidate as () => void);
  };
  const repaintCalmToolRows = (): void => {
    for (const invalidate of calmToolRowRepaints.values()) invalidate();
  };

  function wrapBuiltIn<TParams extends TSchema, TDetails, TState>(
    factory: DefinitionFactory<TParams, TDetails, TState>,
  ): ToolDefinition<TParams, TDetails, TState> {
    const definitions = new Map<string, ToolDefinition<TParams, TDetails, TState>>();
    const definitionFor = (cwd: string): ToolDefinition<TParams, TDetails, TState> => {
      let definition = definitions.get(cwd);
      if (!definition) {
        definition = factory(cwd);
        definitions.set(cwd, definition);
      }
      return definition;
    };

    const original = definitionFor(process.cwd());
    const originalRenderCall = original.renderCall;
    const originalRenderResult = original.renderResult;
    const originalSelfShell = original.renderShell === "self";
    const standardShells = new WeakMap<object, StandardShellState>();

    if (!originalRenderCall || !originalRenderResult) {
      throw new Error(`Firstmate calm mode requires both render slots for Pi built-in tool ${original.name}`);
    }

    const shellStateFor = (
      context: RenderContext<TParams, TDetails, TState>,
    ): StandardShellState => {
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
      theme: RenderTheme<TParams, TDetails, TState>,
      context: RenderContext<TParams, TDetails, TState>,
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
      ...original,
      renderShell: "self",

      async execute(toolCallId, params, signal, onUpdate, ctx) {
        return definitionFor(ctx.cwd).execute(toolCallId, params, signal, onUpdate, ctx);
      },

      renderCall(
        args: RenderArgs<TParams, TDetails, TState>,
        theme: RenderTheme<TParams, TDetails, TState>,
        context: RenderContext<TParams, TDetails, TState>,
      ) {
        rememberCalmToolRow(context.state as object, context.invalidate);
        if (exportRendering) return originalRenderCall(args, theme, context);
        if (calmPresentationHides("assistant-tool-call")) return new Container();
        if (originalSelfShell) return originalRenderCall(args, theme, context);

        const state = shellStateFor(context);
        state.call = originalRenderCall(args, theme, {
          ...context,
          lastComponent: state.call,
        });
        return refreshStandardShell(state, theme, context);
      },

      renderResult(
        result: RenderResult<TParams, TDetails, TState>,
        options: ToolRenderResultOptions,
        theme: RenderTheme<TParams, TDetails, TState>,
        context: RenderContext<TParams, TDetails, TState>,
      ) {
        rememberCalmToolRow(context.state as object, context.invalidate);
        if (exportRendering) return originalRenderResult(result, options, theme, context);
        if (calmPresentationHides("tool-result")) return new Container();
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

  // Each wrapBuiltIn() call below has its own concrete TParams/TDetails/TState; the
  // array holding all seven has no single sound instantiation, so it is typed the same
  // way Pi's own ToolDefinition consumers erase this (any, any, any).
  const wrappedBuiltIns: ToolDefinition<any, any, any>[] = [
    wrapBuiltIn(createReadToolDefinition),
    wrapBuiltIn(createBashToolDefinition),
    wrapBuiltIn(createEditToolDefinition),
    wrapBuiltIn(createWriteToolDefinition),
    wrapBuiltIn(createGrepToolDefinition),
    wrapBuiltIn(createFindToolDefinition),
    wrapBuiltIn(createLsToolDefinition),
  ];

  // True once this extension has handled built-in registration for its lifetime.
  let builtInsRegistered = false;

  function builtInOwnership():
    | {
        uncontested: ToolDefinition<any, any, any>[];
        contested: ToolDefinition<any, any, any>[];
        unverified: ToolDefinition<any, any, any>[];
      }
    | undefined {
    try {
      const registered = pi.getAllTools();
      if (!Array.isArray(registered)) throw new Error("tool inventory was not an array");
      const uncontested: ToolDefinition<any, any, any>[] = [];
      const contested: ToolDefinition<any, any, any>[] = [];
      const unverified: ToolDefinition<any, any, any>[] = [];
      for (const tool of wrappedBuiltIns) {
        const matches = registered.filter(
          (info: ToolInfo) => info !== null && typeof info === "object" && info.name === tool.name,
        );
        const owner = matches.length === 1 ? matches[0].sourceInfo : undefined;
        if (
          !owner ||
          typeof owner.source !== "string" ||
          owner.source.trim().length === 0 ||
          typeof owner.path !== "string" ||
          owner.path.trim().length === 0
        ) {
          unverified.push(tool);
        } else if (owner.source === "builtin" || realpathOrSelf(owner.path) === extensionRealFile) {
          uncontested.push(tool);
        } else {
          contested.push(tool);
        }
      }
      return { uncontested, contested, unverified };
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Firstmate Calm: built-in ownership check unavailable; no built-in wrappers were registered. ${reason}`);
      return undefined;
    }
  }

  // Once Calm is active, claim every uncontested built-in and leave each contested
  // tool and its owning extension untouched. Tell the user which built-in Calm could
  // not take over, since Calm's presentation does not apply to it.
  function activateBuiltInsIfNeeded(ui: ExtensionUIContext): void {
    if (builtInsRegistered) return;
    const ownership = builtInOwnership();
    if (!ownership) {
      ui.notify(
        "Firstmate Calm: built-in ownership could not be verified, so Calm left every built-in tool untouched this session.",
        "warning",
      );
      return;
    }
    for (const tool of ownership.uncontested) pi.registerTool(tool);
    builtInsRegistered = true;
    if (ownership.contested.length > 0) {
      const names = ownership.contested.map((tool) => `"${tool.name}"`).join(", ");
      const plural = ownership.contested.length > 1;
      ui.notify(
        `Firstmate Calm: the ${names} built-in tool${plural ? "s are" : " is"} already provided by another extension, so Calm may not fully function for ${plural ? "them" : "it"} this session.`,
        "warning",
      );
    }
    for (const tool of ownership.contested) {
      console.error(`Firstmate Calm: skipped claiming built-in "${tool.name}" because another extension already owns it.`);
    }
    if (ownership.unverified.length > 0) {
      const names = ownership.unverified.map((tool) => `"${tool.name}"`).join(", ");
      const plural = ownership.unverified.length > 1;
      ui.notify(
        `Firstmate Calm: ownership of the ${names} built-in tool${plural ? "s" : ""} could not be verified, so Calm left ${plural ? "them" : "it"} untouched this session.`,
        "warning",
      );
    }
    for (const tool of ownership.unverified) {
      console.error(`Firstmate Calm: skipped claiming built-in "${tool.name}" because its ownership could not be verified.`);
    }
  }

  pi.on("session_start", (_event, ctx) => {
    calmToolRowRepaints.clear();
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
    if (calmPresentationIsActive()) activateBuiltInsIfNeeded(ctx.ui);
    setCalmStockExportRendering(false);
    publishPresentationState();
    agentRunActive = false;
    workingShipShown = false;
    // A genuine new session lifetime starts the boat at the normal initial position.
    workingShipAnimation.reset();
    applyWorkingPresentation(ctx.ui, true);
    ctx.ui.setHiddenThinkingLabel(calmPresentationIsActive() ? "" : undefined);
    ctx.ui.setStatus("firstmate-calm", undefined);
    removeTerminalInputHandler?.();
    removeTerminalInputHandler = ctx.ui.onTerminalInput((data) => {
      if (!getKeybindings().matches(data, "tui.input.submit")) return;

      const input = ctx.ui.getEditorText().trim();
      if (
        input !== "/share" &&
        input !== "/export" &&
        !input.startsWith("/export ")
      ) {
        return;
      }

      exportRendering = true;
      setCalmStockExportRendering(true);
      publishPresentationState();
      setTimeout(() => {
        exportRendering = false;
        setCalmStockExportRendering(false);
        publishPresentationState();
        // Repaint the rows Calm presents, never the whole transcript. Pi's export
        // prints "Session exported to: <path>" immediately before this runs, and
        // since Pi 0.83.0 setToolsExpanded() emits its own status line; consecutive
        // status lines coalesce, so a tools-expanded round-trip here silently
        // overwrote the confirmation and left the captain no record of where their
        // export landed. Invalidating the rows individually repaints the same
        // content with no status line of its own, and setStatus adds the redraw the
        // rows that consult Calm live in render(), such as operational user rows,
        // need without appending anything to the transcript.
        repaintCalmToolRows();
        ctx.ui.setStatus("firstmate-calm", undefined);
      }, 0);
    });
  });

  // Headless modes have no working row, so they must not retain UI work into
  // print-mode shutdown after Pi invalidates the session-bound context.
  pi.on("agent_start", (_event, ctx) => {
    agentRunActive = true;
    if (ctx.hasUI) applyWorkingPresentation(ctx.ui);
  });

  // agent_settled is emitted from a finally block, so it also covers abort and failure.
  pi.on("agent_settled", (_event, ctx) => {
    agentRunActive = false;
    if (workingShipShown) applyWorkingPresentation(ctx.ui);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    removeTerminalInputHandler?.();
    removeTerminalInputHandler = undefined;
    if (workingShipShown) applyWorkingPresentation(ctx.ui);
  });

  pi.registerCommand("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      if (active) activateBuiltInsIfNeeded(ctx.ui);
      publishPresentationState();
      applyWorkingPresentation(ctx.ui, true);
      // Pi re-runs every assistant row's layout from this call even when the label is
      // unchanged, which is what makes a toggle apply to rows already on screen.
      ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);
      ctx.ui.setStatus("firstmate-calm", undefined);

      const expanded = ctx.ui.getToolsExpanded();
      ctx.ui.setToolsExpanded(!expanded);
      ctx.ui.setToolsExpanded(expanded);
    },
  });
}
