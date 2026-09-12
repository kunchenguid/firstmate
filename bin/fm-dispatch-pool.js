#!/usr/bin/env node
'use strict';
// Native dispatch admission implementation. Invoke through fm-dispatch-pool.sh,
// which owns the existing Firstmate lock. Configuration is documented in
// docs/configuration.md; this module never creates an endpoint or a supervisor.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const hash = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const token = v => typeof v === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(v) && !v.includes('..');
const modelToken = v => typeof v === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,127}$/.test(v) && !v.includes('..') && !v.includes('//');
const object = v => v && typeof v === 'object' && !Array.isArray(v);
function requireThat(ok, reason) { if (!ok) throw new Error(reason); }
function read(file) {
  const st = fs.lstatSync(file);
  requireThat(st.isFile() && !st.isSymbolicLink() && !(st.mode & 0o022), 'unsafe_file');
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}
function write(file, value) {
  if (fs.existsSync(file)) read(file);
  const tmp = `${file}.${process.pid}.tmp`;
  const fd = fs.openSync(tmp, 'wx', 0o600);
  try { fs.writeFileSync(fd, JSON.stringify(value) + '\n'); fs.fsyncSync(fd); }
  finally { fs.closeSync(fd); }
  fs.renameSync(tmp, file);
  const dir = fs.openSync(path.dirname(file), 'r');
  try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
}
function config(file) {
  const c = read(file);
  requireThat(c.schemaVersion === 1 && object(c.pools) && object(c.defaults), 'invalid_pool_config');
  requireThat(Object.keys(c).every(k => ['schemaVersion', 'pools', 'defaults'].includes(k)), 'unknown_config_field');
  for (const [name, pool] of Object.entries(c.pools)) {
    requireThat(token(name) && Array.isArray(pool) && pool.length > 0 && pool.length <= 64, 'invalid_pool');
    const ids = new Set(), tuples = new Set();
    for (const p of pool) {
      const keys = ['id', 'harness', 'model', 'effort', 'provider', 'authCarrier', 'carrier', 'weight'];
      requireThat(object(p) && Object.keys(p).length === keys.length && keys.every(k => k in p), 'invalid_candidate_fields');
      requireThat(keys.filter(k => k !== 'weight' && k !== 'model').every(k => token(p[k])) && modelToken(p.model), 'invalid_candidate_identity');
      requireThat(Number.isSafeInteger(p.weight) && p.weight > 0 && p.weight <= 10000, 'invalid_weight');
      const tuple = hash(keys.filter(k => !['id', 'weight'].includes(k)).map(k => p[k]));
      requireThat(!ids.has(p.id) && !tuples.has(tuple), 'duplicate_candidate');
      ids.add(p.id); tuples.add(tuple);
    }
  }
  for (const [kind, pool] of Object.entries(c.defaults)) {
    requireThat(['secondmate', 'crewmate'].includes(kind) && token(pool) && Object.hasOwn(c.pools, pool), 'invalid_default_pool');
  }
  return c;
}

// One bounded, read-only app-server session supplies the account, model/effort
// catalog, and applicable subscription limits. No prompts, login or reset calls.
async function codexProbe() {
  const lookup = spawnSync('which', ['codex'], { encoding: 'utf8' });
  requireThat(lookup.status === 0, 'codex_unavailable');
  const binary = fs.realpathSync(lookup.stdout.trim());
  const home = fs.realpathSync(process.env.CODEX_HOME || path.join(process.env.HOME, '.codex'));
  const child = spawn(binary, ['-c', 'model_provider="openai"', 'app-server', '--listen', 'stdio://'], {
    env: { ...process.env, CODEX_HOME: home }, stdio: ['pipe', 'pipe', 'ignore'],
  });
  let seq = 0, buffer = '', fatal;
  const pending = new Map();
  const stop = reason => {
    fatal = reason;
    for (const { reject } of pending.values()) reject(new Error(reason));
    pending.clear();
  };
  child.on('error', () => stop('codex_unavailable'));
  child.on('exit', () => stop('codex_probe_exited'));
  child.stdin.on('error', () => stop('codex_probe_io'));
  child.stdout.on('data', d => {
    buffer += d;
    if (buffer.length > 4 * 1024 * 1024) { stop('codex_probe_oversize'); child.kill(); return; }
    let n;
    while ((n = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, n); buffer = buffer.slice(n + 1);
      try {
        const r = JSON.parse(line), call = pending.get(r.id);
        if (!call) continue;
        pending.delete(r.id);
        if (r.error) call.reject(new Error('codex_protocol_refused'));
        else call.resolve(r.result);
      } catch { stop('codex_protocol_malformed'); }
    }
  });
  const call = (method, params = null) => new Promise((resolve, reject) => {
    if (fatal) return reject(new Error(fatal));
    const id = ++seq; pending.set(id, { resolve, reject });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
  const timer = setTimeout(() => { stop('codex_probe_timeout'); child.kill('SIGKILL'); }, 15000);
  const startedAt = Date.now();
  try {
    const init = await call('initialize', { clientInfo: { name: 'firstmate-pool', version: '1' } });
    requireThat(init?.codexHome && fs.realpathSync(init.codexHome) === home && typeof init.userAgent === 'string', 'codex_auth_home_unknown');
    child.stdin.write('{"method":"initialized"}\n');
    const before = await call('account/read', { refreshToken: false });
    requireThat(before?.account?.type === 'chatgpt' && before.account.email && before.requiresOpenaiAuth === true, 'codex_auth_unknown');
    let models = [], cursor = null;
    for (let page = 0; page < 10; page++) {
      const catalog = await call('model/list', { limit: 100, cursor });
      requireThat(Array.isArray(catalog?.data), 'codex_catalog_unknown');
      models.push(...catalog.data); cursor = catalog.nextCursor;
      if (cursor == null) break;
    }
    requireThat(cursor == null, 'codex_catalog_incomplete');
    const quota = await call('account/rateLimits/read');
    const after = await call('account/read', { refreshToken: false });
    const again = await call('account/rateLimits/read');
    requireThat(hash(before) === hash(after) && typeof quota?.accountId === 'string' && quota.accountId.length > 0 && quota.accountId === again?.accountId, 'codex_identity_unknown_or_changed');
    return { startedAt, checkedAt: Date.now(), binary, authHome: home, version: init.userAgent,
      identity: hash({ account: before.account, accountId: quota.accountId }), models,
      limits: again.rateLimitsByLimitId, defaultLimit: again.rateLimits };
  } finally { clearTimeout(timer); child.kill(); }
}
function reject(p, reason) { return { candidate: p.id, viable: false, reason }; }
function codexEvidence(p, raw, now = Date.now()) {
  if (!raw || now - raw.startedAt > 60000 || raw.startedAt > now || raw.checkedAt > now) return reject(p, 'stale_or_unknown_evidence');
  const model = raw.models.filter(m => m.model === p.model && m.id === p.model);
  if (model.length !== 1 || model[0].hidden !== false || !model[0].supportedReasoningEfforts?.some(e => e.reasoningEffort === p.effort)) return reject(p, 'model_or_effort_unavailable');
  // Only these explicitly qualified general Codex models use the codex bucket.
  // Specialty or unknown models need their own authoritative scope mapping.
  if (!['gpt-6-astra', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-5.5'].includes(p.model)) return reject(p, 'quota_scope_unqualified');
  if (!['low', 'medium', 'high', 'xhigh'].includes(p.effort)) return reject(p, 'native_launch_effort_unsupported');
  const limit = raw.limits?.codex;
  if (!object(limit) || limit.limitId !== 'codex' || hash(limit) !== hash(raw.defaultLimit)) return reject(p, 'quota_scope_unknown');
  if (limit.spendControlReached === true || limit.rateLimitReachedType != null) return reject(p, 'quota_exhausted');
  const windows = [limit.primary, limit.secondary].filter(w => w != null);
  if (!windows.length || windows.some(w => !Number.isFinite(w.usedPercent) || w.usedPercent < 0 || w.usedPercent > 100 || !Number.isSafeInteger(w.resetsAt) || w.resetsAt * 1000 <= now)) return reject(p, 'quota_unknown_or_stale');
  if (limit.individualLimit != null) return reject(p, 'individual_quota_scope_unsupported');
  if (windows.some(w => w.usedPercent >= 100)) return reject(p, 'quota_exhausted');
  return { candidate: p.id, viable: true, source: 'codex-app-server', checkedAt: raw.checkedAt,
    identity: raw.identity, binary: raw.binary, authHome: raw.authHome, version: raw.version,
    capability: { model: p.model, effort: p.effort }, quota: { scope: 'codex', windows },
    digest: hash({ identity: raw.identity, model: model[0], limit, checkedAt: raw.checkedAt }) };
}
function wrapperEvidence(p, now = Date.now()) {
  const lookup = spawnSync('sh', ['-c', 'command -v -- "$1"', 'wrapper-lookup', p.harness], { encoding: 'utf8', timeout: 5000 });
  const found = lookup.status === 0 ? String(lookup.stdout || '').split('\n').map(l => l.trim()).filter(Boolean)[0] : '';
  if (!found) return reject(p, 'wrapper_not_installed');
  let binary = found;
  try { binary = fs.realpathSync(found); } catch { return reject(p, 'wrapper_not_installed'); }
  const list = spawnSync(binary, ['--list-models'], { encoding: 'utf8', timeout: 10000 });
  if (list.error || list.signal != null) return reject(p, 'wrapper_probe_failed');
  if (list.status !== 0) {
    if (p.model !== 'default') return reject(p, 'wrapper_model_unlisted');
    const identity = hash({ binary, models: null });
    return { candidate: p.id, viable: true, source: 'wrapper-pinned', checkedAt: now,
      identity, binary, authHome: null,
      capability: { model: p.model, effort: p.effort }, quota: { scope: 'wrapper', windows: [] },
      digest: hash({ identity, checkedAt: now }) };
  }
  const aliases = String(list.stdout || '').split('\n').map(l => l.trim()).filter(Boolean)
    .map(l => l.split(/\s+/)[0]).filter(a => token(a));
  if (!aliases.length) return reject(p, 'wrapper_probe_failed');
  if (aliases.length === 1) {
    if (p.model !== 'default') return reject(p, 'wrapper_model_pinned_use_default');
  } else if (p.model !== 'default' && !aliases.includes(p.model)) return reject(p, 'wrapper_model_unlisted');
  const identity = hash({ binary, models: aliases });
  return { candidate: p.id, viable: true, source: 'wrapper-list-models', checkedAt: now,
    identity, binary, authHome: null,
    capability: { model: p.model, effort: p.effort }, quota: { scope: 'wrapper', windows: [] },
    digest: hash({ identity, checkedAt: now }) };
}
async function probe(pool) {
  let native;
  const results = [];
  for (const p of pool) {
    if (p.carrier === 'codex-native' && p.harness === 'codex' && p.provider === 'openai' && p.authCarrier === 'codex-chatgpt') {
      if (!native) { try { native = await codexProbe(); } catch (e) { native = { error: e.message }; } }
      results.push(native.error ? reject(p, native.error) : codexEvidence(p, native));
    } else if (p.carrier === 'claude-opencode-muse') {
      results.push(reject(p, 'opencode_go_quota_and_upstream_max_attestation_unqualified'));
    } else if (['gemini_worker_high', 'luna_worker_max'].includes(p.carrier)) {
      results.push(reject(p, 'lawful_managed_routing_projection_producer_unavailable'));
    } else if (p.carrier === 'claude-native') {
      results.push(reject(p, 'claude_live_model_effort_and_account_bound_quota_unqualified'));
    } else if (p.carrier === 'wrapper') {
      results.push(wrapperEvidence(p));
    } else results.push(reject(p, 'unsupported_carrier_tuple'));
  }
  return results;
}
function weighted(pool, viable, before) {
  const next = {}, eligible = pool.filter(p => viable.includes(p.id));
  requireThat(eligible.length > 0, 'zero_viable_candidates');
  let winner, total = 0;
  for (const p of pool) {
    next[p.id] = eligible.includes(p) ? (Object.hasOwn(before, p.id) ? before[p.id] : 0) + p.weight : 0;
    if (eligible.includes(p)) {
      total += p.weight;
      if (!winner || next[p.id] > next[winner.id]) winner = p;
    }
  }
  next[winner.id] -= total;
  return { candidate: winner, next };
}
function metadata(state, task) {
  const file = path.join(state, `${task}.meta`);
  if (!fs.existsSync(file)) return null;
  const st = fs.lstatSync(file);
  requireThat(st.isFile() && !st.isSymbolicLink(), 'unsafe_task_metadata');
  const fields = {};
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const pos = line.indexOf('='); if (pos < 0) continue;
    const key = line.slice(0, pos);
    requireThat(!Object.hasOwn(fields, key), 'duplicate_task_metadata');
    fields[key] = line.slice(pos + 1);
  }
  return fields;
}
function terminalEvidence(file, prior, state, task) {
  const canonical = fs.realpathSync(file);
  requireThat(canonical.startsWith(fs.realpathSync(state) + path.sep), 'terminal_evidence_outside_state');
  const event = read(canonical), meta = metadata(state, task);
  requireThat(event.schemaVersion === 1 && event.task === task && event.generation === prior.generation && event.candidate === prior.candidate.id && event.receipt === prior.id, 'terminal_evidence_identity_mismatch');
  requireThat(event.provider === prior.candidate.provider && event.authIdentity === prior.evidence.identity && event.terminal === true && event.kind === 'quota_exhausted', 'terminal_quota_evidence_required');
  requireThat(typeof event.observedAt === 'number' && Date.now() - event.observedAt >= 0 && Date.now() - event.observedAt <= 300000, 'terminal_evidence_stale');
  requireThat(event.spawnGeneration === meta?.spawn_gen && token(event.spawnGeneration), 'terminal_spawn_generation_mismatch');
  requireThat(object(event.nativeEvent) && event.nativeEvent.method === 'error' && event.nativeEvent.params?.willRetry === false && event.nativeEvent.params?.error?.codexErrorInfo === 'usageLimitExceeded' && typeof event.nativeEvent.params.threadId === 'string', 'native_terminal_quota_event_required');
  // No current TUI adapter produces this binding: real unbound events refuse.
  requireThat(meta.native_thread_id && event.nativeEvent.params.threadId === meta.native_thread_id, 'native_thread_binding_unavailable');
  return { source: canonical, digest: hash(event), event: {
    task, generation: event.generation, candidate: event.candidate, receipt: event.receipt,
    provider: event.provider, authIdentity: event.authIdentity, spawnGeneration: event.spawnGeneration,
    kind: event.kind, terminal: true, observedAt: event.observedAt,
    nativeThreadId: event.nativeEvent.params.threadId, code: 'usageLimitExceeded',
  } };
}
async function main() {
  const [command, configPath, state, task, poolName, mode = 'fresh', eventPath] = process.argv.slice(2);
  if (command === 'validate') { config(configPath); return { ok: true }; }
  if (command === 'default') {
    if (!fs.existsSync(configPath)) return { pool: '' };
    return { pool: config(configPath).defaults[task === 'secondmate' ? 'secondmate' : 'crewmate'] || '' };
  }
  if (command === 'probe') {
    const c = config(configPath), pool = c.pools[poolName];
    requireThat(Array.isArray(pool), 'unknown_pool');
    return { pool: poolName, configDigest: hash(c), candidates: await probe(pool) };
  }
  const stateStat = fs.lstatSync(state);
  requireThat(stateStat.isDirectory() && !stateStat.isSymbolicLink() && !(stateStat.mode & 0o022), 'unsafe_state_directory');
  const stateFile = path.join(state, 'dispatch-pools.json');
  // ponytail: one atomic home record; split immutable receipts only if measured history size makes admission slow.
  const db = fs.existsSync(stateFile) ? read(stateFile) : { schemaVersion: 1, pools: {}, receipts: [], events: [] };
  requireThat(db.schemaVersion === 1 && object(db.pools) && Array.isArray(db.receipts) && Array.isArray(db.events), 'invalid_pool_state');
  requireThat(Object.values(db.pools).every(scores => object(scores) && Object.values(scores).every(Number.isSafeInteger)), 'invalid_selection_state');
  if (command === 'inspect') return db;
  requireThat(token(task), 'invalid_task');
  if (command === 'finish') {
    const r = db.receipts.find(r => r.id === poolName && r.task === task);
    requireThat(r && ['launched', 'failed'].includes(mode), 'invalid_route_finish');
    if (r.status !== mode) {
      requireThat(r.status !== 'launched', 'launched_route_cannot_be_failed');
      r.status = mode; db.events.push({ type: mode, receipt: r.id, at: Date.now() }); write(stateFile, db);
    }
    return r;
  }
  if (command === 'bind') {
    const r = db.receipts.find(r => r.id === poolName && r.task === task);
    const meta = metadata(state, task);
    requireThat(r && meta?.route_receipt === r.id && String(r.generation) === meta.route_generation && meta.route_candidate === r.candidate.id && meta.spawn_gen === mode, 'notification_generation_mismatch');
    let event;
    try { event = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { throw new Error('notification_malformed'); }
    requireThat(event.type === 'agent-turn-complete' && token(event['thread-id']) && token(event['turn-id']) && typeof event.cwd === 'string', 'notification_identity_missing');
    requireThat(fs.realpathSync(event.cwd) === fs.realpathSync(meta.worktree), 'notification_worktree_mismatch');
    requireThat(!r.nativeThread || r.nativeThread.id === event['thread-id'], 'notification_thread_changed');
    r.nativeThread = { source: 'codex-notify', id: event['thread-id'], turnId: event['turn-id'], spawnGeneration: mode, boundAt: Date.now() };
    db.events.push({ type: 'native_thread_bound', receipt: r.id, binding: r.nativeThread });
    write(stateFile, db);
    const marker = path.join(state, `${task}.turn-ended`);
    if (fs.existsSync(marker)) requireThat(fs.lstatSync(marker).isFile() && !fs.lstatSync(marker).isSymbolicLink(), 'unsafe_turnend_marker');
    fs.closeSync(fs.openSync(marker, 'a', 0o600));
    const now = new Date(); fs.utimesSync(marker, now, now);
    return { ok: true, receipt: r.id, binding: r.nativeThread };
  }
  if (command === 'verify') {
    const r = db.receipts.find(r => r.id === poolName && r.task === task);
    requireThat(r && r.status !== 'launched', 'route_not_pending');
    const c = config(configPath);
    requireThat(hash(c) === r.configDigest, 'route_config_changed');
    const e = (await probe([r.candidate]))[0];
    requireThat(e.viable && e.identity === r.evidence.identity && e.authHome === r.evidence.authHome && e.binary === r.evidence.binary, 'route_no_longer_viable_or_identity_changed');
    db.events.push({ type: 'verified', receipt: r.id, evidence: e, at: Date.now() });
    write(stateFile, db);
    return r;
  }
  const c = config(configPath), pool = c.pools[poolName];
  requireThat(Array.isArray(pool), 'unknown_pool');
  requireThat(command === 'reserve' && ['fresh', 'pinned', 'exhausted', 'replay'].includes(mode), 'invalid_pool_operation');
  const meta = metadata(state, task);
  const prior = meta?.route_receipt ? db.receipts.find(r => r.id === meta.route_receipt && r.task === task) : null;
  if (mode === 'fresh') requireThat(!meta, 'existing_task_pinned');
  else requireThat(prior && prior.pool === poolName && String(prior.generation) === meta.route_generation && prior.candidate.id === meta.route_candidate, 'prior_route_identity_mismatch');
  const generation = prior ? prior.generation + (mode === 'replay' ? 0 : 1) : 1;
  const configDigest = hash(c), existing = db.receipts.find(r => r.task === task && r.generation === generation);
  if (existing) requireThat(existing.pool === poolName && existing.configDigest === configDigest && existing.status !== 'launched', 'route_replay_conflict');
  const terminal = mode === 'exhausted' ? terminalEvidence(eventPath, prior, state, task) : null;
  const evidence = await probe(pool);
  let viable = evidence.filter(e => e.viable).map(e => e.candidate);
  if (terminal) viable = viable.filter(id => id !== prior.candidate.id);
  const poolKey = `${poolName}:${hash(pool)}`;
  const before = db.pools[poolKey] || {};
  let picked;
  if (existing || (prior && mode !== 'exhausted')) {
    const pinned = existing || prior;
    const same = pool.find(p => hash(p) === hash(pinned.candidate));
    requireThat(same && viable.includes(same.id), 'pinned_candidate_not_viable');
    picked = { candidate: same, next: before };
  } else if (viable.length) picked = weighted(pool, viable, before);
  db.events.push({ type: terminal ? 'terminal_quota_exhausted' : 'admission', task, generation, pool: poolName, configDigest, evidence, terminal, at: Date.now(), selected: picked?.candidate.id || null });
  if (!picked) { write(stateFile, db); throw new Error('zero_viable_candidates'); }
  const chosenEvidence = evidence.find(e => e.candidate === picked.candidate.id);
  if (existing) {
    requireThat(existing.evidence.identity === chosenEvidence.identity, 'route_replay_auth_changed');
    db.events.push({ type: 'replay', receipt: existing.id, at: Date.now() });
    write(stateFile, db); return existing;
  }
  const r = { id: hash({ state: fs.realpathSync(state), task, generation, configDigest }), task, generation,
    pool: poolName, configDigest, candidate: picked.candidate, evidence: chosenEvidence,
    previous: before, next: picked.next, previousReceipt: prior?.id || null,
    status: 'reserved', at: Date.now(), terminal };
  db.pools[poolKey] = picked.next; db.receipts.push(r); write(stateFile, db);
  return r;
}
if (require.main === module) main().then(r => process.stdout.write(JSON.stringify(r) + '\n')).catch(e => {
  process.stderr.write(`error: dispatch pool: ${e.message}\n`); process.exitCode = 1;
});
module.exports = { config, codexProbe, codexEvidence, weighted };
