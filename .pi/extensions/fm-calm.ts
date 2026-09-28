// Firstmate's home-persistent Pi transcript presentation toggle.
//
// Verified against Pi 0.81.1, 0.82.0, and 0.84.4, which expose session_start replacement
// reasons, agent_start and agent_settled, ExtensionUIContext.setToolsExpanded(),
// setWorkingVisible(), setWidget() with a disposable component factory, and
// setHiddenThinkingLabel().
// ./lib/fm-calm-working-ship.ts owns the animated working presentation this file
// installs. The focused tests pin those assumptions but never reject a
// newer Pi solely for its version. The collapsed-thinking, operational-user,
// queued-operational, and tool-row presentation adapters probe the exact API they patch and degrade
// independently with a diagnostic (see installCalmPresentationAdapter below) if a future
// Pi removes it; Pi still exposes no global renderer for arbitrary built-in or custom rows.
// docs/configuration.md owns the home-local Calm preference contract.
//
// Built-in tool rows are hidden by ./lib/fm-calm-tool-layout.ts at the row's render seam,
// never by registering same-name tools: Pi keeps one unmerged definition per tool name and
// treats a second extension's claim as a fatal startup conflict, so ownership-based
// hiding cannot coexist with any other extension that overrides a built-in.
// docs/calm.md owns the user-facing behavior.
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
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { getKeybindings } from "@earendil-works/pi-tui";
import { installCalmAssistantLayout } from "./lib/fm-calm-assistant-layout.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
import {
  installCalmPendingOperationalLayout,
  refreshCalmPendingOperationalRows,
} from "./lib/fm-calm-pending-operational-layout.ts";
import { installCalmToolLayout } from "./lib/fm-calm-tool-layout.ts";
import {
  CALM_WORKING_SHIP_WIDGET_KEY,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} from "./lib/fm-calm-working-ship.ts";
import {
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  registerFirstmateSyntheticPresentation,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./lib/fm-calm-visibility.ts";

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

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);
  installCalmPresentationAdapter("queued-operational-row", installCalmPendingOperationalLayout);
  installCalmPresentationAdapter("built-in-tool-row", installCalmToolLayout);

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

  pi.on("session_start", (_event, ctx) => {
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
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
        // Redraw without appending to the transcript. Pi's export prints "Session
        // exported to: <path>" immediately before this runs, and since Pi 0.83.0
        // setToolsExpanded() emits its own status line; consecutive status lines
        // coalesce, so a tools-expanded round-trip here silently overwrote the
        // confirmation and left the captain no record of where their export landed.
        // setStatus adds the redraw the rows that consult Calm live in render(), such
        // as operational user rows, need without appending anything.
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
