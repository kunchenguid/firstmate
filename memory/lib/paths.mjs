import path from 'node:path';

export function registryDir(env = process.env) {
  if (env.MEM_REGISTRY_DIR) return path.resolve(env.MEM_REGISTRY_DIR);
  const home = env.HOME || process.env.HOME;
  return path.join(home, 'fleet', 'state', 'memory');
}

// Canonical CODE checkout resolution.
// FM_HOME selects an operational state home for FirstMate, but it must never
// redirect executable memory code to an alternate checkout. Only the explicit
// MEM_CLI test override (handled by the shim) may point at other CLI code.
export function canonicalCheckout(env = process.env) {
  const home = env.HOME || process.env.HOME;
  return path.join(home, 'fleet', 'firstmate-runtime');
}

export function registryPaths(dir = registryDir()) {
  return {
    dir,
    registry: path.join(dir, 'memory-registry.jsonl'),
    index: path.join(dir, 'memory-index.json'),
    audit: path.join(dir, 'audit-latest.json'),
    manifest: path.join(dir, 'activity-manifest.json'),
    lock: path.join(dir, '.memory-registry.lock'),
    activityLock: path.join(dir, '.memory-activity.lock'),
    snapshots: path.join(dir, 'snapshots'),
    snapshotState: path.join(dir, 'snapshots', 'snapshot-obligations.json'),
    recovery: path.join(dir, 'recovery')
  };
}
