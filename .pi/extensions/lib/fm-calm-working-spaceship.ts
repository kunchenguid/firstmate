// Firstmate's Calm-only animated spaceship working presentation.
//
// This module is the selectable spaceship counterpart of fm-calm-working-ship.ts and
// follows the same contract shape the redesigned `.pi/extensions/fm-calm.ts` consumes:
// a caller-owned animation, a temporary TUI widget bound to it, and the one working-row
// slot shared with the boat and standalone Pi Calm. `.pi/extensions/fm-calm.ts` owns
// which presentation is installed and when it is installed and removed, and stays the
// sole caller of setWorkingVisible(). docs/calm.md owns the captain-facing contract.
//
// One working mode:
//
// - WORKING (a run is thinking): the sprite is the single-row compact `=( * )` saucer
//   (yellow) on the banner row. The saucer sweeps right one column every TICKS_PER_MOVE
//   ticks (~880ms per column) across the full track, wrapping marquee-style back to the
//   left edge when it crosses the right edge so it never parks, while the starfield
//   advances WORKING_PHASES_PER_TICK phases per tick and renders as warp streaks
//   streaming left past the sprite.
//
// Ticks, not wall-clock timestamps, drive every state change, so tests can seek time
// exactly. One scheduler drives the star clock and the saucer clock, and it stops when
// the widget is disposed.
//
// Continuity: one caller-owned animation instance survives hide/show within the same Pi
// session and Calm extension lifetime. Disposing the widget freezes column, starfield
// phase, and tick cadence without advancing them for hidden wall time. The next working
// period resumes from that exact logical state, including mid-sweep. A fresh session or
// new extension lifetime calls reset() and starts at the left edge. State is never a
// module-level or process-global singleton.
import type { Component, TUI } from "@earendil-works/pi-tui";

// The compact single-row working sprite: hull stroke trailing on the left, dome cockpit
// forward on the right, so the saucer reads as facing right while it cruises. The warp
// keeps the starred cockpit `( * )`.
const WARP_SPRITE = "=( * )";
const WARP_WIDTH = WARP_SPRITE.length;

// Warp streaks, one column per entry. Because the phase advances two steps per tick,
// each streak glyph streams two columns left per tick, past the sprite, while the saucer
// cruises right.
const STREAK_CYCLE = [" ", "-", ".", "-"] as const;

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
const BLUE = "\u001b[34m";
const YELLOW = "\u001b[33m";
// Restores the default foreground so color never bleeds into padding or later frames.
const RESET = "\u001b[39m";

/** Scheduler period. One tick is the base unit for every clock below. */
export const CALM_WORKING_SPACESHIP_TICK_MS = 220;
/** Working starfield cadence: phases advanced per tick (~110ms per phase). */
export const CALM_WORKING_SPACESHIP_WORKING_PHASES_PER_TICK = 2;
/** Working cruise cadence: one column every Nth tick (880ms per column). */
export const CALM_WORKING_SPACESHIP_TICKS_PER_MOVE = 4;

export type CalmWorkingSpaceshipAnimation = {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
  /** Advance one scheduler tick: the mode owns both clocks. */
  tick(): void;
  restoreLastRendered(): void;
  /** Restore the left-edge pose and the initial cadence. */
  reset(): void;
  /**
   * Clamp the frozen column to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current sprite column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current starfield phase, exposed for deterministic streak assertions. */
  starPhase(): number;
};

/** Longest sprite start column that still fits in `width` usable cells. */
function trackSpan(width: number): number {
  return width >= WARP_WIDTH ? width - WARP_WIDTH : 0;
}

export function createCalmWorkingSpaceshipAnimation(): CalmWorkingSpaceshipAnimation {
  let position = 0;
  let span = 0;
  let phase = 0;
  let ticks = 0;
  let renderedPosition = position;
  let renderedSpan = span;
  let renderedPhase = phase;
  let renderedTicks = ticks;

  const applyWidth = (nextWidth: number): void => {
    if (nextWidth <= 0) {
      span = 0;
      position = 0;
      return;
    }
    span = trackSpan(nextWidth);
    position = Math.min(position, span);
  };

  const commitRenderedState = (): void => {
    renderedPosition = position;
    renderedSpan = span;
    renderedPhase = phase;
    renderedTicks = ticks;
  };

  const restoreLastRenderedState = (): void => {
    position = renderedPosition;
    span = renderedSpan;
    phase = renderedPhase;
    ticks = renderedTicks;
  };

  /** One colored streak run covering absolute columns [from, from + count). */
  const field = (from: number, count: number): string => {
    if (count <= 0) return "";
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      cells += STREAK_CYCLE[(column + phase) % STREAK_CYCLE.length];
    }
    return `${BLUE}${cells}${RESET}`;
  };

  const craft = (text: string): string => `${YELLOW}${text}${RESET}`;

  return {
    position: () => position,
    starPhase: () => phase,

    restoreLastRendered: restoreLastRenderedState,

    reset(): void {
      position = 0;
      span = 0;
      phase = 0;
      ticks = 0;
      commitRenderedState();
    },

    clampToWidth(nextWidth: number): void {
      applyWidth(nextWidth);
    },

    tick(): void {
      ticks += 1;
      phase = (phase + CALM_WORKING_SPACESHIP_WORKING_PHASES_PER_TICK) % STREAK_CYCLE.length;
      if (ticks % CALM_WORKING_SPACESHIP_TICKS_PER_MOVE !== 0) return;
      if (span <= 0) {
        position = 0;
        return;
      }
      // Warp marquee: keep sweeping right across the full track at the working cadence,
      // wrapping back to the left edge after the right edge, so the thinking saucer
      // never parks.
      position += 1;
      if (position > span) position = 0;
    },

    render(nextWidth: number): string[] {
      if (nextWidth <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(nextWidth);

      // Warp is the compact single-row sprite: streaks stream left past it. Too narrow
      // for even the sprite, the bare streak field remains.
      const frame =
        nextWidth >= WARP_WIDTH
          ? [
              field(0, position) +
                craft(WARP_SPRITE) +
                field(position + WARP_WIDTH, nextWidth - position - WARP_WIDTH),
            ]
          : [field(0, nextWidth)];

      commitRenderedState();
      return frame;
    },
  };
}

/**
 * Build the Calm working widget bound to one caller-owned animation.
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
