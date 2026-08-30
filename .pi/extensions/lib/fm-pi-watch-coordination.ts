// Synchronous event-bus handshake between the Pi watcher and turn-end guard.
// The guard collects the local reconciliation promise before it evaluates
// whether a repair follow-up is needed.
export const FM_PI_WATCH_RECONCILE_EVENT = "fm-primary-pi-watch:reconcile-demand";

export type PiWatchReconcileRequest = {
  waitUntil(promise: Promise<unknown>): void;
};
