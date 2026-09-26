// Firstmate's harness-neutral Calm working presentation sprite.
//
// This module owns the sprite geometry, the one-way track, the two linked animation
// cadences, and the freeze/resume state that every Calm working presentation shares.
// It paints each frame as rows of color-tagged runs and never as bytes, so each harness
// renders the same picture its own way: `.pi/extensions/lib/fm-calm-working-ship.ts`
// paints the runs as standard ANSI escapes for Pi's widget, and `./fm-calm-ship-raster.ts`
// packs them as Claude Code Raster cells. docs/calm.md owns the captain-facing contract.
//
// The working row is a restrained symbolic depiction: geometric walkers under Cherokee
// forced removal 1838-1839, with a detailed horse and rider behind them labeled as
// Martin Van Buren. The label states the horseback figure is symbolic, not a historical
// personal escort. There is no celebratory framing and no graphic violence.
//
// It lives inside the Claude Code plugin folder because Claude Code 2.1.272 refuses a
// hooks-module import from outside that folder, symlinks included; the Pi extension
// reaches it through the tracked `.pi/extensions/lib/fm-calm-working-ship-sprite.ts`
// symlink. Nothing here imports a harness: every glyph is one terminal column under
// both harnesses' width rules, so widths are plain character counts.
//
// Cadence: one scheduler drives two linked cadences. Every tick advances gait, and
// every CALM_WORKING_SHIP_TICKS_PER_MOVE-th tick moves the procession one cell.
// Ticks, not wall-clock timestamps, drive every state change.
//
// Continuity: one caller-owned sprite instance survives hide/show within one harness
// process and extension lifetime. restoreLastRendered() freezes column, direction, gait
// phase, and tick cadence at the last painted frame without advancing them for hidden
// wall time. State is never a module-level or process-global singleton.

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
/** Three-person even-gait torso row, left to right. */
export const CALM_WORKING_SHIP_HULL = "/|\\/|\\/|\\";
/** Path glyph filling the ground row. */
export const CALM_WORKING_SHIP_GROUND = "─";

const HEADS = CALM_WORKING_SHIP_SAIL;
const TORSO_EVEN = CALM_WORKING_SHIP_HULL;
const TORSO_ODD = " |/ |/ |/";
const LEGS_EVEN = "/ \\/ \\/ \\";
const LEGS_ODD = " |  |  | ";
const WALKER_W = cellCount(HEADS);

const HORSE = [
  "      .@..     ",
  "     /|\\/      ",
  "    /||\\\\      ",
  "   / || \\\\     ",
  "~*-;======;--. ",
  "  ( o      o )  ",
] as const;
const HORSE_LEGS_EVEN = "/|    |\\ ";
const HORSE_LEGS_ODD = " /|  |\\  ";
const HORSE_W = cellCount(HORSE[0]);

const COMPACT_WALKER = "o/|";
const COMPACT_WIDTH = cellCount(COMPACT_WALKER);

/** Scheduler period. One tick advances the gait. */
export const CALM_WORKING_SHIP_TICK_MS = 220;
/** Procession moves one column every Nth tick (220 * 4 = 880ms per column). */
export const CALM_WORKING_SHIP_TICKS_PER_MOVE = 4;

/**
 * Color classes. `plain` is labels and padding; `water` is the ground path;
 * `boat` is the walkers; `horse` is the mount; `rider` is the Van Buren figure.
 * Each harness maps a class to its own palette.
 */
export type CalmWorkingShipColor = "plain" | "water" | "boat" | "horse" | "rider";

export type CalmWorkingShipRun = {
  readonly text: string;
  readonly color: CalmWorkingShipColor;
};

export type CalmWorkingShipFrame = readonly (readonly CalmWorkingShipRun[])[];

export type CalmWorkingShipSprite = {
  frame(width: number): CalmWorkingShipFrame;
  tick(): void;
  restoreLastRendered(): void;
  reset(): void;
  clampToWidth(width: number): void;
  position(): number;
  direction(): number;
  waterPhase(): number;
};

function trackSpan(width: number): number {
  if (width >= HORSE_W + 1 + WALKER_W) return width - WALKER_W;
  if (width >= WALKER_W) return width - WALKER_W;
  if (width >= COMPACT_WIDTH) return width - COMPACT_WIDTH;
  return 0;
}

const WALK_LABELS = [
  [48, "Cherokee forced removal 1838-1839"],
  [24, "forced removal 1838-39"],
  [14, "1838-1839"],
] as const;

const SYMBOL_LABELS = [
  [52, "symbolic: Martin Van Buren on horseback — not a historical escort"],
  [36, "symbolic Van Buren on horseback"],
  [16, "symbolic"],
] as const;

function pickLabel(width: number, options: readonly (readonly [number, string])[]): string {
  for (const [minimum, text] of options) {
    if (width >= minimum) return text;
  }
  return "";
}

function blank(width: number): string[] {
  return Array.from({ length: width }, () => " ");
}

function stamp(
  rows: string[][],
  colors: CalmWorkingShipColor[][],
  col: number,
  row: number,
  glyph: string,
  color: CalmWorkingShipColor,
): void {
  const g = Array.from(glyph);
  if (row < 0 || row >= rows.length) return;
  for (let i = 0; i < g.length; i += 1) {
    const x = col + i;
    if (g[i] === " " || x < 0 || x >= rows[row].length) continue;
    rows[row][x] = g[i];
    colors[row][x] = color;
  }
}

function runsOf(chars: string[], colors: CalmWorkingShipColor[]): CalmWorkingShipRun[] {
  const runs: CalmWorkingShipRun[] = [];
  let i = 0;
  while (i < chars.length) {
    const color = colors[i];
    let j = i + 1;
    while (j < chars.length && colors[j] === color) j += 1;
    runs.push({ text: chars.slice(i, j).join(""), color });
    i = j;
  }
  return runs;
}

export function createCalmWorkingShipSprite(): CalmWorkingShipSprite {
  let position = 0;
  let direction = 1;
  let span = 0;
  let phase = 0;
  let ticks = 0;
  let lastWidth = 0;
  let renderedPosition = position;
  let renderedDirection = direction;
  let renderedSpan = span;
  let renderedPhase = phase;
  let renderedTicks = ticks;
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
    renderedLastWidth = lastWidth;
  };

  const restoreLastRenderedState = (): void => {
    position = renderedPosition;
    direction = renderedDirection;
    span = renderedSpan;
    phase = renderedPhase;
    ticks = renderedTicks;
    lastWidth = renderedLastWidth;
  };

  const paintFull = (width: number): CalmWorkingShipFrame => {
    const artH = 7;
    const rows = Array.from({ length: artH }, () => blank(width));
    const colors = Array.from({ length: artH }, () =>
      Array.from({ length: width }, (): CalmWorkingShipColor => "plain"),
    );
    const even = phase % 2 === 0;
    const walkPos = position;
    const horsePos = walkPos - HORSE_W - 1;

    HORSE.forEach((line, i) => {
      const color: CalmWorkingShipColor = i <= 2 ? "rider" : "horse";
      stamp(rows, colors, horsePos, i, line, color);
    });
    stamp(rows, colors, horsePos, 6, even ? HORSE_LEGS_EVEN : HORSE_LEGS_ODD, "horse");
    stamp(rows, colors, walkPos, 4, HEADS, "boat");
    stamp(rows, colors, walkPos, 5, even ? TORSO_EVEN : TORSO_ODD, "boat");
    stamp(rows, colors, walkPos, 6, even ? LEGS_EVEN : LEGS_ODD, "boat");

    const top = pickLabel(width, WALK_LABELS);
    const sub = pickLabel(width, SYMBOL_LABELS);
    const labelRows: CalmWorkingShipFrame = [
      [{ text: padCells(top.length > 0 ? ` ${top}` : "", width), color: "plain" }],
      [{ text: padCells(sub.length > 0 ? ` ${sub}` : "", width), color: "plain" }],
    ];
    const groundChars = Array.from({ length: width }, () => CALM_WORKING_SHIP_GROUND);
    const groundColors = Array.from({ length: width }, (): CalmWorkingShipColor => "water");
    return [
      ...labelRows,
      ...rows.map((chars, i) => runsOf(chars, colors[i])),
      runsOf(groundChars, groundColors),
    ];
  };

  const paintCompact = (width: number): CalmWorkingShipFrame => {
    if (width < COMPACT_WIDTH) {
      return [[{ text: CALM_WORKING_SHIP_GROUND.repeat(width), color: "water" }]];
    }
    const even = phase % 2 === 0;
    const compact = even ? COMPACT_WALKER : "o|/";
    const start = Math.min(position, Math.max(0, width - COMPACT_WIDTH));
    const groundRow: CalmWorkingShipRun[] = [];
    if (start > 0) {
      groundRow.push({ text: CALM_WORKING_SHIP_GROUND.repeat(start), color: "water" });
    }
    groundRow.push({ text: compact, color: "boat" });
    const rest = width - start - COMPACT_WIDTH;
    if (rest > 0) {
      groundRow.push({ text: CALM_WORKING_SHIP_GROUND.repeat(rest), color: "water" });
    }
    const label = pickLabel(width, WALK_LABELS);
    if (width >= 14) {
      return [
        [{ text: padCells(label.length > 0 ? ` ${label}` : "", width), color: "plain" }],
        groundRow,
      ];
    }
    return [groundRow];
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
      lastWidth = 0;
      commitRenderedState();
    },
    clampToWidth(width: number): void {
      applyWidth(width);
    },
    tick(): void {
      ticks += 1;
      phase = (phase + 1) % CALM_WORKING_SHIP_TICKS_PER_MOVE;
      if (ticks % CALM_WORKING_SHIP_TICKS_PER_MOVE !== 0) return;
      if (span <= 0) {
        position = 0;
        return;
      }
      if (position >= span) {
        position = 0;
        return;
      }
      position = Math.min(span, Math.max(0, position + direction));
    },
    frame(width: number): CalmWorkingShipFrame {
      if (width <= 0) return [];
      applyWidth(width);
      if (width >= HORSE_W + 1 + WALKER_W && ticks === 0 && position === 0) {
        position = Math.min(HORSE_W + 1, span);
      }
      const frame = width >= HORSE_W + 1 + WALKER_W ? paintFull(width) : paintCompact(width);
      commitRenderedState();
      return frame;
    },
  };
}
