import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);

export function validateSnapshot(value) {
  const strings = (object, names) => object && typeof object === 'object' && !Array.isArray(object) &&
    names.every(name => object[name] == null || typeof object[name] === 'string');
  if (value?.schemaVersion !== 5 || !Array.isArray(value.providers) || value.providers.some(p =>
    !strings(p, ['provider', 'label', 'plan', 'source', 'credentialSource']) || typeof p.provider !== 'string' || !/^[a-z0-9-]+$/.test(p.provider) || !Array.isArray(p.windows) ||
    (p.account != null && !strings(p.account, ['email', 'accountId', 'identityStatus'])) ||
    (p.quotaSemantics != null && (!Array.isArray(p.quotaSemantics.effectiveAvailability) || p.quotaSemantics.effectiveAvailability.some(row => !strings(row, ['scope', 'status'])))) ||
    p.windows.some(w => !strings(w, ['id', 'label', 'startsAt', 'resetsAt']) || typeof w.id !== 'string')) ||
    new Set(value.providers.map(p => p.provider)).size !== value.providers.length) throw Error('Invalid quota-axi schema (expected version 5)');
  return value;
}

export function quotaSource(env = process.env) {
  return { async read(pools) {
    const read = async pool => {
      try {
        const { stdout } = await exec('quota-axi', ['--json', '--full', '--no-credential-refresh',
          ...(pool ? ['--provider', pool.provider] : [])],
        { env: { ...env, ...pool?.env }, timeout: 20000, maxBuffer: 4 * 1024 * 1024 });
        const snapshot = validateSnapshot(JSON.parse(stdout));
        const providers = pool ? snapshot.providers.filter(p => p.provider === pool.provider) : snapshot.providers;
        if (!providers.length) throw Error('No provider records');
        return providers.map(data => ({ ...pool, id: pool?.id || data.provider, data }));
      } catch (error) {
        return [{ ...pool, id: pool?.id || 'quota-axi', data: { provider: pool?.provider || 'quota-axi', windows: [] },
          error: error.killed ? 'quota-axi timed out' : 'quota-axi unavailable or invalid output' }];
      }
    };
    // Bound concurrent provider reads; quota-axi owns caching and credential discovery.
    const result = [];
    for (const pool of pools.length ? pools : [null]) result.push(...await read(pool));
    return result;
  } };
}
