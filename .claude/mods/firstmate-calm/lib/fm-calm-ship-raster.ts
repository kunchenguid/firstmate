// Packs one Calm working-ship frame as Claude Code Raster cells.
//
// The Claude Code mods API draws a grid of colored cells as one `Raster` element whose
// `cells` prop is base64 of `columns * rows` little-endian u32 triplets
// `[codePoint, foreground, background]`; `$.ui.blit` repaints a mounted Raster with a
// new `cells` string without a render pass. This module owns that packing and the
// choice of shading family on that surface; ../hooks/register.ts owns when it is drawn.
//
// The shared sprite resolves every cell's colors as RGB, which the Raster takes as is;
// the terminal paints them through its own palette, which paints 1024 distinct color
// pairs at once, far more than the sprite's quantized shading uses in one frame. The
// family follows the `theme` setting's prefix (`dark*` or `light*`); `auto`, custom,
// missing, and unreadable values use the light family as the both-readable fallback.
import type {
  CalmWorkingShipFamily,
  CalmWorkingShipFrame,
} from "./fm-calm-working-ship-sprite.ts";

/** The Raster's `key` inside the Spinner drawing, what `$.ui.blit` names to repaint it. */
export const CALM_SHIP_RASTER_KEY = "firstmate-calm-working-ship";

/** Claude Code's Raster width limit, per RasterProps. */
export const CALM_SHIP_RASTER_MAX_COLUMNS = 512;

/** The transcript's side margin the stock working row also sits inside. */
export const CALM_SHIP_RASTER_MARGIN = 2;

/** The viewport width assumed before the surface has measured. */
export const CALM_SHIP_RASTER_DEFAULT_VIEWPORT_COLUMNS = 80;

/** `0x01000000` (bit 24 alone) asks for the terminal's default color. */
export const CALM_SHIP_RASTER_DEFAULT_COLOR = 0x01000000;

/** The two theme families Claude Code's built-in themes fall into. */
export type CalmShipPaletteFamily = CalmWorkingShipFamily;

/**
 * The palette family for a `theme` setting value: values starting with `dark` select
 * the dark set, values starting with `light` select the light set, and every other,
 * missing, or non-string value selects the both-readable light fallback.
 */
export function calmShipPaletteFamily(theme: unknown): CalmShipPaletteFamily {
  return typeof theme === "string" && theme.startsWith("dark") ? "dark" : "light";
}

/** How many Raster columns a Spinner site of `viewportColumns` gets: the row minus its margin, within the Raster's limits. */
export function calmShipRasterColumns(viewportColumns: number | undefined): number {
  const measured = viewportColumns ?? CALM_SHIP_RASTER_DEFAULT_VIEWPORT_COLUMNS;
  return Math.max(1, Math.min(CALM_SHIP_RASTER_MAX_COLUMNS, measured - CALM_SHIP_RASTER_MARGIN));
}

const BASE64_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** Standard padded base64, written here because the hooks environment and Node differ on native helpers. */
export function encodeBase64(bytes: Uint8Array): string {
  let out = "";
  let index = 0;
  for (; index + 2 < bytes.length; index += 3) {
    const word = ((bytes[index] ?? 0) << 16) | ((bytes[index + 1] ?? 0) << 8) | (bytes[index + 2] ?? 0);
    out +=
      BASE64_ALPHABET[(word >> 18) & 63]! +
      BASE64_ALPHABET[(word >> 12) & 63]! +
      BASE64_ALPHABET[(word >> 6) & 63]! +
      BASE64_ALPHABET[word & 63]!;
  }
  const rest = bytes.length - index;
  if (rest === 1) {
    const word = (bytes[index] ?? 0) << 16;
    out += BASE64_ALPHABET[(word >> 18) & 63]! + BASE64_ALPHABET[(word >> 12) & 63]! + "==";
  } else if (rest === 2) {
    const word = ((bytes[index] ?? 0) << 16) | ((bytes[index + 1] ?? 0) << 8);
    out +=
      BASE64_ALPHABET[(word >> 18) & 63]! +
      BASE64_ALPHABET[(word >> 12) & 63]! +
      BASE64_ALPHABET[(word >> 6) & 63]! +
      "=";
  }
  return out;
}

export type CalmShipRasterCells = {
  /** How many rows the packed grid has: the frame's, one or three. */
  rows: number;
  /** The packed `cells` string for a Raster of `columns` by `rows`. */
  cells: string;
};

/**
 * Pack a frame painted for exactly `columns` cells. Every row is padded with plain
 * spaces to the full width, so the sail row's short run still fills its Raster row,
 * and a row wider than the grid is clipped rather than wrapped. A `null` color is the
 * terminal's default.
 */
export function packCalmShipRasterCells(
  frame: CalmWorkingShipFrame,
  columns: number,
): CalmShipRasterCells {
  const rows = Math.max(1, frame.length);
  const words = new Uint32Array(columns * rows * 3);
  const put = (row: number, column: number, codePoint: number, foreground: number, background: number): void => {
    if (column < 0 || column >= columns) return;
    const offset = (row * columns + column) * 3;
    words[offset] = codePoint;
    words[offset + 1] = foreground;
    words[offset + 2] = background;
  };
  for (let row = 0; row < rows; row += 1) {
    for (let column = 0; column < columns; column += 1) {
      put(row, column, 0x20, CALM_SHIP_RASTER_DEFAULT_COLOR, CALM_SHIP_RASTER_DEFAULT_COLOR);
    }
    let column = 0;
    for (const run of frame[row] ?? []) {
      const foreground = run.fg ?? CALM_SHIP_RASTER_DEFAULT_COLOR;
      const background = run.bg ?? CALM_SHIP_RASTER_DEFAULT_COLOR;
      for (const glyph of Array.from(run.text)) {
        put(row, column, glyph.codePointAt(0) ?? 0x20, foreground, background);
        column += 1;
      }
    }
  }
  return { rows, cells: encodeBase64(new Uint8Array(words.buffer)) };
}
