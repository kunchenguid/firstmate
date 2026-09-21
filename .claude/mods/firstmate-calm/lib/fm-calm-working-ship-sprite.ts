// Firstmate's harness-neutral Calm working-ship sprite.
//
// This module owns the sprite geometry, the bounce track, the two linked animation
// cadences, and the freeze/resume state that every Calm working presentation shares.
// It also owns the alternative candles scene and the parsing of the setting that
// chooses between them, at the end of this file; the boat stays the default.
// It paints each frame as rows of color-tagged runs and never as bytes, so each harness
// renders the same picture its own way: `.pi/extensions/lib/fm-calm-working-ship.ts`
// paints the runs as standard ANSI escapes for Pi's widget, and `./fm-calm-ship-raster.ts`
// packs them as Claude Code Raster cells. docs/calm.md owns the captain-facing contract
// and docs/calm-mode-feasibility.md the geometry rationale.
//
// It lives inside the Claude Code plugin folder because Claude Code 2.1.272 refuses a
// hooks-module import from outside that folder, symlinks included; the Pi extension
// reaches it through the tracked `.pi/extensions/lib/fm-calm-working-ship-sprite.ts`
// symlink. Nothing here imports a harness: every glyph is one terminal column under
// both harnesses' width rules, so widths are plain character counts.
//
// Cadence: one scheduler drives two linked cadences. Every tick advances the wave by
// one quarter-cell, and every CALM_WORKING_SHIP_TICKS_PER_MOVE-th tick moves the boat
// one whole cell, so the trough stays phase-locked to a deliberately calm boat.
// Ticks, not wall-clock timestamps, drive every state change, so tests can seek time exactly.
//
// Continuity: one caller-owned sprite instance survives hide/show within one harness
// process and extension lifetime. restoreLastRendered() freezes column, direction, water
// phase, and tick cadence at the last painted frame without advancing them for hidden
// wall time, and the next working period resumes from that exact logical state. A fresh
// session or new extension lifetime calls reset() and starts at the normal initial
// position. State is never a module-level or process-global singleton.

// The asymmetric three-cell sail is centered over a five-cell hull. The one-cell
// quarter triangle keeps the left sail lighter than the full right sail, and the whole
// boat (both sail halves, mast, and hull) is one color so the sprite reads as one shape.
// The hull's inner cells retain zero-height water glyphs instead of interrupting the trough.
const LEFT_SAIL = "◿";
const MAST = "│";
const RIGHT_SAIL = "◣";
const HULL_LEFT = "╲";
const HULL_WATER = "▁▁▁";
const HULL_RIGHT = "╱";
const SAIL_OFFSET = 1;

/** The complete sail as drawn, left to right. */
export const CALM_WORKING_SHIP_SAIL = `${LEFT_SAIL}${MAST}${RIGHT_SAIL}`;
/** The complete hull as drawn, left to right. */
export const CALM_WORKING_SHIP_HULL = `${HULL_LEFT}${HULL_WATER}${HULL_RIGHT}`;

/** Terminal columns a string of one-column glyphs occupies. */
function cellCount(text: string): number {
  return Array.from(text).length;
}

const HULL_WIDTH = cellCount(CALM_WORKING_SHIP_HULL);
const SAIL_WIDTH = cellCount(CALM_WORKING_SHIP_SAIL);

// Pi Dictation uses these bottom-aligned one-cell bars for truthful level history.
// Calm deliberately keeps only its lower half: a long, low ocean swell rather than an
// audio-sized waveform. Every glyph is one terminal column under both harnesses.
export const CALM_WORKING_SHIP_WAVE_BARS = ["▁", "▂", "▃", "▄"] as const;
const WAVE_MAX_LEVEL = CALM_WORKING_SHIP_WAVE_BARS.length - 1;
const WAVE_HALF_LENGTH_MIN = 9;
const WAVE_HALF_LENGTH_SPAN = 5;
const WAVE_TROUGH_RADIUS = 5;

/** Scheduler period. One tick advances the water by one phase. */
export const CALM_WORKING_SHIP_TICK_MS = 220;
/** Boat moves one column every Nth tick, so it travels at 220 * 4 = 880ms per column. */
export const CALM_WORKING_SHIP_TICKS_PER_MOVE = 4;

/**
 * The color classes a frame uses. `plain` is uncolored padding; `water` is every water
 * cell whatever its height, so the swell reads through glyph height alone; `boat` is
 * the whole boat, both sail halves, the mast, and the complete hull including its
 * zero-height interior. `rise` and `fall` are the candles scene's rising and falling
 * candles, each whole candle, body and wicks, one class. Each harness maps a class to
 * its own color: Pi paints them as standard ANSI blue, yellow, green, and red, the
 * Claude Code mod as Claude Code's theme colors.
 */
export type CalmWorkingShipColor = "plain" | "water" | "boat" | "rise" | "fall";

/** One same-colored run of cells inside a frame row. */
export type CalmWorkingShipRun = {
  readonly text: string;
  readonly color: CalmWorkingShipColor;
};

/** One painted frame: one or two rows of runs, each row exactly the requested width. */
export type CalmWorkingShipFrame = readonly (readonly CalmWorkingShipRun[])[];

export type CalmWorkingShipSprite = {
  /** Paint one frame that exactly fits `width`, clamping the track to it first. */
  frame(width: number): CalmWorkingShipFrame;
  /** Advance one scheduler tick: water every tick, boat on its slower cadence. */
  tick(): void;
  /** Return to the state of the last painted frame, discarding later ticks. */
  restoreLastRendered(): void;
  /** Restore the normal initial column, direction, water phase, and cadence. */
  reset(): void;
  /**
   * Clamp the frozen column and direction to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current hull column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current travel direction: 1 travelling right, -1 travelling left. */
  direction(): number;
  /** Current quarter-cell wave phase, exposed for deterministic swell assertions. */
  waterPhase(): number;
};

/** Longest hull start column that still fits the sprite in `width` usable cells. */
function trackSpan(width: number): number {
  if (width >= HULL_WIDTH) return width - HULL_WIDTH;
  if (width >= SAIL_WIDTH) return width - SAIL_WIDTH;
  return 0;
}

/** Stable bounded variation for successive half-waves on either side of the trough. */
function halfWaveLength(index: number, negative: boolean): number {
  let value =
    ((negative ? 0xc411 : 0x5ea1) + Math.imul(index + 1, 0x9e3779b1)) >>> 0;
  value ^= value >>> 16;
  value = Math.imul(value, 0x7feb352d) >>> 0;
  value ^= value >>> 15;
  value >>>= 0;
  return WAVE_HALF_LENGTH_MIN + (value % WAVE_HALF_LENGTH_SPAN);
}

function smoothstep(value: number): number {
  const bounded = Math.max(0, Math.min(1, value));
  return bounded * bounded * (3 - 2 * bounded);
}

/** Smooth amplitude at one fractional cell in the deterministic variable wave field. */
function waveAmplitude(coordinate: number): number {
  const negative = coordinate < 0;
  let distance = Math.abs(coordinate);
  let rising = true;
  for (let index = 0; ; index += 1) {
    const length = halfWaveLength(index, negative);
    if (distance <= length) {
      const eased = smoothstep(distance / length);
      return (rising ? eased : 1 - eased) * WAVE_MAX_LEVEL;
    }
    distance -= length;
    rising = !rising;
  }
}

/**
 * One bottom-aligned bar level at an absolute column.
 *
 * The wave advances one quarter-cell on every water tick and exactly one cell on the
 * boat's slower movement tick. Anchoring that displacement to the hull center keeps
 * the boat inside the same broad trough without per-frame randomness or jitter.
 */
function waveLevel(
  column: number,
  hullCenter: number,
  direction: number,
  phase: number,
): number {
  const displacement =
    hullCenter + (direction * phase) / CALM_WORKING_SHIP_TICKS_PER_MOVE;
  const coordinate = column - displacement;
  if (Math.abs(coordinate) <= WAVE_TROUGH_RADIUS) return 0;
  const beyondTrough = coordinate - Math.sign(coordinate) * WAVE_TROUGH_RADIUS;
  return Math.max(
    0,
    Math.min(WAVE_MAX_LEVEL, Math.round(waveAmplitude(beyondTrough))),
  );
}

export function createCalmWorkingShipSprite(): CalmWorkingShipSprite {
  let position = 0;
  let direction = 1;
  let span = 0;
  let phase = 0;
  let ticks = 0;
  let renderedPosition = position;
  let renderedDirection = direction;
  let renderedSpan = span;
  let renderedPhase = phase;
  let renderedTicks = ticks;

  // Reversing the moment the boat lands on an endpoint means the endpoint frame already
  // carries the new wave direction, so the trough follows the next boat movement.
  const settleDirectionAtEdges = (): void => {
    if (span <= 0) return;
    if (position >= span) direction = -1;
    else if (position <= 0) direction = 1;
  };

  const applyWidth = (width: number): void => {
    if (width <= 0) {
      span = 0;
      position = 0;
      return;
    }
    span = trackSpan(width);
    position = Math.min(position, span);
    settleDirectionAtEdges();
  };

  const commitRenderedState = (): void => {
    renderedPosition = position;
    renderedDirection = direction;
    renderedSpan = span;
    renderedPhase = phase;
    renderedTicks = ticks;
  };

  const restoreLastRenderedState = (): void => {
    position = renderedPosition;
    direction = renderedDirection;
    span = renderedSpan;
    phase = renderedPhase;
    ticks = renderedTicks;
  };

  /** One water-colored run per cell of low water covering absolute columns [from, from + count). */
  const water = (
    from: number,
    count: number,
    hullCenter: number,
  ): CalmWorkingShipRun[] => {
    const runs: CalmWorkingShipRun[] = [];
    for (let column = from; column < from + count; column += 1) {
      const level = waveLevel(column, hullCenter, direction, phase);
      runs.push({
        text: CALM_WORKING_SHIP_WAVE_BARS[level] ?? CALM_WORKING_SHIP_WAVE_BARS[0],
        color: "water",
      });
    }
    return runs;
  };

  // The boat is one boat-colored run per row, so its halves never split into mismatched colors.
  const sail = (): CalmWorkingShipRun[] => [{ text: CALM_WORKING_SHIP_SAIL, color: "boat" }];
  const hull = (): CalmWorkingShipRun[] => [{ text: CALM_WORKING_SHIP_HULL, color: "boat" }];

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
      position = Math.min(span, Math.max(0, position + direction));
      settleDirectionAtEdges();
    },

    frame(width: number): CalmWorkingShipFrame {
      if (width <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(width);

      const hullCenter =
        position +
        (width >= HULL_WIDTH
          ? Math.floor(HULL_WIDTH / 2)
          : Math.floor(SAIL_WIDTH / 2));

      let frame: CalmWorkingShipFrame;
      if (width < SAIL_WIDTH) {
        // Too narrow for even the sail: a deterministic single row of low water.
        frame = [water(0, width, hullCenter)];
      } else if (width < HULL_WIDTH) {
        // Too narrow for the hull: the sail alone rides inside the water row.
        frame = [
          [
            ...water(0, position, hullCenter),
            ...sail(),
            ...water(position + SAIL_WIDTH, width - position - SAIL_WIDTH, hullCenter),
          ],
        ];
      } else {
        frame = [
          [{ text: " ".repeat(position + SAIL_OFFSET), color: "plain" }, ...sail()],
          [
            ...water(0, position, hullCenter),
            ...hull(),
            ...water(position + HULL_WIDTH, width - position - HULL_WIDTH, hullCenter),
          ],
        ];
      }

      commitRenderedState();
      return frame;
    },
  };
}

// ---------------------------------------------------------------------------------
// The candles scene: the alternative working picture a home picks through its Calm
// scene setting (docs/configuration.md owns the file, docs/calm.md the picture).
//
// Small candlesticks scroll left one column per boat move, like a live chart whose
// newest candle enters at the right edge, on the same two linked cadences and the
// same freeze/resume contract as the boat, so both harnesses drive it through the one
// CalmWorkingShipSprite interface. Each candle is one column: its body is a heavy
// box-drawing stroke and its wicks light strokes, two rows tall at half-row
// resolution, so four stacked half-cells hold a wick, a body, and a wick. The series
// is a pure function of the candle's index, so no history accumulates and any width
// reflows without wrapping. The chart reads as a pattern: a slow swell plus hashed
// noise, never a real price.

/** Which working picture Calm draws. */
export type CalmWorkingScene = "boat" | "candles";

/** The picture drawn when no setting chooses one. */
export const CALM_WORKING_SCENE_DEFAULT: CalmWorkingScene = "boat";

/**
 * The scene a stored setting names: `candles` (surrounding whitespace ignored) selects
 * the candles, and an absent, unreadable, empty, or unknown value draws the boat.
 */
export function parseCalmWorkingScene(stored: string | undefined): CalmWorkingScene {
  return typeof stored === "string" && stored.trim() === "candles" ? "candles" : CALM_WORKING_SCENE_DEFAULT;
}

/** Columns from one candle to the next: the candle and one empty gap. */
export const CALM_WORKING_CANDLES_PITCH = 2;
/** Below this width the chart falls back to one row of compressed candles. */
export const CALM_WORKING_CANDLES_TWO_ROW_MIN_WIDTH = HULL_WIDTH;

// Half-cell boundaries run 0 (bottom of the lower row) to 4 (top of the upper row).
const CANDLE_TOP = 4;
const CANDLE_SWELL_PERIOD = 11;
const CANDLE_SWELL_AMPLITUDE = 1.4;

type CandleSlot = "none" | "wick" | "body";

// One cell's glyph from what fills its upper and lower half.
const CANDLE_GLYPHS: Readonly<Record<CandleSlot, Readonly<Record<CandleSlot, string>>>> = {
  none: { none: " ", wick: "╷", body: "╻" },
  wick: { none: "╵", wick: "│", body: "╽" },
  body: { none: "╹", wick: "╿", body: "┃" },
};

/** Every glyph a candle can draw, exposed for width and glyph-set assertions. */
export const CALM_WORKING_CANDLE_GLYPHS: readonly string[] = [
  ...new Set(Object.values(CANDLE_GLYPHS).flatMap((row) => Object.values(row))),
].filter((glyph) => glyph !== " ");

/** Stable 32-bit hash of a candle index and a salt. */
function candleHash(index: number, salt: number): number {
  let value = (salt + Math.imul(index | 0, 0x9e3779b1)) >>> 0;
  value ^= value >>> 16;
  value = Math.imul(value, 0x7feb352d) >>> 0;
  value ^= value >>> 15;
  value = Math.imul(value, 0x846ca68b) >>> 0;
  value ^= value >>> 16;
  return value >>> 0;
}

/** The close of candle `index` as a half-cell boundary: a slow swell plus bounded noise. */
function candleClose(index: number): number {
  const swell = CANDLE_SWELL_AMPLITUDE * Math.sin((2 * Math.PI * index) / CANDLE_SWELL_PERIOD);
  const noise = (candleHash(index, 0x51ed) % 3) - 1;
  return Math.max(0, Math.min(CANDLE_TOP, Math.round(CANDLE_TOP / 2 + swell + noise)));
}

type Candle = { readonly rising: boolean; readonly slots: readonly CandleSlot[] };

/** Candle `index`: it opens at the previous close, with a body at least one half-cell tall. */
function candleAt(index: number): Candle {
  const open = candleClose(index - 1);
  const close = candleClose(index);
  const rising = close > open || (close === open && candleHash(index, 0x7a11) % 2 === 0);
  let low = Math.min(open, close);
  let high = Math.max(open, close);
  if (low === high) {
    if (high < CANDLE_TOP) high += 1;
    else low -= 1;
  }
  const wicks = candleHash(index, 0x3c6e);
  const wickLow = Math.max(0, low - (wicks & 1));
  const wickHigh = Math.min(CANDLE_TOP, high + ((wicks >>> 1) & 1));
  const slots: CandleSlot[] = [];
  for (let slot = 0; slot < CANDLE_TOP; slot += 1) {
    if (slot >= low && slot < high) slots.push("body");
    else if (slot >= wickLow && slot < wickHigh) slots.push("wick");
    else slots.push("none");
  }
  return { rising, slots };
}

/** The stronger of two half-cells, used to fold two half-cells into one. */
function strongerSlot(first: CandleSlot, second: CandleSlot): CandleSlot {
  if (first === "body" || second === "body") return "body";
  if (first === "wick" || second === "wick") return "wick";
  return "none";
}

export function createCalmWorkingCandlesSprite(): CalmWorkingShipSprite {
  // offset counts whole-column scroll steps: absolute column = visible column + offset.
  let offset = 0;
  let phase = 0;
  let ticks = 0;
  let renderedOffset = offset;
  let renderedPhase = phase;
  let renderedTicks = ticks;

  const commitRenderedState = (): void => {
    renderedOffset = offset;
    renderedPhase = phase;
    renderedTicks = ticks;
  };

  /** One cell of `row` (0 is the top row of a two-row frame) at absolute column `column`. */
  const cell = (column: number, row: number, rows: number): CalmWorkingShipRun => {
    if (column % CALM_WORKING_CANDLES_PITCH !== 0) return { text: " ", color: "plain" };
    const candle = candleAt(column / CALM_WORKING_CANDLES_PITCH);
    const [bottom, lowerMiddle, upperMiddle, top] = candle.slots as [CandleSlot, CandleSlot, CandleSlot, CandleSlot];
    let upper: CandleSlot;
    let lower: CandleSlot;
    if (rows === 1) {
      upper = strongerSlot(upperMiddle, top);
      lower = strongerSlot(bottom, lowerMiddle);
    } else if (row === 0) {
      upper = top;
      lower = upperMiddle;
    } else {
      upper = lowerMiddle;
      lower = bottom;
    }
    const text = CANDLE_GLYPHS[upper][lower];
    return text === " " ? { text, color: "plain" } : { text, color: candle.rising ? "rise" : "fall" };
  };

  return {
    position: () => offset,
    // The chart always travels left: the newest candle enters at the right edge.
    direction: () => -1,
    waterPhase: () => phase,

    restoreLastRendered(): void {
      offset = renderedOffset;
      phase = renderedPhase;
      ticks = renderedTicks;
    },

    reset(): void {
      offset = 0;
      phase = 0;
      ticks = 0;
      commitRenderedState();
    },

    // The chart has no track to clamp: any width shows the same columns from the left.
    clampToWidth(): void {},

    tick(): void {
      ticks += 1;
      phase = (phase + 1) % CALM_WORKING_SHIP_TICKS_PER_MOVE;
      if (ticks % CALM_WORKING_SHIP_TICKS_PER_MOVE === 0) offset += 1;
    },

    frame(width: number): CalmWorkingShipFrame {
      if (width <= 0) return [];
      const rows = width < CALM_WORKING_CANDLES_TWO_ROW_MIN_WIDTH ? 1 : 2;
      const frame: CalmWorkingShipRun[][] = [];
      for (let row = 0; row < rows; row += 1) {
        const runs: CalmWorkingShipRun[] = [];
        for (let column = 0; column < width; column += 1) runs.push(cell(column + offset, row, rows));
        frame.push(runs);
      }
      commitRenderedState();
      return frame;
    },
  };
}

/** A fresh sprite that draws `scene`, with the normal initial state. */
export function createCalmWorkingSceneSprite(scene: CalmWorkingScene): CalmWorkingShipSprite {
  return scene === "candles" ? createCalmWorkingCandlesSprite() : createCalmWorkingShipSprite();
}
