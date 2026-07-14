import path from 'node:path';

export function registryDir(env = process.env) {
  if (env.MEM_REGISTRY_DIR) return path.resolve(env.MEM_REGISTRY_DIR);
  const home = env.HOME || process.env.HOME;
  return path.join(home, 'fleet', 'state', 'memory');
}

export function canonicalCheckout(env = process.env) {
  if (env.FM_HOME) return path.resolve(env.FM_HOME);
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
    snapshots: path.join(dir, 'snapshots'),
    recovery: path.join(dir, 'recovery')
  };
}
