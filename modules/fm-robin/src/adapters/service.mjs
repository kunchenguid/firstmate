import fs from 'node:fs';
import { serviceMessages } from '../../../fm-state-reader/src/index.mjs';
import { fileStore } from './files.mjs';
import { events } from './events.mjs';
import { resourceMonitor, resourceBudget } from './resources.mjs';
import { research } from '../usecases/research.mjs';

/** Foreground composition; shared admission and transport remain the only message owner. */
export async function serve({ home, root, config, retrieval, reasoner, once = false, signal, ready = () => {} }) {
  if (signal?.aborted) return { state: 'stopped' };
  const store = fileStore(home), inbox = store.io.file('state/robin.inbox');
  const unlock = store.lock();
  let messages, monitor, parentWatch, inboxWatch, timer, failure, wake = () => {}, dirty = true;
  let watchedInode = null, signature = null;
  const changed = () => { dirty = true; wake(); };
  const failed = error => { failure = error; wake(); };
  const refreshWatch = () => {
    // Metadata fallback recovers a dropped native notification without spawning a polling CLI.
    store.io.file('state/robin.inbox');
    let stat;
    try { stat = fs.statSync(inbox); if (!stat.isDirectory()) throw Error('invalid_inbox'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const next = stat ? `${stat.ino}:${stat.mtimeMs}` : null;
    if (next !== signature) { signature = next; changed(); }
    if ((stat?.ino ?? null) !== watchedInode) {
      inboxWatch?.close(); watchedInode = stat?.ino ?? null;
      inboxWatch = stat ? fs.watch(inbox, (_, name) => {
        if (!name || /^\d+\.msg$/.test(String(name))) changed();
      }).on('error', failed) : null;
    }
  };
  const stop = () => wake();
  signal?.addEventListener('abort', stop);
  try {
    messages = await serviceMessages({ home, root, name: 'robin' });
    monitor = resourceMonitor(home, 'research'); monitor.sample();
    parentWatch = fs.watch(store.io.file('state'), (_, name) => {
      if (!name || String(name) === 'robin.inbox') {
        try { refreshWatch(); } catch (error) { failed(error); }
      }
    }).on('error', failed);
    refreshWatch();
    timer = setInterval(() => {
      try { monitor.sample(); refreshWatch(); } catch (error) { failed(error); }
    }, resourceBudget.sampleMs);
    ready();
    const ports = { messages, store, retrieval, reasoner, events: events({ home, root }), clock: { now: Date.now } };
    while (!signal?.aborted) {
      if (failure) throw failure;
      dirty = false;
      const result = await research(ports, config);
      if (once) return result;
      if (result.state === 'answered') continue;
      while (!dirty && !signal?.aborted && !failure) await new Promise(resolve => { wake = resolve; });
    }
  } finally {
    clearInterval(timer); parentWatch?.close(); inboxWatch?.close();
    signal?.removeEventListener('abort', stop);
    // Drain an in-flight operation before deregistration; never discard its pending inbox/journal.
    try { await messages?.close(); }
    finally { try { monitor?.close(); } finally { unlock(); } }
  }
}
