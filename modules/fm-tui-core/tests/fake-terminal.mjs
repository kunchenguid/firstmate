/** @returns {import('../src/ports/terminal').Terminal & {writes: string[]}} */
export function fakeTerminal(tty = true, color = true) {
  const writes = [];
  return { tty, color, writes, write: text => { writes.push(text); } };
}
