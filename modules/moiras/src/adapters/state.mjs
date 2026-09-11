import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { json } from './journal.mjs';
import { files, snapshot, publishEvent } from '../../../fm-state-reader/src/index.mjs';
/** @returns {import('../ports/io').StateSource} */
export function state(home, poolFiles = []) {
  const source = files(home, { poolFiles });
  return { read: now => ({ ...snapshot(source, now), load: os.loadavg()[0] }), watch: changed => source.watch(changed) };
}
/** @returns {import('../ports/io').Publisher} */
export const publisher = (home, root) => ({
  publish: id => publishEvent({ home, root, module: 'moiras', id }),
  captured(id) {
    if (!/^[a-f0-9]{24}$/.test(id)) throw Error('Invalid event id');
    const file = path.join(fs.realpathSync(home), 'state/procevent-inbox', `moiras-${id}.1.result`);
    if (!fs.existsSync(file)) return false;
    if (fs.realpathSync(file) !== file) throw Error('Unsafe event capture');
    return json(file)?.id === id;
  },
});
