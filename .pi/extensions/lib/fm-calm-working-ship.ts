// Firstmate's Calm-only animated working presentation.
//
// Calm replaces Pi's stock working row with a tiny SSHHIP-derived boat while one
// logical agent run is active. This module owns only the sprite geometry, the bounce
// track, and the temporary TUI widget; `.pi/extensions/fm-calm.ts` owns when the
// presentation is installed and removed, and stays the sole caller of
// setWorkingVisible(). docs/calm.md owns the captain-facing contract.
//
// Verified against Pi 0.81.1 declarations and the Pi 0.82.0 CLI, which expose
// ExtensionUIContext.setWidget() with a component factory, per-widget dispose(), and
// TUI.requestRender(). Pi renders a widget through Component.render(width), so this
// module recomputes its track from that width on every frame instead of caching a
// terminal size that a resize would invalidate.
import type { Component, TUI } from "@earendil-works/pi-tui";
import type { Theme } from "@earendil-works/pi-coding-agent";

// The hull replaces waves on the water row rather than adding a third row, and the
// open `|>` sail keeps its orientation in both travel directions because it is the
// SSHHIP brand mark rather than a generic mirrored sail.
const HULL = "\\__/";
const SAIL = "|>";
const WAVE = "~";
// Centers the two-cell sail over the four-cell hull.
const SAIL_OFFSET = 1;
const HULL_WIDTH = HULL.length;
const SAIL_WIDTH = SAIL.length;

export const CALM_WORKING_SHIP_WIDGET_KEY = "firstmate-calm-working-ship";
export const CALM_WORKING_SHIP_INTERVAL_MS = 140;

/** Theme-driven styling for one frame. Callers pass Pi theme colors, never raw RGB. */
export type CalmWorkingShipPalette = {
  sail(text: string): string;
  hull(text: string): string;
  waves(text: string): string;
};

export type CalmWorkingShipAnimation = {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
  /** Advance one animation step, bouncing at the usable edges of the last width. */
  advance(): void;
  /** Current hull column, exposed for deterministic motion assertions. */
  position(): number;
};

/** Longest hull start column that still fits the sprite in `width` usable cells. */
function trackSpan(width: number): number {
  if (width >= HULL_WIDTH) return width - HULL_WIDTH;
  if (width >= SAIL_WIDTH) return width - SAIL_WIDTH;
  return 0;
}

function waves(count: number, palette: CalmWorkingShipPalette): string {
  // Skip empty runs so an edge frame never emits a bare color escape with no cells.
  return count > 0 ? palette.waves(WAVE.repeat(count)) : "";
}

export function createCalmWorkingShipAnimation(
  palette: CalmWorkingShipPalette,
): CalmWorkingShipAnimation {
  let position = 0;
  let direction = 1;
  let span = 0;

  return {
    position: () => position,

    advance(): void {
      if (span <= 0) {
        position = 0;
        direction = 1;
        return;
      }
      const next = position + direction;
      if (next < 0 || next > span) direction = -direction;
      position = Math.min(span, Math.max(0, position + direction));
    },

    render(width: number): string[] {
      if (width <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      span = trackSpan(width);
      position = Math.min(position, span);

      if (width < SAIL_WIDTH) {
        // Too narrow for even the brand mark: a deterministic single wave cell.
        return [waves(width, palette)];
      }

      if (width < HULL_WIDTH) {
        // Too narrow for the hull: the sail alone rides the water row.
        return [
          waves(position, palette) +
            palette.sail(SAIL) +
            waves(width - position - SAIL_WIDTH, palette),
        ];
      }

      return [
        " ".repeat(position + SAIL_OFFSET) + palette.sail(SAIL),
        waves(position, palette) +
          palette.hull(HULL) +
          waves(width - position - HULL_WIDTH, palette),
      ];
    },
  };
}

/**
 * Build the temporary Calm working widget. Pi disposes the previous component before
 * installing a replacement under the same key and when it clears extension widgets, so
 * the frame timer is owned here and cannot outlive the widget or duplicate itself.
 */
export function createCalmWorkingShipWidget(
  tui: TUI,
  theme: Theme,
): Component & { dispose(): void } {
  const animation = createCalmWorkingShipAnimation({
    sail: (text) => theme.fg("accent", text),
    hull: (text) => theme.fg("accent", text),
    waves: (text) => theme.fg("dim", text),
  });
  const timer = setInterval(() => {
    animation.advance();
    tui.requestRender();
  }, CALM_WORKING_SHIP_INTERVAL_MS);
  // The animation must never keep Pi's process alive on its own.
  timer.unref?.();

  return {
    render: (width) => animation.render(width),
    // Every frame is rebuilt from the live theme proxy, so there is no cache to clear.
    invalidate: () => {},
    dispose: () => clearInterval(timer),
  };
}
