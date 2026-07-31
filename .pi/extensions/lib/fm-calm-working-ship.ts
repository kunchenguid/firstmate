// Firstmate's Calm-only animated working presentation.
//
// Calm replaces Pi's stock working row with a tiny SSHHIP-derived boat while one
// logical agent run is active. This module owns only the sprite geometry, the bounce
// track, the two animation cadences, and the temporary TUI widget;
// `.pi/extensions/fm-calm.ts` owns when the presentation is installed and removed, and
// stays the sole caller of setWorkingVisible(). docs/calm.md owns the captain-facing
// contract.
//
// Cadence: one scheduler drives two logically independent clocks. Every tick advances
// the water phase, and only every CALM_WORKING_SHIP_TICKS_PER_MOVE-th tick moves the
// boat, so the water visibly ripples several times between boat steps and the boat
// itself reads as calm. Both clocks stop together when the widget is disposed. Ticks,
// not wall-clock timestamps, drive every state change, so tests can seek time exactly.
//
// Verified against Pi 0.81.1 declarations and the Pi 0.82.0 CLI, which expose
// ExtensionUIContext.setWidget() with a component factory, per-widget dispose(), and
// TUI.requestRender(). Pi renders a widget through Component.render(width), so this
// module recomputes its track from that width on every frame instead of caching a
// terminal size that a resize would invalidate.
import type { Component, TUI } from "@earendil-works/pi-tui";

// The hull is symmetric and replaces waves on its row rather than adding a third row.
const HULL = "\\__/";
// A mainsail extends aft of the mast, so it trails behind the bow relative to travel.
const SAIL_RIGHT = "<|";
const SAIL_LEFT = "|>";
// Centers the two-cell sail over the four-cell hull.
const SAIL_OFFSET = 1;
const HULL_WIDTH = HULL.length;
const SAIL_WIDTH = SAIL_RIGHT.length;

// Bounded deterministic fixed-cell water phases. Every entry is exactly one column, so
// advancing the phase ripples the surface without changing visible width or row count.
const WAVE_CYCLE = ["~", "~", "-", "~"] as const;

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
const BLUE = "\u001b[34m";
const YELLOW = "\u001b[33m";
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
  /** Current hull column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current travel direction: 1 travelling right, -1 travelling left. */
  direction(): number;
  /** Current water phase, exposed for deterministic ripple assertions. */
  waterPhase(): number;
};

/** Longest hull start column that still fits the sprite in `width` usable cells. */
function trackSpan(width: number): number {
  if (width >= HULL_WIDTH) return width - HULL_WIDTH;
  if (width >= SAIL_WIDTH) return width - SAIL_WIDTH;
  return 0;
}

export function createCalmWorkingShipAnimation(): CalmWorkingShipAnimation {
  let position = 0;
  let direction = 1;
  let span = 0;
  let phase = 0;
  let ticks = 0;

  // Reversing the moment the boat lands on an endpoint means the endpoint frame itself
  // already shows the new heading, so no frame at or after a bounce shows the old sail.
  const settleDirectionAtEdges = (): void => {
    if (span <= 0) return;
    if (position >= span) direction = -1;
    else if (position <= 0) direction = 1;
  };

  /** One colored run of water covering absolute columns [from, from + count). */
  const water = (from: number, count: number): string => {
    if (count <= 0) return "";
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      cells += WAVE_CYCLE[(column + phase) % WAVE_CYCLE.length];
    }
    return `${BLUE}${cells}${RESET}`;
  };

  const boat = (text: string): string => `${YELLOW}${text}${RESET}`;

  return {
    position: () => position,
    direction: () => direction,
    waterPhase: () => phase,

    tick(): void {
      ticks += 1;
      phase = (phase + 1) % WAVE_CYCLE.length;
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
      span = trackSpan(width);
      position = Math.min(position, span);
      settleDirectionAtEdges();

      const sail = direction >= 0 ? SAIL_RIGHT : SAIL_LEFT;

      if (width < SAIL_WIDTH) {
        // Too narrow for even the sail: a deterministic single row of water.
        return [water(0, width)];
      }

      if (width < HULL_WIDTH) {
        // Too narrow for the hull: the sail alone rides the water row.
        return [
          water(0, position) +
            boat(sail) +
            water(position + SAIL_WIDTH, width - position - SAIL_WIDTH),
        ];
      }

      return [
        " ".repeat(position + SAIL_OFFSET) + boat(sail),
        water(0, position) +
          boat(HULL) +
          water(position + HULL_WIDTH, width - position - HULL_WIDTH),
      ];
    },
  };
}

/**
 * Build the temporary Calm working widget. Pi disposes the previous component before
 * installing a replacement under the same key and when it clears extension widgets, so
 * the single scheduler driving both cadences cannot outlive the widget or duplicate.
 */
export function createCalmWorkingShipWidget(tui: TUI): Component & { dispose(): void } {
  const animation = createCalmWorkingShipAnimation();
  const timer = setInterval(() => {
    animation.tick();
    tui.requestRender();
  }, CALM_WORKING_SHIP_TICK_MS);
  // The animation must never keep Pi's process alive on its own.
  timer.unref?.();

  return {
    render: (width) => animation.render(width),
    // Every frame is rebuilt from fixed standard ANSI codes, so there is no cache.
    invalidate: () => {},
    dispose: () => clearInterval(timer),
  };
}
