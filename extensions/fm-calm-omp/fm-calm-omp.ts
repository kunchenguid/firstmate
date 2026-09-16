// OMP Calm delegates to the native tool-activity visibility action, including
// settings persistence, tool images, and terminal-history repainting.
// OMP has no public extension setter for this action. Its widget factory gives
// us the live TUI, whose focused CustomEditor exposes the native callback.
// Probe that seam for each command; never patch or retain an editor instance.
import {
  CALM_WORKING_SHIP_TICK_MS,
  createCalmWorkingShipAnimation,
} from "../../.pi/extensions/lib/fm-calm-working-ship.ts";

type Component = { render: (width: number) => string[]; invalidate: () => void; dispose?: () => void };
type UI = {
  notify: (message: string, type?: "info" | "warning" | "error") => void;
  setWidget?: (key: string, content: ((tui: unknown) => Component) | undefined) => void;
};
type Context = { hasUI: boolean; ui: UI };
type ExtensionAPI = {
  // The loader provides its own live namespace; importing the package again can
  // create a second settings singleton when OMP runs from its bundled CLI.
  pi?: { settings?: { get: (key: "display.hideToolActivity") => unknown } };
  on?: (event: string, handler: (event: { willContinue?: boolean }, ctx: Context) => void) => void;
  registerCommand: (
    name: string,
    command: { description: string; handler: (args: string, ctx: Context) => Promise<void> },
  ) => void;
};

const WIDGET_KEY = "fm-calm-omp-action-probe";
const BOAT_KEY = "firstmate-calm-omp-working-ship";
const FALLBACK = "Use Ctrl+Shift+O or /settings > Appearance > Display > Hide Tool Activity.";

export default function calmOmp(omp: ExtensionAPI): void {
  const animation = createCalmWorkingShipAnimation();
  let timer: ReturnType<typeof setInterval> | undefined;
  let context: Context | undefined;
  let boat: Component | undefined;
  let requestRender: (() => void) | undefined;
  let warned = false;

  const clearBoat = (): void => {
    if (!boat) return;
    // Dispose explicitly too: cleanup stays reliable if OMP clears widgets first.
    boat.dispose?.();
    boat = undefined;
    requestRender = undefined;
    context?.ui.setWidget?.(BOAT_KEY, undefined);
  };
  const stop = (): void => {
    if (timer !== undefined) clearInterval(timer);
    timer = undefined;
    clearBoat();
    context = undefined;
  };
  const syncBoat = (): void => {
    if (!context?.hasUI || !context.ui.setWidget) return;
    let hidden: unknown;
    try {
      hidden = omp.pi?.settings?.get("display.hideToolActivity");
    } catch {
      hidden = undefined;
    }
    if (typeof hidden !== "boolean") {
      clearBoat();
      if (!warned) {
        warned = true;
        context.ui.notify("/calm-omp: native display setting is unavailable; the working boat is disabled.", "warning");
      }
      return;
    }
    if (!hidden) {
      clearBoat();
      return;
    }
    if (boat) return;
    context.ui.setWidget(BOAT_KEY, (tui) => {
      const live = tui as { requestRender?: () => void } | undefined;
      let disposed = false;
      const component: Component = {
        render: (width) => disposed ? [] : animation.render(width),
        invalidate: () => {},
        dispose: () => {
          if (disposed) return;
          disposed = true;
          animation.restoreLastRendered();
          // OMP also disposes widgets during reload and session transitions.
          if (boat === component) {
            boat = undefined;
            requestRender = undefined;
          }
        },
      };
      requestRender = () => live?.requestRender?.();
      boat = component;
      return component;
    });
  };
  omp.on?.("session_start", () => {
    stop();
    animation.reset();
  });
  omp.on?.("agent_start", (_event, ctx) => {
    // Repeated starts in a continuing logical run must not duplicate the clock.
    if (timer !== undefined) return;
    context = ctx;
    if (!ctx.hasUI || !ctx.ui.setWidget) return;
    syncBoat();
    timer = setInterval(() => {
      const previous = boat;
      syncBoat();
      // The first resumed frame is the frozen frame, with no hidden-time tick.
      if (boat && boat === previous) {
        animation.tick();
        requestRender?.();
      }
    }, CALM_WORKING_SHIP_TICK_MS);
    timer.unref?.();
  });
  omp.on?.("agent_end", (event) => {
    if (!event.willContinue) stop();
  });
  omp.on?.("session_shutdown", stop);

  omp.registerCommand("calm-omp", {
    description: "Toggle OMP's native tool activity visibility",
    handler: async (args, ctx) => {
      if (args.trim()) {
        ctx.ui.notify("Usage: /calm-omp (toggles OMP tool activity visibility)", "warning");
        return;
      }
      if (!ctx.hasUI || typeof ctx.ui.setWidget !== "function") {
        ctx.ui.notify("/calm-omp requires OMP's interactive terminal UI.", "warning");
        return;
      }

      let toggle: (() => void) | undefined;
      let probing = true;
      try {
        ctx.ui.setWidget(WIDGET_KEY, (tui) => {
          // A future asynchronous widget factory must not act after this command.
          if (probing && tui && typeof (tui as any).getFocused === "function") {
            const focused = (tui as any).getFocused();
            if (focused && typeof focused.onToggleToolActivity === "function") {
              toggle = () => focused.onToggleToolActivity();
            }
          }
          return { render: () => [], invalidate: () => {} };
        });
      } catch {
        toggle = undefined;
      } finally {
        probing = false;
        try {
          ctx.ui.setWidget(WIDGET_KEY, undefined);
        } catch {
          // Do not change visibility if the temporary UI probe cannot be removed.
          toggle = undefined;
        }
      }

      if (!toggle) {
        ctx.ui.notify(`/calm-omp: OMP's focused editor visibility action is unavailable. ${FALLBACK}`, "warning");
        return;
      }
      try {
        // The native action reports hidden/visible itself and persists its setting.
        toggle();
        syncBoat();
      } catch {
        ctx.ui.notify(`/calm-omp: OMP's tool visibility action failed; check the current display setting. ${FALLBACK}`, "error");
      }
    },
  });
}
