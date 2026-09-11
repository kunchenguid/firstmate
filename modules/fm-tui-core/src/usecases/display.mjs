import { diff, plain } from '../core/frame.mjs';
/** @param {import('../ports/terminal').Terminal} port */
export function display(port, { clean = false, noUi = false } = {}) {
  const animated = port.tty && !clean && !noUi;
  let before, opened = false, closed = false;
  return {
    animated,
    draw(grid) {
      if (closed || (!animated && opened)) return;
      if (animated) {
        if (!opened) { opened = true; port.write('\x1b[?1049h\x1b[?25l'); }
        const changes = diff(before, grid, port.color);
        if (changes) port.write(changes);
      } else port.write(plain(grid));
      before = grid.map(row => row.map(cell => [...cell])); opened = true;
    },
    close() {
      if (!closed && opened && animated) port.write((port.color ? '\x1b[0m' : '') + '\x1b[?25h\x1b[?1049l');
      closed = true;
    },
  };
}
