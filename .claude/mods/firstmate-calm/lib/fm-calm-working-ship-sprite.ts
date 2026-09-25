// Firstmate's harness-neutral Calm working presentation sprite.
//
// This module owns the sprite geometry, the one-way track, the two linked animation
// cadences, the walk-then-title sequence, and the freeze/resume state that every Calm
// working presentation shares. It paints each frame as rows of color-tagged runs and
// never as bytes, so each harness renders the same picture its own way:
// `.pi/extensions/lib/fm-calm-working-ship.ts` paints the runs as standard ANSI escapes
// for Pi's widget, and `./fm-calm-ship-raster.ts` packs them as Claude Code Raster cells.
// docs/calm.md owns the captain-facing contract.
//
// The working row is a restrained historical sequence, not a comic or a celebration:
// geometric stick figures walk one way under a forced-removal label, then a separate
// title names President Martin Van Buren. The title never shares the path with the
// walkers, so the drawing does not place him in the removal. Labels stay historically
// specific: Cherokee forced removal 1838-1839 during his presidency.
//
// It lives inside the Claude Code plugin folder because Claude Code 2.1.272 refuses a
// hooks-module import from outside that folder, symlinks included; the Pi extension
// reaches it through the tracked `.pi/extensions/lib/fm-calm-working-ship-sprite.ts`
// symlink. Nothing here imports a harness: every glyph is one terminal column under
// both harnesses' width rules, so widths are plain character counts.
//
// Cadence: one scheduler drives two linked cadences. Every tick advances the walking
// gait, and every CALM_WORKING_SHIP_TICKS_PER_MOVE-th tick moves the procession one
// whole cell. Ticks, not wall-clock timestamps, drive every state change, so tests can
// seek time exactly. There is no flashing: the 220ms tick is a slow step, and the title
// card is static.
//
// Continuity: one caller-owned sprite instance survives hide/show within one harness
// process and extension lifetime. restoreLastRendered() freezes column, direction, gait
// phase, title hold, and tick cadence at the last painted frame without advancing them
// for hidden wall time, and the next working period resumes from that exact logical
// state. A fresh session or new extension lifetime calls reset() and starts at the
// normal initial position. State is never a module-level or process-global singleton.

/** Terminal columns a string of one-column glyphs occupies. */
function cellCount(text: string): number {
  return Array.from(text).length;
}

function truncateCells(text: string, width: number): string {
  if (width <= 0) return "";
  const cells = Array.from(text);
  return cells.length <= width ? cells.join("") : cells.slice(0, width).join("");
}

function padCells(text: string, width: number): string {
  const count = cellCount(text);
  if (count >= width) return truncateCells(text, width);
  return `${text}${" ".repeat(width - count)}`;
}

/** Three-person head row, left to right. */
export const CALM_WORKING_SHIP_SAIL = " o  o  o ";
/** Three-person even-gait body row, left to right. */
export const CALM_WORKING_SHIP_HULL = "/|\\/|\\/|\\";
/** Path glyph filling the ground row around the walkers. */
export const CALM_WORKING_SHIP_GROUND = "─";

const HEADS_THREE = CALM_WORKING_SHIP_SAIL;
const HEADS_TWO = " o  o ";
const HEADS_ONE = " o ";
const BODY_THREE_EVEN = CALM_WORKING_SHIP_HULL;
const BODY_THREE_ODD = " |/ |/ |/";
const BODY_TWO_EVEN = "/|\\/|\\";
const BODY_TWO_ODD = " |/ |/";
const BODY_ONE_EVEN = "/|\\";
const BODY_ONE_ODD = " |/";
const COMPACT_WALKER = "o/|";

const THREE_WIDTH = cellCount(HEADS_THREE);
const TWO_WIDTH = cellCount(HEADS_TWO);
const ONE_WIDTH = cellCount(HEADS_ONE);
const COMPACT_WIDTH = cellCount(COMPACT_WALKER);

/** Scheduler period. One tick advances the gait. */
export const CALM_WORKING_SHIP_TICK_MS = 220;
/** Procession moves one column every Nth tick, so it travels at 220 * 4 = 880ms per column. */
export const CALM_WORKING_SHIP_TICKS_PER_MOVE = 4;
/** How many scheduler ticks the Van Buren title holds before the walk restarts. */
export const CALM_WORKING_SHIP_TITLE_TICKS = 16;
/** Narrowest width that can name Van Buren without clipping the name to noise. */
const TITLE_MIN_WIDTH = 9;

/**
 * The color classes a frame uses. `plain` is uncolored padding and historical labels;
 * `water` is the ground path; `boat` is the geometric walker figures. Each harness maps
 * a class to its own color: Pi paints them as standard ANSI blue and yellow, the Claude
 * Code mod as Claude Code's theme colors.
 */
export type CalmWorkingShipColor = "plain" | "water" | "boat";

/** One same-colored run of cells inside a frame row. */
export type CalmWorkingShipRun = {
  readonly text: string;
  readonly color: CalmWorkingShipColor;
};

/** One painted frame: one or two rows of runs, each row at most the requested width. */
export type CalmWorkingShipFrame = readonly (readonly CalmWorkingShipRun[])[];

export type CalmWorkingShipSprite = {
  /** Paint one frame that exactly fits `width`, clamping the track to it first. */
  frame(width: number): CalmWorkingShipFrame;
  /** Advance one scheduler tick: gait every tick, walkers on their slower cadence. */
  tick(): void;
  /** Return to the state of the last painted frame, discarding later ticks. */
  restoreLastRendered(): void;
  /** Restore the normal initial column, direction, gait phase, title hold, and cadence. */
  reset(): void;
  /**
   * Clamp the frozen column and direction to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current procession column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current travel direction: 1 travelling right (away). The walk never reverses. */
  direction(): number;
  /** Current gait phase, exposed for deterministic stride assertions. */
  waterPhase(): number;
};

function figureCount(width: number): 0 | 1 | 2 | 3 {
  if (width >= THREE_WIDTH) return 3;
  if (width >= TWO_WIDTH) return 2;
  if (width >= ONE_WIDTH) return 1;
  return 0;
}

function headsFor(count: 1 | 2 | 3): string {
  if (count === 3) return HEADS_THREE;
  if (count === 2) return HEADS_TWO;
  return HEADS_ONE;
}

function bodiesFor(count: 1 | 2 | 3, phase: number): string {
  const even = phase % 2 === 0;
  if (count === 3) return even ? BODY_THREE_EVEN : BODY_THREE_ODD;
  if (count === 2) return even ? BODY_TWO_EVEN : BODY_TWO_ODD;
  return even ? BODY_ONE_EVEN : BODY_ONE_ODD;
}

function spriteWidth(width: number): number {
  if (width >= THREE_WIDTH) return THREE_WIDTH;
  if (width >= TWO_WIDTH) return TWO_WIDTH;
  if (width >= COMPACT_WIDTH) return COMPACT_WIDTH;
  return 0;
}

/** Longest procession start column that still fits the sprite in `width` usable cells. */
function trackSpan(width: number): number {
  const spanWidth = spriteWidth(width);
  if (spanWidth > 0 && width >= spanWidth) return width - spanWidth;
  return 0;
}

function pickLabel(width: number, options: readonly (readonly [number, string])[]): string {
  for (const [minimum, text] of options) {
    if (width >= minimum) return text;
  }
  return "";
}

const WALK_LABELS = [
  [40, "Cherokee forced removal 1838-1839"],
  [24, "forced removal 1838-39"],
  [14, "1838-1839"],
] as const;

const TITLE_TOP = [
  [48, "Cherokee Nation forced removal 1838-1839"],
  [28, "Forced removal 1838-1839"],
  [16, "Forced removal"],
  [9, "1838-1839"],
] as const;

const TITLE_BOTTOM = [
  [36, "under President Martin Van Buren"],
  [22, "President Martin Van Buren"],
  [16, "Martin Van Buren"],
  [9, "Van Buren"],
] as const;

function plainRow(text: string, width: number): CalmWorkingShipRun[] {
  const fitted = padCells(text, width);
  return fitted.length === 0 ? [] : [{ text: fitted, color: "plain" }];
}

function ground(from: number, count: number): CalmWorkingShipRun[] {
  if (count <= 0) return [];
  return [{ text: CALM_WORKING_SHIP_GROUND.repeat(count), color: "water" }];
}

export function createCalmWorkingShipSprite(): CalmWorkingShipSprite {
  let position = 0;
  let direction = 1;
  let span = 0;
  let phase = 0;
  let ticks = 0;
  let titleRemaining = 0;
  let lastWidth = 0;
  let renderedPosition = position;
  let renderedDirection = direction;
  let renderedSpan = span;
  let renderedPhase = phase;
  let renderedTicks = ticks;
  let renderedTitleRemaining = titleRemaining;
  let renderedLastWidth = lastWidth;

  const applyWidth = (width: number): void => {
    lastWidth = width;
    if (width <= 0) {
      span = 0;
      position = 0;
      return;
    }
    span = trackSpan(width);
    position = Math.min(position, span);
  };

  const commitRenderedState = (): void => {
    renderedPosition = position;
    renderedDirection = direction;
    renderedSpan = span;
    renderedPhase = phase;
    renderedTicks = ticks;
    renderedTitleRemaining = titleRemaining;
    renderedLastWidth = lastWidth;
  };

  const restoreLastRenderedState = (): void => {
    position = renderedPosition;
    direction = renderedDirection;
    span = renderedSpan;
    phase = renderedPhase;
    ticks = renderedTicks;
    titleRemaining = renderedTitleRemaining;
    lastWidth = renderedLastWidth;
  };

  const paintWalk = (width: number): CalmWorkingShipFrame => {
    const count = figureCount(width);
    if (count === 0) {
      if (width >= COMPACT_WIDTH) {
        return [[
          ...ground(0, position),
          { text: COMPACT_WALKER, color: "boat" },
          ...ground(position + COMPACT_WIDTH, width - position - COMPACT_WIDTH),
        ]];
      }
      return [ground(0, width)];
    }

    if (width < TWO_WIDTH) {
      const compact = phase % 2 === 0 ? COMPACT_WALKER : "o|/";
      return [[
        ...ground(0, position),
        { text: compact, color: "boat" },
        ...ground(position + COMPACT_WIDTH, width - position - COMPACT_WIDTH),
      ]];
    }

    const heads = headsFor(count);
    const bodies = bodiesFor(count, phase);
    const figureWidth = cellCount(heads);
    const afterHeads = width - position - figureWidth;
    const walkLabel = pickLabel(afterHeads - 1, WALK_LABELS);
    const headRow: CalmWorkingShipRun[] = [];
    if (position > 0) headRow.push({ text: " ".repeat(position), color: "plain" });
    headRow.push({ text: heads, color: "boat" });
    if (walkLabel.length > 0 && afterHeads > 1) {
      headRow.push({
        text: truncateCells(` ${walkLabel}`, afterHeads),
        color: "plain",
      });
    }

    return [
      headRow,
      [
        ...ground(0, position),
        { text: bodies, color: "boat" },
        ...ground(position + figureWidth, width - position - figureWidth),
      ],
    ];
  };

  const paintTitle = (width: number): CalmWorkingShipFrame => {
    const top = pickLabel(width, TITLE_TOP);
    const bottom = pickLabel(width, TITLE_BOTTOM);
    if (width >= TWO_WIDTH) {
      return [plainRow(top.length > 0 ? ` ${top}` : "", width), plainRow(bottom.length > 0 ? ` ${bottom}` : "", width)];
    }
    return [plainRow(bottom.length > 0 ? bottom : top, width)];
  };

  return {
    position: () => position,
    direction: () => direction,
    waterPhase: () => phase,

    restoreLastRendered: restoreLastRenderedState,

    reset(): void {
      position = 0;
      direction = 1;
      span = 0;
      phase = 0;
      ticks = 0;
      titleRemaining = 0;
      lastWidth = 0;
      commitRenderedState();
    },

    clampToWidth(width: number): void {
      applyWidth(width);
    },

    tick(): void {
      ticks += 1;
      phase = (phase + 1) % CALM_WORKING_SHIP_TICKS_PER_MOVE;
      if (titleRemaining > 0) {
        titleRemaining -= 1;
        if (titleRemaining === 0) {
          position = 0;
          direction = 1;
        }
        return;
      }
      if (ticks % CALM_WORKING_SHIP_TICKS_PER_MOVE !== 0) return;
      if (span <= 0) {
        position = 0;
        if (lastWidth >= TITLE_MIN_WIDTH) titleRemaining = CALM_WORKING_SHIP_TITLE_TICKS;
        return;
      }
      if (position >= span) {
        if (lastWidth >= TITLE_MIN_WIDTH) {
          titleRemaining = CALM_WORKING_SHIP_TITLE_TICKS;
        } else {
          position = 0;
        }
        return;
      }
      position = Math.min(span, Math.max(0, position + direction));
    },

    frame(width: number): CalmWorkingShipFrame {
      if (width <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(width);

      const frame =
        titleRemaining > 0 && width >= TITLE_MIN_WIDTH
          ? paintTitle(width)
          : paintWalk(width);

      commitRenderedState();
      return frame;
    },
  };
}
