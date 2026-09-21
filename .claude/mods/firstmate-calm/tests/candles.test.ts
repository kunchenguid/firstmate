// firstmate-calm under `claude plugin test`: the candles scene a home picks through its
// config/calm-scene setting, drawn in the working row in place of the sailboat, and
// the boat it falls back to for every other value.
import { describe, expect, test } from "claude-code/testing";
import { HOME, PREFERENCE, calmCommand, decodeCells, isStock, rasterOf, spinner, themeChange, world } from "./support.ts";

const SCENE = `${HOME}/config/calm-scene`;
const HULL = "╲▁▁▁╱";
const CANDLE_ROW = /^[ ╷╻╵│╽╹╿┃]+$/;
const DEFAULT = 0x01000000;
// Claude Code's success green and error red per theme family, fixed to xterm-256 cube
// entries so truecolor and 256-color terminals paint the same hue.
const DARK = { rise: 0x5faf5f, fall: 0xff5f87 };
const LIGHT = { rise: 0x00875f, fall: 0xaf005f };
const TICK = 220;
const TICKS_PER_MOVE = 4;

/** Every glyph cell of a decoded candle frame is a rise or fall color, every blank the default. */
function colorsAreCandles(glyphs: string[], foregrounds: number[][], family: { rise: number; fall: number }): boolean {
  return glyphs.every((row, index) =>
    Array.from(row).every((glyph, column) => {
      const color = foregrounds[index]![column];
      return glyph === " " ? color === DEFAULT : color === family.rise || color === family.fall;
    }),
  );
}

describe("the candles scene", () => {
  test("replaces the spinner with two rows of green and red candles when the setting says candles", async ($, on) => {
    const { files } = world(on, { preference: "on\n" });
    files.set(SCENE, "candles\n");
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!;
    expect(raster.key).toBe("firstmate-calm-working-ship");
    expect(raster.columns).toBe(38);
    expect(raster.rows).toBe(2);
    const { glyphs, foregrounds, backgrounds } = decodeCells(raster.cells, 38, 2);
    expect(glyphs[0]).toMatch(CANDLE_ROW);
    expect(glyphs[1]).toMatch(CANDLE_ROW);
    expect(glyphs.join("")).not.toContain(HULL);
    // Candles sit in every other column, starting at the left edge.
    expect(glyphs[0]![0] !== " " || glyphs[1]![0] !== " ").toBe(true);
    expect(glyphs[0]![1]).toBe(" ");
    expect(glyphs[1]![1]).toBe(" ");
    expect(colorsAreCandles(glyphs, foregrounds, DARK)).toBe(true);
    const painted = new Set(foregrounds.flat().filter((color) => color !== DEFAULT));
    expect(painted.has(DARK.rise)).toBe(true);
    expect(painted.has(DARK.fall)).toBe(true);
    expect(backgrounds.flat().every((color) => color === DEFAULT)).toBe(true);
  });

  test("scrolls one column left every fourth tick through blits of the mounted size", async ($, on) => {
    const { clock, journal, files } = world(on, { preference: "on\n" });
    files.set(SCENE, "candles\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const first = decodeCells(rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!.cells, 38, 2);
    await clock.advance(TICK * (TICKS_PER_MOVE - 1));
    expect(journal.blits).toHaveLength(TICKS_PER_MOVE - 1);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 2).glyphs).toEqual(first.glyphs);
    await clock.advance(TICK);
    expect(journal.blits.at(-1)).toMatchObject({ requestId: "agent-main", columns: 38, rows: 2 });
    const moved = decodeCells(journal.blits.at(-1)!.cells, 38, 2);
    for (const row of [0, 1]) expect(moved.glyphs[row]!.slice(0, 37)).toBe(first.glyphs[row]!.slice(1));
  });

  test("keeps two rows on a viewport down to one column wide and reflows to a new width without wrapping", async ($, on) => {
    const { files } = world(on, { preference: "on\n" });
    files.set(SCENE, "candles\n");
    for (const columns of [1, 2, 3, 4]) {
      const narrow = rasterOf(await $.ui.render(spinner("a", { columns: columns + 2, rows: 24 })))!;
      expect(narrow.columns).toBe(columns);
      expect(narrow.rows).toBe(2);
      for (const row of decodeCells(narrow.cells, columns, 2).glyphs) {
        expect(row).toHaveLength(columns);
        expect(row).toMatch(CANDLE_ROW);
      }
    }
    const wide = rasterOf(await $.ui.render(spinner("a", { columns: 80, rows: 24 })))!;
    expect(wide.columns).toBe(78);
    const decoded = decodeCells(wide.cells, 78, 2);
    expect(decoded.glyphs[0]).toHaveLength(78);
    expect(decoded.glyphs[1]).toMatch(CANDLE_ROW);
  });

  test("paints the light theme family's green and red, and follows a theme change", async ($, on) => {
    const { clock, journal, files } = world(on, { preference: "on\n", theme: "light" });
    files.set(SCENE, "candles\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    const light = decodeCells(rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!.cells, 38, 2);
    expect(colorsAreCandles(light.glyphs, light.foregrounds, LIGHT)).toBe(true);
    await $.config.set(themeChange("dark", "light"));
    await clock.advance(TICK);
    const dark = decodeCells(journal.blits.at(-1)!.cells, 38, 2);
    expect(colorsAreCandles(dark.glyphs, dark.foregrounds, DARK)).toBe(true);
  });

  for (const [label, stored] of [
    ["an unknown value", "fish\n"],
    ["an empty file", ""],
    ["a differently cased value", "Candles\n"],
    ["the explicit boat", "boat\n"],
  ] as const) {
    test(`draws the boat for ${label}`, async ($, on) => {
      const { files } = world(on, { preference: "on\n" });
      files.set(SCENE, stored);
      const { glyphs } = decodeCells(rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!.cells, 38, 2);
      expect(glyphs[1]!.indexOf(HULL)).toBe(0);
    });
  }

  test("draws the boat when the setting is absent, without a failed read of the missing file", async ($, on) => {
    const { journal } = world(on, { preference: "on\n" });
    const { glyphs } = decodeCells(rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!.cells, 38, 2);
    expect(glyphs[1]!.indexOf(HULL)).toBe(0);
    expect(journal.fsReads).toEqual([PREFERENCE]);
  });

  test("reads the setting with the preference once per session and re-reads it on a new session", async ($, on) => {
    const { files, journal } = world(on, { preference: "on\n" });
    files.set(SCENE, "candles\n");
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    expect(journal.fsReads).toEqual([PREFERENCE, SCENE]);
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    expect(journal.fsReads).toEqual([PREFERENCE, SCENE]);
    // A change lands at the next session, not mid-session.
    files.set(SCENE, "boat\n");
    const still = decodeCells(rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!.cells, 38, 2);
    expect(still.glyphs[1]).toMatch(CANDLE_ROW);
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    expect(journal.fsReads).toEqual([PREFERENCE, SCENE, PREFERENCE, SCENE]);
    const boat = decodeCells(rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!.cells, 38, 2);
    expect(boat.glyphs[1]!.indexOf(HULL)).toBe(0);
  });

  test("leaves the working row to the engine while Calm is off and draws the chosen candles once /calm turns it on", async ($, on) => {
    const { files, journal, clock } = world(on, { preference: "off\n" });
    files.set(SCENE, "candles\n");
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
    await clock.advance(TICK * 4);
    expect(journal.blits).toHaveLength(0);
    expect(journal.fsReads).toEqual([PREFERENCE, SCENE]);
    await $.command.run(calmCommand());
    const { glyphs } = decodeCells(rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })))!.cells, 38, 2);
    expect(glyphs[0]).toMatch(CANDLE_ROW);
  });

  test("is fully inert with the candles setting when the function-hooks opt-in is absent", async ($, on) => {
    const { files, journal } = world(on, { preference: "on\n", functionHooks: undefined });
    files.set(SCENE, "candles\n");
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
    expect(journal.fsReads).toHaveLength(0);
    expect(journal.blits).toHaveLength(0);
  });
});
