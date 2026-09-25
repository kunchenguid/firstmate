// Firstmate's home-persistent omp transcript presentation toggle.
//
// A port of .pi/extensions/fm-calm.ts for the omp fork. The Calm policy, the
// transcript-class allowlist, and the sprite geometry are shared: this file installs
// only the omp-specific presentation adapters and the /calm command. The omp-specific
// differences from Pi are stated once here:
//   - omp exposes no setWorkingVisible / setHiddenThinkingLabel on ExtensionUIContext.
//     The stock working spinner is gated through InteractiveMode.ensureLoadingAnimation
//     (./lib/fm-calm-working-loader.ts); thinking hide is policy-only in the assistant
//     layout adapter.
//   - agent_end without a continuation replaces Pi's agent_settled for run lifetime.
//   - Tool rows are gated via ToolExecutionComponent.render and
//     ReadToolGroupComponent.render rather than per-name renderer functions and
//     a first-wins ToolDefinition registry.
//   - No supervision-branch tools exist; fm_watch_arm_omp calm rendering is owned by
//     fm-primary-omp-watch.ts, which listens for FIRSTMATE_CALM_PRESENTATION_EVENT.
//   - The standard-ANSI working-ship widget and sprite geometry are shared verbatim
//     with Pi through ../../.pi/extensions/lib/fm-calm-working-ship.ts.
//
// docs/configuration.md owns config/calm. docs/calm.md owns captain-facing behavior,
// and docs/calm-mode-feasibility.md owns the version-scoped evidence.
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
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import type { TUI } from "@oh-my-pi/pi-tui";
import { installCalmAssistantLayout } from "./lib/fm-calm-assistant-layout.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  registerFirstmateSyntheticPresentation,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./lib/fm-calm-visibility.ts";
import {
  clearLiveWorkingLoader,
  installCalmWorkingLoaderGate,
} from "./lib/fm-calm-working-loader.ts";
import {
  CALM_WORKING_SHIP_WIDGET_KEY,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} from "../../.pi/extensions/lib/fm-calm-working-ship.ts";

type ExtensionUIContext = {
  setWidget: (
    key: string,
    factory: ((tui: TUI) => unknown) | undefined,
    options?: { placement?: string },
  ) => void;
  setStatus: (key: string, value: unknown) => void;
  setWorkingMessage?: (message: string | undefined) => void;
  getToolsExpanded: () => boolean;
  setToolsExpanded: (expanded: boolean) => void;
  getEditorText: () => string;
  onTerminalInput: (handler: (data: string) => unknown) => () => void;
  notify: (message: string, level?: string) => void;
  ctx?: unknown;
};

type ExtensionCommandContext = {
  ui: ExtensionUIContext;
  hasUI?: boolean;
};

type ExtensionAPI = {
  on?: (event: string, handler: (event: unknown, ctx: { ui: ExtensionUIContext }) => unknown) => void;
  registerCommand?: (
    name: string,
    command: {
      description: string;
      handler: (args: string, ctx: ExtensionCommandContext) => Promise<void> | void;
    },
  ) => void;
  events?: {
    emit: (event: string, data: unknown) => void;
    on?: (event: string, handler: (data: unknown) => void) => void;
  };
  registerMessageRenderer?: (customType: string, renderer: (...args: unknown[]) => unknown) => void;
  registerEntryRenderer?: (customType: string, renderer: (...args: unknown[]) => unknown) => void;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

// Each presentation adapter probes the exact omp API it patches. If a future omp
// removes that API, only the affected adapter degrades; the rest of Calm keeps working.
function installCalmPresentationAdapter(name: string, install: () => void): void {
  try {
    install();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`Firstmate Calm: skipped ${name} adapter on omp. ${reason}`);
  }
}

// Adapt presentation only: native schemas, approval policy, and execution stay owned by
// omp. omp routes every tool row through ToolExecutionComponent and grouped reads
// through ReadToolGroupComponent, so gating those two renders covers every tool
// without replacing a tool definition or tracking built-in names.
const CALM_TOOL_COMPONENTS = ["ToolExecutionComponent", "ReadToolGroupComponent"] as const;
const CALM_TOOL_COMPONENT_PATCH = Symbol.for("firstmate:calm-tool-component:omp");

type ToolComponentPrototype = {
  render: (width: number) => string[];
  [CALM_TOOL_COMPONENT_PATCH]?: { hides: typeof calmPresentationHides };
};

function installCalmToolComponents(): void {
  const ompExports = OmpCodingAgent as unknown as Record<string, unknown>;
  for (const name of CALM_TOOL_COMPONENTS) {
    installCalmPresentationAdapter(name, () => {
      const componentClass = ompExports[name];
      if (typeof componentClass !== "function") {
        throw new Error(`omp does not expose ${name}`);
      }
      const prototype: ToolComponentPrototype | undefined = componentClass.prototype;
      if (!prototype || typeof prototype.render !== "function") {
        throw new Error(`omp does not expose ${name}.render`);
      }
      const installed = prototype[CALM_TOOL_COMPONENT_PATCH];
      if (installed) {
        installed.hides = calmPresentationHides;
        return;
      }
      const patch = { hides: calmPresentationHides };
      const original = prototype.render;
      prototype.render = function (this: unknown, width: number): string[] {
        return patch.hides("assistant-tool-call") ? [] : original.call(this, width);
      };
      prototype[CALM_TOOL_COMPONENT_PATCH] = patch;
    });
  }
}

// Rows already painted, and rows retired to terminal scrollback, do not repaint just
// because the gate above changed answer. omp's own tool-visibility toggle drives the
// transcript container and replays native history, so Calm drives the same pair on
// every state change. The instance is captured from addMessageToChat because omp
// hands extensions no InteractiveMode reference.
const CALM_CAPTURE_PATCH = Symbol.for("firstmate:calm-interactive-capture:omp");

type InteractiveModeInstance = {
  chatContainer?: { setToolActivityVisible?: (visible: boolean) => void };
  ui?: { resetDisplay?: () => void };
};

let interactiveMode: InteractiveModeInstance | undefined;

function installInteractiveModeCapture(): void {
  installCalmPresentationAdapter("interactive-mode-capture", () => {
    const ompExports = OmpCodingAgent as unknown as Record<string, unknown>;
    const componentClass = ompExports.InteractiveMode;
    if (typeof componentClass !== "function") {
      throw new Error("omp does not expose InteractiveMode");
    }
    const prototype: Record<string | symbol, unknown> = componentClass.prototype;
    if (prototype[CALM_CAPTURE_PATCH] !== undefined) return;
    const original = prototype.addMessageToChat;
    if (typeof original !== "function") {
      throw new Error("omp does not expose InteractiveMode.addMessageToChat");
    }
    prototype.addMessageToChat = function (this: InteractiveModeInstance, ...args: unknown[]) {
      interactiveMode = this;
      return original.apply(this, args);
    };
    prototype[CALM_CAPTURE_PATCH] = true;
  });
}

function refreshCalmToolActivity(active: boolean): void {
  const container = interactiveMode?.chatContainer;
  if (container && typeof container.setToolActivityVisible === "function") {
    container.setToolActivityVisible(!active);
  }
  const ui = interactiveMode?.ui;
  if (ui && typeof ui.resetDisplay === "function") {
    ui.resetDisplay();
  }
}

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);
  installCalmPresentationAdapter("working-loader", installCalmWorkingLoaderGate);
  installCalmToolComponents();
  installInteractiveModeCapture();

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  let agentRunActive = false;
  let workingShipShown = false;
  const workingShipAnimation = createCalmWorkingShipAnimation();

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
          ? (tui: TUI) => createCalmWorkingShipWidget(tui, workingShipAnimation)
          : undefined,
      );
      if (showShip) {
        clearLiveWorkingLoader(ui);
        ui.setWorkingMessage?.(undefined);
      }
    } else if (forceStockVisibility && !showShip) {
      ui.setWidget(CALM_WORKING_SHIP_WIDGET_KEY, undefined);
      workingShipShown = false;
    }
  };

  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");

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
    pi.events?.emit(FIRSTMATE_CALM_PRESENTATION_EVENT, {
      active: calmPresentationIsActive(),
      stockExportRendering: exportRendering,
    });
  };

  registerFirstmateSyntheticPresentation(pi);

  const agentEndContinues = (event: unknown): boolean => {
    if (!event || typeof event !== "object") return false;
    if ("isTerminal" in event && event.isTerminal === false) return true;
    return "willContinue" in event && event.willContinue === true;
  };

  pi.on?.("session_start", (_event, ctx) => {
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
    refreshCalmToolActivity(calmPresentationIsActive());
    setCalmStockExportRendering(false);
    publishPresentationState();
    agentRunActive = false;
    workingShipShown = false;
    workingShipAnimation.reset();
    applyWorkingPresentation(ctx.ui, true);
    ctx.ui.setStatus("firstmate-calm", undefined);
    removeTerminalInputHandler?.();
    removeTerminalInputHandler = ctx.ui.onTerminalInput((data) => {
      // omp does not export getKeybindings; match Enter-ish submit conservatively.
      if (data !== "\r" && data !== "\n" && data !== "\r\n") return undefined;
      const input = ctx.ui.getEditorText().trim();
      if (input !== "/share" && input !== "/export" && !input.startsWith("/export ")) {
        return undefined;
      }
      exportRendering = true;
      setCalmStockExportRendering(true);
      publishPresentationState();
      setTimeout(() => {
        exportRendering = false;
        setCalmStockExportRendering(false);
        publishPresentationState();
        // Toggle tools-expanded to force a redraw without a status line.
        try {
          const expanded = ctx.ui.getToolsExpanded();
          ctx.ui.setToolsExpanded(!expanded);
          ctx.ui.setToolsExpanded(expanded);
        } catch {
          // ignore redraw failures
        }
        ctx.ui.setStatus("firstmate-calm", undefined);
      }, 0);
      return undefined;
    });
  });

  pi.on?.("agent_start", (_event, ctx) => {
    agentRunActive = true;
    applyWorkingPresentation(ctx.ui);
  });

  pi.on?.("agent_end", (event, ctx) => {
    if (agentEndContinues(event)) return;
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.on?.("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.registerCommand?.("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      refreshCalmToolActivity(active);
      publishPresentationState();
      applyWorkingPresentation(ctx.ui, true);
      if (active) clearLiveWorkingLoader(ctx.ui);
      ctx.ui.setStatus("firstmate-calm", undefined);
      try {
        const expanded = ctx.ui.getToolsExpanded();
        ctx.ui.setToolsExpanded(!expanded);
        ctx.ui.setToolsExpanded(expanded);
      } catch {
        // ignore redraw failures
      }
      ctx.ui.notify(
        active
          ? "Calm on: quieter transcript presentation for this Firstmate home."
          : "Calm off: ordinary omp transcript presentation restored.",
        "info",
      );
    },
  });
}
