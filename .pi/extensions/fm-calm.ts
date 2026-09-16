// Firstmate's home-persistent Pi transcript presentation toggle.
//
// Verified against Pi 0.85.1, which exposes display-only Markdown transformers and
// exports the assistant, tool, and interactive components used by the zero-height
// presentation adapters, plus the lifecycle and ExtensionUIContext methods below.
// ./lib/fm-calm-working-ship.ts owns the animated working presentation. Focused tests
// pin those assumptions but never reject a newer Pi solely for its version. Each
// presentation adapter probes its exact API and degrades independently with a
// diagnostic if a future Pi removes one. docs/configuration.md owns the home-local
// Calm preference contract.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { getKeybindings, Text } from "@earendil-works/pi-tui";
import {
  installCalmAssistantLayout,
  installCalmToolLayout,
} from "./lib/fm-calm-assistant-layout.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
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

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const CALM_CURRENT_STEP_WIDGET_KEY = "firstmate-calm-current-step";

type CurrentStep = {
  key: string;
  text: string;
};

function currentStep(message: AssistantMessage, messageSequence: number): CurrentStep | undefined {
  for (let index = message.content.length - 1; index >= 0; index--) {
    const block = message.content[index];
    if (block.type !== "thinking") continue;
    const lines = block.thinking
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const latest = lines.at(-1);
    if (!latest) continue;
    const text = latest.match(/^\*\*(.+)\*\*$/)?.[1] ?? latest;
    return { key: `${messageSequence}:${index}:${lines.length}`, text };
  }
  return undefined;
}

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
  installCalmPresentationAdapter("assistant-markdown", () => installCalmAssistantLayout(pi));
  installCalmPresentationAdapter("tool-row", installCalmToolLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  // One logical agent run, tracked from agent_start through agent_settled rather than
  // from turns or tool calls, so the boat never flickers between tool calls, automatic
  // continuations, retries, or compaction that stay inside the same run.
  let agentRunActive = false;
  let workingShipShown = false;
  let currentStepWidgetShown = false;
  let currentStepRequestRender: (() => void) | undefined;
  let assistantMessageSequence = 0;
  let currentStepKey: string | undefined;
  let currentStepNumber = 0;
  let currentStepText: string | undefined;

  const clearCurrentStep = (): void => {
    currentStepKey = undefined;
    if (currentStepText === undefined) return;
    currentStepText = undefined;
    currentStepRequestRender?.();
  };

  // Pi renders above-editor widgets in insertion order. Install this zero-height-until-
  // needed component before the ship and update it in place, because setWidget()
  // removes and re-adds an existing key and would move every new step below the ship.
  const applyCurrentStepPresentation = (ui: ExtensionUIContext): void => {
    const show = agentRunActive && calmPresentationIsActive();
    if (show === currentStepWidgetShown) return;
    currentStepWidgetShown = show;
    if (!show) {
      ui.setWidget(CALM_CURRENT_STEP_WIDGET_KEY, undefined);
      currentStepRequestRender = undefined;
      return;
    }
    ui.setWidget(CALM_CURRENT_STEP_WIDGET_KEY, (tui) => {
      const requestRender = (): void => tui.requestRender();
      currentStepRequestRender = requestRender;
      return {
        render: (width) =>
          currentStepText === undefined
            ? []
            : new Text(currentStepText, 1, 0).render(width),
        invalidate: () => {},
        dispose: () => {
          if (currentStepRequestRender === requestRender) {
            currentStepRequestRender = undefined;
          }
        },
      };
    });
  };

  const showCurrentStep = (message: AssistantMessage): void => {
    if (!agentRunActive || !calmPresentationIsActive()) {
      clearCurrentStep();
      return;
    }
    const step = currentStep(message, assistantMessageSequence);
    if (!step) return;
    if (step.key !== currentStepKey) {
      currentStepKey = step.key;
      currentStepNumber += 1;
    }
    currentStepText = `Step ${currentStepNumber}: ${step.text}`;
    currentStepRequestRender?.();
  };

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

  pi.on("session_start", (_event, ctx) => {
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
    setCalmStockExportRendering(false);
    publishPresentationState();
    agentRunActive = false;
    workingShipShown = false;
    currentStepWidgetShown = false;
    currentStepRequestRender = undefined;
    assistantMessageSequence = 0;
    currentStepNumber = 0;
    clearCurrentStep();
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
        // setStatus requests a redraw without appending a transcript row, so the
        // tool and operational adapters return to Calm without overwriting Pi's
        // visible "Session exported to" confirmation.
        ctx.ui.setStatus("firstmate-calm", undefined);
      }, 0);
      return undefined;
    });
  });

  pi.on("agent_start", (_event, ctx) => {
    assistantMessageSequence = 0;
    currentStepNumber = 0;
    clearCurrentStep();
    agentRunActive = true;
    applyCurrentStepPresentation(ctx.ui);
    applyWorkingPresentation(ctx.ui);
    ctx.ui.setStatus("firstmate-calm", undefined);
  });

  pi.on("message_start", (event) => {
    if (event.message.role !== "assistant") return;
    assistantMessageSequence += 1;
    clearCurrentStep();
  });

  pi.on("message_update", (event) => {
    if (event.message.role !== "assistant") return;
    showCurrentStep(event.message);
  });

  pi.on("message_end", (event) => {
    if (event.message.role === "assistant") clearCurrentStep();
  });

  // agent_settled is emitted from a finally block, so it also covers abort and failure.
  pi.on("agent_settled", (_event, ctx) => {
    agentRunActive = false;
    clearCurrentStep();
    applyCurrentStepPresentation(ctx.ui);
    applyWorkingPresentation(ctx.ui);
    ctx.ui.setStatus("firstmate-calm", undefined);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    clearCurrentStep();
    applyCurrentStepPresentation(ctx.ui);
    applyWorkingPresentation(ctx.ui);
    ctx.ui.setStatus("firstmate-calm", undefined);
  });

  pi.registerCommand("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      publishPresentationState();
      if (!active) clearCurrentStep();
      applyCurrentStepPresentation(ctx.ui);
      applyWorkingPresentation(ctx.ui, true);
      ctx.ui.setStatus("firstmate-calm", undefined);
      // Pi re-runs every assistant row's layout from this call even when the label is
      // unchanged, which is what makes a toggle apply to rows already on screen.
      ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);

      const expanded = ctx.ui.getToolsExpanded();
      ctx.ui.setToolsExpanded(!expanded);
      ctx.ui.setToolsExpanded(expanded);
    },
  });
}
