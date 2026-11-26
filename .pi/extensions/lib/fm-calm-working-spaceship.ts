// Firstmate's Calm-only animated spaceship working presentation.
//
// This module is the selectable spaceship counterpart of fm-calm-working-ship.ts and
// follows the same contract shape the redesigned `.pi/extensions/fm-calm.ts` consumes:
// a caller-owned animation, a temporary TUI widget bound to it, and the one working-row
// slot shared with the boat and standalone Pi Calm. Unlike the boat, which exists only
// while one logical agent run is under way, this presentation is ambient: while Calm is
// active and config/calm-ship selects it, the banner is present for the whole session
// and drifts while idle.
// `.pi/extensions/fm-calm.ts` owns when either presentation is installed and removed,
// drives setWorking() from the same run-visibility signals the boat consumes so a run
// is what puts the banner into warp, and stays the sole caller of setWorkingVisible().
// docs/calm.md owns the captain-facing contract.
//
// Two modes and one bounded transition:
//
// - IDLE: the rest mode the settle transition below returns to; the saucer drifts
//   slowly and continuously left to right across the banner in the two-row rest pose
//   (the three-cell `(|)` saucer over the three-cell `|^|` hull, centered), one column
//   every IDLE_TICKS_PER_MOVE ticks (~1.5 seconds), wrapping marquee-style back to the
//   left edge when it crosses the right edge, while the hull row's asymmetric `*`/`.`
//   starfield streams one column every IDLE_TICKS_PER_PHASE ticks (~1.3 seconds), so
//   the stars visibly move left past the chasing ship instead of just twinkling in
//   place.
// - WORKING (a run is thinking): the sprite becomes the single-row compact `=( * )`
//   saucer (yellow) on the banner row - the two-row pose is not rendered in warp - the
//   saucer sweeps right one column every TICKS_PER_MOVE ticks (~880ms per column)
//   across the full track, wrapping marquee-style back to the left edge when it
//   crosses the right edge so it never parks, the starfield advances
//   WORKING_PHASES_PER_TICK phases per tick (faster than the idle stream), and the
//   field renders as warp streaks streaming left past the sprite.
// - Settle: setWorking(false) relaxes the sprite back to the two-row rest pose, returns the
//   stars to the idle cadence immediately, and eases the movement pace back into the
//   slow idle drift: the next few moves run at graduated intervals that lengthen by
//   one tick per move until they reach the drift pace, always moving exactly one
//   column per move and never teleporting. The whole ease is bounded to
//   SETTLE_EASE_MOVES moves, after which the marquee drift continues indefinitely.
//
// Ticks, not wall-clock timestamps, drive every state change, so tests can seek time
// exactly. One scheduler drives the star clock and the saucer clock; both stop
// together when the widget is disposed.
//
// Continuity: one caller-owned animation instance survives hide/show within the same
// Pi session and Calm extension lifetime. Disposing the widget freezes column,
// starfield phase, movement countdown, and mode transition state without advancing
// them for hidden wall time. The next working period resumes from that exact logical
// state, including mid-drift and mid-warp. A fresh session or new extension lifetime
// calls reset() and starts at the left edge. State is never a module-level or
// process-global singleton.
import type { Component, TUI } from "@earendil-works/pi-tui";

// The idle rest pose is two rows: the three-cell `(|)` saucer chevron over the
// three-cell `|^|` hull. The `|` reads as the ship's dome/antenna; the pair are the
// same width, so the hull sits directly beneath the saucer as they sweep.
const SAUCER_IDLE = "(|)";
const SAUCER_IDLE_WIDTH = SAUCER_IDLE.length;
const HULL = "|^|";
const HULL_WIDTH = HULL.length;
// The compact single-row working sprite: hull stroke trailing on the left, dome cockpit
// forward on the right, so the saucer reads as facing right while it cruises. The warp
// keeps the starred cockpit `( * )`.
const WARP_SPRITE = "=( * )";
const WARP_WIDTH = WARP_SPRITE.length;

// Bounded deterministic fixed-cell starfield phases. Every entry is exactly one
// column. The unit is deliberately asymmetric (star, dot, gap, dot) so a phase step
// SLIDES the whole pattern one column instead of only inverting it in place: the old
// symmetric `* . * .` unit just blinked (each cell flipped between `*` and `.`), while
// this unit streams, so the idle saucer's row visibly travels left past the saucer.
const STAR_CYCLE = ["*", ".", " ", "."] as const;
// Working-mode warp streaks, one column per entry. The same phase drives both
// cycles: because the phase advances two steps per working tick, each streak glyph
// streams two columns left per tick, past the sprite, while the saucer cruises right.
const STREAK_CYCLE = [" ", "-", ".", "-"] as const;

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
const BLUE = "\u001b[34m";
const YELLOW = "\u001b[33m";
// Restores the default foreground so color never bleeds into padding or later frames.
const RESET = "\u001b[39m";

/** Scheduler period. One tick is the base unit for every clock below. */
export const CALM_WORKING_SPACESHIP_TICK_MS = 220;
/** Idle starfield cadence: one twinkle phase every Nth tick (~1.3s at 220ms). */
export const CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_PHASE = 6;
/** Idle drift cadence: one column every Nth tick (~1.5s per column, marquee loop). */
export const CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE = 7;
/** Working starfield cadence: phases advanced per tick (~110ms per phase). */
export const CALM_WORKING_SPACESHIP_WORKING_PHASES_PER_TICK = 2;
/** Working cruise cadence: one column every Nth tick (880ms per column). */
export const CALM_WORKING_SPACESHIP_TICKS_PER_MOVE = 4;
/**
 * Settle ease bound: after settling, the movement pace lengthens by one tick per move
 * for exactly this many moves before it reaches the idle drift pace, so the whole
 * transition is bounded and never jumps.
 */
export const CALM_WORKING_SPACESHIP_SETTLE_EASE_MOVES = 3;

export type CalmWorkingSpaceshipAnimation = {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
  /** Advance one scheduler tick: the mode owns both clocks. */
  tick(): void;
  restoreLastRendered(): void;
  /** Restore the left-edge pose, idle cadence, and no settle ease. */
  reset(): void;
  /**
   * Clamp the frozen column to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current sprite column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current starfield phase, exposed for deterministic twinkle and streak assertions. */
  starPhase(): number;
  /** True while a run is thinking: compact warp sprite, cruise, fast streaks. */
  isWorking(): boolean;
  /** True while the settle ease back into the drift pace is still under way. */
  isGliding(): boolean;
  /**
   * Drive the mode from the same run-visibility signals the boat consumes.
   * Settling starts the bounded pace ease back into the idle drift.
   */
  setWorking(active: boolean): void;
};

/** Longest sprite start column that still fits in `width` usable cells. */
function trackSpan(width: number, working: boolean): number {
  if (working) return width >= WARP_WIDTH ? width - WARP_WIDTH : 0;
  return width >= SAUCER_IDLE_WIDTH ? width - SAUCER_IDLE_WIDTH : 0;
}

export function createCalmWorkingSpaceshipAnimation(): CalmWorkingSpaceshipAnimation {
  let position = 0;
  let span = 0;
  let phase = 0;
  let ticks = 0;
  let working = false;
  // Idle movement clock: ticks remaining until the next drift column, and the interval
  // that countdown restarts with after each move. While easing after a settle, the
  // interval lengthens by one tick per move until it reaches the drift pace.
  let nextMoveIn = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
  let moveInterval = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
  let easeMovesRemaining = 0;
  let width: number | undefined;
  let renderedPosition = position;
  let renderedSpan = span;
  let renderedPhase = phase;
  let renderedTicks = ticks;
  let renderedNextMoveIn = nextMoveIn;
  let renderedMoveInterval = moveInterval;
  let renderedEaseMovesRemaining = easeMovesRemaining;

  const applyWidth = (nextWidth: number): void => {
    width = nextWidth;
    if (nextWidth <= 0) {
      span = 0;
      position = 0;
      return;
    }
    span = trackSpan(nextWidth, working);
    position = Math.min(position, span);
  };

  const commitRenderedState = (): void => {
    renderedPosition = position;
    renderedSpan = span;
    renderedPhase = phase;
    renderedTicks = ticks;
    renderedNextMoveIn = nextMoveIn;
    renderedMoveInterval = moveInterval;
    renderedEaseMovesRemaining = easeMovesRemaining;
  };

  const restoreLastRenderedState = (): void => {
    position = renderedPosition;
    span = renderedSpan;
    phase = renderedPhase;
    ticks = renderedTicks;
    nextMoveIn = renderedNextMoveIn;
    moveInterval = renderedMoveInterval;
    easeMovesRemaining = renderedEaseMovesRemaining;
  };

  /** One colored field run covering absolute columns [from, from + count). */
  const field = (from: number, count: number): string => {
    if (count <= 0) return "";
    const cycle = working ? STREAK_CYCLE : STAR_CYCLE;
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      cells += cycle[(column + phase) % cycle.length];
    }
    return `${BLUE}${cells}${RESET}`;
  };

  const craft = (text: string): string => `${YELLOW}${text}${RESET}`;

  // The idle top (saucer) row: a sparse blue dot field with the saucer drawn over it.
  // The dots sit on absolute columns, so the sparse pattern stays stable as the
  // saucer sweeps instead of sliding with it.
  const saucerRow = (width: number): string => {
    let cells = "";
    for (let column = 0; column < width; column += 1) {
      if (column >= position && column < position + SAUCER_IDLE_WIDTH) {
        cells += YELLOW + SAUCER_IDLE[column - position] + RESET;
      } else {
        cells += BLUE + (column % 3 === 0 ? "." : " ") + RESET;
      }
    }
    return cells;
  };

  return {
    position: () => position,
    starPhase: () => phase,
    isWorking: () => working,
    isGliding: () => easeMovesRemaining > 0,

    restoreLastRendered: restoreLastRenderedState,

    reset(): void {
      position = 0;
      span = 0;
      phase = 0;
      ticks = 0;
      working = false;
      nextMoveIn = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
      moveInterval = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
      easeMovesRemaining = 0;
      width = undefined;
      commitRenderedState();
    },

    clampToWidth(nextWidth: number): void {
      applyWidth(nextWidth);
    },

    setWorking(active: boolean): void {
      if (active === working) {
        // A repeated start inside one logical run must not restart the cruise.
        return;
      }
      working = active;
      if (active) {
        easeMovesRemaining = 0;
      } else {
        // Settle: ease the pace from the cruise cadence back into the drift cadence.
        // The first eased move runs at the cruise pace, then each later move waits one
        // tick longer, so the transition is smooth, bounded, and never teleports.
        easeMovesRemaining = CALM_WORKING_SPACESHIP_SETTLE_EASE_MOVES;
        moveInterval = CALM_WORKING_SPACESHIP_TICKS_PER_MOVE;
        nextMoveIn = CALM_WORKING_SPACESHIP_TICKS_PER_MOVE;
      }
      // The track bound depends on the sprite the mode renders.
      if (width !== undefined) applyWidth(width);
    },

    tick(): void {
      ticks += 1;
      if (working) {
        phase = (phase + CALM_WORKING_SPACESHIP_WORKING_PHASES_PER_TICK) % STAR_CYCLE.length;
        if (ticks % CALM_WORKING_SPACESHIP_TICKS_PER_MOVE !== 0) return;
        if (span <= 0) {
          position = 0;
          return;
        }
        // Warp marquee: keep sweeping right across the full track at the working
        // cadence, wrapping back to the left edge after the right edge, so the
        // thinking saucer never parks.
        position += 1;
        if (position > span) position = 0;
        return;
      }
      // Idle and easing share the slow idle twinkle cadence.
      if (ticks % CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_PHASE === 0) {
        phase = (phase + 1) % STAR_CYCLE.length;
      }
      nextMoveIn -= 1;
      if (nextMoveIn > 0) return;
      // Marquee drift: always one column right, wrapping to the left edge after the
      // right edge, so the sweep is continuous and never reverses.
      if (span > 0) {
        position += 1;
        if (position > span) position = 0;
      }
      if (easeMovesRemaining > 0) {
        easeMovesRemaining -= 1;
        moveInterval = Math.min(CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE, moveInterval + 1);
      } else {
        moveInterval = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
      }
      nextMoveIn = moveInterval;
    },

    render(nextWidth: number): string[] {
      if (nextWidth <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(nextWidth);

      let frame: string[];
      if (working) {
        // Warp is the compact single-row sprite: streaks stream left past it. Too
        // narrow for even the sprite, the bare streak field remains.
        frame =
          nextWidth >= WARP_WIDTH
            ? [
                field(0, position) +
                  craft(WARP_SPRITE) +
                  field(position + WARP_WIDTH, nextWidth - position - WARP_WIDTH),
              ]
            : [field(0, nextWidth)];
      } else if (nextWidth >= SAUCER_IDLE_WIDTH) {
        // Two-row rest pose: the `(|)` saucer rides a quiet dotted row while the
        // `|^|` hull below keeps the streaming starfield (the asymmetric cycle slides,
        // so the stars visibly move left past the chasing ship). The saucer and hull
        // are both three cells wide, so the hull centers directly beneath the saucer.
        frame = [
          saucerRow(nextWidth),
          field(0, position) +
            craft(HULL) +
            field(position + HULL_WIDTH, nextWidth - position - HULL_WIDTH),
        ];
      } else {
        // Too narrow for even the hull: a bare deterministic starfield stays.
        frame = [field(0, nextWidth)];
      }

      commitRenderedState();
      return frame;
    },
  };
}

/**
 * Build the Calm banner widget bound to one caller-owned animation.
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
