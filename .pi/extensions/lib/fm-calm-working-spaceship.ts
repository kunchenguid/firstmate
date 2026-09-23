// Firstmate's Calm-only animated spaceship working presentation for Pi.
//
// This module is the selectable spaceship counterpart of fm-calm-working-ship.ts and
// follows the same contract shape the redesigned `.pi/extensions/fm-calm.ts` consumes:
// a per-extension-lifetime animation, a temporary TUI widget bound to it, and one
// widget key. The sprite geometry, both starfield cycles, the two linked cadences, the
// settle ease, the working-mode transition, palette classes, and freeze/resume state
// are owned by the harness-neutral ./fm-calm-working-spaceship-sprite.ts (a tracked
// symlink into the Claude Code Calm mod, which both harnesses share); this module owns
// only Pi's rendering of those frames as standard ANSI escapes and the temporary TUI
// widget. Unlike the boat, the spaceship is a persistent banner while Calm is active:
// `.pi/extensions/fm-calm.ts` owns when either presentation is installed and removed,
// drives setWorking() from the same run-visibility signals the boat consumes, and
// stays the sole caller of setWorkingVisible(). docs/calm.md owns the captain-facing
// contract.
//
// Continuity: one extension-owned animation instance survives hide/show within the same
// Pi process and Calm extension lifetime. Disposing the widget freezes column,
// starfield phase, movement countdown, and mode transition state without advancing
// them for hidden wall time. The next working period resumes from that exact logical
// state, including mid-drift and mid-warp. A fresh session or new extension lifetime
// calls reset() and starts at the left edge. State is never a module-level or
// process-global singleton.
import type { Component, TUI } from "@earendil-works/pi-tui";
import {
  CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE,
  CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_PHASE,
  CALM_WORKING_SPACESHIP_SETTLE_EASE_MOVES,
  CALM_WORKING_SPACESHIP_TICK_MS,
  CALM_WORKING_SPACESHIP_TICKS_PER_MOVE,
  CALM_WORKING_SPACESHIP_WORKING_PHASES_PER_TICK,
  createCalmWorkingSpaceshipSprite,
  type CalmWorkingSpaceshipColor,
  type CalmWorkingSpaceshipRun,
  type CalmWorkingSpaceshipSprite,
} from "./fm-calm-working-spaceship-sprite.ts";

export {
  CALM_WORKING_SPACESHIP_TICK_MS,
  CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_PHASE,
  CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE,
  CALM_WORKING_SPACESHIP_WORKING_PHASES_PER_TICK,
  CALM_WORKING_SPACESHIP_TICKS_PER_MOVE,
  CALM_WORKING_SPACESHIP_SETTLE_EASE_MOVES,
};

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
// The field is a single blue so the starfield and warp streaks read as one surface;
// the ship is a single yellow so the saucer and hull never split into mismatched colors.
const ANSI_FOREGROUND: Record<Exclude<CalmWorkingSpaceshipColor, "plain">, string> = {
  field: "\u001b[34m",
  ship: "\u001b[33m",
};
// Restores the default foreground so color never bleeds into padding or later frames.
const RESET = "\u001b[39m";

export const CALM_WORKING_SPACESHIP_WIDGET_KEY = "firstmate-calm-working-spaceship";

export type CalmWorkingSpaceshipAnimation = Omit<CalmWorkingSpaceshipSprite, "frame"> & {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
};

/** One run painted as its standard ANSI escape, closed with a default-foreground reset. */
function paintRun(run: CalmWorkingSpaceshipRun): string {
  if (run.color === "plain") return run.text;
  return `${ANSI_FOREGROUND[run.color]}${run.text}${RESET}`;
}

export function createCalmWorkingSpaceshipAnimation(): CalmWorkingSpaceshipAnimation {
  const sprite = createCalmWorkingSpaceshipSprite();
  return {
    position: sprite.position,
    starPhase: sprite.starPhase,
    isWorking: sprite.isWorking,
    isGliding: sprite.isGliding,
    restoreLastRendered: sprite.restoreLastRendered,
    reset: sprite.reset,
    clampToWidth: sprite.clampToWidth,
    tick: sprite.tick,
    setWorking: sprite.setWorking,
    render(width: number): string[] {
      return sprite.frame(width).map((row) => row.map(paintRun).join(""));
    },
  };
}

/**
 * Build the persistent Calm banner widget bound to one caller-owned animation.
 * Pi disposes the previous component before installing a replacement under the same
 * key and when it clears extension widgets, so the single scheduler driving both
 * cadences cannot outlive the widget or duplicate. Disposing freezes the shared
 * animation in place; the next widget bound to the same animation resumes without
 * applying hidden wall time.
 */
export function createCalmWorkingSpaceshipWidget(
  tui: TUI,
  animation: CalmWorkingSpaceshipAnimation = createCalmWorkingSpaceshipAnimation(),
): Component & { dispose(): void } {
  let disposed = false;
  const timer = setInterval(() => {
    if (disposed) return;
    animation.tick();
    tui.requestRender();
  }, CALM_WORKING_SPACESHIP_TICK_MS);
  // The animation must never keep Pi's process alive on its own.
  timer.unref?.();

  return {
    render: (widgetWidth) => (disposed ? [] : animation.render(widgetWidth)),
    // Every frame is rebuilt from fixed standard ANSI codes, so there is no cache.
    invalidate: () => {},
    dispose: () => {
      if (disposed) return;
      disposed = true;
      clearInterval(timer);
      animation.restoreLastRendered();
    },
  };
}