// firstmate-calm under `claude plugin test`: the sailboat riding its simulated sea that
// replaces the stock working row while Calm is on, its cadence on the mocked clock, its
// size against the viewport, its shading family, and how it lets go of a site the
// surface no longer draws.
import { describe, expect, test } from "claude-code/testing";
import {
  CALM_WORKING_SHIP_HULL_LENGTH,
  CALM_WORKING_SHIP_ROWS as ROWS,
  calmWorkingShipBoatColors,
  createCalmWorkingShipSprite,
} from "../lib/fm-calm-working-ship-sprite.ts";
import { packCalmShipRasterCells } from "../lib/fm-calm-ship-raster.ts";
import { calmCommand, decodeCells, isStock, rasterOf, spinner, themeChange, unmeasuredSpinner, world } from "./support.ts";

const RIG_ANY = /^(?:◢│◺|◿│◣)$/;
const DEFAULT = 0x01000000;
const TICK = 16;
// About how long the calm boat takes to cross one column at cruise.
const COLUMN_MS = 1000;

type Decoded = ReturnType<typeof decodeCells>;

/** The frame a fresh sprite paints first in `family`, packed as the mod packs it. */
function freshCells(columns: number, family: "dark" | "light"): string {
  return packCalmShipRasterCells(createCalmWorkingShipSprite().frame(columns, family), columns).cells;
}

/** Every cell holding a color `pick` accepts, as [row, column]. */
function cellsWith(decoded: Decoded, pick: (color: number) => boolean): [number, number][] {
  const found: [number, number][] = [];
  decoded.foregrounds.forEach((row, index) =>
    row.forEach((color, column) => {
      if (pick(color) || pick(decoded.backgrounds[index]![column]!)) found.push([index, column]);
    }),
  );
  return found;
}

/** The hull's drawn middle, in columns, found by its color. */
function hullMiddle(decoded: Decoded, family: "dark" | "light"): number {
  const { hull } = calmWorkingShipBoatColors(family);
  const columns = cellsWith(decoded, (color) => color === hull).map(([, column]) => column);
  expect(columns.length).toBeGreaterThan(0);
  return (Math.min(...columns) + Math.max(...columns) + 1) / 2;
}

describe("the working ship", () => {
  test("replaces the spinner with a five-row raster sized to the row inside the transcript margin", async ($, on) => {
    world(on, { preference: "on\n" });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })));
    expect(raster).toBeDefined();
    expect(raster!.key).toBe("firstmate-calm-working-ship");
    expect(raster!.columns).toBe(38);
    expect(raster!.rows).toBe(ROWS);
    const decoded = decodeCells(raster!.cells, 38, ROWS);
    const { glyphs, foregrounds, backgrounds } = decoded;
    for (const row of glyphs) expect(row).toHaveLength(38);
    // The boat starts at the left edge heading right: its hull spans the first hull
    // length, with the sails above it and nothing of the boat further along.
    const { hull, sails } = calmWorkingShipBoatColors("dark");
    const middle = hullMiddle(decoded, "dark");
    expect(Math.abs(middle - CALM_WORKING_SHIP_HULL_LENGTH / 2)).toBeLessThanOrEqual(1.5);
    const sailCells = cellsWith(decoded, (color) => sails.includes(color));
    expect(sailCells.length).toBeGreaterThan(3);
    for (const [row, column] of sailCells) {
      expect(row).toBeLessThan(ROWS - 1);
      expect(column).toBeLessThan(CALM_WORKING_SHIP_HULL_LENGTH);
    }
    for (const [, column] of cellsWith(decoded, (color) => color === hull)) expect(column).toBeLessThan(CALM_WORKING_SHIP_HULL_LENGTH + 1);
    // The sea is lit per cell and fills the width: the water body has no gaps and many
    // distinct shades, none of them the default.
    expect(foregrounds[ROWS - 1]!.every((color) => color !== DEFAULT)).toBe(true);
    expect(new Set([...foregrounds[ROWS - 2]!, ...foregrounds[ROWS - 1]!, ...backgrounds[ROWS - 1]!]).size).toBeGreaterThan(6);
    for (const row of glyphs) expect(row).toMatch(/^[ ▁▂▃▄▅▆▇█▔▀]+$/);
    // Sky stays the terminal's own colors.
    expect(glyphs[0]!.slice(12)).toBe(" ".repeat(26));
    expect(foregrounds[0]!.slice(12).every((color) => color === DEFAULT)).toBe(true);
    expect(backgrounds[0]!.every((color) => color === DEFAULT)).toBe(true);
  });

  test("animates the sea on every frame and carries the boat along at a calm pace, through blits of the mounted size", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    const first = decodeCells(raster.cells, 38, ROWS);
    await clock.advance(TICK * 10);
    expect(journal.blits).toHaveLength(10);
    expect(journal.blits[0]).toMatchObject({ requestId: "agent-main", key: "firstmate-calm-working-ship", columns: 38, rows: ROWS });
    const later = decodeCells(journal.blits.at(-1)!.cells, 38, ROWS);
    expect(hullMiddle(later, "dark")).toBeLessThanOrEqual(CALM_WORKING_SHIP_HULL_LENGTH / 2 + 1.5);
    expect(later.foregrounds.slice(2)).not.toEqual(first.foregrounds.slice(2));
    await clock.advance(COLUMN_MS * 3);
    const moved = hullMiddle(decodeCells(journal.blits.at(-1)!.cells, 38, ROWS), "dark") - CALM_WORKING_SHIP_HULL_LENGTH / 2;
    expect(moved).toBeGreaterThanOrEqual(1.5);
    expect(moved).toBeLessThanOrEqual(5.5);
  });

  test("stops blitting a site the surface denies and resumes when the spinner is drawn again", async ($, on) => {
    const { clock, journal, denyBlits } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner());
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(1);
    denyBlits("nothing of firstmate-calm is mounted there");
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(2);
    await clock.advance(TICK * 5);
    expect(journal.blits).toHaveLength(2);
    denyBlits(undefined);
    await $.ui.render(spinner());
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(3);
  });

  test("never blits while off, and drops every site when toggled off", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner());
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(1);
    await $.command.run(calmCommand());
    await clock.advance(TICK * 4);
    expect(journal.blits).toHaveLength(1);
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
    await clock.advance(TICK * 4);
    expect(journal.blits).toHaveLength(1);
  });

  test("sizes to the raster limits: an unmeasured viewport reads as 80 columns, a wide one clips at 512, a narrow one falls back to one row", async ($, on) => {
    world(on, { preference: "on\n" });
    expect(rasterOf(await $.ui.render(unmeasuredSpinner("a")))!.columns).toBe(78);
    expect(rasterOf(await $.ui.render(spinner("b", { columns: 900, rows: 40 })))!.columns).toBe(512);
    const narrow = rasterOf(await $.ui.render(spinner("c", { columns: 5, rows: 40 })))!;
    expect(narrow.columns).toBe(3);
    expect(narrow.rows).toBe(1);
    expect(decodeCells(narrow.cells, 3, 1).glyphs[0]).toMatch(RIG_ANY);
    const tiny = rasterOf(await $.ui.render(spinner("d", { columns: 2, rows: 40 })))!;
    expect(tiny.columns).toBe(1);
    expect(tiny.rows).toBe(1);
    expect(decodeCells(tiny.cells, 1, 1).glyphs[0]).toMatch(/^[▁▂▃▄▅▆▇█]$/);
  });

  test("reflows to a new width on the redraw a resize causes, and blits at that width from then on", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner("agent-main", { columns: 80, rows: 24 }));
    await clock.advance(COLUMN_MS * 8);
    expect(hullMiddle(decodeCells(journal.blits.at(-1)!.cells, 78, ROWS), "dark")).toBeGreaterThan(9);
    const shrunk = rasterOf(await $.ui.render(spinner("agent-main", { columns: 12, rows: 24 })))!;
    expect(shrunk.columns).toBe(10);
    // The track clamps to the new right edge: the hull's far end sits at the last column.
    expect(hullMiddle(decodeCells(shrunk.cells, 10, ROWS), "dark")).toBeGreaterThanOrEqual(10 - CALM_WORKING_SHIP_HULL_LENGTH / 2 - 1.5);
    await clock.advance(TICK);
    expect(journal.blits.at(-1)).toMatchObject({ columns: 10, rows: ROWS });
  });

  test("leaves a non-terminal surface to the engine", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    const desktop = { ...spinner(), surface: "desktop" as const };
    expect(isStock(await $.ui.render(desktop as never))).toBe(true);
    await clock.advance(TICK * 4);
    expect(journal.blits).toHaveLength(0);
  });

  test("keeps the boat sailing when a resize redraws the site while a blit is in flight", async ($, on) => {
    const { clock, journal, holdNextBlit } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(1);
    expect(journal.blits[0]!.columns).toBe(38);
    const held = holdNextBlit();
    const pendingTick = clock.advance(TICK);
    // Wait until the ticker's repaint has entered the held blit and stays in flight.
    for (let wait = 0; wait < 50 && journal.blits.length < 2; wait++) await new Promise((r) => setTimeout(r, 0));
    expect(journal.blits).toHaveLength(2);
    expect(journal.blits[1]!.columns).toBe(38);
    const resized = rasterOf(await $.ui.render(spinner("agent-main", { columns: 12, rows: 24 }))!)!;
    expect(resized.columns).toBe(10);
    // The old blit was for the previous width; the surface now denies it because the
    // resize redrew the same requestId with a new Raster.
    held.release("resize denied: old raster no longer mounted");
    await pendingTick;
    // The denied old Raster must not have deleted the live resized site, so the frame
    // clock keeps ticking at the new width.
    expect(journal.blits).toHaveLength(2);
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(3);
    expect(journal.blits[2]).toMatchObject({ requestId: "agent-main", columns: 10, rows: ROWS });
  });

  // Each theme value needs its own world, so the family rule gets one test per value.
  for (const [theme, family] of [
    ["dark", "dark"],
    ["dark-ansi", "dark"],
    ["dark-daltonized", "dark"],
    ["light", "light"],
    ["light-daltonized", "light"],
    ["light-ansi", "light"],
    ["auto", "light"],
    ["custom:rose-pine", "light"],
  ] as const) {
    test(`shades in the ${family} family for the theme value ${JSON.stringify(theme)}`, async ($, on) => {
      world(on, { preference: "on\n", theme });
      const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
      expect(raster.cells).toBe(freshCells(38, family));
    });
  }

  test("re-shades in the new family after the theme changes, through the next drawing and every later blit", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", theme: "dark" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const first = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    expect(first.cells).toBe(freshCells(38, "dark"));
    await clock.advance(TICK);
    const hullOf = (family: "dark" | "light") => calmWorkingShipBoatColors(family).hull;
    const shows = (hull: number) =>
      cellsWith(decodeCells(journal.blits.at(-1)!.cells, 38, ROWS), (color) => color === hull).length > 0;
    expect(shows(hullOf("dark"))).toBe(true);
    const redrawsBefore = journal.invalidations.length;
    const changed = await $.config.set(themeChange("light", "dark"));
    expect(changed.value).toBe("light");
    expect(journal.invalidations.length).toBe(redrawsBefore + 1);
    await clock.advance(TICK);
    expect(shows(hullOf("light"))).toBe(true);
    expect(shows(hullOf("dark"))).toBe(false);
    // A change within the same family redraws nothing.
    const redrawsAfter = journal.invalidations.length;
    await $.config.set(themeChange("light-ansi", "light"));
    expect(journal.invalidations.length).toBe(redrawsAfter);
  });

  test("leaves a theme change to the engine while Calm is off, and shades in the new family once Calm turns on", async ($, on) => {
    const { journal } = world(on, { theme: "dark" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const redrawsBefore = journal.invalidations.length;
    await $.config.set(themeChange("light", "dark"));
    expect(journal.invalidations.length).toBe(redrawsBefore);
    await $.command.run(calmCommand());
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    expect(raster.cells).toBe(freshCells(38, "light"));
  });
});
