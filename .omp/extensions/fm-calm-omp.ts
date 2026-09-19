// Firstmate's Calm presentation toggle for the omp (Oh My Pi) primary.
//
// A presentation-only adaptation of .pi/extensions/fm-calm.ts. While Calm is on
// and one logical agent run is active (agent_start through the agent_end whose
// willContinue is not true), the shared SSHHIP boat is installed as an
// above-editor widget and built-in tool rows are collapsed. The state line under
// the boat and the footer hook status carry only what omp's own events show:
// `working`, `waiting for you` (any open tool approval or a running built-in
// `ask`), or `working, quiet Nm` when no tool or message event has arrived for a
// while. There is never a percent, an estimate, or a "nearly done" claim, and the
// run is reported finished only when omp settles it.
//
// Verified against omp 18.2.1: ctx.ui.setWidget(key, factory, { placement }) hands
// the factory the live TUI (requestRender) and theme; setWidget(key, undefined)
// disposes the component; setToolsExpanded/getToolsExpanded and setStatus(key,
// undefined-to-clear) are exposed by the interactive controller; agent_end
// carries willContinue; tool_approval_requested/resolved fire only when a tool
// needs approval, always as a pair carrying the same toolCallId, and several can
// be open at once because shared-concurrency tools run in parallel;
// tool_execution_start/end carry toolCallId and toolName and always pair, and the
// built-in question tool is named `ask`. omp has no setWorkingVisible and no
// per-row renderer for built-in tools, so the stock working row stays on screen
// under the boat and tool rows collapse rather than disappear.
//
// The preference is the home-local config/calm file that
// .pi/extensions/lib/fm-calm-preference.ts also serves the Pi extension from;
// docs/configuration.md owns its contract. It is reloaded on session_start
// (process startup and extension reload) and on session_switch, which omp 18.2.1
// emits for every in-process /new, /resume, and /fork, so a choice made on
// another harness applies at the next omp session. A worker omp launched from a
// Firstmate checkout loads this file too
// but reads only its own effective home, where a crewmate worktree has no
// config/calm. Toggling Calm off restores the tool expansion observed when it was
// turned on. No tool is registered and no model context is injected.
import { loadCalmPreference, persistCalmPreference } from "../../.pi/extensions/lib/fm-calm-preference.ts";
import {
  CALM_WORKING_SHIP_WIDGET_KEY,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} from "../../.pi/extensions/lib/fm-calm-working-ship.ts";

// The omp extension API surface this file uses, declared locally: omp ships no
// separately installable type package and is a Pi fork whose event and UI names
// match where they are used here.
type WidgetComponent = { render(width: number): string[]; invalidate(): void; dispose?(): void };
type WidgetTui = { requestRender(): void };
type ExtensionUI = {
  setWidget(key: string, factory: ((tui: WidgetTui, theme: unknown) => WidgetComponent) | undefined, options?: { placement?: "aboveEditor" | "belowEditor" }): void;
  setStatus(key: string, text: string | undefined): void;
  setToolsExpanded(expanded: boolean): void;
  getToolsExpanded?(): boolean;
  notify(message: string, level?: string): void;
};
type Context = { ui: ExtensionUI; hasUI?: boolean };
type ObservedEvent = { willContinue?: boolean; toolCallId?: string; toolName?: string };
type ExtensionAPI = {
  on?: (event: string, handler: (event: ObservedEvent, ctx: Context) => unknown) => void;
  registerCommand?: (name: string, command: { description: string; handler: (args: string, ctx: Context) => unknown }) => void;
};

const STATUS_KEY = "fm-calm";
// A run with no tool or message event for this long is reported as quiet, with its
// age; it is an observation about event silence, never a stuck or failed verdict.
const QUIET_AFTER_MS = 5 * 60 * 1000;
const STATE_REFRESH_MS = 15 * 1000;
const DIM = "\u001b[2m";
const RESET = "\u001b[22m";

export default function (pi: ExtensionAPI) {
  let calmActive = false;
  let agentRunActive = false;
  // Every open wait on the captain, keyed by source and toolCallId. The source
  // prefix matters: an `ask` under a prompt approval policy shares its toolCallId
  // with its own approval, which resolves while the question is still open.
  const waitingOn = new Set<string>();
  let lastEventAt = 0;
  let shipShown = false;
  let restoreToolsExpanded: boolean | undefined;
  let refreshTimer: NodeJS.Timeout | undefined;
  let lastStateText: string | undefined;
  const animation = createCalmWorkingShipAnimation();

  const stateText = (): string => {
    if (!agentRunActive) return "idle";
    if (waitingOn.size > 0) return "waiting for you";
    const quietMs = Date.now() - lastEventAt;
    if (quietMs >= QUIET_AFTER_MS) return `working, quiet ${Math.floor(quietMs / 60000)}m`;
    return "working";
  };

  // Single owner of every presentation surface Calm touches. Only real transitions
  // create or dispose the widget, so repeated starts never duplicate its timer.
  const apply = (ui: ExtensionUI): void => {
    const showShip = calmActive && agentRunActive;
    if (showShip !== shipShown) {
      shipShown = showShip;
      ui.setWidget(
        CALM_WORKING_SHIP_WIDGET_KEY,
        showShip
          ? (tui) => {
              const ship = createCalmWorkingShipWidget(tui, animation);
              return {
                render: (width) => [...ship.render(width), `${DIM}${stateText()}${RESET}`],
                invalidate: () => {},
                dispose: () => ship.dispose(),
              };
            }
          : undefined,
        { placement: "aboveEditor" },
      );
    }
    const text = calmActive ? stateText() : undefined;
    if (text !== lastStateText) {
      lastStateText = text;
      ui.setStatus(STATUS_KEY, text);
    }
    if (showShip && !refreshTimer) {
      refreshTimer = setInterval(() => apply(ui), STATE_REFRESH_MS);
      refreshTimer.unref?.();
    } else if (!showShip && refreshTimer) {
      clearInterval(refreshTimer);
      refreshTimer = undefined;
    }
  };

  const setCalm = (ui: ExtensionUI, active: boolean): void => {
    if (active === calmActive) return;
    calmActive = active;
    if (active) {
      restoreToolsExpanded = ui.getToolsExpanded?.();
      ui.setToolsExpanded(false);
    } else if (restoreToolsExpanded !== undefined) {
      ui.setToolsExpanded(restoreToolsExpanded);
      restoreToolsExpanded = undefined;
    }
    apply(ui);
  };

  const touch = (ui: ExtensionUI): void => {
    lastEventAt = Date.now();
    apply(ui);
  };

  pi.registerCommand?.("calm", {
    description: "Toggle Firstmate Calm: boat while working, collapsed tool rows",
    handler: (_args, ctx) => {
      const next = !calmActive;
      persistCalmPreference(next);
      setCalm(ctx.ui, next);
      ctx.ui.notify(next ? "Calm on: boat while working, tool rows collapsed" : "Calm off: stock presentation restored", "info");
    },
  });

  for (const event of ["session_start", "session_switch"]) {
    pi.on?.(event, (_event, ctx) => {
      animation.reset();
      setCalm(ctx.ui, loadCalmPreference());
    });
  }

  pi.on?.("agent_start", (_event, ctx) => {
    agentRunActive = true;
    waitingOn.clear();
    touch(ctx.ui);
  });

  pi.on?.("agent_end", (event, ctx) => {
    if (event.willContinue === true) return;
    agentRunActive = false;
    waitingOn.clear();
    apply(ctx.ui);
  });

  pi.on?.("tool_approval_requested", (event, ctx) => {
    waitingOn.add(`approval:${event.toolCallId}`);
    touch(ctx.ui);
  });

  pi.on?.("tool_approval_resolved", (event, ctx) => {
    waitingOn.delete(`approval:${event.toolCallId}`);
    touch(ctx.ui);
  });

  pi.on?.("tool_execution_start", (event, ctx) => {
    if (event.toolName === "ask") waitingOn.add(`ask:${event.toolCallId}`);
    if (agentRunActive) touch(ctx.ui);
  });

  pi.on?.("tool_execution_end", (event, ctx) => {
    if (event.toolName === "ask") waitingOn.delete(`ask:${event.toolCallId}`);
    if (agentRunActive) touch(ctx.ui);
  });

  for (const event of ["tool_execution_update", "message_update"]) {
    pi.on?.(event, (_event, ctx) => {
      if (agentRunActive) touch(ctx.ui);
    });
  }

  pi.on?.("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    apply(ctx.ui);
  });
}
