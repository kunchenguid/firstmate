// Firstmate's home-persistent Pi transcript presentation toggle.
//
// Verified against Pi 0.81.1 through 0.82.1, which expose built-in ToolDefinitions,
// per-slot renderers, renderShell: "self", session_start replacement reasons,
// ExtensionUIContext.setToolsExpanded(), setWorkingVisible(), and
// setHiddenThinkingLabel(). The focused tests pin those assumptions but never reject a
// newer Pi solely for its version. The assistant, tool-row, operational-user, and
// non-conversation row presentation adapters probe the exact API they patch and degrade
// independently with a diagnostic (see installCalmPresentationAdapter below) if a future Pi
// removes it.
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
import {
  installCalmBranchSummaryLayout,
  installCalmCacheNoticeLayout,
  installCalmCompactionSummaryLayout,
  installCalmCustomEntryLayout,
  installCalmCustomMessageLayout,
  installCalmLeadingSpacerLayout,
  installCalmSkillInvocationLayout,
  installCalmUserBashLayout,
} from "./lib/fm-calm-nonconversation-layout.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
import {
  installCalmToolErrorTurnBoundary,
  installCalmToolLayout,
} from "./lib/fm-calm-tool-layout.ts";
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

function isTrustedInteractiveContext(
  ctx: Pick<ExtensionContext, "isProjectTrusted" | "mode">,
): boolean {
  return ctx.mode === "tui" && ctx.isProjectTrusted();
}

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("tool-row", installCalmToolLayout);
  installCalmPresentationAdapter("tool-error-turn", installCalmToolErrorTurnBoundary);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);
  installCalmPresentationAdapter("user-bash-row", installCalmUserBashLayout);
  installCalmPresentationAdapter("skill-invocation-row", installCalmSkillInvocationLayout);
  installCalmPresentationAdapter("compaction-summary-row", installCalmCompactionSummaryLayout);
  installCalmPresentationAdapter("branch-summary-row", installCalmBranchSummaryLayout);
  installCalmPresentationAdapter("custom-message-row", installCalmCustomMessageLayout);
  installCalmPresentationAdapter("custom-entry-row", installCalmCustomEntryLayout);
  installCalmPresentationAdapter("cache-notice-row", installCalmCacheNoticeLayout);
  installCalmPresentationAdapter("hidden-row-spacing", installCalmLeadingSpacerLayout);

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;

  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");
  const loadCalmPreference = (): boolean => {
    try {
      return readFileSync(calmPreferencePath, "utf8").trim() === "on";
    } catch {
      return false;
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
  const redrawTranscript = (ctx: ExtensionContext): void => {
    const expanded = ctx.ui.getToolsExpanded();
    ctx.ui.setToolsExpanded(!expanded);
    ctx.ui.setToolsExpanded(expanded);
  };
  const applyPresentation = (ctx: ExtensionContext, active: boolean): void => {
    ctx.ui.setWorkingVisible(!active);
    ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);
    ctx.ui.setStatus("firstmate-calm", undefined);
    redrawTranscript(ctx);
  };

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

    pi.registerTool({
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
    });
  }

  registerBuiltIn(createReadToolDefinition);
  registerBuiltIn(createBashToolDefinition);
  registerBuiltIn(createEditToolDefinition);
  registerBuiltIn(createWriteToolDefinition);
  registerBuiltIn(createGrepToolDefinition);
  registerBuiltIn(createFindToolDefinition);
  registerBuiltIn(createLsToolDefinition);

  pi.on("session_start", (_event, ctx) => {
    exportRendering = false;
    setCalmStockExportRendering(false);
    removeTerminalInputHandler?.();
    removeTerminalInputHandler = undefined;

    const trustedInteractive = isTrustedInteractiveContext(ctx);
    setCalmPresentation(trustedInteractive && loadCalmPreference());
    publishPresentationState();
    if (!trustedInteractive) return;

    applyPresentation(ctx, calmPresentationIsActive());
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
        redrawTranscript(ctx);
      }, 0);
    });
  });

  pi.registerCommand("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      if (!isTrustedInteractiveContext(ctx)) {
        ctx.ui.notify("Calm is available only in a trusted interactive Pi session.", "warning");
        return;
      }

      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      publishPresentationState();
      applyPresentation(ctx, active);
    },
  });
}
