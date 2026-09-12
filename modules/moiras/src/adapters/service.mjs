import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { config } from './config.mjs';
import { state, publisher } from './state.mjs';
import { forge } from './forge.mjs';
import { journal } from './journal.mjs';
import { telemetry } from './telemetry.mjs';
import { inspect } from '../usecases/inspect.mjs';
import { serviceId } from '../core/findings.mjs';
import { serviceMessages } from '../../../fm-state-reader/src/index.mjs';
export async function observe({ home, root, configFile, messages, notify = () => {}, signal }) {
  config(configFile); // Reject configuration before creating state.
  const store = journal(home), release = store.claim(), eventPort = publisher(home, root);
  const controller = new AbortController(), cancel = () => controller.abort();
  signal?.addEventListener('abort', cancel, { once: true }); if (signal?.aborted) cancel();
  let stopped = false, active = null, pending = false, debounce, deadline, closeSource = () => {}, current, ready;
  const firstSnapshot = new Promise(resolve => { ready = resolve; });
  const changed = () => { if (!stopped && !debounce) debounce = setTimeout(() => { debounce = null; void update(); }, 1000); };
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
        await inspect({ source, forge: { read: repos => forge.read(repos, controller.signal) }, journal: store, publisher: eventPort, messages, audit,
          onSnapshot: data => { current = data; if (!messages) current.facts.push('Two-way channel disabled by caller'); ready(); },
          onNotice: notify }, c, now);
        clearTimeout(deadline);
        const boundaries = [c.repositories.length ? now + c.forgeSeconds : Infinity, current.beaconAt === null ? Infinity : current.beaconAt + c.beaconSeconds + 1,
          ...current.workers.filter(w => w.busy === 'busy').map(w => (w.changed ?? now) + c.busySilentSeconds + 1),
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
  let configWatch, ownedMessages, stopping;
  try {
    if (messages === undefined && !controller.signal.aborted) {
      ownedMessages = await serviceMessages({ home, root, name: serviceId });
      messages = ownedMessages;
    }
    configWatch = fs.watch(path.dirname(configFile), (_, name) => { if (!name || String(name) === path.basename(configFile)) changed(); }).on('error', changed);
    await Promise.race([firstSnapshot, update()]);
  } catch (error) {
    configWatch?.close(); closeSource();
    try { await ownedMessages?.close(); } finally { release(); signal?.removeEventListener('abort', cancel); }
    throw error;
  }
  return { data: () => current, stop: () => stopping ??= (async () => {
    stopped = true; cancel(); clearTimeout(debounce); clearTimeout(deadline); closeSource(); configWatch.close();
    await active; closeSource(); clearTimeout(deadline); clearTimeout(debounce); signal?.removeEventListener('abort', cancel);
    // The shared port logs its own lifecycle; failed observation logging must not block cleanup.
    try { await ownedMessages?.close(); } finally { release(); }
  })() };
}
