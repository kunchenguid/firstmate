// Firstmate's harness-neutral Calm working-ship sprite.
//
// This module owns the sea simulation, the floating boat, the lighting that shades
// them, and the freeze/resume state that every Calm working presentation shares. It
// paints each frame as rows of runs carrying resolved RGB foreground and background
// colors and never as bytes, so each harness renders the same picture its own way:
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
// sharper than troughs, and the pattern never repeats on screen. Each column's surface
// is lit from its normal: a height term for light passing through thin crests, a
// diffuse term for the flank facing the sun, a narrow specular lobe that twinkles as
// sun glitter, and whitecap foam where crests stack, in the boat's wake, and where its
// bow slams into the water. Below the lit skin the water darkens with depth.
//
// Boat: the hull floats by strip theory. Each of a dozen hull sections is buoyed in
// proportion to how deep the water under it covers it, so the summed lift heaves the
// boat and its moment pitches it; both are lightly damped, so the boat rises and falls
// with the water under it, tilts to the local slope, and keeps bobbing and rocking a
// little after each wave passes. The boat cruises, surges with the waves' orbital
// velocity, surfs down their faces, brakes into each edge, and comes about there.
//
// Rigid boat: the hull and sails keep one shape. The boat is drawn once, at a set of
// tilts and facing each way, and each frame shows the drawing at the tilt nearest its
// pitch, on whole columns and lifted in eighth-row steps, so it only rises, falls, and
// tilts and is never re-sampled into a different outline.
//
// Rendering: the scene is sampled at eight sub-rows per cell, and each cell shows its
// best two-color split through the bottom-aligned block glyphs, so the waterline and
// the rising and falling boat move in eighth-cell steps rather than whole rows. The
// sky stays the terminal's own background.
//
// Cadence: one fixed-step scheduler at CALM_WORKING_SHIP_TICK_MS drives everything.
// Ticks, not wall-clock timestamps, drive every state change, so tests can seek time
// exactly and a slow frame never makes the physics jump.
//
// Continuity: one caller-owned sprite instance survives hide/show within one harness
// process and extension lifetime. restoreLastRendered() freezes the boat, its motion,
// and the sea clock at the last painted frame without advancing them for hidden wall
// time, and the next working period resumes from that exact logical state. A fresh
// session or new extension lifetime calls reset() and starts at the normal initial
// position. State is never a module-level or process-global singleton.

// ---------------------------------------------------------------------------------
// Geometry and glyphs.

/** Rig glyphs heading left, drawn inside the water row when the hull does not fit. */
export const CALM_WORKING_SHIP_SAIL_LEFT = "◿│◣";
/** Rig glyphs heading right, the narrow fallback's mirror. */
export const CALM_WORKING_SHIP_SAIL_RIGHT = "◢│◺";
const SAIL_WIDTH = 3;

/** Bottom-aligned eighth blocks: a cell split at one-eighth-cell height steps. */
export const CALM_WORKING_SHIP_WAVE_BARS = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"] as const;
const LEVELS = CALM_WORKING_SHIP_WAVE_BARS.length;
/** Top-aligned blocks for a cell whose lower part is sky. */
const TOP_EIGHTH = "▔";
const TOP_HALF = "▀";

/** Rows in the full scene: three of sky for the rig, the surface row, and the water body. */
export const CALM_WORKING_SHIP_ROWS = 5;
/** Hull length in columns: the narrowest width that draws the full scene. */
export const CALM_WORKING_SHIP_HULL_LENGTH = 8;
const HALF = CALM_WORKING_SHIP_HULL_LENGTH / 2;

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
/** Resting water level, in rows above the bottom of the scene. */
const MEAN_LEVEL = 1.25;

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
  { wavelength: 44.0, amplitude: 0.26, direction: 1, phase: 0.3 },
  { wavelength: 28.9, amplitude: 0.16, direction: 1, phase: 2.1 },
  { wavelength: 19.3, amplitude: 0.1, direction: 1, phase: 4.4 },
  { wavelength: 12.1, amplitude: 0.058, direction: 1, phase: 1.2 },
  { wavelength: 7.7, amplitude: 0.034, direction: -1, phase: 5.0 },
  { wavelength: 4.9, amplitude: 0.02, direction: 1, phase: 3.3 },
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
// The boat's shape, in its own frame: `u` along the hull in columns with the bow at
// +HALF, `v` up in physical units from the design waterline, both before pitch.

/** Freeboard amidships and draft of the hull, in physical units. */
const FREEBOARD = 0.4 * ASPECT;
const DRAFT = 0.6 * ASPECT;

/** Top of the hull: a sheer line rising toward both ends, highest at the bow. */
function deckAt(t: number): number {
  return FREEBOARD * (1 + 0.32 * t * t + 0.14 * t);
}

/** Bottom of the hull: a rounded body whose ends rake up out of the water. */
function keelAt(t: number): number {
  const body = -DRAFT * Math.pow(Math.max(0, 1 - t * t), 0.6);
  const rake = t > 0 ? 1.15 * FREEBOARD * t ** 6 : 0.55 * FREEBOARD * t ** 8;
  return body + rake;
}

/** The underwater lift a section contributes grows with its beam, fullest amidships. */
function beamAt(t: number): number {
  return 1 - 0.55 * t * t;
}

/** Mast position along the hull, and its height above the deck, in physical units. */
const MAST_U = 0.1 * HALF;
const MAST_HEIGHT = 2.75 * ASPECT;
/** The mainsail's foot, from the mast aft to the boom end, in columns. */
const BOOM = 2.5;
/** The jib's head as a fraction of the mast height, and its tack forward of the mast. */
const JIB_HEAD = 0.72;
const JIB_TACK = MAST_U + 2.2;
/** Where each sail's leech meets its foot: a full cell above the deck (see drawBoat). */
const CLEW = ASPECT;

/**
 * Whether the rig covers `u` along the hull and `v` up: the mainsail aft of the mast
 * and the jib forward of it, one sail color, both rising straight from the deck line,
 * each leech sloping down from its head to a clew a full cell above the deck.
 */
function rigAt(u: number, v: number): number {
  const above = v - deckAt(u / HALF);
  if (above < 0) return SKY;
  if (u <= MAST_U && u >= MAST_U - BOOM) {
    if (above <= CLEW + ((MAST_HEIGHT - CLEW) * (u - (MAST_U - BOOM))) / BOOM) return MAIN_INDEX;
  } else if (u > MAST_U && u <= JIB_TACK) {
    if (above <= CLEW + ((JIB_HEAD * MAST_HEIGHT - CLEW) * (JIB_TACK - u)) / (JIB_TACK - MAST_U)) return MAIN_INDEX;
  }
  return SKY;
}

// ---------------------------------------------------------------------------------
// Boat dynamics.

/** Cruising speed in columns per second: a deliberately calm boat. */
export const CALM_WORKING_SHIP_CRUISE = 1.15;
/** How much of the waves' orbital velocity carries the hull along. */
const SURGE = 0.9;
/** How strongly gravity pulls the boat down a wave face, in columns per second squared. */
const SURF = 1.4;
/** Speed response time constant in seconds. */
const SPEED_LAG = 0.9;
/** Columns from an edge over which the boat eases off before it turns. */
const BRAKE_DISTANCE = 3;
/** Heave and pitch natural periods and damping ratios: light, so the boat keeps rocking. */
const HEAVE_OMEGA = (2 * Math.PI) / 1.35;
const HEAVE_DAMPING = 0.26;
const PITCH_OMEGA = (2 * Math.PI) / 1.0;
const PITCH_DAMPING = 0.2;
const PITCH_LIMIT = 0.45;
/** Hull sections the buoyancy integrates over. */
const STRIPS = 12;
/** Turning rate when the boat comes about, in radians per second. */
const TURN_RATE = Math.PI / 1.7;
/**
 * The tilts the boat is drawn at: the rigid boat is drawn once at each multiple of
 * TILT_STEP radians up to TILT_STEPS either way, and every frame shows the one nearest
 * its pitch, so at one tilt its outline is the same in every frame.
 */
const TILT_STEP = 0.06;
const TILT_STEPS = 6;
/**
 * Wind gusts on the rig: a smooth random pitching moment, in radians of equivalent
 * slope, and how many gusts arrive a second. They set the hull rocking on its own
 * lightly damped springs, the wobble a small boat keeps even between waves.
 */
const GUST_PITCH = 0.16;
const GUST_HEAVE = 0.05;
const GUST_RATE = 1.1;
/** How long a bow splash takes to settle, in seconds. */
const SPLASH_DECAY = 0.35;

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
};

const PALETTES: Readonly<Record<CalmWorkingShipFamily, ShipPalette>> = {
  dark: {
    water: [
      [0.0, [5, 16, 58]],
      [0.3, [10, 58, 138]],
      [0.55, [19, 95, 156]],
      [0.78, [31, 134, 185]],
      [1.0, [79, 181, 212]],
    ],
    foam: [223, 241, 247],
    glint: [255, 246, 216],
    hull: [176, 50, 34],
    sailLit: [243, 236, 218],
    sailShade: [196, 186, 162],
  },
  light: {
    water: [
      [0.0, [4, 14, 56]],
      [0.3, [10, 56, 138]],
      [0.55, [19, 92, 154]],
      [0.78, [27, 120, 174]],
      [1.0, [47, 151, 194]],
    ],
    foam: [140, 189, 214],
    glint: [178, 216, 232],
    hull: [150, 36, 24],
    sailLit: [182, 162, 122],
    sailShade: [140, 121, 86],
  },
};

/**
 * The boat's resolved colors in `family`, as `0xRRGGBB`, for callers locating it: the
 * hull, and the sails (the working boat's one sail color, then the narrow rig's jib).
 */
export function calmWorkingShipBoatColors(family: CalmWorkingShipFamily): { hull: number; sails: readonly number[] } {
  const colors = COLOR_TABLES[family];
  return { hull: colors[HULL_INDEX]!, sails: [colors[MAIN_INDEX]!, colors[JIB_INDEX]!] };
}

// Every color is an index into a small per-family table: runs of equal color merge,
// frames stay well inside a terminal's palette and Claude Code's color-pair budget,
// and no per-cell color math runs per frame. The deep stops keep blue rising faster
// than green, so a terminal or multiplexer that downsamples to 256 colors by plain RGB
// distance lands on navy and steel blue rather than the cube's teal.
const TONE_STEPS = 16;
const FOAM_STEPS = 6;
const GLINT_STEPS = 4;
/** Depth bands below the lit skin, each BAND rows thick, darkening with depth. */
const BANDS = 6;
const SKIN = 0.28;
const BAND = 0.33;

const SKY = -1;
const SURFACE_BASE = 0;
const BODY_BASE = SURFACE_BASE + TONE_STEPS * FOAM_STEPS * GLINT_STEPS;
const HULL_INDEX = BODY_BASE + BANDS;
const MAIN_INDEX = HULL_INDEX + 1;
const JIB_INDEX = MAIN_INDEX + 1;
const PALETTE_SIZE = JIB_INDEX + 1;

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

const COLOR_TABLES: Readonly<Record<CalmWorkingShipFamily, Uint32Array>> = {
  dark: buildColorTable(PALETTES.dark),
  light: buildColorTable(PALETTES.light),
};

function buildColorTable(palette: ShipPalette): Uint32Array {
  const table = new Uint32Array(PALETTE_SIZE);
  for (let tone = 0; tone < TONE_STEPS; tone += 1) {
    const base = waterTone(palette.water, tone / (TONE_STEPS - 1));
    for (let foam = 0; foam < FOAM_STEPS; foam += 1) {
      const foamed = mix(base, palette.foam, (foam / (FOAM_STEPS - 1)) * 0.9);
      for (let glint = 0; glint < GLINT_STEPS; glint += 1) {
        const lit = mix(foamed, palette.glint, (glint / (GLINT_STEPS - 1)) * 0.85);
        table[SURFACE_BASE + (tone * FOAM_STEPS + foam) * GLINT_STEPS + glint] = packRgb(lit);
      }
    }
  }
  // Light fades with depth, so each band is a darker echo of the lit water above it.
  for (let band = 0; band < BANDS; band += 1) {
    table[BODY_BASE + band] = packRgb(waterTone(palette.water, 0.38 * 0.62 ** band));
  }
  table[HULL_INDEX] = packRgb(palette.hull);
  table[MAIN_INDEX] = packRgb(palette.sailLit);
  table[JIB_INDEX] = packRgb(palette.sailShade);
  return table;
}

/** What a palette index draws: sky, water (including the keel under it), hull, or sail. */
function classOf(index: number): number {
  if (index === SKY) return 0;
  if (index < HULL_INDEX) return 1;
  if (index === HULL_INDEX) return 2;
  return 3;
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

/** The lit skin's palette index from its surface height, slope, and extra foam. */
function surfaceIndex(height: number, slope: number, x: number, seconds: number, extraFoam: number): number {
  // Crest height through the full span of the stacked trains.
  const crest = clamp01(height / (2 * AMPLITUDE_SUM) + 0.5);
  // Lambert term against the resting surface, so flat water keeps its base tone.
  const diffuse = (-slope * SUN_X + SUN_Y) / Math.hypot(slope, 1) - SUN_Y;
  const tone = clamp01(0.12 + 0.66 * crest + 2.4 * diffuse);
  // Sun glitter: a narrow specular lobe around the mirror tilt, twinkling per facet.
  const lobe = Math.exp(-(((Math.atan(slope) - GLINT_ANGLE) / GLINT_SPREAD) ** 2));
  const twinkle = hash01(Math.floor(x), Math.floor(seconds * 9)) > 0.6 ? 1 : 0;
  const glint = lobe * twinkle * smoothstep(0.55, 0.8, crest);
  // Whitecaps where trains stack into steep, high crests, patchy along the swell.
  const patches = 0.55 * valueNoise((x - SWELL_SPEED * seconds) * 0.21, 11) + 0.45 * valueNoise(x * 0.07 + seconds * 0.19, 29);
  const whitecap = smoothstep(0.74, 0.96, crest) * smoothstep(0.3, 0.8, patches) * smoothstep(0.02, 0.12, Math.abs(slope) + 0.06);
  const foam = clamp01(whitecap + extraFoam);
  const toneIndex = Math.round(tone * (TONE_STEPS - 1));
  const foamIndex = Math.round(foam * (FOAM_STEPS - 1));
  const glintIndex = Math.round(clamp01(glint) * (GLINT_STEPS - 1));
  return SURFACE_BASE + (toneIndex * FOAM_STEPS + foamIndex) * GLINT_STEPS + glintIndex;
}

// ---------------------------------------------------------------------------------
// Frames.

/**
 * What a cell shows: `plain` is uncolored sky or padding, `water` any water cell, `hull`
 * a cell holding the hull, and `sail` a cell holding a sail or the narrow fallback rig.
 */
export type CalmWorkingShipColor = "plain" | "water" | "hull" | "sail";

/** Colors are `0xRRGGBB`, or `null` for the terminal's default. */
export type CalmWorkingShipRun = {
  readonly text: string;
  readonly color: CalmWorkingShipColor;
  readonly fg: number | null;
  readonly bg: number | null;
};

/**
 * One painted frame, each row exactly the requested width: two sky rows for the rig,
 * the surface row, and the water body when the hull fits, or one row when it does not.
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
  /** Restore the normal initial column, heading, motion, and sea clock. */
  reset(): void;
  /**
   * Clamp the frozen boat to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current hull column (its left end), exposed for deterministic motion assertions. */
  position(): number;
  /** Current travel intent: 1 bound right, -1 bound left. */
  direction(): number;
  /** Current speed over the water in columns per second, signed. */
  velocity(): number;
  /** Current pitch in radians, positive with the right end up. */
  pitch(): number;
  /** The tilt the boat is drawn at, in radians: the drawn tilt nearest its pitch. */
  tilt(): number;
  /** Which way the drawn bow points: 1 right, -1 left, flipping as the boat comes about. */
  bow(): number;
  /** Current heave in rows: the hull's rise above its resting waterline. */
  heave(): number;
  /** Elapsed sea time in milliseconds, exposed for deterministic freeze assertions. */
  seaTime(): number;
};

/** Longest hull start column that still fits the sprite in `width` usable cells. */
function trackSpan(width: number): number {
  if (width >= CALM_WORKING_SHIP_HULL_LENGTH) return width - CALM_WORKING_SHIP_HULL_LENGTH;
  if (width >= SAIL_WIDTH) return width - SAIL_WIDTH;
  return 0;
}

type BoatState = {
  /** Left end of the hull's track slot, in columns. */
  x: number;
  v: number;
  direction: number;
  span: number;
  ticks: number;
  /** Heave in physical units above the resting waterline, and its rate. */
  z: number;
  zRate: number;
  pitch: number;
  pitchRate: number;
  /** Heading angle: 0 sailing right, pi sailing left, between while coming about. */
  heading: number;
  /** How far the bow section is immersed, and the spray it last threw. */
  bowImmersion: number;
  splash: number;
};

/** Which way the bow points on screen: right until the boat has turned past end-on. */
function bowOf(heading: number): number {
  return Math.cos(heading) >= 0 ? 1 : -1;
}

type Forcing = {
  /** Lift and its moment in excess of still-water equilibrium, normalized. */
  lift: number;
  moment: number;
  slope: number;
  velocity: number;
  bowImmersion: number;
};

/** Buoyancy over the hull's sections for the boat state `state` at `seconds`. */
function hullForcing(state: BoatState, seconds: number): Forcing {
  const bow = bowOf(state.heading);
  const center = state.x + HALF;
  const tilt = Math.tan(state.pitch);
  let lift = 0;
  let still = 0;
  let moment = 0;
  let stillMoment = 0;
  let beam = 0;
  let inertia = 0;
  let bowImmersion = 0;
  for (let strip = 0; strip < STRIPS; strip += 1) {
    const t = -1 + (2 * strip + 1) / STRIPS;
    const offset = t * HALF * bow;
    const keel = keelAt(t);
    const depth = deckAt(t) - keel;
    const water = calmWorkingShipSea(center + offset, seconds).height * ASPECT;
    const immersion = Math.min(depth, Math.max(0, water - (state.z + offset * tilt + keel)));
    const rest = Math.min(depth, Math.max(0, -keel));
    const width = beamAt(t);
    lift += immersion * width;
    still += rest * width;
    moment += immersion * width * offset;
    stillMoment += rest * width * offset;
    beam += width;
    inertia += width * offset * offset;
    if (strip === STRIPS - 1) bowImmersion = immersion;
  }
  const here = calmWorkingShipSea(center, seconds);
  return {
    lift: (lift - still) / beam,
    moment: (moment - stillMoment) / inertia,
    slope: here.slope,
    velocity: here.velocity,
    bowImmersion,
  };
}

function initialState(): BoatState {
  const state: BoatState = {
    x: 0,
    v: CALM_WORKING_SHIP_CRUISE,
    direction: 1,
    span: 0,
    ticks: 0,
    z: 0,
    zRate: 0,
    pitch: 0,
    pitchRate: 0,
    heading: 0,
    bowImmersion: 0,
    splash: 0,
  };
  // Start floating where the water holds the boat rather than dropping it in.
  let heave = 0;
  for (let offset = 0; offset < CALM_WORKING_SHIP_HULL_LENGTH; offset += 1) {
    heave += calmWorkingShipSea(offset + 0.5, 0).height;
  }
  state.z = (heave / CALM_WORKING_SHIP_HULL_LENGTH) * ASPECT;
  state.pitch = Math.atan(calmWorkingShipSea(HALF, 0).slope);
  state.bowImmersion = hullForcing(state, 0).bowImmersion;
  return state;
}

type Cell = { glyph: string; color: CalmWorkingShipColor; fg: number | null; bg: number | null };

const PLAIN: Cell = { glyph: " ", color: "plain", fg: null, bg: null };

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

// Reused per-cell scratch for the two-color split: the cell's runs of equal sub-rows.
/** Stands in for all water and sky while a cell holding part of the boat is split. */
const BACKGROUND = -2;
const runValues = new Int32Array(LEVELS);
const runLengths = new Int32Array(LEVELS);

/**
 * Cost of drawing a sub-row of `actual` as `drawn`: a shade within one kind costs
 * least, an edge between kinds more, and losing any of the boat, which is often only a
 * sliver of a cell, costs most.
 */
function mismatch(actual: number, drawn: number): number {
  if (actual === drawn) return 0;
  const kind = classOf(actual);
  if (kind === classOf(drawn)) return 1;
  return kind >= 2 ? 8 : 4;
}

/** The value among runs [from, to) that draws them with the least cost, and that cost. */
function bestValue(from: number, to: number): { value: number; cost: number } {
  let value = SKY;
  let cost = Infinity;
  for (let candidate = from; candidate < to; candidate += 1) {
    let total = 0;
    for (let run = from; run < to; run += 1) total += runLengths[run]! * mismatch(runValues[run]!, runValues[candidate]!);
    if (total < cost) {
      cost = total;
      value = runValues[candidate]!;
    }
  }
  return { value, cost };
}

/**
 * Draw one cell from its eight sub-rows (bottom first) as one glyph with at most two
 * colors: a lower part up to one boundary and an upper part above it.
 */
function cellOf(sub: Int32Array, offset: number, colors: Uint32Array): Cell {
  // A cell holding part of the boat is split on the boat alone, with water and sky as
  // one background, so the boat is drawn the same whatever the water behind it does.
  let boat = false;
  for (let level = 0; level < LEVELS; level += 1) if (classOf(sub[offset + level]!) >= 2) boat = true;
  let runs = 0;
  for (let level = 0; level < LEVELS; level += 1) {
    const actual = sub[offset + level]!;
    const value = boat && classOf(actual) < 2 ? BACKGROUND : actual;
    if (runs > 0 && runValues[runs - 1] === value) runLengths[runs - 1]! += 1;
    else {
      runValues[runs] = value;
      runLengths[runs] = 1;
      runs += 1;
    }
  }
  let lower = runValues[0]!;
  let upper = runValues[runs - 1]!;
  let split = runs === 1 ? LEVELS : runLengths[0]!;
  if (runs > 2) {
    // Choose the boundary, at a run edge, and the two values that draw it best.
    let best = Infinity;
    let height = 0;
    for (let boundary = 1; boundary < runs; boundary += 1) {
      height += runLengths[boundary - 1]!;
      const below = bestValue(0, boundary);
      const above = bestValue(boundary, runs);
      if (below.cost + above.cost < best) {
        best = below.cost + above.cost;
        lower = below.value;
        upper = above.value;
        split = height;
      }
    }
  }
  if (lower === BACKGROUND) lower = backgroundOf(sub, offset, 0, split);
  if (upper === BACKGROUND) upper = backgroundOf(sub, offset, split, LEVELS);
  if (lower === upper || split >= LEVELS) return solid(lower, colors);
  if (split <= 0) return solid(upper, colors);
  const category = categoryOf(lower, upper);
  if (lower === SKY) {
    // Only top-aligned glyphs can leave the sky below, since a block drawn in the
    // terminal's default foreground would paint text color rather than sky. The boat
    // never needs this: water fills in under its hull and its sails rise from the deck.
    const cover = LEVELS - split;
    if (cover <= 2) return { glyph: TOP_EIGHTH, color: category, fg: colors[upper]!, bg: null };
    if (cover <= 6) return { glyph: TOP_HALF, color: category, fg: colors[upper]!, bg: null };
    return solid(upper, colors);
  }
  return {
    glyph: CALM_WORKING_SHIP_WAVE_BARS[split - 1]!,
    color: category,
    fg: colors[lower]!,
    bg: upper === SKY ? null : colors[upper]!,
  };
}

/** The most common water or sky value among sub-rows [from, to) of a cell, or sky. */
function backgroundOf(sub: Int32Array, offset: number, from: number, to: number): number {
  let value = SKY;
  let most = 0;
  for (let level = from; level < to; level += 1) {
    const candidate = sub[offset + level]!;
    if (classOf(candidate) >= 2) continue;
    let count = 0;
    for (let other = from; other < to; other += 1) if (sub[offset + other] === candidate) count += 1;
    if (count > most) {
      most = count;
      value = candidate;
    }
  }
  return value;
}

function solid(value: number, colors: Uint32Array): Cell {
  if (value === SKY) return PLAIN;
  return { glyph: "█", color: categoryOf(value, value), fg: colors[value]!, bg: null };
}

function categoryOf(lower: number, upper: number): CalmWorkingShipColor {
  const top = Math.max(classOf(lower), classOf(upper));
  return top === 3 ? "sail" : top === 2 ? "hull" : top === 1 ? "water" : "plain";
}

/**
 * The rigid boat drawn once at one tilt and heading: its palette index (or SKY) at
 * every column and sub-row of a box around it. Columns count from the hull's left end
 * starting at `left`; sub-rows count up from the design waterline starting at `bottom`.
 * `lowest` holds each column's lowest boat sub-row, or -1 when the column is empty.
 */
type BoatImage = {
  left: number;
  columns: number;
  bottom: number;
  rows: number;
  pixels: Int32Array;
  lowest: Int32Array;
};

/** Sub-columns sampled per column when drawing the boat's outline. */
const SUBSAMPLES = 4;

/**
 * Draw the rigid boat at one tilt and heading. Each column is made one hull run with
 * at most one sail run straight above it, and each run at least a full cell tall, so
 * no cell the boat touches ever holds more than two of its colors and the background.
 * A cell can show only two colors, so that is what keeps the drawn outline identical
 * at every eighth-row height the boat rides at, instead of thin parts being redrawn
 * differently as they cross cell boundaries.
 */
function drawBoat(bow: number, tilt: number): BoatImage {
  const cos = Math.cos(tilt);
  const sin = Math.sin(tilt);
  const lean = Math.abs(sin);
  const reach = Math.ceil((MAST_HEIGHT + 2 * FREEBOARD) * lean) + 1;
  const left = -reach;
  const columns = CALM_WORKING_SHIP_HULL_LENGTH + 2 * reach;
  const rise = Math.ceil(((HALF * lean) / ASPECT) * LEVELS);
  const bottom = -Math.max(LEVELS, Math.ceil((DRAFT / ASPECT) * LEVELS)) - rise - 1;
  const top = Math.ceil(((2 * FREEBOARD + MAST_HEIGHT) / ASPECT) * LEVELS) + rise + LEVELS;
  const rows = top - bottom;
  const pixels = new Int32Array(columns * rows).fill(SKY);
  const lowest = new Int32Array(columns).fill(-1);
  const votes = new Int32Array(SUBSAMPLES);
  for (let column = 0; column < columns; column += 1) {
    let hullLow = -1;
    let hullHigh = -1;
    let sailLow = -1;
    let sailHigh = -1;
    for (let row = 0; row < rows; row += 1) {
      const dy = ((bottom + row + 0.5) / LEVELS) * ASPECT;
      for (let sample = 0; sample < SUBSAMPLES; sample += 1) {
        const dx = left + column + (sample + 0.5) / SUBSAMPLES - HALF;
        const along = (dx * cos + dy * sin) * bow;
        const up = -dx * sin + dy * cos;
        let part = SKY;
        if (along >= -HALF && along <= HALF) {
          const t = along / HALF;
          part = up <= deckAt(t) && up >= keelAt(t) ? HULL_INDEX : rigAt(along, up);
        }
        votes[sample] = part;
      }
      const part = majority(votes);
      if (part === HULL_INDEX) {
        if (hullLow < 0) hullLow = row;
        hullHigh = row;
      } else if (part === MAIN_INDEX) {
        if (sailLow < 0) sailLow = row;
        sailHigh = row;
      }
    }
    // The hull reaches at least a cell below its deck, and the sail rises from the deck
    // to at least a cell above it, or is left out where only a sliver of it shows.
    if (hullHigh >= 0) {
      hullLow = Math.min(hullLow, hullHigh - LEVELS + 1);
      for (let row = hullLow; row <= hullHigh; row += 1) pixels[column * rows + row] = HULL_INDEX;
      if (sailHigh > hullHigh) sailLow = hullHigh + 1;
    }
    if (sailHigh >= 0 && sailLow >= 0) {
      const height = sailHigh - sailLow + 1;
      if (height >= 3) {
        sailHigh = Math.max(sailHigh, sailLow + LEVELS - 1);
        for (let row = sailLow; row <= sailHigh; row += 1) pixels[column * rows + row] = MAIN_INDEX;
      }
    }
    for (let row = 0; row < rows; row += 1) {
      if (pixels[column * rows + row] !== SKY) {
        lowest[column] = row;
        break;
      }
    }
  }
  return { left, columns, bottom, rows, pixels, lowest };
}

/** The boat at every drawn tilt, heading right then heading left. */
const BOAT_IMAGES: readonly (readonly BoatImage[])[] = [1, -1].map((bow) =>
  Array.from({ length: 2 * TILT_STEPS + 1 }, (_, index) => drawBoat(bow, (index - TILT_STEPS) * TILT_STEP)),
);

/** The drawn tilt nearest `pitch`, as an index into a heading's images. */
function tiltIndex(pitch: number): number {
  return Math.max(-TILT_STEPS, Math.min(TILT_STEPS, Math.round(pitch / TILT_STEP))) + TILT_STEPS;
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

  /** Too narrow for the hull: the rig alone rides in a single water row. */
  const paintNarrow = (width: number, colors: Uint32Array, seconds: number): CalmWorkingShipFrame => {
    const cells: Cell[] = new Array(width);
    for (let x = 0; x < width; x += 1) {
      const sea = calmWorkingShipSea(x + 0.5, seconds);
      const level = Math.max(1, Math.min(LEVELS, Math.round((0.5 + sea.height) * LEVELS)));
      cells[x] = {
        glyph: CALM_WORKING_SHIP_WAVE_BARS[level - 1]!,
        color: "water",
        fg: colors[surfaceIndex(sea.height, sea.slope, x, seconds, 0)]!,
        bg: null,
      };
    }
    if (width >= SAIL_WIDTH) {
      const rig = Array.from(bowOf(state.heading) > 0 ? CALM_WORKING_SHIP_SAIL_RIGHT : CALM_WORKING_SHIP_SAIL_LEFT);
      const at = column();
      cells.splice(
        at,
        SAIL_WIDTH,
        { glyph: rig[0]!, color: "sail", fg: colors[MAIN_INDEX]!, bg: null },
        { glyph: rig[1]!, color: "sail", fg: colors[HULL_INDEX]!, bg: null },
        { glyph: rig[2]!, color: "sail", fg: colors[JIB_INDEX]!, bg: null },
      );
    }
    return [toRuns(cells)];
  };

  const paint = (width: number, family: CalmWorkingShipFamily): CalmWorkingShipFrame => {
    const colors = COLOR_TABLES[family];
    const seconds = state.ticks * DT;
    if (width < CALM_WORKING_SHIP_HULL_LENGTH) return paintNarrow(width, colors, seconds);

    // The rigid boat at its drawn tilt, on whole columns, lifted in eighth-row steps.
    const bow = bowOf(state.heading);
    const image = BOAT_IMAGES[bow > 0 ? 0 : 1]![tiltIndex(state.pitch)]!;
    const at = column();
    const base = Math.round((MEAN_LEVEL + state.z / ASPECT) * LEVELS) + image.bottom;
    const center = at + HALF;
    const speed = clamp01(Math.abs(state.v) / CALM_WORKING_SHIP_CRUISE);
    const stern = center - HALF * bow;
    const stem = center + HALF * bow;

    // The surface at every column center, through per-train phase recurrences so a
    // frame costs a handful of multiplies per column rather than fresh trigonometry.
    const heights = new Float64Array(width);
    const slopes = new Float64Array(width);
    for (const train of TRAINS) {
      const theta0 = 0.5 * train.kappa - train.omega * seconds + train.phase;
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

    const subRows = CALM_WORKING_SHIP_ROWS * LEVELS;
    const sub = new Int32Array(subRows);
    const grid: Cell[][] = Array.from({ length: CALM_WORKING_SHIP_ROWS }, () => new Array<Cell>(width));
    for (let x = 0; x < width; x += 1) {
      const middle = x + 0.5;
      // Wake astern, a bow wave just ahead, and spray where the bow slams in.
      const behind = (stern - middle) * bow;
      const ahead = (middle - stem) * bow;
      let foam = 0;
      if (behind > 0) foam = 0.75 * speed * Math.exp(-behind / 2.4) * (0.6 + 0.4 * hash01(x, Math.floor(seconds * 5)));
      else if (ahead > -0.5 && ahead < 1.2) foam = 0.3 * speed + state.splash;
      const skin = surfaceIndex(heights[x]!, slopes[x]!, x, seconds, foam);
      const imageColumn = x - at - image.left;
      const inImage = imageColumn >= 0 && imageColumn < image.columns && image.lowest[imageColumn]! >= 0;
      // The boat floats in the water, so the water reaches up to its hull wherever the
      // hull rides above the surface, and the boat is drawn in front of the water.
      let surface = MEAN_LEVEL + heights[x]!;
      if (inImage) surface = Math.max(surface, (base + image.lowest[imageColumn]!) / LEVELS);
      for (let level = 0; level < subRows; level += 1) {
        const row = level - base;
        const part = inImage && row >= 0 && row < image.rows ? image.pixels[imageColumn * image.rows + row]! : SKY;
        if (part !== SKY) {
          sub[level] = part;
          continue;
        }
        const depth = surface - (level + 0.5) / LEVELS;
        sub[level] = depth < 0 ? SKY : depth < SKIN ? skin : BODY_BASE + Math.min(BANDS - 1, Math.floor((depth - SKIN) / BAND));
      }
      for (let row = 0; row < CALM_WORKING_SHIP_ROWS; row += 1) {
        grid[CALM_WORKING_SHIP_ROWS - 1 - row]![x] = cellOf(sub, row * LEVELS, colors);
      }
    }
    return grid.map(toRuns);
  };

  return {
    position: column,
    direction: () => state.direction,
    velocity: () => state.v,
    pitch: () => state.pitch,
    tilt: () => (tiltIndex(state.pitch) - TILT_STEPS) * TILT_STEP,
    bow: () => bowOf(state.heading),
    heave: () => state.z / ASPECT,
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
      const forcing = hullForcing(state, seconds);

      // Heave and pitch: the sections' excess lift and its moment plus the wind's gusts
      // on the rig, lightly damped.
      const gust = valueNoise(seconds * GUST_RATE, 41) - 0.5;
      const lull = valueNoise(seconds * GUST_RATE * 0.7, 53) - 0.5;
      state.zRate += (HEAVE_OMEGA * HEAVE_OMEGA * (forcing.lift + GUST_HEAVE * lull) - 2 * HEAVE_DAMPING * HEAVE_OMEGA * state.zRate) * DT;
      state.z += state.zRate * DT;
      state.pitchRate += (PITCH_OMEGA * PITCH_OMEGA * (forcing.moment + GUST_PITCH * gust) - 2 * PITCH_DAMPING * PITCH_OMEGA * state.pitchRate) * DT;
      state.pitch = Math.max(-PITCH_LIMIT, Math.min(PITCH_LIMIT, state.pitch + state.pitchRate * DT));

      // Spray where the bow drives down into the water faster than a gentle entry.
      const entry = (forcing.bowImmersion - state.bowImmersion) / DT;
      state.bowImmersion = forcing.bowImmersion;
      state.splash = Math.max(state.splash * Math.exp(-DT / SPLASH_DECAY), clamp01((entry - 0.35) * 0.5));

      // Come about toward the travel intent at a steady turning rate.
      const target = state.direction > 0 ? 0 : Math.PI;
      state.heading += Math.max(-TURN_RATE * DT, Math.min(TURN_RATE * DT, target - state.heading));

      if (state.span <= 0) {
        state.x = 0;
        return;
      }
      // Surge: cruise toward the intent, easing off near the edge ahead, carried along
      // by the orbital velocity of the water under the hull and pulled down wave faces.
      const edgeDistance = state.direction > 0 ? state.span - state.x : state.x;
      const cruise = CALM_WORKING_SHIP_CRUISE * Math.max(0.3, Math.min(1, edgeDistance / BRAKE_DISTANCE));
      const aim = state.direction * cruise + SURGE * forcing.velocity;
      state.v += (aim - state.v) * (1 - Math.exp(-DT / SPEED_LAG)) - SURF * forcing.slope * DT;
      state.x = Math.max(0, Math.min(state.span, state.x + state.v * DT));
      settleDirectionAtEdges();
    },

    frame(width: number, family: CalmWorkingShipFamily = "dark"): CalmWorkingShipFrame {
      if (width <= 0) return [];
      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(width);
      const key = `${width}|${family}|${state.ticks}|${state.x}|${state.direction}|${state.z}|${state.pitch}|${state.heading}|${state.splash}`;
      if (cache?.key !== key) cache = { key, frame: paint(width, family) };
      rendered = { ...state };
      return cache.frame;
    },
  };
}

/** The most common of the sub-column votes, preferring the boat or water over sky on a tie. */
function majority(votes: Int32Array): number {
  let best = votes[0]!;
  let bestCount = 0;
  for (let index = 0; index < votes.length; index += 1) {
    const value = votes[index]!;
    let count = 0;
    for (let other = 0; other < votes.length; other += 1) if (votes[other] === value) count += 1;
    if (count > bestCount || (count === bestCount && best === SKY && value !== SKY)) {
      best = value;
      bestCount = count;
    }
  }
  return best;
}
