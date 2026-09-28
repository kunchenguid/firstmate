// Firstmate's Calm-only animated working presentation for Pi.
//
// Calm replaces Pi's stock working row with a small sailboat riding a simulated sea
// while one logical agent run is active. The sea physics, shading, floating boat, cadence,
// and freeze/resume state are owned by the harness-neutral
// ./fm-calm-working-ship-sprite.ts (a tracked symlink into the Claude Code Calm mod,
// which both harnesses share); this module owns only Pi's rendering of those frames as
// ANSI escapes at Pi's own color depth and the temporary TUI widget.
// `.pi/extensions/fm-calm.ts` owns when the presentation is installed and removed, and
// stays the sole caller of setWorkingVisible(). docs/calm.md owns the captain-facing
// contract.
//
// Color: the shared frame carries resolved RGB colors. This module paints them the way
// Pi's own theme paints its colors, as 24-bit escapes when the theme's color mode is
// truecolor and as the nearest xterm 256-color index otherwise, and picks the shading
// family from the active theme's name: a name starting with `light` selects the light
// family and every other theme the dark one.
//
// Continuity: one extension-owned animation instance survives hide/show within the same
// Pi process and Calm extension lifetime. Disposing the widget freezes the boat, its
// motion, and the sea clock without advancing them for hidden wall time. The next
// working period resumes from that exact logical state. A fresh session or new
// extension lifetime calls reset() and starts at the normal initial position. State is
// never a module-level or process-global singleton.
//
// Verified against Pi 0.81.1 declarations and the Pi 0.87.1 CLI, which expose
// ExtensionUIContext.setWidget() with a component factory receiving the TUI and the
// theme, per-widget dispose(), and TUI.requestRender(), whose renders Pi throttles to
// one per 16ms. Pi renders a widget through Component.render(width), so this module
// recomputes its track from that width on every frame instead of caching a terminal
// size that a resize would invalidate. A resize while the boat is hidden is applied on
// the first resumed frame through the same clamp path.
import type { Component, TUI } from "@earendil-works/pi-tui";
import {
  CALM_WORKING_SHIP_TICK_MS,
  createCalmWorkingShipSprite,
  type CalmWorkingShipFamily,
  type CalmWorkingShipRun,
  type CalmWorkingShipSprite,
} from "./fm-calm-working-ship-sprite.ts";

export { CALM_WORKING_SHIP_TICK_MS };

export const CALM_WORKING_SHIP_WIDGET_KEY = "firstmate-calm-working-ship";

/** Pi's two theme color modes, as Theme.getColorMode() reports them. */
export type CalmWorkingShipColorMode = "truecolor" | "256color";

/** The slice of Pi's Theme the widget reads: its name and color mode. */
export type CalmWorkingShipTheme = {
  readonly name?: string;
  getColorMode(): CalmWorkingShipColorMode;
};

/** How a frame is painted: shading family and terminal color depth. */
export type CalmWorkingShipPaint = {
  family: CalmWorkingShipFamily;
  mode: CalmWorkingShipColorMode;
};

const DEFAULT_PAINT: CalmWorkingShipPaint = { family: "dark", mode: "truecolor" };

// Restores the default foreground and background so color never bleeds into padding,
// later frames, or the rows Pi draws after the widget.
const RESET = "\u001b[39;49m";

export type CalmWorkingShipAnimation = Omit<CalmWorkingShipSprite, "frame"> & {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number, paint?: CalmWorkingShipPaint): string[];
};

/** The shading family for a Pi theme name. */
export function calmWorkingShipFamily(themeName: unknown): CalmWorkingShipFamily {
  return typeof themeName === "string" && themeName.startsWith("light") ? "light" : "dark";
}

/** How to paint for a Pi theme, falling back to dark truecolor when it cannot be read. */
export function calmWorkingShipPaint(theme: CalmWorkingShipTheme | undefined): CalmWorkingShipPaint {
  if (theme === undefined) return DEFAULT_PAINT;
  let mode: CalmWorkingShipColorMode = "truecolor";
  try {
    mode = theme.getColorMode() === "256color" ? "256color" : "truecolor";
  } catch {
    // A theme without a readable mode paints as truecolor, Pi's own default.
  }
  return { family: calmWorkingShipFamily(theme.name), mode };
}

const CUBE_LEVELS = [0, 95, 135, 175, 215, 255];

/** A color in Oklab, where straight-line distance tracks perceived difference. */
function oklab(rgb: number): readonly [number, number, number] {
  const linear = (channel: number): number => {
    const value = channel / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  };
  const r = linear((rgb >> 16) & 0xff);
  const g = linear((rgb >> 8) & 0xff);
  const b = linear(rgb & 0xff);
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

/** The 240 portable xterm entries: the 6x6x6 color cube and the 24-step grey ramp. */
const XTERM_256: readonly { index: number; lab: readonly [number, number, number] }[] = [
  ...Array.from({ length: 216 }, (_, cube) => ({
    index: 16 + cube,
    lab: oklab((CUBE_LEVELS[Math.floor(cube / 36)]! << 16) | (CUBE_LEVELS[Math.floor(cube / 6) % 6]! << 8) | CUBE_LEVELS[cube % 6]!),
  })),
  ...Array.from({ length: 24 }, (_, grey) => ({ index: 232 + grey, lab: oklab((8 + grey * 10) * 0x010101) })),
];
const ANSI_256_CACHE = new Map<number, number>();

/**
 * The perceptually nearest xterm 256-color index to `0xRRGGBB`. A plain RGB distance
 * turns dark navy water teal, because the cube's only dark blues sit far from it;
 * Oklab keeps the hue. The sprite's quantized shading uses a few hundred colors, so
 * each is matched once and remembered.
 */
export function calmWorkingShipAnsi256(rgb: number): number {
  const cached = ANSI_256_CACHE.get(rgb);
  if (cached !== undefined) return cached;
  const [l, a, b] = oklab(rgb);
  let best = 16;
  let bestDistance = Infinity;
  for (const entry of XTERM_256) {
    const distance = (entry.lab[0] - l) ** 2 + (entry.lab[1] - a) ** 2 + (entry.lab[2] - b) ** 2;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = entry.index;
    }
  }
  ANSI_256_CACHE.set(rgb, best);
  return best;
}

function colorEscape(layer: 38 | 48, rgb: number | null, mode: CalmWorkingShipColorMode): string {
  if (rgb === null) return layer === 38 ? "\u001b[39m" : "\u001b[49m";
  if (mode === "256color") return `\u001b[${layer};5;${calmWorkingShipAnsi256(rgb)}m`;
  return `\u001b[${layer};2;${(rgb >> 16) & 0xff};${(rgb >> 8) & 0xff};${rgb & 0xff}m`;
}

/** Paint one row, emitting an escape only where a color changes, and close it reset. */
function paintRow(row: readonly CalmWorkingShipRun[], mode: CalmWorkingShipColorMode): string {
  let out = "";
  let fg: number | null = null;
  let bg: number | null = null;
  let colored = false;
  for (const run of row) {
    if (run.fg !== fg) out += colorEscape(38, run.fg, mode);
    if (run.bg !== bg) out += colorEscape(48, run.bg, mode);
    fg = run.fg;
    bg = run.bg;
    if (fg !== null || bg !== null) colored = true;
    out += run.text;
  }
  return colored ? out + RESET : out;
}

export function createCalmWorkingShipAnimation(): CalmWorkingShipAnimation {
  const sprite = createCalmWorkingShipSprite();
  return {
    position: sprite.position,
    direction: sprite.direction,
    velocity: sprite.velocity,
    pitch: sprite.pitch,
    tilt: sprite.tilt,
    bow: sprite.bow,
    heave: sprite.heave,
    seaTime: sprite.seaTime,
    restoreLastRendered: sprite.restoreLastRendered,
    reset: sprite.reset,
    clampToWidth: sprite.clampToWidth,
    tick: sprite.tick,
    render(width: number, paint: CalmWorkingShipPaint = DEFAULT_PAINT): string[] {
      return sprite.frame(width, paint.family).map((row) => paintRow(row, paint.mode));
    },
  };
}

/**
 * Build the temporary Calm working widget bound to one caller-owned animation.
 * Pi disposes the previous component before installing a replacement under the same
 * key and when it clears extension widgets, so the single scheduler cannot outlive the
 * widget or duplicate. Disposing freezes the shared animation in place; the next
 * widget bound to the same animation resumes without applying hidden wall time. The
 * theme is read on every frame, so a theme switch repaints in the new family.
 */
export function createCalmWorkingShipWidget(
  tui: TUI,
  animation: CalmWorkingShipAnimation = createCalmWorkingShipAnimation(),
  theme?: CalmWorkingShipTheme,
): Component & { dispose(): void } {
  let disposed = false;
  const timer = setInterval(() => {
    if (disposed) return;
    animation.tick();
    tui.requestRender();
  }, CALM_WORKING_SHIP_TICK_MS);
  // The animation must never keep Pi's process alive on its own.
  timer.unref?.();

  return {
    render: (width) => (disposed ? [] : animation.render(width, calmWorkingShipPaint(theme))),
    // Every frame is rebuilt from the sprite's own cached frame, so there is no cache here.
    invalidate: () => {},
    dispose: () => {
      if (disposed) return;
      disposed = true;
      clearInterval(timer);
      animation.restoreLastRendered();
    },
  };
}
