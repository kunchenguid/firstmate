import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { config } from './config.mjs';
import { state, publisher } from './state.mjs';
import { forge } from './forge.mjs';
import { journal } from './journal.mjs';
import { telemetry } from './telemetry.mjs';
import { inspect } from '../usecases/inspect.mjs';
export async function observe({ home, root, configFile, messages = null, notify = () => {}, signal }) {
  config(configFile); // Reject configuration before creating state.
  const store = journal(home), release = store.claim(), eventPort = publisher(home, root);
  const controller = new AbortController(), cancel = () => controller.abort();
  signal?.addEventListener('abort', cancel, { once: true }); if (signal?.aborted) cancel();
  let stopped = false, active = null, pending = false, debounce, deadline, closeSource = () => {}, current;
  const changed = () => { if (!stopped) { clearTimeout(debounce); debounce = setTimeout(update, 150); } };
  const update = async () => {
    if (stopped) return;
    if (active) { pending = true; return; }
    active = (async () => {
      const audit = telemetry(store, randomUUID()), loggedStep = audit.step;
      audit.step = (...args) => { if (stopped || controller.signal.aborted) throw Error('Observation cancelled'); return loggedStep(...args); };
      try {
        const c = await audit.step('config.read', () => config(configFile));
        const source = state(home, c.poolFiles); closeSource();
        closeSource = await audit.step('state.watch', () => source.watch(error => { if (error) notify('State watch failed; restart after inspecting the filesystem'); changed(); }));
        const now = Date.now() / 1000;
        const result = await inspect({ source, forge: { read: repos => forge.read(repos, controller.signal) }, journal: store, publisher: eventPort, messages, audit }, c, now);
        current = result.snapshot;
        if (!messages) current.facts.push('Two-way channel unavailable: standalone service admission is pending');
        for (const notice of result.notices) notify(notice);
        clearTimeout(deadline);
        const boundaries = [c.repositories.length ? now + c.forgeSeconds : Infinity, current.beaconAt === null ? Infinity : current.beaconAt + c.beaconSeconds + 1,
          ...current.workers.filter(w => w.busy === 'idle').map(w => Math.max(w.changed ?? now, w.idleAt ?? now) + c.idleSeconds + 1),
          ...current.workers.filter(w => Number.isFinite(w.loopSince)).map(w => w.loopSince + c.loopSeconds + 1)].filter(t => Number.isFinite(t) && t > now);
        if (boundaries.length) deadline = setTimeout(update, Math.min(2147483647, Math.max(1000, (Math.min(...boundaries) - now) * 1000)));
      } catch (error) {
        try { audit.decision('observation', 'refused', [error.code ?? error.message]); } catch { notify('Moiras telemetry is unavailable'); }
        if (stopped || controller.signal.aborted) return;
        current = { ...(current ?? { workers: [], findings: [] }), facts: ['Observation failed; previous data is stale. Inspect telemetry and configuration.'] };
        notify(`Moiras observation failed: ${error.code ?? 'see telemetry'}`);
      }
    })();
    try { await active; } finally { active = null; if (pending) { pending = false; void update(); } }
  };
  let configWatch;
  try {
    configWatch = fs.watch(path.dirname(configFile), (_, name) => { if (!name || String(name) === path.basename(configFile)) changed(); }).on('error', changed);
    await update();
  } catch (error) { closeSource(); release(); signal?.removeEventListener('abort', cancel); throw error; }
  return { data: () => current, stop: async () => {
    stopped = true; cancel(); clearTimeout(debounce); clearTimeout(deadline); closeSource(); configWatch.close();
    await active; closeSource(); clearTimeout(deadline); clearTimeout(debounce); signal?.removeEventListener('abort', cancel); release();
  } };
}
