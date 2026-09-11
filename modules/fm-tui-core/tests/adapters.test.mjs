import test from 'node:test';
import assert from 'node:assert/strict';
import { buffer, put, display, terminal } from '../src/index.mjs';
import { fakeTerminal } from './fake-terminal.mjs';
test('display uses its fake port; clean/no-ui/pipe stay static without escapes', () => {
  for (const [tty, options] of [[true, { clean: true }], [true, { noUi: true }], [false, {}]]) {
    const port = fakeTerminal(tty), view = display(port, options), grid = buffer(20, 3);
    put(grid, 0, 0, 'quiet'); view.draw(grid); view.draw(buffer(20, 3)); view.close(); view.close();
    assert.equal(view.animated, false); assert.equal(port.writes.length, 1); assert.ok(!port.writes[0].includes('\x1b'));
  }
});
test('animated display tracks a reused buffer, suppresses empty writes and restores once', () => {
  const port = fakeTerminal(true, false), view = display(port), grid = buffer(20, 3);
  view.draw(grid); const start = port.writes.length; view.draw(grid); assert.equal(port.writes.length, start);
  put(grid, 3, 1, 'X'); view.draw(grid); assert.ok(port.writes.at(-1).includes('X'));
  view.close(); view.close(); assert.equal(port.writes.filter(s => s.includes('\x1b[?1049l')).length, 1);
  assert.ok(!/\x1b\[[0-9;]*m/.test(port.writes.join('')));
});
test('a failed frame write can still restore the terminal', () => {
  const port = fakeTerminal(), original = port.write; let calls = 0;
  port.write = text => { if (++calls === 2) throw Error('write failed'); original(text); };
  const view = display(port); assert.throws(() => view.draw(buffer(20, 3)), /write failed/); view.close();
  assert.ok(port.writes.at(-1).includes('\x1b[?1049l'));
});
test('real stream adapter honors even an empty NO_COLOR variable', () => {
  const writes = [], port = terminal({ isTTY: true, write: text => writes.push(text) }, { NO_COLOR: '' });
  assert.equal(port.color, false); assert.equal(port.tty, true); port.write('ok'); assert.deepEqual(writes, ['ok']);
});
