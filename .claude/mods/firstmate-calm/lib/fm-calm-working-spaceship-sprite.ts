// Firstmate's harness-neutral Calm working-spaceship sprite.
//
// This module owns the spaceship's geometry, both starfield cycles, the two linked
// animation cadences, the settle ease, the working-mode transition, and the
// freeze/resume state that every Calm spaceship presentation shares. It paints each
// frame as rows of color-tagged runs and never as bytes, so each harness renders the
// same picture its own way: `.pi/extensions/lib/fm-calm-working-spaceship.ts` paints
// the runs as standard ANSI escapes for Pi's widget, and `./fm-calm-ship-raster.ts`
// packs them as Claude Code Raster cells. docs/calm.md owns the captain-facing
// contract.
//
// It lives inside the Claude Code plugin folder because Claude Code 2.1.272 refuses a
// hooks-module import from outside that folder, symlinks included; the Pi extension
// reaches it through the tracked `.pi/extensions/lib/fm-calm-working-spaceship-sprite.ts`
// symlink. Nothing here imports a harness: every glyph is one terminal column under
// both harnesses' width rules, so widths are plain character counts.
//
// Cadence: one scheduler drives two linked clocks. Idle, the starfield advances one
// phase every IDLE_TICKS_PER_PHASE-th tick while the saucer drifts one column every
// IDLE_TICKS_PER_MOVE-th tick; working, the starfield advances
// WORKING_PHASES_PER_TICK phases per tick while the saucer cruises one column every
// TICKS_PER_MOVE-th tick. Ticks, not wall-clock timestamps, drive every state change,
// so tests can seek time exactly.
//
// Modes: IDLE renders the two-row rest pose, the `(|)` saucer over the `|^|` hull,
// drifting marquee-style; WORKING (a run is thinking) renders the single-row compact
// `=( * )` warp saucer sweeping marquee-style. setWorking(false) settles: the stars
// return to the idle cadence immediately and the movement pace eases back into the
// drift over a bounded SETTLE_EASE_MOVES of graduated moves that never teleport.
//
// Continuity: one caller-owned sprite instance survives hide/show within one harness
// process and extension lifetime. restoreLastRendered() freezes column, starfield
// phase, movement countdown, and mode transition state at the last painted frame
// without advancing them for hidden wall time, and the next working period resumes
// from that exact logical state. A fresh session or new extension lifetime calls
// reset() and starts at the left edge. State is never a module-level or
// process-global singleton.

// The idle rest pose is two rows: the three-cell `(|)` saucer chevron over the
// three-cell `|^|` hull. The `|` reads as the ship's dome/antenna; the pair are the
// same width, so the hull sits directly beneath the saucer as they sweep.
const SAUCER_IDLE = "(|)";
const SAUCER_IDLE_WIDTH = SAUCER_IDLE.length;
const HULL = "|^|";
const HULL_WIDTH = HULL.length;
// The three-cell hull centers under the three-cell saucer with no offset.
const HULL_CENTER_OFFSET = (SAUCER_IDLE_WIDTH - HULL_WIDTH) / 2;
// The compact single-row working sprite: hull stroke trailing on the left, dome cockpit
// forward on the right, so the saucer reads as facing right while it cruises. The warp
// keeps the starred cockpit `( * )`.
const WARP_SPRITE = "=( * )";
const WARP_WIDTH = WARP_SPRITE.length;

/** The idle saucer chevron as drawn, left to right. */
export const CALM_WORKING_SPACESHIP_SAUCER = SAUCER_IDLE;
/** The idle hull as drawn, left to right. */
export const CALM_WORKING_SPACESHIP_HULL = HULL;
/** The compact single-row working sprite as drawn. */
export const CALM_WORKING_SPACESHIP_WARP = WARP_SPRITE;

// Bounded deterministic fixed-cell starfield phases. Every entry is exactly one
// column. The unit is deliberately asymmetric (star, dot, gap, dot) so a phase step
// SLIDES the whole pattern one column instead of only inverting it in place: the old
// symmetric `* . * .` unit just blinked (each cell flipped between `*` and `.`), while
// this unit streams, so the idle saucer's row visibly travels left past the saucer.
const STAR_CYCLE = ["*", ".", " ", "."] as const;
// Working-mode warp streaks, one column per entry. The same phase drives both
// cycles: because the phase advances two steps per working tick and the cycle is
// four cells long, the working phase stays parity-locked to even values, so the
// field toggles between two phase states in place rather than drifting, while the
// saucer cruises right.
const STREAK_CYCLE = [" ", "-", ".", "-"] as const;

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

/**
 * The color classes a frame uses. `field` is every starfield, starfield-dots, and
 * warp-streak cell, so the space the ship flies through reads as one surface;
 * `ship` is the whole craft, saucer and hull in either mode. Each harness maps a
 * class to its own color: Pi paints them as standard ANSI blue and yellow, the
 * Claude Code mod as Claude Code's theme colors. `plain` is unused by this sprite's
 * own frames but reserved so padding and future runs stay expressible.
 */
export type CalmWorkingSpaceshipColor = "plain" | "field" | "ship";

/** One same-colored run of cells inside a frame row. */
export type CalmWorkingSpaceshipRun = {
  readonly text: string;
  readonly color: CalmWorkingSpaceshipColor;
};

/** One painted frame: one or two rows of runs, each row exactly the requested width. */
export type CalmWorkingSpaceshipFrame = readonly (readonly CalmWorkingSpaceshipRun[])[];

export type CalmWorkingSpaceshipSprite = {
  /** Paint one frame that exactly fits `width`, clamping the track to it first. */
  frame(width: number): CalmWorkingSpaceshipFrame;
  /** Advance one scheduler tick: the mode owns both clocks. */
  tick(): void;
  /** Return to the state of the last painted frame, discarding later ticks. */
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
  if (width >= SAUCER_IDLE_WIDTH) return width - SAUCER_IDLE_WIDTH;
  // Too narrow for the saucer chevron but wide enough for the hull: the hull alone
  // rides the field, so its own width bounds the track.
  if (width >= HULL_WIDTH) return width - HULL_WIDTH;
  return 0;
}

export function createCalmWorkingSpaceshipSprite(): CalmWorkingSpaceshipSprite {
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

  /** One field-colored run covering absolute columns [from, from + count); empty runs are omitted. */
  const field = (from: number, count: number): CalmWorkingSpaceshipRun[] => {
    if (count <= 0) return [];
    const cycle = working ? STREAK_CYCLE : STAR_CYCLE;
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      cells += cycle[(column + phase) % cycle.length];
    }
    return [{ text: cells, color: "field" }];
  };

  /** Sparse dots-only fill for the row the saucer rides: a quiet `.` accent (no `*`)
      every third column, anchored to absolute columns so the sparse pattern stays
      stable as the saucer sweeps instead of sliding with it. */
  const dots = (from: number, count: number): CalmWorkingSpaceshipRun[] => {
    if (count <= 0) return [];
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      cells += column % 3 === 0 ? "." : " ";
    }
    return [{ text: cells, color: "field" }];
  };

  const craft = (text: string): CalmWorkingSpaceshipRun[] => [{ text, color: "ship" }];

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

    frame(nextWidth: number): CalmWorkingSpaceshipFrame {
      if (nextWidth <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(nextWidth);

      let frame: CalmWorkingSpaceshipFrame;
      if (working) {
        // Warp is the compact single-row sprite: the streak field toggles between
        // two phase states in place (the +2-per-tick advance keeps the phase
        // parity-locked on the four-cell cycle). Too narrow for even the sprite,
        // the bare streak field remains.
        frame =
          nextWidth >= WARP_WIDTH
            ? [
                [
                  ...field(0, position),
                  ...craft(WARP_SPRITE),
                  ...field(position + WARP_WIDTH, nextWidth - position - WARP_WIDTH),
                ],
              ]
            : [field(0, nextWidth)];
      } else if (nextWidth >= SAUCER_IDLE_WIDTH) {
        // Two-row rest pose: the `(|)` saucer rides a quiet dotted row while the
        // `|^|` hull below keeps the streaming starfield (the asymmetric cycle slides,
        // so the stars visibly move left past the chasing ship). The saucer and hull
        // are both three cells wide, so the hull centers directly beneath the saucer.
        frame = [
          [
            ...dots(0, position),
            ...craft(SAUCER_IDLE),
            ...dots(position + SAUCER_IDLE_WIDTH, nextWidth - position - SAUCER_IDLE_WIDTH),
          ],
          [
            ...field(0, position + HULL_CENTER_OFFSET),
            ...craft(HULL),
            ...field(
              position + HULL_CENTER_OFFSET + HULL_WIDTH,
              nextWidth - position - HULL_CENTER_OFFSET - HULL_WIDTH,
            ),
          ],
        ];
      } else if (nextWidth >= HULL_WIDTH) {
        // Too narrow for the saucer chevron but wide enough for the hull: the hull
        // alone rides the streaming starfield.
        frame = [
          [...field(0, position), ...craft(HULL), ...field(position + HULL_WIDTH, nextWidth - position - HULL_WIDTH)],
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