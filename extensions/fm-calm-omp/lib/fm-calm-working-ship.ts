// Firstmate's Calm-only animated working presentation.
//
// Calm replaces Pi's stock working row with a tiny SSHHIP-derived boat while one
// logical agent run is active. This module owns only the sprite geometry, the bounce
// track, the two animation cadences, the session-scoped freeze/resume state, and the
// temporary TUI widget; `.pi/extensions/fm-calm.ts` owns when the presentation is
// installed and removed, and stays the sole caller of setWorkingVisible().
// docs/calm.md owns the captain-facing contract.
//
// Cadence: one scheduler drives two linked cadences. Every tick advances the wave by
// one quarter-cell, and every CALM_WORKING_SHIP_TICKS_PER_MOVE-th tick moves the boat
// one whole cell, so the trough stays phase-locked to a deliberately calm boat.
// Both cadences stop together when the widget is disposed.
// Ticks, not wall-clock timestamps, drive every state change, so tests can seek time exactly.
//
// Continuity: one extension-owned animation instance survives hide/show within the same
// Pi process and Calm extension lifetime. Disposing the widget freezes column,
// direction, water phase, and tick cadence without advancing them for hidden wall
// time. The next working period resumes from that exact logical state. A fresh session
// or new extension lifetime calls reset() and starts at the normal initial position.
// State is never a module-level or process-global singleton.
//
// Verified against Pi 0.81.1 declarations and the Pi 0.82.0 CLI, which expose
// ExtensionUIContext.setWidget() with a component factory, per-widget dispose(), and
// TUI.requestRender(). Pi renders a widget through Component.render(width), so this
// module recomputes its track from that width on every frame instead of caching a
// terminal size that a resize would invalidate. A resize while the boat is hidden is
// applied on the first resumed frame through the same clamp path.
type Component = { render: (width: number) => readonly string[]; invalidate: () => void; dispose?: () => void };
type TUI = { requestRender: () => void };
function visibleWidth(value: string): number { return value.replace(/\x1b\[[0-9;]*m/g, "").length; }

// The asymmetric three-cell sail is centered over a five-cell hull. The one-cell
// quarter triangle keeps the yellow left sail lighter than the full red right sail.
// The hull's inner cells retain zero-height water glyphs instead of interrupting the trough.
const LEFT_SAIL = "◿";
const MAST = "│";
const RIGHT_SAIL = "◣";
const SAIL = `${LEFT_SAIL}${MAST}${RIGHT_SAIL}`;
const HULL_LEFT = "╲";
const HULL_WATER = "▁▁▁";
const HULL_RIGHT = "╱";
const HULL = `${HULL_LEFT}${HULL_WATER}${HULL_RIGHT}`;
const SAIL_OFFSET = 1;
const HULL_WIDTH = visibleWidth(HULL);
const SAIL_WIDTH = visibleWidth(SAIL);

// Pi Dictation uses these bottom-aligned one-cell bars for truthful level history.
// Calm deliberately keeps only its lower half: a long, low ocean swell rather than an
// audio-sized waveform. Every glyph is one terminal column under Pi TUI's width rules.
const WAVE_BARS = ["▁", "▂", "▃", "▄"] as const;
const WAVE_MAX_LEVEL = WAVE_BARS.length - 1;
const WAVE_HALF_LENGTH_MIN = 9;
const WAVE_HALF_LENGTH_SPAN = 5;
const WAVE_TROUGH_RADIUS = 5;

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
const BLUE = "\u001b[34m";
const CYAN = "\u001b[36m";
const YELLOW = "\u001b[33m";
const RED = "\u001b[31m";
// Restores the default foreground so color never bleeds into padding or later frames.
const RESET = "\u001b[39m";

export const CALM_WORKING_SHIP_WIDGET_KEY = "firstmate-calm-working-ship";
/** Scheduler period. One tick advances the water by one phase. */
export const CALM_WORKING_SHIP_TICK_MS = 220;
/** Boat moves one column every Nth tick, so it travels at 220 * 4 = 880ms per column. */
export const CALM_WORKING_SHIP_TICKS_PER_MOVE = 4;

export type CalmWorkingShipAnimation = {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
  /** Advance one scheduler tick: water every tick, boat on its slower cadence. */
  tick(): void;
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
 * One bottom-aligned bar at an absolute column.
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

export function createCalmWorkingShipAnimation(): CalmWorkingShipAnimation {
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

  /** One colored run of low water covering absolute columns [from, from + count). */
  const water = (from: number, count: number, hullCenter: number): string => {
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      const level = waveLevel(column, hullCenter, direction, phase);
      const color = level >= 2 ? CYAN : BLUE;
      cells += `${color}${WAVE_BARS[level]}${RESET}`;
    }
    return cells;
  };

  const boat = (text: string): string => `${YELLOW}${text}${RESET}`;
  const sail = (): string =>
    `${YELLOW}${LEFT_SAIL}${MAST}${RESET}${RED}${RIGHT_SAIL}${RESET}`;
  const hull = (): string =>
    `${boat(HULL_LEFT)}${BLUE}${HULL_WATER}${RESET}${boat(HULL_RIGHT)}`;

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

    render(width: number): string[] {
      if (width <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(width);

      const hullCenter =
        position +
        (width >= HULL_WIDTH
          ? Math.floor(HULL_WIDTH / 2)
          : Math.floor(SAIL_WIDTH / 2));

      let frame: string[];
      if (width < SAIL_WIDTH) {
        // Too narrow for even the sail: a deterministic single row of low water.
        frame = [water(0, width, hullCenter)];
      } else if (width < HULL_WIDTH) {
        // Too narrow for the hull: the sail alone rides inside the water row.
        frame = [
          water(0, position, hullCenter) +
            sail() +
            water(position + SAIL_WIDTH, width - position - SAIL_WIDTH, hullCenter),
        ];
      } else {
        frame = [
          " ".repeat(position + SAIL_OFFSET) + sail(),
          water(0, position, hullCenter) +
            hull() +
            water(position + HULL_WIDTH, width - position - HULL_WIDTH, hullCenter),
        ];
      }

      commitRenderedState();
      return frame;
    },
  };
}

/**
 * Build the temporary Calm working widget bound to one caller-owned animation.
 * Pi disposes the previous component before installing a replacement under the same
 * key and when it clears extension widgets, so the single scheduler driving both
 * cadences cannot outlive the widget or duplicate. Disposing freezes the shared
 * animation in place; the next widget bound to the same animation resumes without
 * applying hidden wall time.
 */
export function createCalmWorkingShipWidget(
  tui: TUI,
  animation: CalmWorkingShipAnimation = createCalmWorkingShipAnimation(),
): Component & { dispose(): void } {
  let disposed = false;
  const timer = setInterval(() => {
    if (disposed) return;
    animation.tick();
    tui.requestRender();
  }, CALM_WORKING_SHIP_TICK_MS);
  // The animation must never keep Pi's process alive on its own.
  (timer as unknown as { unref?: () => void }).unref?.();

  return {
    render: (width) => (disposed ? [] : animation.render(width)),
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
