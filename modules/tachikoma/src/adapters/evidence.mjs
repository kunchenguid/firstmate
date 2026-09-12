import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { files } from '../../../fm-state-reader/src/index.mjs';
import { tupleKey } from '../core/routing.mjs';
import { poolRecovery } from '../core/recovery.mjs';
import { checkDirectory, parseJSON, readJSON, readText } from './storage.mjs';

const assert = (condition, reason) => { if (!condition) throw new Error(reason); };
const number = value => typeof value === 'number' && Number.isFinite(value);
export const token = value => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,159}$/.test(value) && !value.includes('..');
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
export function command(executable, args, env) {
  const result = spawnSync(executable, args, { env, encoding: 'utf8', timeout: 120000, maxBuffer: 64 * 1024 * 1024 });
  assert(!result.error && result.status === 0, `${path.basename(executable)} refused (exit ${result.status ?? 'unavailable'})`);
  return result.stdout;
}

export function quotaSnapshot(text, now) {
  const result = { quota: [], exhaustion: [], attention: [] };
  const rows = text.trim().split('\n');
  const stamp = rows.find(row => row.startsWith('generatedAt: '));
  assert(stamp, 'quota snapshot missing generatedAt');
  result.generatedAt = parseJSON(stamp.slice(13));
  const seen = new Set();
  for (let i = 0; i < rows.length; i++) {
    const header = /^(quota|exhaustion|attention)\[(\d+)\](?:\{([^}]+)\})?:$/.exec(rows[i]);
    if (!header) continue;
    assert(!seen.has(header[1]), 'duplicate quota block'); seen.add(header[1]);
    const keys = header[3]?.split(',') || [];
    assert(new Set(keys).size === keys.length, 'duplicate quota column');
    for (let n = 0; n < Number(header[2]); n++) {
      const line = rows[++i]; assert(line?.startsWith('  '), 'truncated quota block');
      const values = line.trim().match(/"(?:[^"\\]|\\.)*"|[^,]+/g) || [];
      assert(values.length === keys.length, 'invalid quota row');
      result[header[1]].push(Object.fromEntries(keys.map((key, j) => [key, values[j].startsWith('"') ? parseJSON(values[j]) : /^-?\d+(\.\d+)?$/.test(values[j]) ? Number(values[j]) : values[j]])));
    }
  }
  return fresh(result, now);
}
function fresh(snapshot, now) {
  const age = (now - Date.parse(snapshot.generatedAt)) / 1000;
  assert(number(age) && age >= -5 && age <= 300, 'stale or invalid quota snapshot');
  snapshot.ageSeconds = Math.max(0, age);
  return snapshot;
}
export function jsonQuota(value, now) {
  assert(Array.isArray(value.providers), 'invalid quota JSON providers');
  const result = { generatedAt: value.generatedAt, quota: [], exhaustion: [], attention: [] };
  for (const provider of value.providers) for (const scope of provider.quotaSemantics?.effectiveAvailability || []) {
    const usable = provider.state?.status === 'fresh' && provider.state?.stale === false;
    // Display the producer's window reset evidence; never recompute its pacing.
    const resets = (provider.windows || []).filter(window => scope.boundedBy?.includes(window.id)).map(window => window.resetsAt).filter(value => typeof value === 'string' && Number.isFinite(Date.parse(value)));
    result.quota.push({ provider: provider.provider, scope: scope.scope, effectivePercentRemaining: usable ? scope.effectivePercentRemaining : null, spendPriority: usable ? scope.selection?.spendPriority : null, runway: usable ? scope.runway?.status : 'unknown', resetsAt: scope.resetsAt ?? resets.sort((a, b) => Date.parse(b) - Date.parse(a))[0] ?? null, pacingRecoveryAt: scope.pacingRecoveryAt ?? null });
    if (usable) result.exhaustion.push({ provider: provider.provider, scope: scope.scope, usableRunwaySeconds: scope.runway?.usableRunwaySeconds });
  }
  return fresh(result, now);
}

export function evidence({ root, home, data }) {
  const config = path.join(home, 'config');
  const defaults = readJSON(path.join(root, 'modules/tachikoma/config.json'));
  const schema = readJSON(path.join(root, 'modules/tachikoma/config.schema.json'));
  const shape = (value, spec) => assert(value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(key => Object.hasOwn(spec.properties, key)) && (spec.required || []).every(key => Object.hasOwn(value, key)), 'unknown or missing routing policy fields');
  const source = files(home, { poolFiles: ['config/tachikoma/policy.json', 'config/model-catalog.json', 'config/crew-dispatch.json'], maxBytes: 1048576 });
  const read = index => {
    checkDirectory(index === 0 ? path.join(config, 'tachikoma') : config);
    const record = source.read(`pool:${index}`);
    assert(record && !record.truncated, 'missing, unsafe, or oversized routing configuration');
    return record.text;
  };
  const env = { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: data, FM_STATE_OVERRIDE: path.join(home, 'state'), FM_CONFIG_OVERRIDE: config };
  const owner = (name, args) => command(path.join(root, 'bin', name), args, env);
  return {
    activation() {
      checkDirectory(path.join(config, 'tachikoma'));
      const record = source.read('pool:0');
      if (!record) {
        try { fs.lstatSync(path.join(config, 'tachikoma/policy.json')); }
        catch (error) { if (error.code === 'ENOENT') return false; throw error; }
        throw new Error('unsafe activation file');
      }
      assert(!record.truncated, 'oversized activation file');
      const value = parseJSON(record.text);
      shape(value, schema);
      assert(value.schemaVersion === 1 && typeof value.enabled === 'boolean', 'invalid activation');
      return value.enabled;
    },
    async read(request) {
      for (const key of ['task', 'class', 'repo']) assert(token(request[key]), `--${key} must be an identifier`);
      assert(request.brief, '--brief required');
      const brief = readText(path.resolve(request.brief)); assert(brief !== null, 'brief unavailable');
      const text = read(0), rawPolicy = parseJSON(text), catalogText = read(1), dispatchText = read(2);
      shape(rawPolicy, schema);
      const policy = { ...defaults, ...rawPolicy };
      command('bash', ['-c', '. "$1/fm-model-catalog-lib.sh"; . "$1/fm-crew-dispatch-lib.sh"; fm_model_catalog_read "$2" && fm_crew_dispatch_validate_file "$2/crew-dispatch.json"', 'tachikoma', path.join(root, 'bin'), config], env);
      assert(policy.schemaVersion === 1 && typeof policy.enabled === 'boolean', 'invalid policy version or activation');
      if (request.requireEnabled) assert(policy.enabled, 'Tachikoma activation is off');
      assert(policy.catalogSha256 === hash(catalogText) && policy.dispatchSha256 === hash(dispatchText), 'policy compilation is stale');
      assert(Array.isArray(policy.allowedHarnesses) && policy.allowedHarnesses.length && policy.allowedHarnesses.every(token), 'allowedHarnesses required');
      assert(Array.isArray(policy.disabledPools) && policy.disabledPools.every(token), 'disabledPools required');
      assert(number(policy.maxLoadPerCpu) && policy.maxLoadPerCpu > 0, 'maxLoadPerCpu required');
      assert(number(policy.explorationRate) && policy.explorationRate > 0 && policy.explorationRate <= 1, 'invalid explorationRate');
      assert(number(policy.unmeasuredRate) && policy.unmeasuredRate > 0 && policy.unmeasuredRate < 1, 'invalid unmeasuredRate');
      assert(Number.isInteger(policy.unmeasuredDailyCap) && policy.unmeasuredDailyCap > 0, 'invalid unmeasuredDailyCap');
      assert(Array.isArray(policy.rules) && Array.isArray(policy.bindings), 'rules and bindings required');
      for (const rule of policy.rules) {
        shape(rule, schema.properties.rules.items);
        assert(token(rule.repo) && token(rule.taskClass), 'invalid rule identity');
      }
      const rules = policy.rules.filter(rule => rule.repo?.toLowerCase() === request.repo.toLowerCase() && rule.taskClass === request.class);
      assert(rules.length === 1, 'exactly one compiled repo/class rule required');
      const rule = rules[0];
      assert(/^(default|rule-[1-9][0-9]*)$/.test(rule.matchedRule) && number(rule.horizonSeconds) && rule.horizonSeconds > 0 && typeof rule.strongestOnly === 'boolean' && ['highest-priority', 'quota-weighted'].includes(rule.selectionStrategy), 'invalid compiled rule');
      const pools = parseJSON(catalogText).pools, dispatch = parseJSON(dispatchText);
      const profiles = rule.matchedRule === 'default' ? dispatch.default : dispatch.rules[Number(rule.matchedRule.slice(5)) - 1]?.use;
      assert(profiles, 'compiled rule does not exist');
      const candidates = Array.isArray(profiles) ? profiles : [profiles];
      assert(new Set(candidates.map(tupleKey)).size === candidates.length, 'duplicate concrete profiles');
      const disabledHarnesses = [];
      for (const harness of new Set(candidates.map(candidate => candidate.harness))) {
        const result = spawnSync(path.join(root, 'bin/fm-harness.sh'), ['validate', harness], { env, encoding: 'utf8', timeout: 10000 });
        assert(!result.error && [0, 1].includes(result.status), 'harness admission policy unreadable');
        if (result.status === 1) disabledHarnesses.push(harness);
      }
      policy.allowedHarnesses = policy.allowedHarnesses.filter(harness => !disabledHarnesses.includes(harness));
      const bindings = new Set();
      for (const binding of policy.bindings) {
        shape(binding, schema.properties.bindings.items);
        assert(binding.accountProfile == null || (binding.harness === 'claude' && /^[a-z][a-z0-9-]{0,31}$/.test(binding.accountProfile)), 'invalid account profile binding');
        assert(binding.qualityPrior === undefined || (number(binding.qualityPrior) && binding.qualityPrior >= 0 && binding.qualityPrior <= 1), 'invalid quality prior');
        for (const field of ['modelVersion', 'cliVersion']) assert(binding[field] === undefined || (typeof binding[field] === 'string' && /^[\x20-\x7e]{1,160}$/.test(binding[field])), 'invalid version binding');
        assert(['harness', 'model', 'pool', 'catalogModel', 'quotaProvider', 'modelFamily'].every(key => token(binding[key])) && (binding.effort === null || ['low', 'medium', 'high', 'xhigh', 'max'].includes(binding.effort)), 'invalid binding tuple');
        assert(!bindings.has(tupleKey(binding)), 'duplicate binding tuple'); bindings.add(tupleKey(binding));
        const matches = pools.filter(pool => pool.pool === binding.pool && pool.models.includes(binding.catalogModel));
        assert(matches.length === 1, 'binding is outside the subscription catalog');
        binding.provider = matches[0].provider;
        assert(typeof binding.strongest === 'boolean' && Array.isArray(binding.quotaScopes) && binding.quotaScopes.length && binding.quotaScopes.every(token), 'binding needs explicit reasoning strength and quota scopes');
        assert(new Set(binding.quotaScopes).size === binding.quotaScopes.length, 'duplicate quota scope');
      }
      for (const candidate of candidates) assert(bindings.has(tupleKey(candidate)), 'unbound profile');
      let snapshot = quotaSnapshot(request.snapshot ? readText(path.resolve(request.snapshot)) : command('quota-axi', [], env), Date.now());
      const applicable = row => policy.bindings.some(binding => candidates.some(candidate => tupleKey(candidate) === tupleKey(binding)) && row.provider === binding.quotaProvider && (['all_models', 'all_products'].includes(row.scope) || binding.quotaScopes.includes(row.scope)));
      if (!request.snapshot && (snapshot.quota.filter(applicable).some(row => !number(row.spendPriority) || !number(row.effectivePercentRemaining) || !['through_reset','projected_exhaustion','exhausted_now'].includes(row.runway)) || candidates.some(candidate => { const binding = policy.bindings.find(b => tupleKey(b) === tupleKey(candidate)); return !snapshot.quota.some(row => row.provider === binding.quotaProvider); }))) snapshot = jsonQuota(parseJSON(command('quota-axi', ['--json'], env)), Date.now());
      const cooldowns = {};
      for (const candidate of candidates) {
        const binding = policy.bindings.find(b => tupleKey(b) === tupleKey(candidate));
        const result = spawnSync(path.join(root, 'bin/fm-quota-cooldown.sh'), ['authorize', '--harness', binding.harness, '--provider', binding.provider, '--model-family', binding.modelFamily], { env, encoding: 'utf8', timeout: 10000 });
        assert(!result.error && [0,3].includes(result.status), 'cooldown store unreadable');
        cooldowns[tupleKey(binding)] = result.status === 3;
      }
      const machine = { loadAverage1m: os.loadavg()[0], logicalCpuCount: os.availableParallelism?.() || os.cpus().length };
      assert(number(machine.loadAverage1m) && machine.logicalCpuCount > 0, 'machine load unavailable');
      const seed = request.seed ?? crypto.randomInt(0x100000000);
      const recoveryStore = parseJSON(owner('fm-quota-cooldown.sh', ['list', '--json'])).cooldowns;
      const recordedAt = new Date().toISOString();
      fresh(snapshot, Date.parse(recordedAt));
      const recovery = poolRecovery(policy, candidates, snapshot, recoveryStore, recordedAt);
      return { input: { policy, rule, candidates, snapshot, machine, cooldowns, repo: request.repo, seed }, stamp: { schemaVersion: 1, decisionId: crypto.randomUUID(), requestId: request.requestId, recordedAt, poolRecovery: recovery, task: request.task, taskClass: request.class, repo: request.repo, briefSha256: hash(brief), policySha256: hash(text + JSON.stringify(defaults) + (disabledHarnesses.length ? JSON.stringify(disabledHarnesses.sort()) : '')), quotaObservedAt: snapshot.generatedAt, machine, matchedRule: rule.matchedRule } };
    },
    async readAttempts() { return parseJSON(owner('fm-model-telemetry.sh', ['sheet', '--format', 'json'])); },
  };
}
