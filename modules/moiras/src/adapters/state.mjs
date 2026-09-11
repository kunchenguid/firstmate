import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { json } from './journal.mjs';
import { serviceId } from '../core/findings.mjs';
import { files, snapshot, publishEvent } from '../../../fm-state-reader/src/index.mjs';
/** @returns {import('../ports/io').StateSource} */
export function state(home, poolFiles = []) {
  const source = files(home, { poolFiles });
  return { read: now => ({ ...snapshot(source, now), load: os.loadavg()[0] }), watch(changed) {
    const closeSource = source.watch(changed), dir = path.join(fs.realpathSync(home), 'state'), name = `${serviceId}.inbox`;
    let inbox, parent;
    const attach = () => {
      inbox?.close(); inbox = undefined;
      const target = path.join(dir, name);
      if (!fs.existsSync(target)) return;
      if (!fs.lstatSync(target).isDirectory()) throw Error('Unsafe message watch directory');
      inbox = fs.watch(target, (_, file) => { if (!file || /^\d+\.msg$/.test(String(file))) changed(); }).on('error', changed);
    };
    const close = () => { inbox?.close(); parent?.close(); closeSource(); };
    try {
      parent = fs.watch(dir, (_, file) => {
        if (!file || String(file) === name) { try { attach(); changed(); } catch (error) { changed(error); } }
      }).on('error', changed);
      attach();
    } catch (error) { close(); throw error; }
    return close;
  } };
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
