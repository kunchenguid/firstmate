// firstmate-calm under `claude plugin test`: the spaceship that replaces the stock
// working row when config/calm-ship selects it - the same shared sprite the Pi banner
// renders, packed as a Raster in Claude Code's own theme colors, cruising on the mocked
// clock, and re-selected on each fresh session.
import { describe, expect, test } from "claude-code/testing";
import { HOME, calmCommand, decodeCells, isStock, rasterOf, spinner, themeChange, unmeasuredSpinner, world } from "./support.ts";

const WARP = "=( * )";
const SAUCER = "(|)";
const HULL = "|^|";
const DEFAULT = 0x01000000;
// Claude Code's own theme tables: the spinner blue of each family for the starfield
// and the Claude orange of the stock spinner for the whole saucer.
const DARK_FIELD = 0x93a5ff;
const LIGHT_FIELD = 0x5769f7;
const SHIP = 0xd77757;
const TICK = 220;
const TICKS_PER_MOVE = 4;

const SHIP_FILE = `${HOME}/config/calm-ship`;

describe("the working spaceship selection", () => {
  test("replaces the spinner with the single-row warp saucer raster when config/calm-ship names spaceship", async ($, on) => {
    const { files } = world(on, { preference: "on\n" });
    files.set(SHIP_FILE, "spaceship\n");
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })));
    expect(raster).toBeDefined();
    expect(raster!.key).toBe("firstmate-calm-working-spaceship");
    expect(raster!.columns).toBe(38);
    expect(raster!.rows).toBe(1);
    const { glyphs, foregrounds, backgrounds } = decodeCells(raster!.cells, 38, 1);
    expect(glyphs[0]).toHaveLength(38);
    // A Spinner drawing exists only while a run is under way, so the first frame is
    // already the compact warp saucer facing right, at the left edge.
    expect(glyphs[0]!.indexOf(WARP)).toBe(0);
    // Colors on the default dark theme: the whole saucer one Claude orange, the streak
    // field the dark spinner blue, default-colored padding, default backgrounds.
    expect(foregrounds[0]!.slice(0, 6)).toEqual([SHIP, SHIP, SHIP, SHIP, SHIP, SHIP]);
    expect(foregrounds[0]!.slice(6).every((color) => color === DARK_FIELD)).toBe(true);
    expect(backgrounds.flat().every((color) => color === DEFAULT)).toBe(true);
    // The warp field streams streaks, not idle stars.
    expect(glyphs[0]!.slice(6)).toMatch(/^[- .]+$/);
    expect(glyphs[0]!.slice(6)).toContain("-");
  });

  test("keeps the two-row boat when the selection is missing or unrecognized", async ($, on) => {
    const { files } = world(on, { preference: "on\n" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    expect(rasterOf(await $.ui.render(spinner("a")))!.key).toBe("firstmate-calm-working-ship");
    files.set(SHIP_FILE, "yacht\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    expect(rasterOf(await $.ui.render(spinner("b")))!.key).toBe("firstmate-calm-working-ship");
  });

  test("cruises the warp saucer on the mocked clock: the streak field moves every tick and the saucer one column every fourth", async ($, on) => {
    const { files, clock, journal } = world(on, { preference: "on\n" });
    files.set(SHIP_FILE, "spaceship\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(1);
    expect(journal.blits[0]).toMatchObject({ requestId: "agent-main", key: "firstmate-calm-working-spaceship", columns: 38, rows: 1 });
    const first = decodeCells(journal.blits[0]!.cells, 38, 1);
    await clock.advance(TICK);
    const afterOne = decodeCells(journal.blits.at(-1)!.cells, 38, 1);
    expect(afterOne.glyphs[0]).not.toBe(first.glyphs[0]);
    expect(afterOne.glyphs[0]!.indexOf(WARP)).toBe(0);
    await clock.advance(TICK * (TICKS_PER_MOVE - 1));
    const afterMove = decodeCells(journal.blits.at(-1)!.cells, 38, 1);
    expect(afterMove.glyphs[0]!.indexOf(WARP)).toBe(1);
  });

  test("re-reads the selection on each fresh session, swapping sprite and raster key", async ($, on) => {
    const { files } = world(on, { preference: "on\n" });
    files.set(SHIP_FILE, "spaceship\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    expect(rasterOf(await $.ui.render(spinner("a")))!.key).toBe("firstmate-calm-working-spaceship");
    files.set(SHIP_FILE, "on\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const boat = rasterOf(await $.ui.render(spinner("b")));
    expect(boat!.key).toBe("firstmate-calm-working-ship");
    expect(boat!.rows).toBe(2);
    expect(decodeCells(boat!.cells, 38, 2).glyphs[1]!.indexOf(HULL)).toBe(0);
  });

  test("sizes to the raster limits: an unmeasured viewport reads as 80 columns, a wide one clips at 512, a narrow one falls back to the bare streak field", async ($, on) => {
    const { files } = world(on, { preference: "on\n" });
    files.set(SHIP_FILE, "spaceship\n");
    expect(rasterOf(await $.ui.render(unmeasuredSpinner("a")))!.columns).toBe(78);
    expect(rasterOf(await $.ui.render(spinner("b", { columns: 900, rows: 40 })))!.columns).toBe(512);
    const narrow = rasterOf(await $.ui.render(spinner("c", { columns: 5, rows: 40 })))!;
    expect(narrow.columns).toBe(3);
    expect(narrow.rows).toBe(1);
    expect(decodeCells(narrow.cells, 3, 1).glyphs[0]).toMatch(/^[ .-]*$/);
    const tiny = rasterOf(await $.ui.render(spinner("d", { columns: 2, rows: 40 })))!;
    expect(tiny.columns).toBe(1);
    expect(tiny.rows).toBe(1);
    expect(decodeCells(tiny.cells, 1, 1).glyphs[0]).toMatch(/^[ .-]$/);
  });

  test("paints the light theme family's spinner blue for the field and the same Claude orange saucer", async ($, on) => {
    const { files } = world(on, { preference: "on\n", theme: "light" });
    files.set(SHIP_FILE, "spaceship\n");
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    const { foregrounds } = decodeCells(raster.cells, 38, 1);
    expect(foregrounds[0]!.slice(0, 6)).toEqual([SHIP, SHIP, SHIP, SHIP, SHIP, SHIP]);
    expect(foregrounds[0]!.slice(6).every((color) => color === LIGHT_FIELD)).toBe(true);
  });

  test("re-paints in the new theme family after the theme changes, through the next blit", async ($, on) => {
    const { files, clock, journal } = world(on, { preference: "on\n", theme: "dark" });
    files.set(SHIP_FILE, "spaceship\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    await clock.advance(TICK);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 1).foregrounds[0]!.at(-1)).toBe(DARK_FIELD);
    const redrawsBefore = journal.invalidations.length;
    const changed = await $.config.set(themeChange("light", "dark"));
    expect(changed.value).toBe("light");
    expect(journal.invalidations.length).toBe(redrawsBefore + 1);
    await clock.advance(TICK);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 1).foregrounds[0]!.at(-1)).toBe(LIGHT_FIELD);
    const redrawsAfter = journal.invalidations.length;
    await $.config.set(themeChange("light-ansi", "light"));
    expect(journal.invalidations.length).toBe(redrawsAfter);
  });

  test("never blits the spaceship while Calm is off, and drops every site when toggled off", async ($, on) => {
    const { files, clock, journal } = world(on, { preference: "on\n" });
    files.set(SHIP_FILE, "spaceship\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    await $.ui.render(spinner());
    await clock.advance(TICK);
    expect(journal.blits).toHaveLength(1);
    await $.command.run(calmCommand());
    await clock.advance(TICK * TICKS_PER_MOVE);
    expect(journal.blits).toHaveLength(1);
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
  });

  test("leaves a non-terminal surface to the engine even with the spaceship selected", async ($, on) => {
    const { files, clock, journal } = world(on, { preference: "on\n" });
    files.set(SHIP_FILE, "spaceship\n");
    const desktop = { ...spinner(), surface: "desktop" as const };
    expect(isStock(await $.ui.render(desktop as never))).toBe(true);
    await clock.advance(TICK * TICKS_PER_MOVE);
    expect(journal.blits).toHaveLength(0);
  });
});