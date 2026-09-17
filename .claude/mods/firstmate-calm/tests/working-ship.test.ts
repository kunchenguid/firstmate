// firstmate-calm under `claude plugin test`: the sailboat that replaces the stock
// working row while Calm is on, its cadence on the mocked clock, its size against the
// viewport, and how it lets go of a site the surface no longer draws.
import { describe, expect, test } from "claude-code/testing";
import { parseCalmWorkingShipOverride } from "../lib/fm-calm-working-ship-sprite.ts";
import { calmCommand, decodeCells, isStock, rasterOf, spinner, themeChange, unmeasuredSpinner, WORKING_BOAT, world } from "./support.ts";

const SAIL = "◿│◣";
const HULL = "╲▁▁▁╱";
const DEFAULT = 0x01000000;
// Claude Code's own theme tables: the spinner blue of each family for the water and
// the Claude orange of the stock spinner for the boat.
const DARK_WATER = 0x93a5ff;
const LIGHT_WATER = 0x5769f7;
const BOAT = 0xd77757;
const TICK = 220;
const TICKS_PER_MOVE = 4;
const CAPTAIN_BOAT = JSON.stringify({
  version: 1,
  mode: "stationary",
  tickMs: 440,
  hull: "\\__/",
  sails: ["◁|", "◀|", "◂|"],
  sailOffset: 1,
  wave: ["~", "~", "-", "~"],
});

describe("the working ship", () => {
  test("uses a valid home-local stationary boat definition", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", workingBoat: CAPTAIN_BOAT });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    const { glyphs } = decodeCells(raster.cells, 38, 2);
    expect(glyphs[0]).toHaveLength(38);
    expect(glyphs[0]!.indexOf("◁|")).toBe(18);
    expect(glyphs[1]!.indexOf("\\__/")).toBe(17);
    await clock.advance(439);
    expect(journal.blits).toHaveLength(0);
    await clock.advance(1);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 2).glyphs[0]).toContain("◀|");
  });

  test("falls back to stock when the local boat file is absent", async ($, on) => {
    const absent = world(on, { preference: "on\n" });
    const absentRaster = rasterOf(await $.ui.render(spinner("agent-absent", { columns: 40, rows: 24 })))!;
    expect(absent.journal.fsReads).toContain(WORKING_BOAT);
    expect(decodeCells(absentRaster.cells, 38, 2).glyphs[1]).toContain(HULL);
  });

  test("falls back to stock when the local boat file is malformed", async ($, on) => {
    const malformed = world(on, { preference: "on\n", workingBoat: "{" });
    const malformedRaster = rasterOf(await $.ui.render(spinner("agent-malformed", { columns: 40, rows: 24 })))!;
    expect(malformed.journal.fsReads).toContain(WORKING_BOAT);
    expect(decodeCells(malformedRaster.cells, 38, 2).glyphs[1]).toContain(HULL);
  });

  test("rejects override text that is not one terminal cell per code point", () => {
    const base = { version: 1, mode: "stationary", tickMs: 440, hull: "____", sails: ["a"], sailOffset: 1, wave: ["~"] };
    expect(parseCalmWorkingShipOverride(JSON.stringify({ ...base, hull: "界" })).override).toBeUndefined();
    expect(parseCalmWorkingShipOverride(JSON.stringify({ ...base, sails: ["a\u0301"] })).override).toBeUndefined();
  });

  test("replaces the spinner with a two-row raster sized to the row inside the transcript margin", async ($, on) => {
    world(on, { preference: "on\n" });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })));
    expect(raster).toBeDefined();
    expect(raster!.key).toBe("firstmate-calm-working-ship");
    expect(raster!.columns).toBe(38);
    expect(raster!.rows).toBe(2);
    const { glyphs, foregrounds, backgrounds } = decodeCells(raster!.cells, 38, 2);
    expect(glyphs[0]).toHaveLength(38);
    expect(glyphs[1]).toHaveLength(38);
    // The boat starts at the left edge: hull at column 0, sail centered one column in.
    expect(glyphs[1]!.indexOf(HULL)).toBe(0);
    expect(glyphs[0]!.indexOf(SAIL)).toBe(1);
    expect(glyphs[0]!.slice(4)).toBe(" ".repeat(34));
    expect(glyphs[1]!.replace(HULL, "▁▁▁▁▁")).toMatch(/^[▁▂▃▄]+$/);
    // Colors on the default dark theme: the whole boat one Claude orange (both sail halves,
    // mast, and the complete hull including its interior), every water cell the dark
    // spinner blue whatever its height, default-colored padding, default backgrounds.
    expect(foregrounds[1]!.slice(0, 5)).toEqual([BOAT, BOAT, BOAT, BOAT, BOAT]);
    expect(foregrounds[0]!.slice(1, 4)).toEqual([BOAT, BOAT, BOAT]);
    expect(foregrounds[0]![0]).toBe(DEFAULT);
    expect(foregrounds[0]!.slice(4).every((color) => color === DEFAULT)).toBe(true);
    expect(foregrounds[1]!.slice(5).every((color) => color === DARK_WATER)).toBe(true);
    expect(glyphs[1]!.slice(5)).toMatch(/[▃▄]/);
    expect(backgrounds.flat().every((color) => color === DEFAULT)).toBe(true);
  });

  test("animates the water every tick and moves the hull one column every fourth, through blits of the mounted size", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    const first = decodeCells(raster.cells, 38, 2);
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(1);
    expect(journal.blits[0]).toMatchObject({ requestId: "agent-main", key: "firstmate-calm-working-ship", columns: 38, rows: 2 });
    const afterOne = decodeCells(journal.blits[0]!.cells, 38, 2);
    expect(afterOne.glyphs[1]!.indexOf(HULL)).toBe(0);
    expect(afterOne.glyphs[1]).not.toBe(first.glyphs[1]);
    await clock.advance(TICK * (TICKS_PER_MOVE - 1));
    expect(journal.blits).toHaveLength(TICKS_PER_MOVE);
    const afterMove = decodeCells(journal.blits[TICKS_PER_MOVE - 1]!.cells, 38, 2);
    expect(afterMove.glyphs[1]!.indexOf(HULL)).toBe(1);
    expect(afterMove.glyphs[0]!.indexOf(SAIL)).toBe(2);
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
    expect(decodeCells(narrow.cells, 3, 1).glyphs[0]).toBe(SAIL);
    const tiny = rasterOf(await $.ui.render(spinner("d", { columns: 2, rows: 40 })))!;
    expect(tiny.columns).toBe(1);
    expect(tiny.rows).toBe(1);
    expect(decodeCells(tiny.cells, 1, 1).glyphs[0]).toMatch(/^[▁▂▃▄]$/);
  });

  test("reflows to a new width on the redraw a resize causes, and blits at that width from then on", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner("agent-main", { columns: 80, rows: 24 }));
    await clock.advance(TICK * TICKS_PER_MOVE * 6);
    const wide = decodeCells(journal.blits.at(-1)!.cells, 78, 2);
    expect(wide.glyphs[1]!.indexOf(HULL)).toBe(6);
    const shrunk = rasterOf(await $.ui.render(spinner("agent-main", { columns: 12, rows: 24 })))!;
    expect(shrunk.columns).toBe(10);
    expect(decodeCells(shrunk.cells, 10, 2).glyphs[1]!.indexOf(HULL)).toBe(5);
    await clock.advance(TICK);
    expect(journal.blits.at(-1)).toMatchObject({ columns: 10, rows: 2 });
  });

  test("leaves a non-terminal surface to the engine", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    const desktop = { ...spinner(), surface: "desktop" as const };
    expect(isStock(await $.ui.render(desktop as never))).toBe(true);
    await clock.advance(TICK * 4);
    expect(journal.blits).toHaveLength(0);
  });

  test("paints the light theme family's spinner blue for the water and the same Claude orange boat", async ($, on) => {
    world(on, { preference: "on\n", theme: "light" });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    const { foregrounds } = decodeCells(raster.cells, 38, 2);
    expect(foregrounds[1]!.slice(0, 5)).toEqual([BOAT, BOAT, BOAT, BOAT, BOAT]);
    expect(foregrounds[1]!.slice(5).every((color) => color === LIGHT_WATER)).toBe(true);
  });

  // Each theme value needs its own world, so the family rule gets one test per value.
  for (const [theme, expected, family] of [
    ["dark-ansi", DARK_WATER, "dark"],
    ["dark-daltonized", DARK_WATER, "dark"],
    ["light", LIGHT_WATER, "light"],
    ["light-daltonized", LIGHT_WATER, "light"],
    ["light-ansi", LIGHT_WATER, "light"],
    ["auto", LIGHT_WATER, "light"],
    ["custom:rose-pine", LIGHT_WATER, "light"],
  ] as const) {
    test(`paints the ${family} family for the theme value ${JSON.stringify(theme)}`, async ($, on) => {
      world(on, { preference: "on\n", theme });
      const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
      const { foregrounds } = decodeCells(raster.cells, 38, 2);
      expect(foregrounds[1]!.slice(5).every((color) => color === expected)).toBe(true);
      expect(foregrounds[1]![0]).toBe(BOAT);
    });
  }

  test("re-paints in the new family after the theme changes, through the next drawing and every later blit", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", theme: "dark" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    await clock.advance(TICK);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 2).foregrounds[1]!.at(-1)).toBe(DARK_WATER);
    const redrawsBefore = journal.invalidations.length;
    const changed = await $.config.set(themeChange("light", "dark"));
    expect(changed.value).toBe("light");
    expect(journal.invalidations.length).toBe(redrawsBefore + 1);
    await clock.advance(TICK);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 2).foregrounds[1]!.at(-1)).toBe(LIGHT_WATER);
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    expect(decodeCells(raster.cells, 38, 2).foregrounds[1]!.at(-1)).toBe(LIGHT_WATER);
    // A change within the same family redraws nothing.
    const redrawsAfter = journal.invalidations.length;
    await $.config.set(themeChange("light-ansi", "light"));
    expect(journal.invalidations.length).toBe(redrawsAfter);
  });

  test("leaves a theme change to the engine while Calm is off, and paints the new family once Calm turns on", async ($, on) => {
    const { journal } = world(on, { theme: "dark" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const redrawsBefore = journal.invalidations.length;
    await $.config.set(themeChange("light", "dark"));
    expect(journal.invalidations.length).toBe(redrawsBefore);
    await $.command.run(calmCommand());
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    expect(decodeCells(raster.cells, 38, 2).foregrounds[1]!.at(-1)).toBe(LIGHT_WATER);
  });
});
