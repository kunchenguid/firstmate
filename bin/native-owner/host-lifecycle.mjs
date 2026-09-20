// Host-owned lifecycle, never a model tool. Callbacks close the registered
// operation jobs and the retained app-server process, not a shared process tree.
export function reconciliationWarning(journal) {
  if (typeof journal !== 'string' || !journal) throw new TypeError('Receipt journal path is required');
  return `Acknowledgement completion is unconfirmed. Its records are preserved and require reconciliation: ${journal}`;
}
export function createHostLifecycle({ gate, interrupt, stopOperations, closeInput, waitForExit, terminate, graceMs = 2000 }) {
  if (!Number.isInteger(graceMs) || graceMs < 1 || graceMs > 10000) throw new TypeError('Invalid shutdown bound');
  let stopping = null;
  async function bounded(action, label) {
    let timer;
    const controller = new AbortController();
    try {
      return await Promise.race([
        Promise.resolve().then(() => action(controller.signal)),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), graceMs); }),
      ]);
    } finally { clearTimeout(timer); controller.abort(); }
  }
  return Object.freeze({
    shutdown() {
      if (stopping) return stopping;
      // Revoke new tool calls synchronously, before any await or interrupt.
      gate.close();
      stopping = (async () => {
        const errors = [];
        let operationsStopped = false, reconciliationRequired = false;
        try { await bounded(interrupt, 'Turn interruption'); } catch (error) { errors.push(error.message); }
        try {
          const operationResult = await bounded(stopOperations, 'Operation shutdown');
          if (operationResult && typeof operationResult === 'object') {
            operationsStopped = operationResult.stopped === true;
            reconciliationRequired = operationResult.reconciliationRequired === true;
          } else operationsStopped = operationResult === true;
          if (!operationsStopped) errors.push('Operation shutdown was not confirmed');
        } catch (error) { errors.push(error.message); }
        try { closeInput(); } catch (error) { errors.push(error.message); }
        let exited = false, forced = false;
        try { exited = (await bounded(waitForExit, 'App-server exit')) === true; } catch { /* Escalate to its retained handle only. */ }
        if (!exited) {
          forced = true;
          try { terminate(); } catch (error) { errors.push(error.message); }
          try { exited = (await bounded(waitForExit, 'App-server termination')) === true; } catch (error) { errors.push(error.message); }
        }
        if (!exited) errors.push('App-server exit was not confirmed');
        return { stopped: operationsStopped && exited, operationsStopped, reconciliationRequired, exited, forced, errors };
      })();
      return stopping;
    },
  });
}
