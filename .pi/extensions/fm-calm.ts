/**
 * Present Firstmate's home-persistent Calm choice without changing transcript data.
 * docs/calm.md owns presentation capabilities; docs/calm-mode-feasibility.md owns the
 * built-in override constraints and Pi-source evidence; docs/configuration.md owns the
 * preference, and lib/fm-calm-working-ship.ts owns the boat.
 */
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
  installCalmPendingOperationalLayout,
  refreshCalmPendingOperationalRows,
} from "./lib/fm-calm-pending-operational-layout.ts";
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

type ToolPresentation = Pick<ToolDefinition<any, any, any>, "renderShell" | "renderCall" | "renderResult">;
type RendererRegistrar = {
  registerToolRenderer?: (
    resolver: (name: string, next: () => ToolPresentation | undefined) => ToolPresentation | undefined,
  ) => void;
};

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

/**
 * Reproduce Pi's default tool framing, including its configured output padding, around
 * a row's retained slot components.
 */
function refreshStandardShell(
  shell: StandardShellState,
  theme: RenderTheme<any, any, any>,
  context: RenderContext<any, any, any> & { outputPad?: number },
): Box {
  const background = context.isPartial
    ? (text: string) => theme.bg("toolPendingBg", text)
    : context.isError
      ? (text: string) => theme.bg("toolErrorBg", text)
      : (text: string) => theme.bg("toolSuccessBg", text);
  const outputPad = context.outputPad ?? 1;
  const box = shell.shell ?? new Box(outputPad, 1, background);
  shell.shell = box;
  box.setBgFn(background);
  (box as Box & { setPaddingX?: (padding: number) => void }).setPaddingX?.(outputPad);
  box.clear();
  if (shell.call) box.addChild(shell.call);
  if (shell.result) box.addChild(shell.result);
  return box;
}

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);
  installCalmPresentationAdapter("queued-operational-row", installCalmPendingOperationalLayout);

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  // One logical agent run, tracked from agent_start through agent_settled rather than
  // from turns or tool calls, so the boat never flickers between tool calls, automatic
  // continuations, retries, or compaction that stay inside the same run.
  let agentRunActive = false;
  let workingShipShown = false;
  let workingShipWidgetDisposed = false;
  // One animation instance per extension lifetime. Hiding the working widget freezes
  // this state; the next working period resumes it. session_start resets it so a fresh
  // Pi session starts at the normal initial position. Never module-global.
  const workingShipAnimation = createCalmWorkingShipAnimation();

  // Single owner of Calm's working-row presentation choice. The widget is only created
  // or removed on a real transition, so repeated starts cannot duplicate its timer.
  // The slot is shared with standalone Pi Calm; the dispose signal prevents turning
  // Firstmate Calm off from clearing a widget that the other extension installed.
  const applyWorkingPresentation = (
    ui: ExtensionUIContext,
    forceStockVisibility = false,
  ): void => {
    const showShip = agentRunActive && calmPresentationIsActive();
    if (showShip !== workingShipShown) {
      workingShipShown = showShip;
      if (showShip) {
        ui.setWidget(CALM_WORKING_SHIP_WIDGET_KEY, (tui) => {
          workingShipWidgetDisposed = false;
          const widget = createCalmWorkingShipWidget(tui, workingShipAnimation);
          const dispose = widget.dispose;
          widget.dispose = () => {
            workingShipWidgetDisposed = true;
            dispose();
          };
          return widget;
        });
        ui.setWorkingVisible(false);
      } else if (!workingShipWidgetDisposed) {
        ui.setWidget(CALM_WORKING_SHIP_WIDGET_KEY, undefined);
        ui.setWorkingVisible(true);
      }
    } else if (forceStockVisibility && !showShip && !workingShipWidgetDisposed) {
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

  // Stock slot components each visible row retains apart from Calm's zero-height ones,
  // keyed by the row-local state Pi hands every render slot.
  const standardShells = new WeakMap<object, StandardShellState>();

  /** Return one row's retained stock slot components, creating them on first use. */
  function standardShellFor(rowState: object): StandardShellState {
    let shell = standardShells.get(rowState);
    if (!shell) {
      shell = {};
      standardShells.set(rowState, shell);
    }
    return shell;
  }

  let codemodeUI: ExtensionUIContext | undefined;
  let codemodeWarningShown = false;

  /** Disclose a missing Codemode presentation capability once, through the UI when one exists, else stderr. */
  function reportCodemodeLimitation(reason: string): void {
    if (codemodeWarningShown || !calmPresentationIsActive()) return;
    codemodeWarningShown = true;
    const message = `Firstmate Calm: Codemode transcript remains visible because ${reason}. Tool execution is unchanged.`;
    // Raw stderr would draw over the live TUI and linger as a stray transcript line.
    if (codemodeUI) codemodeUI.notify(message, "warning");
    else console.error(message);
  }

  /** Warn only when Codemode exists on a Pi surface without renderer registration. */
  function reportMissingCodemodeRegistrar(): void {
    if (codemodeRegistrarLimitation && pi.getAllTools?.().some((tool) => tool.name === "codemode")) {
      reportCodemodeLimitation(codemodeRegistrarLimitation);
    }
  }

  /** Wrap only Codemode's installed renderers, preserving their components and framing. */
  function wrapCodemodePresentation(original: ToolPresentation): ToolPresentation {
    const renderCall = original.renderCall!;
    const renderResult = original.renderResult!;

    return {
      renderShell: "self",
      /** Hide the entire script shell, or delegate to the installed call renderer. */
      renderCall(args, theme, context) {
        rememberCalmToolRow(context.state, context.invalidate);
        if (exportRendering) return renderCall(args, theme, context);
        if (calmPresentationHides("assistant-tool-call")) return new Container();
        const shell = standardShellFor(context.state);
        shell.call = renderCall(args, theme, { ...context, lastComponent: shell.call });
        return original.renderShell === "self" ? shell.call : refreshStandardShell(shell, theme, context);
      },
      /** Hide nested-call summaries and output, or delegate to the installed result renderer. */
      renderResult(result, options, theme, context) {
        rememberCalmToolRow(context.state, context.invalidate);
        if (exportRendering) return renderResult(result, options, theme, context);
        if (calmPresentationHides("tool-result")) return new Container();
        const shell = standardShellFor(context.state);
        shell.result = renderResult(result, options, theme, { ...context, lastComponent: shell.result });
        if (original.renderShell === "self") return shell.result;
        refreshStandardShell(shell, theme, context);
        return new Container();
      },
    };
  }

  const rendererRegistrar = pi as ExtensionAPI & RendererRegistrar;
  let codemodeRegistrarLimitation: string | undefined = "pi.registerToolRenderer() is unavailable";
  if (typeof rendererRegistrar.registerToolRenderer === "function") {
    try {
      /** Wrap only Codemode, leaving every other tool's resolver chain untouched. */
      rendererRegistrar.registerToolRenderer((name, next) => {
        const original = next();
        if (name !== "codemode") return original;
        if (!original?.renderCall || !original.renderResult) {
          reportCodemodeLimitation("its installed call/result renderers are unavailable");
          return original;
        }
        return wrapCodemodePresentation(original);
      });
      codemodeRegistrarLimitation = undefined;
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      codemodeRegistrarLimitation = `pi.registerToolRenderer() could not register its presentation: ${reason}`;
    }
  }

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

    if (!originalRenderCall || !originalRenderResult) {
      throw new Error(`Firstmate calm mode requires both render slots for Pi built-in tool ${original.name}`);
    }

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

        const state = standardShellFor(context.state as object);
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

        const state = standardShellFor(context.state as object);
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

  // True once this extension has handled built-in registration for its lifetime:
  // either all seven synchronously at load, or only the uncontested subset during
  // first activation.
  let builtInsRegistered = false;

  // Gate on Calm already being on at load time. This must stay synchronous and
  // unconditional here (see docs/calm-mode-feasibility.md): a foreign-claim check is
  // not reachable at this point, while deferral would make restored rows capture the
  // wrong definition. A Calm-off session or reload registers nothing and creates no
  // collision exposure.
  if (loadCalmPreference()) {
    for (const tool of wrappedBuiltIns) pi.registerTool(tool);
    builtInsRegistered = true;
  }

  // Which of the 7 built-ins are currently owned by a different, non-builtin
  // extension. Only safe to call once every extension has finished loading (see
  // docs/calm-mode-feasibility.md); never call this during the factory's own synchronous
  // execution above.
  function contestedBuiltIns(): ToolDefinition<any, any, any>[] {
    let registered: ToolInfo[];
    try {
      registered = pi.getAllTools();
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Firstmate Calm: built-in ownership check unavailable, claiming every built-in unconditionally. ${reason}`);
      return [];
    }
    return wrappedBuiltIns.filter((tool) => {
      const owner = registered.find((info) => info.name === tool.name)?.sourceInfo;
      return owner !== undefined && owner.source !== "builtin" && realpathOrSelf(owner.path) !== extensionRealFile;
    });
  }

  // The first time Calm turns on in a session that started off, claim every
  // uncontested built-in and leave each contested tool and its owning extension
  // untouched. Tell the user which built-in Calm could not take over, since Calm's
  // presentation does not apply to it.
  function activateBuiltInsIfNeeded(ui: ExtensionUIContext): void {
    if (builtInsRegistered) return;
    const contested = contestedBuiltIns();
    const contestedNames = new Set(contested.map((tool) => tool.name));
    for (const tool of wrappedBuiltIns) {
      if (!contestedNames.has(tool.name)) pi.registerTool(tool);
    }
    builtInsRegistered = true;
    if (contested.length === 0) return;
    const names = contested.map((tool) => `"${tool.name}"`).join(", ");
    const plural = contested.length > 1;
    ui.notify(
      `Firstmate Calm: the ${names} built-in tool${plural ? "s are" : " is"} already provided by another extension, so Calm may not fully function for ${plural ? "them" : "it"} this session.`,
      "warning",
    );
    for (const tool of contested) {
      console.error(`Firstmate Calm: skipped claiming built-in "${tool.name}" because another extension already owns it.`);
    }
  }

  // Backstop for the one case activateBuiltInsIfNeeded cannot reach: Calm registered
  // unconditionally at load time because it was already on, without any chance to
  // check for a foreign claim first, so it can still silently lose a name to an
  // earlier-loaded extension. Runs on every session_start reason because a reload
  // rebuilds every extension's registrations from scratch, so last session's clean
  // bill of health does not carry over.
  function reportBuiltInLosses(): void {
    if (!builtInsRegistered) return;
    let registered: ToolInfo[];
    try {
      registered = pi.getAllTools();
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Firstmate Calm: built-in ownership check unavailable. ${reason}`);
      return;
    }
    for (const tool of wrappedBuiltIns) {
      const owner = registered.find((info) => info.name === tool.name)?.sourceInfo;
      if (owner && owner.source !== "builtin" && realpathOrSelf(owner.path) !== extensionRealFile) {
        console.error(
          `Firstmate Calm: another extension (${owner.path}) also claimed the built-in "${tool.name}" tool and won; Calm's presentation for it is unavailable this session.`,
        );
      }
    }
  }

  pi.on("session_start", (_event, ctx) => {
    reportBuiltInLosses();
    calmToolRowRepaints.clear();
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
    setCalmStockExportRendering(false);
    codemodeUI = ctx.hasUI ? ctx.ui : undefined;
    reportMissingCodemodeRegistrar();
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
      if (!getKeybindings().matches(data, "tui.input.submit")) return undefined;

      const input = ctx.ui.getEditorText().trim();
      if (
        input !== "/share" &&
        input !== "/export" &&
        !input.startsWith("/export ")
      ) {
        return undefined;
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
      return undefined;
    });
  });

  pi.on("agent_start", (_event, ctx) => {
    agentRunActive = true;
    applyWorkingPresentation(ctx.ui);
  });

  // agent_settled is emitted from a finally block, so it also covers abort and failure.
  pi.on("agent_settled", (_event, ctx) => {
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.registerCommand("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      if (active) activateBuiltInsIfNeeded(ctx.ui);
      reportMissingCodemodeRegistrar();
      publishPresentationState();
      applyWorkingPresentation(ctx.ui, true);
      // Pi re-runs every assistant row's layout from this call even when the label is
      // unchanged, which is what makes a toggle apply to rows already on screen.
      ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);
      ctx.ui.setStatus("firstmate-calm", undefined);
      refreshCalmPendingOperationalRows();

      const expanded = ctx.ui.getToolsExpanded();
      ctx.ui.setToolsExpanded(!expanded);
      ctx.ui.setToolsExpanded(expanded);
    },
  });
}
