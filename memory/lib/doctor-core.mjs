// Zero-dependency doctor core. This module must NOT import zod (or anything that
// does), because the missing-dependencies fallback in bin/mem.mjs imports it when
// node_modules is absent. It owns semantic-version comparison and the single
// stable doctor payload shape shared by the full and fallback code paths.

export function parseSemver(version) {
  const clean = String(version).replace(/^[v=]/, '').split('-')[0].split('+')[0];
  const [maj = 0, min = 0, patch = 0] = clean.split('.').map((n) => Number(n) || 0);
  return [maj, min, patch];
}

export function cmpSemver(a, b) {
  for (let i = 0; i < 3; i += 1) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

// Minimal range check for the comparator forms used in package.json engines,
// e.g. ">=20.11.0 <23". Honors the minor/patch floor, not just the major.
export function satisfiesRange(version, range) {
  const v = parseSemver(version);
  const comparators = String(range).trim().split(/\s+/).filter(Boolean);
  if (comparators.length === 0) return true;
  return comparators.every((comparator) => {
    const match = comparator.match(/^(>=|<=|>|<|=)?\s*v?(.+)$/);
    if (!match) return true;
    const op = match[1] || '=';
    const target = parseSemver(match[2]);
    const r = cmpSemver(v, target);
    switch (op) {
      case '>=': return r >= 0;
      case '<=': return r <= 0;
      case '>': return r > 0;
      case '<': return r < 0;
      default: return r === 0;
    }
  });
}

export function versionMatches(installed, want) {
  const spec = String(want).trim();
  if (/^\d/.test(spec)) return String(installed) === spec; // exact pin
  return satisfiesRange(installed, spec);
}

// Assemble the canonical doctor object. Every key is always present; callers that
// could not run a probe pass an explicit status plus reason rather than dropping
// the field, so `mem doctor --json` has one stable schema in every condition.
export function assembleDoctor(parts) {
  const compatible = satisfiesRange(parts.nodeVersion, parts.engines);
  const registryOk = parts.registry.status !== 'critical' && !String(parts.registry.status).startsWith('error');
  const registryPresentAndHealthy = registryOk && parts.registry.status !== 'missing' && parts.registry.health !== null;
  const activeIndexOk = !registryPresentAndHealthy || parts.activeIndex?.status === 'current';
  const snapshotsOk = !parts.snapshots || !['degraded', 'critical'].includes(parts.snapshots.health);
  const ok = Boolean(
    compatible
    && parts.requiredDependencies.ok
    && parts.packageLock.present
    && parts.packageLock.current
    && registryOk
    && activeIndexOk
    && snapshotsOk
  );
  return {
    ok,
    cli: parts.cli,
    canonicalCheckout: parts.canonicalCheckout,
    node: { version: parts.nodeVersion, compatible, required: parts.engines },
    packageLock: parts.packageLock,
    requiredDependencies: parts.requiredDependencies,
    pglite: parts.pglite,
    vectorExtension: parts.vectorExtension,
    embeddingProvider: parts.embeddingProvider,
    registry: parts.registry,
    snapshots: parts.snapshots || { health: null, outstanding: [], issues: [], reason: null },
    activeIndex: parts.activeIndex
  };
}

export function packageLockStatus(lock, pkg, lockPath) {
  if (!lock) return { path: lockPath, present: false, current: false };
  let current = lock.version === pkg.version;
  const rootDeps = lock.packages?.['']?.dependencies || {};
  for (const [name, want] of Object.entries(pkg.dependencies || {})) {
    if (rootDeps[name] !== want) current = false;
  }
  return { path: lockPath, present: true, current };
}
