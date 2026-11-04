// firstmate-calm under `claude plugin test`: the neutral indicator that replaces the stock
// working row while Calm is on, its cadence on the mocked clock, its size against the
// viewport, and how it lets go of a site the surface no longer draws.
import { describe, expect, test } from "claude-code/testing";
import { boxOf, calmCommand, decodeCells, isStock, rasterOf, spinner, themeChange, unmeasuredSpinner, world } from "./support.ts";

const MARKERS = ["●", "◉", "○", "◉"];
const DEFAULT = 0x01000000;
// Claude Code's own theme tables: spinner-blue track and Claude-orange marker.
const DARK_TRACK = 0x93a5ff;
const LIGHT_TRACK = 0x5769f7;
const INDICATOR = 0xd77757;
const TICK = 220;
const TICKS_PER_MOVE = 4;

describe("the activity indicator", () => {
  test("replaces the spinner with a one-row raster sized inside the transcript margin", async ($, on) => {
    world(on, { preference: "on\n" });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })));
    expect(raster).toBeDefined();
    expect(raster!.key).toBe("firstmate-calm-working-ship");
    expect(raster!.columns).toBe(38);
    expect(raster!.rows).toBe(1);
    const { glyphs, foregrounds, backgrounds } = decodeCells(raster!.cells, 38, 1);
    expect(glyphs[0]).toHaveLength(38);
    expect(glyphs[0]).toBe("●" + "·".repeat(37));
    expect(foregrounds[0]![0]).toBe(INDICATOR);
    expect(foregrounds[0]!.slice(1).every((color) => color === DARK_TRACK)).toBe(true);
    expect(backgrounds.flat().every((color) => color === DEFAULT)).toBe(true);
  });

  test("adds no presentation-only blank row above the indicator", async ($, on) => {
    world(on, { preference: "on\n" });
    const drawing = await $.ui.render(spinner());
    const wrapper = boxOf(drawing);
    expect(wrapper?.props?.paddingTop).toBe(0);
    expect(rasterOf(wrapper)).toBeDefined();
  });

  test("pulses every tick and moves the marker every fourth through mounted-size blits", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    const first = decodeCells(raster.cells, 38, 1);
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(1);
    expect(journal.blits[0]).toMatchObject({ requestId: "agent-main", key: "firstmate-calm-working-ship", columns: 38, rows: 1 });
    const afterOne = decodeCells(journal.blits[0]!.cells, 38, 1);
    expect(afterOne.glyphs[0]!.indexOf(MARKERS[1]!)).toBe(0);
    expect(afterOne.glyphs[0]).not.toBe(first.glyphs[0]);
    await clock.advance(TICK * (TICKS_PER_MOVE - 1));
    expect(journal.blits).toHaveLength(TICKS_PER_MOVE);
    const afterMove = decodeCells(journal.blits[TICKS_PER_MOVE - 1]!.cells, 38, 1);
    expect(afterMove.glyphs[0]!.indexOf(MARKERS[0]!)).toBe(1);
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

  test("sizes to raster limits and keeps the indicator valid at narrow widths", async ($, on) => {
    world(on, { preference: "on\n" });
    expect(rasterOf(await $.ui.render(unmeasuredSpinner("a")))!.columns).toBe(78);
    expect(rasterOf(await $.ui.render(spinner("b", { columns: 900, rows: 40 })))!.columns).toBe(512);
    const narrow = rasterOf(await $.ui.render(spinner("c", { columns: 5, rows: 40 })))!;
    expect(narrow.columns).toBe(3);
    expect(narrow.rows).toBe(1);
    expect(decodeCells(narrow.cells, 3, 1).glyphs[0]).toBe("●··");
    const tiny = rasterOf(await $.ui.render(spinner("d", { columns: 2, rows: 40 })))!;
    expect(tiny.columns).toBe(1);
    expect(tiny.rows).toBe(1);
    expect(decodeCells(tiny.cells, 1, 1).glyphs[0]).toBe("●");
  });

  test("reflows to a new width on the redraw a resize causes, and blits at that width from then on", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner("agent-main", { columns: 80, rows: 24 }));
    await clock.advance(TICK * TICKS_PER_MOVE * 6);
    const wide = decodeCells(journal.blits.at(-1)!.cells, 78, 1);
    expect(wide.glyphs[0]!.indexOf("●")).toBe(6);
    const shrunk = rasterOf(await $.ui.render(spinner("agent-main", { columns: 12, rows: 24 })))!;
    expect(shrunk.columns).toBe(10);
    expect(decodeCells(shrunk.cells, 10, 1).glyphs[0]!.indexOf("●")).toBe(6);
    await clock.advance(TICK);
    expect(journal.blits.at(-1)).toMatchObject({ columns: 10, rows: 1 });
  });

  test("leaves a non-terminal surface to the engine", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n" });
    const desktop = { ...spinner(), surface: "desktop" as const };
    expect(isStock(await $.ui.render(desktop as never))).toBe(true);
    await clock.advance(TICK * 4);
    expect(journal.blits).toHaveLength(0);
  });

  test("paints the light theme track blue and the marker Claude orange", async ($, on) => {
    world(on, { preference: "on\n", theme: "light" });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    const { foregrounds } = decodeCells(raster.cells, 38, 1);
    expect(foregrounds[0]![0]).toBe(INDICATOR);
    expect(foregrounds[0]!.slice(1).every((color) => color === LIGHT_TRACK)).toBe(true);
  });

  // Each theme value needs its own world, so the family rule gets one test per value.
  for (const [theme, expected, family] of [
    ["dark-ansi", DARK_TRACK, "dark"],
    ["dark-daltonized", DARK_TRACK, "dark"],
    ["light", LIGHT_TRACK, "light"],
    ["light-daltonized", LIGHT_TRACK, "light"],
    ["light-ansi", LIGHT_TRACK, "light"],
    ["auto", LIGHT_TRACK, "light"],
    ["custom:rose-pine", LIGHT_TRACK, "light"],
  ] as const) {
    test(`paints the ${family} family for the theme value ${JSON.stringify(theme)}`, async ($, on) => {
      world(on, { preference: "on\n", theme });
      const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
      const { foregrounds } = decodeCells(raster.cells, 38, 1);
      expect(foregrounds[0]!.slice(1).every((color) => color === expected)).toBe(true);
      expect(foregrounds[0]![0]).toBe(INDICATOR);
    });
  }

  test("re-paints in the new family after the theme changes, through the next drawing and every later blit", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", theme: "dark" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    await clock.advance(TICK);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 1).foregrounds[0]!.at(-1)).toBe(DARK_TRACK);
    const redrawsBefore = journal.invalidations.length;
    const changed = await $.config.set(themeChange("light", "dark"));
    expect(changed.value).toBe("light");
    expect(journal.invalidations.length).toBe(redrawsBefore + 1);
    await clock.advance(TICK);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 1).foregrounds[0]!.at(-1)).toBe(LIGHT_TRACK);
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    expect(decodeCells(raster.cells, 38, 1).foregrounds[0]!.at(-1)).toBe(LIGHT_TRACK);
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
    expect(decodeCells(raster.cells, 38, 1).foregrounds[0]!.at(-1)).toBe(LIGHT_TRACK);
  });
});
