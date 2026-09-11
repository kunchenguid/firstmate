import { buffer, sprite, put, clean } from '../../../fm-tui-core/src/index.mjs';

/** Pure pose frames; the application chooses slow timing, never random motion. */
export function scene({ phase = 'idle', queue = null, fetches = 0, sources = 0, verified = 0, demo = false } = {}, tick = 0, width = 76) {
  const grid = buffer(width, 19);
  put(grid, 2, 0, `ROBIN / RESEARCH${demo ? ' / SYNTHETIC DEMO' : ''}`, 1);
  put(grid, 2, 1, '____________________________________________________________', 2);
  sprite(grid, 33, 3, ['  ___________________', ' /__________________/|', ' |  []  +  []  +  [] | |', ' |  +  []  +  []  + | |', ' |  []  +  []  +  [] | |', ' |  +  []  +  []  + | |', ' |__________________|/'], 2);
  sprite(grid, 9, 5, ['    .------.', '   /  ____  \\', `   |  ${tick % 16 === 15 ? '-  -' : 'o  o'}  |`, '   |   __   |', '   /|______|\\', '  / |  /\\  | \\', ' /__| /  \\ |__\\', '    |______|', '    / /  \\ \\'], 1);
  if (phase === 'retrieving') sprite(grid, 26, 10, ['__   _', '  \\_| |__', '   (_____/'], 3);
  if (verified > 0) put(grid, 37, 5, '[]', 4);
  put(grid, 2, 15, 'History awaits independent corroboration.', 2);
  put(grid, 2, 17, `phase=${clean(phase)}  queue=${queue ?? '?'}  fetches=${fetches}  sources=${sources}  citations=${verified}`, 2);
  return grid;
}
