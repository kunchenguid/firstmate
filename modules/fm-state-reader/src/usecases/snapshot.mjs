import { task, pool, ledger, completeLines } from '../core/records.mjs';
/** @param {import('../ports/files').StateFiles} source */
export function snapshot(source, now) {
  if (!Number.isFinite(now)) throw Error('Invalid observation time');
  const workers = source.taskIds().map(id => task(id, ...['meta', 'status', 'busy-state', 'busy-gen'].map(ext => source.read(`state/${id}.${ext}`)), now));
  const beacon = source.read('state/.last-watcher-beat'), wake = source.read('state/.wake-queue');
  return { workers, now, beaconAt: beacon?.at ?? null, beaconAge: beacon ? Math.max(0, now - beacon.at) : null,
    pools: source.pools.map(key => ({ key, ...pool(source.read(key)) })),
    wake: wake ? { count: completeLines(wake).length, truncated: wake.truncated } : null };
}
/** @param {import('../ports/files').StateFiles} source */
export const readLedger = (source, key) => ledger(source.read(key));
