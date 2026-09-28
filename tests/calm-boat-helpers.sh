#!/usr/bin/env bash
# tests/calm-boat-helpers.sh - locate the Calm working ship in a colored terminal
# capture, for the live Pi and Claude Code Calm suites. The boat is drawn entirely in
# shaded block glyphs, so no plain-text glyph marks it; this reads the capture's color
# escapes (`tmux capture-pane -p -e`) instead and finds the hull by its red and the
# sails by their light neutral or warm tone, which holds at 24-bit color and after either harness
# or tmux maps the shared palette to the xterm 256 colors.

# Print "<left> <right> <top> <bottom> <width> <sails>" for the boat in the colored
# capture file $1: the hull's first and last 1-based columns, the 1-based lines of the
# scene's top (the highest hull or sail cell) and of the water body's last row, that
# row's width in cells, and how many sail cells show. Print nothing when no hull shows.
calm_boat_scan() {  # <colored capture file>
  node --input-type=module - "$1" <<'JS'
import { readFileSync } from "node:fs";
const BLOCKS = " ▁▂▃▄▅▆▇█▔▀";
const BASIC = [[0,0,0],[205,0,0],[0,205,0],[205,205,0],[0,0,238],[205,0,205],[0,205,205],[229,229,229],
  [127,127,127],[255,0,0],[0,255,0],[255,255,0],[92,92,255],[255,0,255],[0,255,255],[255,255,255]];
const CUBE = [0, 95, 135, 175, 215, 255];
const xterm = (n) => n < 16 ? BASIC[n]
  : n < 232 ? [CUBE[Math.floor((n - 16) / 36)], CUBE[Math.floor((n - 16) / 6) % 6], CUBE[(n - 16) % 6]]
  : [8 + (n - 232) * 10, 8 + (n - 232) * 10, 8 + (n - 232) * 10];
const rows = readFileSync(process.argv[2], "utf8").split("\n").map((line) => {
  const cells = [];
  let fg = null, bg = null;
  const text = line.replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, "");
  for (const token of text.matchAll(/\u001b\[([0-9;:]*)m|\u001b\[[0-9;?]*[A-Za-z]|([^\u001b])/gu)) {
    if (token[2] !== undefined) { cells.push({ glyph: token[2], fg, bg }); continue; }
    if (token[1] === undefined) continue;
    const params = token[1].split(/[;:]/).map(Number);
    for (let index = 0; index < params.length; index += 1) {
      const code = params[index];
      if (code === 0) { fg = null; bg = null; }
      else if (code === 38 || code === 48) {
        let color = null;
        if (params[index + 1] === 2) { color = params.slice(index + 2, index + 5); index += 4; }
        else if (params[index + 1] === 5) { color = xterm(params[index + 2]); index += 2; }
        if (code === 38) fg = color; else bg = color;
      }
      else if (code === 39) fg = null;
      else if (code === 49) bg = null;
      else if (code >= 30 && code <= 37) fg = BASIC[code - 30];
      else if (code >= 90 && code <= 97) fg = BASIC[code - 82];
      else if (code >= 40 && code <= 47) bg = BASIC[code - 40];
      else if (code >= 100 && code <= 107) bg = BASIC[code - 92];
    }
  }
  return cells;
});
const block = (cell) => BLOCKS.includes(cell.glyph);
const colors = (cell) => [cell.glyph === " " ? null : cell.fg, cell.bg].filter(Boolean);
const hullish = ([r, g, b]) => r >= 100 && r > 1.8 * g && r > 1.8 * b;
const sailish = ([r, g, b]) => r >= 95 && g >= 90 && r >= b - 5 && Math.abs(r - g) < 45 && !hullish([r, g, b]);
const waterish = (cell) => cell.glyph !== " " && block(cell) && cell.fg !== null && cell.fg[2] > cell.fg[0] + 30;
const hull = [];
rows.forEach((cells, row) => cells.forEach((cell, column) => {
  if (block(cell) && colors(cell).some(hullish)) hull.push([row, column]);
}));
if (hull.length === 0) process.exit(0);
const left = Math.min(...hull.map(([, column]) => column));
const right = Math.max(...hull.map(([, column]) => column));
const hullTop = Math.min(...hull.map(([row]) => row));
const hullBottom = Math.max(...hull.map(([row]) => row));
let top = hullTop, sails = 0;
for (let row = Math.max(0, hullTop - 3); row < hullBottom; row += 1) {
  rows[row].forEach((cell, column) => {
    if (column < left || column > right || !block(cell) || !colors(cell).some(sailish)) return;
    sails += 1;
    top = Math.min(top, row);
  });
}
let bottom = hullBottom;
while (bottom + 1 < rows.length) {
  const cells = rows[bottom + 1];
  if (cells.length === 0 || cells.filter(waterish).length < cells.length * 0.6) break;
  bottom += 1;
}
console.log(`${left + 1} ${right + 1} ${top + 1} ${bottom + 1} ${rows[bottom].length} ${sails}`);
JS
}
