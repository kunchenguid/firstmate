// Firstmate's home-persistent Pi transcript presentation toggle.
//
// Compatibility boundary: Pi 0.81.1 through 0.82.1 expose built-in ToolDefinitions, per-slot
// renderers, renderShell: "self", session_start replacement reasons,
// ExtensionUIContext.setToolsExpanded(), setWorkingVisible(), and
// setHiddenThinkingLabel(). A preflight certifies those assumptions before any override. Version-bounded
// presentation adapters cover collapsed assistant thinking and operational user rows;
// Pi still exposes no global renderer for arbitrary built-in or custom rows.
// docs/configuration.md owns the home-local Calm preference contract.
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionContext,
  ToolDefinition,
  ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";
import {
  AssistantMessageComponent,
  createBashToolDefinition,
  createEditToolDefinition,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  InteractiveMode,
  VERSION,
} from "@earendil-works/pi-coding-agent";
import { Box, Container, getKeybindings, Text, type Component } from "@earendil-works/pi-tui";
import type { TSchema } from "typebox";
import { installCalmAssistantLayout } from "./lib/fm-calm-assistant-layout.ts";
import { calmCompatibilityFailure } from "./lib/fm-calm-compatibility.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  calmTechnicalFailureText,
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

export default function (pi: ExtensionAPI) {
  const builtInFactories = [
    createReadToolDefinition,
    createBashToolDefinition,
    createEditToolDefinition,
    createWriteToolDefinition,
    createGrepToolDefinition,
    createFindToolDefinition,
    createLsToolDefinition,
  ] as const;
  const builtInRenderers: string[] = [];
  for (const factory of builtInFactories) {
    try {
      const definition = factory(process.cwd());
      if (definition.renderCall && definition.renderResult) builtInRenderers.push(definition.name);
    } catch {
      // The compatibility result below owns the actionable stock-rendering fallback.
    }
  }
  const interactivePrototype = InteractiveMode.prototype as unknown as { addMessageToChat?: unknown };
  let compatibilityFailure = calmCompatibilityFailure(VERSION, {
    assistantLayout: typeof AssistantMessageComponent.prototype.updateContent === "function",
    operationalUserLayout: typeof interactivePrototype.addMessageToChat === "function",
    builtInRenderers,
  });
  if (!compatibilityFailure) {
    try {
      installCalmAssistantLayout();
      installCalmOperationalUserLayout();
    } catch (error) {
      compatibilityFailure = error instanceof Error ? error.message : String(error);
    }
  }

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;

  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");
  const loadCalmPreference = (): boolean => {
    try {
      const preference = readFileSync(calmPreferencePath, "utf8").trim();
      if (preference === "on") return true;
      if (preference === "off") return false;
      return false;
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === "ENOENT";
    }
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

  if (compatibilityFailure) {
    const warning = `Firstmate Calm is disabled for Pi ${VERSION}: ${compatibilityFailure}; stock rendering is active. Update Firstmate before enabling Calm.`;
    let warned = false;
    setCalmPresentation(false);
    setCalmStockExportRendering(false);
    pi.on("session_start", (_event, ctx) => {
      ctx.ui.setWorkingVisible(true);
      ctx.ui.setHiddenThinkingLabel(undefined);
      ctx.ui.setStatus("firstmate-calm", undefined);
      if (!warned) {
        warned = true;
        ctx.ui.notify(warning, "warning");
      }
    });
    pi.registerCommand("calm", {
      description: "Set, clear, inspect, or toggle Firstmate's supported conversation presentation.",
      handler: async (_args, ctx) => {
        ctx.ui.notify(warning, "warning");
      },
    });
    return;
  }

  registerFirstmateSyntheticPresentation(pi);

  function registerBuiltIn<TParams extends TSchema, TDetails, TState>(
    factory: DefinitionFactory<TParams, TDetails, TState>,
  ): void {
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

    const wrapped: ToolDefinition<TParams, TDetails, TState> = {
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
        if (exportRendering) return originalRenderCall(args, theme, context);
        if (calmPresentationHides("assistant-tool-call") && !context.expanded) return new Container();
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
        if (exportRendering) return originalRenderResult(result, options, theme, context);
        if (calmPresentationHides("tool-result") && !options.expanded) {
          if (context.isError) {
            return new Text(
              theme.fg("dim", calmTechnicalFailureText()),
              0,
              0,
            );
          }
          return new Container();
        }
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
    pi.registerTool(wrapped);
  }

  registerBuiltIn(createReadToolDefinition);
  registerBuiltIn(createBashToolDefinition);
  registerBuiltIn(createEditToolDefinition);
  registerBuiltIn(createWriteToolDefinition);
  registerBuiltIn(createGrepToolDefinition);
  registerBuiltIn(createFindToolDefinition);
  registerBuiltIn(createLsToolDefinition);

  const applyCalmPresentation = (
    active: boolean,
    ctx: ExtensionContext,
  ): void => {
    setCalmPresentation(active);
    publishPresentationState();
    ctx.ui.setWorkingVisible(true);
    ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);
    ctx.ui.setStatus("firstmate-calm", undefined);
    const expanded = ctx.ui.getToolsExpanded();
    ctx.ui.setToolsExpanded(!expanded);
    ctx.ui.setToolsExpanded(expanded);
  };

  pi.on("session_start", (_event, ctx) => {
    exportRendering = false;
    setCalmStockExportRendering(false);
    applyCalmPresentation(loadCalmPreference(), ctx);
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
        const expanded = ctx.ui.getToolsExpanded();
        ctx.ui.setToolsExpanded(!expanded);
        ctx.ui.setToolsExpanded(expanded);
      }, 0);
      return undefined;
    });
  });

  pi.registerCommand("calm", {
    description: "Set, clear, inspect, or toggle Firstmate's supported conversation presentation.",
    handler: async (args, ctx) => {
      const action = args.trim().toLowerCase();
      if (action === "status") {
        ctx.ui.notify(`Calm is ${calmPresentationIsActive() ? "on" : "off"}.`, "info");
        return;
      }
      if (action && action !== "on" && action !== "off") {
        ctx.ui.notify("Usage: /calm [on|off|status]", "error");
        return;
      }
      const active = action === "on" || (action === "" && !calmPresentationIsActive());
      persistCalmPreference(active);
      applyCalmPresentation(active, ctx);
    },
  });
}
