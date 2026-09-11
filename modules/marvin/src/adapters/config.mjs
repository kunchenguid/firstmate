import fs from 'node:fs';
const keys = (value, allowed) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(key => allowed.includes(key));
const text = value => typeof value === 'string' && value.length > 0 && !/[\x00-\x1f\x7f]/.test(value);
export function validateConfig(config) {
  if (!keys(config, ['refreshSeconds', 'pools']) || !Number.isInteger(config.refreshSeconds) || config.refreshSeconds < 1 || config.refreshSeconds > 86400 || !Array.isArray(config.pools)) throw Error('Config requires refreshSeconds (1..86400) and pools array');
  const ids = new Set();
  for (const pool of config.pools) {
    if (!keys(pool, ['id', 'provider', 'label', 'expectedEmail', 'credentialSource', 'env', 'windows']) ||
      !text(pool.id) || !/^[a-zA-Z0-9_-]+$/.test(pool.id) || ids.has(pool.id) || !text(pool.provider) || !/^[a-z0-9-]+$/.test(pool.provider) ||
      ['label', 'expectedEmail', 'credentialSource'].some(key => key in pool && !text(pool[key])) ||
      ('env' in pool && (!keys(pool.env, ['CODEX_HOME', 'CLAUDE_CONFIG_DIR']) || Object.values(pool.env).some(value => !text(value)))) ||
      ('windows' in pool && (!pool.windows || Array.isArray(pool.windows) || typeof pool.windows !== 'object' || Object.values(pool.windows).some(value => !Number.isFinite(value) || value <= 0)))) throw Error('Invalid or duplicate pool configuration');
    ids.add(pool.id);
  }
  return config;
}
export const loadConfig = file => validateConfig(JSON.parse(fs.readFileSync(file, 'utf8')));
