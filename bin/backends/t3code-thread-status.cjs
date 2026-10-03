// The one T3 thread -> status word rule, shared by the shell stream reader
// (t3code-eventwait.cjs) and the HTTP probe in t3code.sh, whose status table
// maps each word to busy and agent state. It follows T3's own classification:
// a stopped or failed session is over whatever background job outlives it,
// and on a live session only `working` background work (a terminal job that
// outlived its turn) is active work; `monitoring` adds no activity verdict.
module.exports = (thread) => {
  const status = thread.session?.status;
  if (thread.archivedAt) return 'archived';
  if (status === 'stopped') return thread.settledAt ? 'settled-stopped' : 'stopped';
  if (status === 'error') return 'error';
  return thread.backgroundLiveness === 'working' ? 'running' : status || 'idle';
};
