// Firstmate's harness-neutral Calm working-ship sprite.
//
// This module owns the sea simulation, the lighting that shades it, the floating boat,
// and the freeze/resume state that every Calm working presentation shares. It paints
// each frame as rows of runs carrying resolved RGB foreground and background colors and
// never as bytes, so each harness renders the same picture its own way:
// `.pi/extensions/lib/fm-calm-working-ship.ts` paints the runs as ANSI escapes at Pi's
// color depth, and `./fm-calm-ship-raster.ts` packs them as Claude Code Raster cells.
// docs/calm.md owns the captain-facing contract and docs/calm-mode-feasibility.md the
// geometry rationale.
//
// It lives inside the Claude Code plugin folder because Claude Code 2.1.272 refuses a
// hooks-module import from outside that folder, symlinks included; the Pi extension
// reaches it through the tracked `.pi/extensions/lib/fm-calm-working-ship-sprite.ts`
// symlink. Nothing here imports a harness: every glyph is one terminal column under
// both harnesses' width rules, so widths are plain character counts.
//
// Sea: the surface is a sum of second-order Stokes wave trains with the deep-water
// dispersion relation omega = sqrt(g k), so long swells outrun short chop, crests are
// sharper than troughs, and the pattern never repeats on screen. The water row draws
// the surface at eighth-cell height through the bottom-aligned block glyphs, and every
// cell is lit from the surface normal: a height term for light passing through thin
// crests, a diffuse term for the flank facing the sun, a narrow specular lobe that
// twinkles as sun glitter, and whitecap foam where crests stack and in the boat's wake.
//
// Boat: the hull floats. Heave and pitch are damped springs driven by the water under
// the hull, and the view follows the heave the way a camera on a sister boat would, so
// the waterline drawn across the hull rises and falls only by the residual the springs
// have not caught up with. The boat sails at a steady cruise, surges forward on crests
// and back in troughs with the waves' orbital velocity, brakes into each edge, turns
// through zero speed, and mirrors its rig when it comes about. Its mast leans with the
// pitch.
//
// Cadence: one fixed-step scheduler at CALM_WORKING_SHIP_TICK_MS drives everything.
// Ticks, not wall-clock timestamps, drive every state change, so tests can seek time
// exactly and a slow frame never makes the physics jump.
//
// Continuity: one caller-owned sprite instance survives hide/show within one harness
// process and extension lifetime. restoreLastRendered() freezes the boat, the springs,
// and the sea clock at the last painted frame without advancing them for hidden wall
// time, and the next working period resumes from that exact logical state. A fresh
// session or new extension lifetime calls reset() and starts at the normal initial
// position. State is never a module-level or process-global singleton.

// ---------------------------------------------------------------------------------
// Geometry and glyphs.

/** Rig glyphs heading left: small jib ahead of the mast, full mainsail behind it. */
export const CALM_WORKING_SHIP_SAIL_LEFT = "◿│◣";
/** Rig glyphs heading right: the same rig mirrored. */
export const CALM_WORKING_SHIP_SAIL_RIGHT = "◢│◺";
/** Hull ends: a raked bow and stern on either side of the three waterline cells. */
export const CALM_WORKING_SHIP_HULL_LEFT = "◥";
export const CALM_WORKING_SHIP_HULL_RIGHT = "◤";
/** The mast upright, and leaning as the boat pitches. */
export const CALM_WORKING_SHIP_MASTS = { upright: "│", leanLeft: "╲", leanRight: "╱" } as const;

const HULL_WIDTH = 5;
const SAIL_WIDTH = 3;
const SAIL_OFFSET = 1;

/** Bottom-aligned eighth blocks: the water surface at one-eighth-cell height steps. */
export const CALM_WORKING_SHIP_WAVE_BARS = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"] as const;
const LEVELS = CALM_WORKING_SHIP_WAVE_BARS.length;

// ---------------------------------------------------------------------------------
// Time.

/** Scheduler period: one fixed physics step and one painted frame, about 60 a second. */
export const CALM_WORKING_SHIP_TICK_MS = 16;
const DT = CALM_WORKING_SHIP_TICK_MS / 1000;

// ---------------------------------------------------------------------------------
// Sea physics. Horizontal distance is in columns; heights are in rows. A terminal cell
// is about twice as tall as it is wide, so one row spans ASPECT columns of real length.

const ASPECT = 2;
/** Gravity in columns per second squared, scaled so the longest swell rolls calmly. */
const GRAVITY = 2.4;
/** Resting water level inside the water row, as a fraction of the row. */
const MEAN_LEVEL = 0.5;
/** How deep the hull sits: the waterline drawn on a hull in still water. */
const DRAFT = 0.4;

/**
 * The wave trains: wavelength in columns, amplitude in rows, travel direction, and
 * phase. Amplitudes fall with wavelength at a near-constant gentle steepness, the
 * wavelengths are mutually incommensurate so their sum never settles into a cycle,
 * and one short train runs against the swell as cross-sea chop.
 */
export const CALM_WORKING_SHIP_WAVE_TRAINS: readonly {
  readonly wavelength: number;
  readonly amplitude: number;
  readonly direction: 1 | -1;
  readonly phase: number;
}[] = [
  { wavelength: 44.0, amplitude: 0.24, direction: 1, phase: 0.3 },
  { wavelength: 28.9, amplitude: 0.15, direction: 1, phase: 2.1 },
  { wavelength: 19.3, amplitude: 0.095, direction: 1, phase: 4.4 },
  { wavelength: 12.1, amplitude: 0.056, direction: 1, phase: 1.2 },
  { wavelength: 7.7, amplitude: 0.034, direction: -1, phase: 5.0 },
  { wavelength: 4.9, amplitude: 0.022, direction: 1, phase: 3.3 },
];

type Train = {
  /** Signed wavenumber in radians per column: positive trains travel right. */
  kappa: number;
  /** Unsigned wavenumber. */
  k: number;
  /** Angular frequency from deep-water dispersion. */
  omega: number;
  /** Amplitude in physical columns. */
  a: number;
  phase: number;
  direction: number;
};

const TRAINS: readonly Train[] = CALM_WORKING_SHIP_WAVE_TRAINS.map((train) => {
  const k = (2 * Math.PI) / train.wavelength;
  return {
    kappa: train.direction * k,
    k,
    omega: Math.sqrt(GRAVITY * k),
    a: train.amplitude * ASPECT,
    phase: train.phase,
    direction: train.direction,
  };
});
const AMPLITUDE_SUM = CALM_WORKING_SHIP_WAVE_TRAINS.reduce((sum, train) => sum + train.amplitude, 0);
/** Phase speed of the dominant swell, which carries the foam patches. */
const SWELL_SPEED = TRAINS[0]!.omega / TRAINS[0]!.k;

/** Deep-water phase speed of a wave train of `wavelength` columns, in columns per second. */
export function calmWorkingShipPhaseSpeed(wavelength: number): number {
  return Math.sqrt((GRAVITY * wavelength) / (2 * Math.PI));
}

/** One surface sample: height in rows, physical slope, and orbital surface velocity. */
export type CalmSeaSample = { height: number; slope: number; velocity: number };

/**
 * The sea surface at a fractional column and time in seconds: elevation in rows about
 * the resting level, the physical slope (rise over run in real length), and the
 * horizontal orbital velocity of the surface water in columns per second.
 */
export function calmWorkingShipSea(column: number, seconds: number): CalmSeaSample {
  let height = 0;
  let slope = 0;
  let velocity = 0;
  for (const train of TRAINS) {
    const theta = train.kappa * column - train.omega * seconds + train.phase;
    const c = Math.cos(theta);
    const s = Math.sin(theta);
    const bound = 0.5 * train.k * train.a * train.a;
    height += train.a * c + bound * (2 * c * c - 1);
    slope += -train.a * train.kappa * s - 2 * bound * train.kappa * (2 * s * c);
    velocity += train.direction * train.a * train.omega * c;
  }
  return { height: height / ASPECT, slope, velocity };
}

// ---------------------------------------------------------------------------------
// Boat dynamics.

/** Cruising speed in columns per second: a deliberately calm boat. */
export const CALM_WORKING_SHIP_CRUISE = 1.15;
/** How much of the waves' orbital velocity carries the hull along. */
const SURGE = 0.9;
/** Speed response time constant in seconds. */
const SPEED_LAG = 0.9;
/** Columns from an edge over which the boat eases off before it turns. */
const BRAKE_DISTANCE = 3;
const HEAVE_OMEGA = (2 * Math.PI) / 1.6;
const HEAVE_DAMPING = 0.7;
const PITCH_OMEGA = (2 * Math.PI) / 1.1;
const PITCH_DAMPING = 0.45;
/** Pitch, in radians, past which the mast is drawn leaning. */
const MAST_LEAN = 0.05;

// ---------------------------------------------------------------------------------
// Shading.

/** The two theme families a harness chooses between for contrast with its background. */
export type CalmWorkingShipFamily = "dark" | "light";

type Rgb = readonly [number, number, number];

type ShipPalette = {
  /** Water tone stops from deep trough to lit crest. */
  water: readonly (readonly [number, Rgb])[];
  foam: Rgb;
  glint: Rgb;
  hull: Rgb;
  sailLit: Rgb;
  sailShade: Rgb;
  mast: Rgb;
};

const PALETTES: Readonly<Record<CalmWorkingShipFamily, ShipPalette>> = {
  dark: {
    water: [
      [0.0, [8, 24, 86]],
      [0.3, [10, 58, 138]],
      [0.55, [19, 95, 156]],
      [0.78, [31, 134, 185]],
      [1.0, [79, 181, 212]],
    ],
    foam: [223, 241, 247],
    glint: [255, 246, 216],
    hull: [168, 52, 34],
    sailLit: [241, 233, 214],
    sailShade: [200, 189, 163],
    mast: [202, 164, 117],
  },
  light: {
    water: [
      [0.0, [6, 20, 80]],
      [0.3, [10, 56, 138]],
      [0.55, [19, 92, 154]],
      [0.78, [27, 120, 174]],
      [1.0, [47, 151, 194]],
    ],
    foam: [140, 189, 214],
    glint: [178, 216, 232],
    hull: [140, 36, 24],
    sailLit: [179, 159, 120],
    sailShade: [143, 124, 88],
    mast: [107, 76, 44],
  },
};

// Shading is quantized into a small lookup table: runs of equal color merge, frames
// stay well inside a terminal's palette, and no per-cell color math runs per frame.
// The deep stops keep blue rising faster than green, so a terminal or multiplexer that
// downsamples to 256 colors by plain RGB distance lands on navy and steel blue rather
// than the cube's teal.
const TONE_STEPS = 16;
const FOAM_STEPS = 6;
const GLINT_STEPS = 4;

/** Sun direction in the view plane: high and to the upper left, normalized. */
const SUN_X = -0.45 / Math.hypot(0.45, 1);
const SUN_Y = 1 / Math.hypot(0.45, 1);
/** The surface tilt, in radians, that mirrors the sun toward the viewer, and its spread. */
const GLINT_ANGLE = 0.07;
const GLINT_SPREAD = 0.035;

function packRgb([r, g, b]: Rgb): number {
  return ((Math.round(r) & 0xff) << 16) | ((Math.round(g) & 0xff) << 8) | (Math.round(b) & 0xff);
}

function mix(a: Rgb, b: Rgb, t: number): Rgb {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

function waterTone(stops: ShipPalette["water"], t: number): Rgb {
  for (let index = 1; index < stops.length; index += 1) {
    const [end, to] = stops[index]!;
    const [start, from] = stops[index - 1]!;
    if (t <= end) return mix(from, to, (t - start) / (end - start));
  }
  return stops[stops.length - 1]![1];
}

type ShadeTable = {
  /** Surface water color by [tone][foam][glint], packed 0xRRGGBB. */
  water: Uint32Array;
  /** Water body color below the surface, by the tone of the surface above it. */
  deep: Uint32Array;
  /** The same body with the keel showing through it, by tone. */
  keel: Uint32Array;
  hull: number;
  sailLit: number;
  sailShade: number;
  mast: number;
};

const SHADE_TABLES: Readonly<Record<CalmWorkingShipFamily, ShadeTable>> = {
  dark: buildShadeTable(PALETTES.dark),
  light: buildShadeTable(PALETTES.light),
};

function buildShadeTable(palette: ShipPalette): ShadeTable {
  const water = new Uint32Array(TONE_STEPS * FOAM_STEPS * GLINT_STEPS);
  for (let tone = 0; tone < TONE_STEPS; tone += 1) {
    const base = waterTone(palette.water, tone / (TONE_STEPS - 1));
    for (let foam = 0; foam < FOAM_STEPS; foam += 1) {
      const foamed = mix(base, palette.foam, (foam / (FOAM_STEPS - 1)) * 0.9);
      for (let glint = 0; glint < GLINT_STEPS; glint += 1) {
        const lit = mix(foamed, palette.glint, (glint / (GLINT_STEPS - 1)) * 0.85);
        water[(tone * FOAM_STEPS + foam) * GLINT_STEPS + glint] = packRgb(lit);
      }
    }
  }
  const deep = new Uint32Array(TONE_STEPS);
  const keel = new Uint32Array(TONE_STEPS);
  for (let tone = 0; tone < TONE_STEPS; tone += 1) {
    // Light fades with depth, so the body is a darker echo of the surface above it.
    const body = waterTone(palette.water, 0.1 + 0.16 * (tone / (TONE_STEPS - 1)));
    deep[tone] = packRgb(body);
    keel[tone] = packRgb(mix(body, palette.hull, 0.1));
  }
  return {
    water,
    deep,
    keel,
    hull: packRgb(palette.hull),
    sailLit: packRgb(palette.sailLit),
    sailShade: packRgb(palette.sailShade),
    mast: packRgb(palette.mast),
  };
}

function clamp01(value: number): number {
  return value < 0 ? 0 : value > 1 ? 1 : value;
}

function smoothstep(edge0: number, edge1: number, value: number): number {
  const t = clamp01((value - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
}

/** Stable 32-bit integer hash to [0, 1). */
function hash01(a: number, b: number): number {
  let value = (Math.imul(a | 0, 0x9e3779b1) ^ Math.imul((b | 0) + 0x632be5ab, 0x85ebca6b)) >>> 0;
  value ^= value >>> 16;
  value = Math.imul(value, 0x7feb352d) >>> 0;
  value ^= value >>> 15;
  value = Math.imul(value, 0x846ca68b) >>> 0;
  value ^= value >>> 16;
  return (value >>> 0) / 4294967296;
}

/** Smooth one-dimensional value noise in [0, 1). */
function valueNoise(x: number, seed: number): number {
  const cell = Math.floor(x);
  const t = x - cell;
  const eased = t * t * (3 - 2 * t);
  return hash01(cell, seed) + (hash01(cell + 1, seed) - hash01(cell, seed)) * eased;
}

// ---------------------------------------------------------------------------------
// Frames.

/**
 * What a cell shows: `plain` is uncolored padding, `water` any water cell, `hull` the
 * hull including its waterline cells, `sail` either sail, and `mast` the mast.
 */
export type CalmWorkingShipColor = "plain" | "water" | "hull" | "sail" | "mast";

/** Colors are `0xRRGGBB`, or `null` for the terminal's default. */
export type CalmWorkingShipRun = {
  readonly text: string;
  readonly color: CalmWorkingShipColor;
  readonly fg: number | null;
  readonly bg: number | null;
};

/**
 * One painted frame, each row exactly the requested width: the rig, the surface with
 * the hull, and the water body when the hull fits, or one row when it does not.
 */
export type CalmWorkingShipFrame = readonly (readonly CalmWorkingShipRun[])[];

export type CalmWorkingShipSprite = {
  /**
   * Paint one frame that exactly fits `width` in the `family` shading, clamping the
   * track to it first.
   */
  frame(width: number, family?: CalmWorkingShipFamily): CalmWorkingShipFrame;
  /** Advance one fixed physics step. */
  tick(): void;
  /** Return to the state of the last painted frame, discarding later ticks. */
  restoreLastRendered(): void;
  /** Restore the normal initial column, heading, springs, and sea clock. */
  reset(): void;
  /**
   * Clamp the frozen boat to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current hull column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current travel intent: 1 bound right, -1 bound left. */
  direction(): number;
  /** Current speed over the water in columns per second, signed. */
  velocity(): number;
  /** Current pitch in radians, positive bow-right up. */
  pitch(): number;
  /** Elapsed sea time in milliseconds, exposed for deterministic freeze assertions. */
  seaTime(): number;
};

/** Longest hull start column that still fits the sprite in `width` usable cells. */
function trackSpan(width: number): number {
  if (width >= HULL_WIDTH) return width - HULL_WIDTH;
  if (width >= SAIL_WIDTH) return width - SAIL_WIDTH;
  return 0;
}

type BoatState = {
  x: number;
  v: number;
  direction: number;
  span: number;
  ticks: number;
  heave: number;
  heaveRate: number;
  pitch: number;
  pitchRate: number;
};

/** Mean water height and pitch slope under a hull whose left end is at `x`. */
function hullForcing(x: number, seconds: number): { heave: number; slope: number; velocity: number } {
  let heave = 0;
  for (let offset = 0; offset < HULL_WIDTH; offset += 1) {
    heave += calmWorkingShipSea(x + offset, seconds).height;
  }
  const bow = calmWorkingShipSea(x + HULL_WIDTH - 1, seconds).height;
  const stern = calmWorkingShipSea(x, seconds).height;
  const center = calmWorkingShipSea(x + (HULL_WIDTH - 1) / 2, seconds);
  // Rows over columns, rescaled to a physical slope.
  const slope = ((bow - stern) * ASPECT) / (HULL_WIDTH - 1);
  return { heave: heave / HULL_WIDTH, slope, velocity: center.velocity };
}

function initialState(): BoatState {
  const forcing = hullForcing(0, 0);
  return {
    x: 0,
    v: CALM_WORKING_SHIP_CRUISE,
    direction: 1,
    span: 0,
    ticks: 0,
    heave: forcing.heave,
    heaveRate: 0,
    pitch: Math.atan(forcing.slope),
    pitchRate: 0,
  };
}

type Cell = { glyph: string; color: CalmWorkingShipColor; fg: number | null; bg: number | null };

/** Merge equal neighbouring cells into runs, so harnesses emit one color change per run. */
function toRuns(cells: readonly Cell[]): CalmWorkingShipRun[] {
  const runs: CalmWorkingShipRun[] = [];
  let text = "";
  let current: Cell | undefined;
  for (const cell of cells) {
    if (current && cell.color === current.color && cell.fg === current.fg && cell.bg === current.bg) {
      text += cell.glyph;
      continue;
    }
    if (current) runs.push({ text, color: current.color, fg: current.fg, bg: current.bg });
    current = cell;
    text = cell.glyph;
  }
  if (current) runs.push({ text, color: current.color, fg: current.fg, bg: current.bg });
  return runs;
}

export function createCalmWorkingShipSprite(): CalmWorkingShipSprite {
  let state = initialState();
  let rendered = { ...state };
  let cache: { key: string; frame: CalmWorkingShipFrame } | undefined;

  // Reversing the moment the boat lands on an endpoint means the endpoint frame already
  // carries the new intent, and the hull then eases through zero speed to turn.
  const settleDirectionAtEdges = (): void => {
    if (state.span <= 0) return;
    if (state.x >= state.span) state.direction = -1;
    else if (state.x <= 0) state.direction = 1;
  };

  const applyWidth = (width: number): void => {
    if (width <= 0) {
      state.span = 0;
      state.x = 0;
      return;
    }
    state.span = trackSpan(width);
    state.x = Math.min(state.x, state.span);
    settleDirectionAtEdges();
  };

  const column = (): number => Math.max(0, Math.min(state.span, Math.round(state.x)));

  const heading = (): number => {
    if (state.v > 0.05) return 1;
    if (state.v < -0.05) return -1;
    return state.direction;
  };

  /** Shade one water column from its surface height and slope, as packed colors. */
  const shadeWater = (
    table: ShadeTable,
    height: number,
    slope: number,
    x: number,
    seconds: number,
    extraFoam: number,
  ): { surface: number; deep: number; keel: number } => {
    // Crest height through the full span of the stacked trains.
    const crest = clamp01(height / (2 * AMPLITUDE_SUM) + 0.5);
    // Lambert term against the resting surface, so flat water keeps its base tone.
    const normalLength = Math.hypot(slope, 1);
    const diffuse = (-slope * SUN_X + SUN_Y) / normalLength - SUN_Y;
    const tone = clamp01(0.12 + 0.66 * crest + 2.4 * diffuse);
    // Sun glitter: a narrow specular lobe around the mirror tilt, twinkling per facet.
    const tilt = Math.atan(slope);
    const lobe = Math.exp(-(((tilt - GLINT_ANGLE) / GLINT_SPREAD) ** 2));
    const twinkle = hash01(Math.floor(x), Math.floor(seconds * 9)) > 0.6 ? 1 : 0;
    const glint = lobe * twinkle * smoothstep(0.55, 0.8, crest);
    // Whitecaps where trains stack into steep, high crests, patchy along the swell.
    const patches = 0.55 * valueNoise((x - SWELL_SPEED * seconds) * 0.21, 11) + 0.45 * valueNoise(x * 0.07 + seconds * 0.19, 29);
    const whitecap = smoothstep(0.74, 0.96, crest) * smoothstep(0.3, 0.8, patches) * smoothstep(0.02, 0.12, Math.abs(slope) + 0.06);
    const foam = clamp01(whitecap + extraFoam);
    const toneIndex = Math.round(tone * (TONE_STEPS - 1));
    const foamIndex = Math.round(foam * (FOAM_STEPS - 1));
    const glintIndex = Math.round(clamp01(glint) * (GLINT_STEPS - 1));
    return {
      surface: table.water[(toneIndex * FOAM_STEPS + foamIndex) * GLINT_STEPS + glintIndex]!,
      deep: table.deep[toneIndex]!,
      keel: table.keel[toneIndex]!,
    };
  };

  const levelOf = (height: number, min: number, max: number): number => {
    const level = Math.round(height * LEVELS);
    return Math.max(min, Math.min(max, level));
  };

  const paint = (width: number, family: CalmWorkingShipFamily): CalmWorkingShipFrame => {
    const table = SHADE_TABLES[family];
    const seconds = state.ticks * DT;
    const at = column();
    const hullMode = width >= HULL_WIDTH;
    const bodyWidth = hullMode ? HULL_WIDTH : SAIL_WIDTH;
    const center = at + (bodyWidth - 1) / 2;
    const facing = heading();
    const speed = clamp01(Math.abs(state.v) / CALM_WORKING_SHIP_CRUISE);
    // The waterline the hull's heave and pitch would hold in still water.
    const tilt = Math.tan(state.pitch) / ASPECT;

    // The sea row, sampled at every column through phase recurrences so a frame costs
    // a handful of multiplies per column rather than fresh trigonometry.
    const heights = new Float64Array(width);
    const slopes = new Float64Array(width);
    for (const train of TRAINS) {
      const theta0 = -train.omega * seconds + train.phase;
      let c = Math.cos(theta0);
      let s = Math.sin(theta0);
      const stepC = Math.cos(train.kappa);
      const stepS = Math.sin(train.kappa);
      const bound = 0.5 * train.k * train.a * train.a;
      for (let x = 0; x < width; x += 1) {
        heights[x]! += (train.a * c + bound * (2 * c * c - 1)) / ASPECT;
        slopes[x]! += -train.a * train.kappa * s - 2 * bound * train.kappa * (2 * s * c);
        const nextC = c * stepC - s * stepS;
        s = s * stepC + c * stepS;
        c = nextC;
      }
    }

    const cells: Cell[] = new Array(width);
    const body: Cell[] = new Array(width);
    for (let x = 0; x < width; x += 1) {
      // Wake behind the stern and a small bow wave ahead, both scaled by speed.
      const behind = facing > 0 ? at - 1 - x : x - (at + bodyWidth);
      const ahead = facing > 0 ? x - (at + bodyWidth) : at - 1 - x;
      let wake = 0;
      if (behind >= 0) wake = 0.75 * speed * Math.exp(-behind / 2.2) * (0.6 + 0.4 * hash01(x, Math.floor(seconds * 5)));
      else if (ahead === 0) wake = 0.35 * speed;
      const shade = shadeWater(table, heights[x]!, slopes[x]!, x, seconds, wake);
      // The view follows the boat's heave, so the sea stays level around a floating hull.
      const surface = MEAN_LEVEL + heights[x]! - state.heave;
      cells[x] = {
        glyph: CALM_WORKING_SHIP_WAVE_BARS[levelOf(surface, 1, LEVELS) - 1]!,
        color: "water",
        fg: shade.surface,
        bg: null,
      };
      const underHull = hullMode && x > at && x < at + HULL_WIDTH - 1;
      body[x] = { glyph: "█", color: "water", fg: underHull ? shade.keel : shade.deep, bg: null };
    }

    if (width < SAIL_WIDTH) return [toRuns(cells)];

    const rig = facing > 0 ? CALM_WORKING_SHIP_SAIL_RIGHT : CALM_WORKING_SHIP_SAIL_LEFT;
    const [leftSail, , rightSail] = Array.from(rig);
    const mast =
      state.pitch > MAST_LEAN
        ? CALM_WORKING_SHIP_MASTS.leanLeft
        : state.pitch < -MAST_LEAN
          ? CALM_WORKING_SHIP_MASTS.leanRight
          : CALM_WORKING_SHIP_MASTS.upright;
    // The sun sits upper left, so the left sail catches the light.
    const rigCells: Cell[] = [
      { glyph: leftSail!, color: "sail", fg: table.sailLit, bg: null },
      { glyph: mast, color: "mast", fg: table.mast, bg: null },
      { glyph: rightSail!, color: "sail", fg: table.sailShade, bg: null },
    ];

    if (!hullMode) {
      // Too narrow for the hull: the rig alone rides inside the water row.
      cells.splice(at, SAIL_WIDTH, ...rigCells);
      return [toRuns(cells)];
    }

    cells[at] = { glyph: CALM_WORKING_SHIP_HULL_LEFT, color: "hull", fg: table.hull, bg: null };
    cells[at + HULL_WIDTH - 1] = { glyph: CALM_WORKING_SHIP_HULL_RIGHT, color: "hull", fg: table.hull, bg: null };
    for (let offset = 1; offset < HULL_WIDTH - 1; offset += 1) {
      const x = at + offset;
      // The water in front of the hull, drawn over the hull's side: the waterline sits
      // at the draft plus whatever the heave and pitch springs have not yet followed.
      const hullLine = tilt * (x - center);
      const waterline = DRAFT + heights[x]! - state.heave - hullLine;
      cells[x] = {
        glyph: CALM_WORKING_SHIP_WAVE_BARS[levelOf(waterline, 1, 5) - 1]!,
        color: "hull",
        fg: cells[x]!.fg,
        bg: table.hull,
      };
    }

    const top: Cell[] = [];
    for (let x = 0; x < at + SAIL_OFFSET; x += 1) top.push({ glyph: " ", color: "plain", fg: null, bg: null });
    top.push(...rigCells);
    return [toRuns(top), toRuns(cells), toRuns(body)];
  };

  return {
    position: column,
    direction: () => state.direction,
    velocity: () => state.v,
    pitch: () => state.pitch,
    seaTime: () => state.ticks * CALM_WORKING_SHIP_TICK_MS,

    restoreLastRendered(): void {
      state = { ...rendered };
      cache = undefined;
    },

    reset(): void {
      state = initialState();
      rendered = { ...state };
      cache = undefined;
    },

    clampToWidth(width: number): void {
      applyWidth(width);
    },

    tick(): void {
      state.ticks += 1;
      const seconds = state.ticks * DT;
      const forcing = hullForcing(state.x, seconds);

      // Heave and pitch: damped springs toward the water under the hull.
      state.heaveRate +=
        (HEAVE_OMEGA * HEAVE_OMEGA * (forcing.heave - state.heave) - 2 * HEAVE_DAMPING * HEAVE_OMEGA * state.heaveRate) * DT;
      state.heave += state.heaveRate * DT;
      state.pitchRate +=
        (PITCH_OMEGA * PITCH_OMEGA * (Math.atan(forcing.slope) - state.pitch) - 2 * PITCH_DAMPING * PITCH_OMEGA * state.pitchRate) * DT;
      state.pitch += state.pitchRate * DT;

      if (state.span <= 0) {
        state.x = 0;
        return;
      }
      // Surge: cruise toward the intent, easing off near the edge ahead, carried along
      // by the orbital velocity of the water under the hull.
      const edgeDistance = state.direction > 0 ? state.span - state.x : state.x;
      const cruise = CALM_WORKING_SHIP_CRUISE * Math.max(0.3, Math.min(1, edgeDistance / BRAKE_DISTANCE));
      const target = state.direction * cruise + SURGE * forcing.velocity;
      state.v += (target - state.v) * (1 - Math.exp(-DT / SPEED_LAG));
      state.x = Math.max(0, Math.min(state.span, state.x + state.v * DT));
      settleDirectionAtEdges();
    },

    frame(width: number, family: CalmWorkingShipFamily = "dark"): CalmWorkingShipFrame {
      if (width <= 0) return [];
      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(width);
      const key = `${width}|${family}|${state.ticks}|${state.x}|${state.direction}|${state.heave}|${state.pitch}`;
      if (cache?.key !== key) cache = { key, frame: paint(width, family) };
      rendered = { ...state };
      return cache.frame;
    },
  };
}
