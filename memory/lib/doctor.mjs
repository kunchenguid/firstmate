import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { auditRegistry } from './registry.mjs';
import { canonicalCheckout, registryDir } from './paths.mjs';

export function checkDoctor(root, env = process.env) {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const lockPath = path.join(root, 'package-lock.json');
  const lock = fs.existsSync(lockPath) ? JSON.parse(fs.readFileSync(lockPath, 'utf8')) : null;
  const major = Number(process.version.replace(/^v/, '').split('.')[0]);
  const requiredMissing = [];
  for (const name of Object.keys(pkg.dependencies || {})) {
    if (!fs.existsSync(path.join(root, 'node_modules', name, 'package.json'))) requiredMissing.push(name);
  }
  let registryStatus = 'missing';
  let activeIndexStatus = 'missing';
  let registryHealth = null;
  try {
    const audit = auditRegistry(registryDir(env));
    registryStatus = audit.registry.health === 'critical' ? 'critical' : fs.existsSync(audit.registry.path) ? writable(registryDir(env)) : 'missing';
    registryHealth = audit.registry;
    activeIndexStatus = audit.activeIndex.status;
  } catch (error) {
    registryStatus = `error: ${error.message}`;
  }
  const payload = {
    ok: major >= 20 && major < 23 && requiredMissing.length === 0 && registryStatus !== 'critical',
    cli: { available: true, path: fileURLToPath(new URL('../bin/mem.mjs', import.meta.url)) },
    canonicalCheckout: { path: canonicalCheckout(env), source: env.FM_HOME ? 'FM_HOME' : 'HOME' },
    node: { version: process.version, compatible: major >= 20 && major < 23, required: pkg.engines.node },
    packageLock: { path: lockPath, present: Boolean(lock), current: Boolean(lock && lock.version === pkg.version && lock.packages?.['']?.dependencies?.zod === pkg.dependencies.zod) },
    requiredDependencies: { ok: requiredMissing.length === 0, missing: requiredMissing },
    pglite: { available: dependencyAvailable(root, '@electric-sql/pglite'), required: false, status: 'not installed for current milestone' },
    vectorExtension: { available: dependencyAvailable(root, '@electric-sql/pglite-pgvector'), required: false, status: 'not installed for current milestone' },
    embeddingProvider: { configured: Boolean(env.MEM_EMBEDDING_KEY || env.OPENAI_API_KEY), required: false },
    registry: { path: registryDir(env), status: registryStatus, health: registryHealth },
    activeIndex: { status: activeIndexStatus }
  };
  payload.ok = payload.ok && payload.packageLock.present && payload.packageLock.current;
  return payload;
}

function dependencyAvailable(root, name) {
  return fs.existsSync(path.join(root, 'node_modules', name, 'package.json'));
}

function writable(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o755 });
    fs.accessSync(dir, fs.constants.W_OK);
    return 'writable';
  } catch {
    return 'read-only';
  }
}
