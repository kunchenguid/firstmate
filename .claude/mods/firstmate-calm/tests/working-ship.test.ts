// firstmate-calm under `claude plugin test`: the sailboat on its simulated sea that
// replaces the stock working row while Calm is on, its cadence on the mocked clock, its
// size against the viewport, its shading family, and how it lets go of a site the
// surface no longer draws.
import { describe, expect, test } from "claude-code/testing";
import { createCalmWorkingShipSprite } from "../lib/fm-calm-working-ship-sprite.ts";
import { packCalmShipRasterCells } from "../lib/fm-calm-ship-raster.ts";
import { calmCommand, decodeCells, isStock, rasterOf, spinner, themeChange, unmeasuredSpinner, world } from "./support.ts";

const HULL_LEFT = "◥";
const HULL_RIGHT = "◤";
const RIG_RIGHT = /^[◢][│╲╱][◺]$/;
const RIG_ANY = /^(?:◢[│╲╱]◺|◿[│╲╱]◣)$/;
const BARS = /^[▁▂▃▄▅▆▇█]+$/;
const DEFAULT = 0x01000000;
const TICK = 16;
// About how long the calm boat takes to cross one column at cruise.
const COLUMN_MS = 1000;

/** The frame a fresh sprite paints first in `family`, packed as the mod packs it. */
function freshCells(columns: number, family: "dark" | "light"): string {
  return packCalmShipRasterCells(createCalmWorkingShipSprite().frame(columns, family), columns).cells;
}

describe("the working ship", () => {
  test("replaces the spinner with a three-row raster sized to the row inside the transcript margin", async ($, on) => {
    world(on, { preference: "on\n" });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })));
    expect(raster).toBeDefined();
    expect(raster!.key).toBe("firstmate-calm-working-ship");
    expect(raster!.columns).toBe(38);
    expect(raster!.rows).toBe(3);
    const { glyphs, foregrounds, backgrounds } = decodeCells(raster!.cells, 38, 3);
    for (const row of glyphs) expect(row).toHaveLength(38);
    // The boat starts at the left edge heading right: raked hull ends at columns 0 and
    // 4 with the waterline cells between them, and the rig centered one column in.
    expect(glyphs[1]![0]).toBe(HULL_LEFT);
    expect(glyphs[1]![4]).toBe(HULL_RIGHT);
    expect(glyphs[0]!.slice(1, 4)).toMatch(RIG_RIGHT);
    expect(glyphs[0]!.slice(4)).toBe(" ".repeat(34));
    expect(glyphs[1]!.slice(1, 4) + glyphs[1]!.slice(5)).toMatch(BARS);
    expect(glyphs[2]).toBe("█".repeat(38));
    // The sea is lit per cell: many distinct water colors, none of them the default.
    const water = foregrounds[1]!.slice(5);
    expect(water.every((color) => color !== DEFAULT)).toBe(true);
    expect(new Set([...water, ...foregrounds[2]!]).size).toBeGreaterThan(6);
    // The hull's waterline cells draw the water in front of a hull-colored side.
    const hull = foregrounds[1]![0];
    expect(foregrounds[1]![4]).toBe(hull);
    expect(backgrounds[1]!.slice(1, 4)).toEqual([hull, hull, hull]);
    // Padding and sky stay the terminal's own colors.
    expect(foregrounds[0]![0]).toBe(DEFAULT);
    expect(foregrounds[0]!.slice(4).every((color) => color === DEFAULT)).toBe(true);
    expect(backgrounds[0]!.every((color) => color === DEFAULT)).toBe(true);
    expect(backgrounds[2]!.every((color) => color === DEFAULT)).toBe(true);
  });

  test("animates the sea on every frame and carries the boat along at a calm pace, through blits of the mounted size", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    const first = decodeCells(raster.cells, 38, 3);
    await clock.advance(TICK * 10);
    expect(journal.blits).toHaveLength(10);
    expect(journal.blits[0]).toMatchObject({ requestId: "agent-main", key: "firstmate-calm-working-ship", columns: 38, rows: 3 });
    const later = decodeCells(journal.blits.at(-1)!.cells, 38, 3);
    expect(later.glyphs[1]!.indexOf(HULL_LEFT)).toBe(0);
    expect(later.foregrounds[1]).not.toEqual(first.foregrounds[1]);
    await clock.advance(COLUMN_MS * 3);
    const moved = decodeCells(journal.blits.at(-1)!.cells, 38, 3);
    const column = moved.glyphs[1]!.indexOf(HULL_LEFT);
    expect(column).toBeGreaterThanOrEqual(2);
    expect(column).toBeLessThanOrEqual(5);
    expect(moved.glyphs[0]!.slice(column + 1, column + 4)).toMatch(RIG_ANY);
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
    const wide = decodeCells(journal.blits.at(-1)!.cells, 78, 3);
    expect(wide.glyphs[1]!.indexOf(HULL_LEFT)).toBeGreaterThan(5);
    const shrunk = rasterOf(await $.ui.render(spinner("agent-main", { columns: 12, rows: 24 })))!;
    expect(shrunk.columns).toBe(10);
    expect(decodeCells(shrunk.cells, 10, 3).glyphs[1]!.indexOf(HULL_LEFT)).toBe(5);
    await clock.advance(TICK);
    expect(journal.blits.at(-1)).toMatchObject({ columns: 10, rows: 3 });
  });

  test("leaves a non-terminal surface to the engine", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    const desktop = { ...spinner(), surface: "desktop" as const };
    expect(isStock(await $.ui.render(desktop as never))).toBe(true);
    await clock.advance(TICK * 4);
    expect(journal.blits).toHaveLength(0);
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
    const darkHull = decodeCells(journal.blits.at(-1)!.cells, 38, 3).foregrounds[1]![0];
    const redrawsBefore = journal.invalidations.length;
    const changed = await $.config.set(themeChange("light", "dark"));
    expect(changed.value).toBe("light");
    expect(journal.invalidations.length).toBe(redrawsBefore + 1);
    await clock.advance(TICK);
    const lightHull = decodeCells(journal.blits.at(-1)!.cells, 38, 3).foregrounds[1]![0];
    expect(lightHull).not.toBe(darkHull);
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
