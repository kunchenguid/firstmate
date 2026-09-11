import test from 'node:test';
import assert from 'node:assert/strict';
import { buffer, put, sprite, ticker, clean, plain, diff } from '../src/index.mjs';
test('bounded cells, original sprite rows, wrap guard and sanitized text', () => {
  const grid = buffer(10, 4);
  sprite(grid, 0, 0, [' ▄ ', '███'], 1); put(grid, 0, 2, clean('\x1b[31m injected'), 2);
  put(grid, 9, 3, 'X'); assert.equal(grid[3][9][0], ' ');
  assert.match(plain(grid), /███/); assert.ok(!plain(grid).includes('\x1b'));
  assert.throws(() => buffer(999999, 3)); assert.throws(() => put(grid, 1, 1, 'x', 7));
});
test('diff continuity at 100x30 and 80x24, ticker and NO_COLOR-compatible output', () => {
  for (const [width, height] of [[100, 30], [80, 24]]) {
    let previous;
    for (let tick = 0; tick < 24; tick++) {
      const grid = buffer(width, height); put(grid, tick, 3, '◉', 3);
      const changes = diff(previous, grid);
      assert.ok(!changes.includes('\x1b[2J')); assert.equal(diff(grid, grid), '');
      if (previous) assert.ok(changes.length < 100);
      assert.ok(!/\x1b\[[0-9;]*m/.test(diff(previous, grid, false))); previous = grid;
    }
  }
  assert.equal(ticker(['one', 'two'], 40), 'two'); assert.equal(ticker([], 100), '');
});
