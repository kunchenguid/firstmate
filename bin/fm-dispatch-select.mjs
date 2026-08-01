#!/usr/bin/env node
// Resolve one already-matched set of comparable crew-dispatch candidates.
//
// Usage:
//   fm-dispatch-select.mjs select [--quota-json <file>] [--now <epoch>] [<json>]
//   fm-dispatch-select.mjs record-failure --provider <claude|codex|grok> --task <id> [--now <epoch>]
//   fm-dispatch-select.mjs clear --provider <claude|codex|grok>
//
// `select` accepts a full rule object with `use`, one profile object, or a
// non-empty profile array on the command line or stdin. It prints exactly one
// compact profile JSON object on stdout. Diagnostics are sanitized summaries on
// stderr; quota payloads and harness output are never printed.
//
// The caller owns natural-language rule matching, task fit, reasoning class,
// model support discovery, and provider identity for non-native adapters. This
// script owns only subscription readiness and deterministic distribution:
//
// - Native claude, codex, and grok profiles resolve to their same-named provider.
//   Other harnesses need an explicit `provider` field.
// - Providers exposed by quota-axi, including Claude, Codex, and Grok, require
//   fresh telemetry no older than the configured maximum. Their tightest
//   reported live percentage must remain strictly above the configured reserve.
//   Stale, absent, malformed, or
//   windowless telemetry makes that provider ineligible; it never falls back to
//   an unmetered guess.
// - Kimi is deliberately unsupported by this selector: its 0.29.1 lifecycle
//   exit could not be made deterministic after interrupt in the guarded Herdr
//   lab. Explicit Kimi work remains outside automatic subscription dispatch.
// - Rate-limit or quota-exhaustion evidence creates a provider cooldown.
//   `record-failure` verifies the evidence in the named task's status file and
//   verifies that task's recorded routing provider before changing state.
// - Eligible providers rotate by least-recent selection. Hash ordering breaks a
//   never-used tie independently of candidate array order, then persisted
//   last-use state gives exact round-robin behavior while the eligible set is
//   stable. Profiles within one provider rotate the same way.
// - State updates are serialized by a private mkdir lock and published through
//   rename. No task is selected when every candidate is unavailable.
//
// config/crew-dispatch.json may contain this optional settings object:
//   "subscriptionRouting": {
//     "reservePercent": 20,
//     "telemetryMaxAgeSeconds": 300,
//     "cooldownSeconds": 1800
//   }
// The defaults above are used when the object or a field is absent. Exact schema
// validation is shared with bootstrap. FM_HOME must be explicit so routing state
// can never land in the wrong Firstmate home.
//
// Test-only seams:
//   --quota-json reads a fixture instead of running quota-axi.
//   --now fixes the current epoch second.
//   FM_DISPATCH_QUOTA_AXI overrides the quota-axi executable.
//   FM_DISPATCH_STATE_FILE overrides the state path.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const PROVIDERS = new Set(['claude', 'codex', 'grok']);
const VERIFIED_HARNESSES = new Set(['claude', 'codex', 'opencode', 'pi', 'pi-signed', 'grok', 'kimi', 'cline', 'cursor-agent', 'copilot', 'agy']);
const NATIVE_PROVIDER = new Map([
  ['claude', 'claude'],
  ['codex', 'codex'],
  ['grok', 'grok'],
]);
const DEFAULTS = Object.freeze({
  reservePercent: 20,
  telemetryMaxAgeSeconds: 300,
  cooldownSeconds: 1800,
});
const LIMITS = Object.freeze({
  reservePercent: [0, 99],
  telemetryMaxAgeSeconds: [1, 3600],
  cooldownSeconds: [60, 86400],
});
const RATE_LIMIT_RE = /rate[ _-]?limit|too many requests|(?:quota|usage)[^\n]{0,80}(?:exhaust|limit|deplet)|(?:exhaust|deplet)[^\n]{0,80}(?:quota|usage)/i;

class CliError extends Error {
  constructor(message, code = 2) {
    super(message);
    this.code = code;
  }
}

function die(message, code = 2) {
  throw new CliError(message, code);
}

function log(message) {
  process.stderr.write(`fm-dispatch-select: ${message}\n`);
}

function usage() {
  const source = fs.readFileSync(new URL(import.meta.url), 'utf8');
  const lines = source.split('\n').slice(1);
  for (const line of lines) {
    if (!line.startsWith('//')) break;
    process.stderr.write(`${line.replace(/^\/\/? ?/, '')}\n`);
  }
}

function parseArgs(argv) {
  const command = argv[0]?.startsWith('-') || argv.length === 0 ? 'select' : argv.shift();
  const options = { command, positional: [] };
  while (argv.length) {
    const arg = argv.shift();
    if (arg === '--help' || arg === '-h') {
      usage();
      process.exit(0);
    }
    if (['--quota-json', '--now', '--provider', '--task'].includes(arg)) {
      if (!argv.length) die(`${arg} requires a value`);
      options[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv.shift();
    } else if (arg === '--') {
      options.positional.push(...argv);
      break;
    } else if (arg.startsWith('-')) {
      die(`unknown option ${arg}`);
    } else {
      options.positional.push(arg);
    }
  }
  return options;
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    die(`${label} is missing, unreadable, or malformed`);
  }
}

function explicitHome() {
  const home = process.env.FM_HOME;
  if (!home) die('FM_HOME must be explicit');
  try {
    return fs.realpathSync(home);
  } catch {
    die(`FM_HOME is not a readable directory: ${home}`);
  }
}

function operationalPaths(home) {
  const stateDir = process.env.FM_STATE_OVERRIDE || path.join(home, 'state');
  const configDir = process.env.FM_CONFIG_OVERRIDE || path.join(home, 'config');
  const stateFile = process.env.FM_DISPATCH_STATE_FILE || path.join(stateDir, '.dispatch-routing.json');
  return { stateDir, configDir, stateFile, lockDir: `${stateFile}.lock` };
}

function settingsFromConfig(configDir) {
  const file = path.join(configDir, 'crew-dispatch.json');
  if (!fs.existsSync(file)) return { ...DEFAULTS };
  const root = readJson(file, 'config/crew-dispatch.json');
  const configured = root.subscriptionRouting ?? {};
  if (!configured || Array.isArray(configured) || typeof configured !== 'object') {
    die('config/crew-dispatch.json subscriptionRouting must be an object');
  }
  const settings = { ...DEFAULTS };
  for (const [key, value] of Object.entries(configured)) {
    if (!(key in LIMITS)) die(`config/crew-dispatch.json subscriptionRouting has unknown field: ${key}`);
    const [min, max] = LIMITS[key];
    if (!Number.isInteger(value) || value < min || value > max) {
      die(`config/crew-dispatch.json subscriptionRouting.${key} must be an integer from ${min} to ${max}`);
    }
    settings[key] = value;
  }
  return settings;
}

function emptyState() {
  return {
    version: 1,
    sequence: 0,
    lastSelected: {},
    profileLastSelected: {},
    cooldowns: {},
  };
}

function loadState(file) {
  if (!fs.existsSync(file)) return emptyState();
  const state = readJson(file, 'dispatch routing state');
  if (!state || state.version !== 1 || !Number.isInteger(state.sequence) || state.sequence < 0) {
    die('dispatch routing state has an unsupported or malformed schema');
  }
  for (const key of ['lastSelected', 'profileLastSelected', 'cooldowns']) {
    if (!state[key] || Array.isArray(state[key]) || typeof state[key] !== 'object') {
      die(`dispatch routing state has malformed ${key}`);
    }
  }
  return state;
}

function saveState(file, state) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temp = `${file}.tmp.${process.pid}.${crypto.randomBytes(4).toString('hex')}`;
  fs.writeFileSync(temp, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temp, file);
}

function acquireLock(lockDir) {
  fs.mkdirSync(path.dirname(lockDir), { recursive: true, mode: 0o700 });
  const deadline = Date.now() + 5000;
  while (true) {
    try {
      fs.mkdirSync(lockDir, { mode: 0o700 });
      fs.writeFileSync(path.join(lockDir, 'owner'), `${process.pid}\n`, { mode: 0o600 });
      return () => fs.rmSync(lockDir, { recursive: true, force: true });
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (Date.now() >= deadline) {
        let owner = null;
        try {
          owner = Number(fs.readFileSync(path.join(lockDir, 'owner'), 'utf8').trim());
          if (Number.isInteger(owner) && owner > 1) process.kill(owner, 0);
        } catch (error) {
          if (owner && error.code === 'ESRCH') {
            fs.rmSync(lockDir, { recursive: true, force: true });
            continue;
          }
        }
        die('routing state lock remained busy for 5 seconds', 3);
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
}

function profileProvider(profile) {
  return profile.provider || NATIVE_PROVIDER.get(profile.harness) || null;
}

function cleanProfile(profile, provider) {
  return {
    harness: profile.harness,
    provider,
    ...(profile.model ? { model: profile.model } : {}),
    ...(profile.effort ? { effort: profile.effort } : {}),
  };
}

function parseProfiles(input) {
  let value;
  try {
    value = JSON.parse(input);
  } catch {
    die('dispatch input is malformed JSON');
  }
  if (value && !Array.isArray(value) && typeof value === 'object' && Object.hasOwn(value, 'use')) value = value.use;
  if (!Array.isArray(value)) value = [value];
  if (!value.length) die('dispatch profile array must not be empty');
  const seen = new Set();
  return value.map((raw) => {
    if (!raw || Array.isArray(raw) || typeof raw !== 'object') die('each dispatch profile must be an object');
    if (typeof raw.harness !== 'string' || !raw.harness) die('each dispatch profile needs a non-empty harness');
    for (const field of ['provider', 'model', 'effort']) {
      if (Object.hasOwn(raw, field) && (typeof raw[field] !== 'string' || !raw[field])) {
        die(`dispatch profile ${field} must be a non-empty string when present`);
      }
    }
    if (!VERIFIED_HARNESSES.has(raw.harness)) {
      die(`subscription dispatch requires a verified harness, not ${raw.harness}`);
    }
    if (raw.harness === 'kimi') die('Kimi is unsupported for subscription dispatch');
    const nativeProvider = NATIVE_PROVIDER.get(raw.harness);
    if (nativeProvider && raw.provider && raw.provider !== nativeProvider) {
      die(`native harness ${raw.harness} requires provider ${nativeProvider}`);
    }
    const provider = profileProvider(raw);
    if (!provider || !PROVIDERS.has(provider)) {
      die(`provider identity is unresolved or unsupported for harness ${raw.harness}`);
    }
    const profile = cleanProfile(raw, provider);
    const identity = JSON.stringify({ ...profile, provider });
    if (seen.has(identity)) die('dispatch profile array contains a duplicate concrete profile');
    seen.add(identity);
    return { profile, provider, identity, key: digest(identity) };
  });
}

function digest(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function parseNow(raw) {
  if (raw === undefined) return Math.floor(Date.now() / 1000);
  if (!/^\d+$/.test(raw)) die('--now must be a non-negative epoch second');
  return Number(raw);
}

function readQuota(options) {
  let text;
  if (options.quotaJson) {
    try {
      text = fs.readFileSync(options.quotaJson, 'utf8');
    } catch {
      return { available: false, reason: 'quota fixture unreadable' };
    }
  } else {
    const executable = process.env.FM_DISPATCH_QUOTA_AXI || 'quota-axi';
    const result = spawnSync(executable, ['--json'], {
      encoding: 'utf8',
      timeout: 15000,
      maxBuffer: 4 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (result.error || result.status !== 0) return { available: false, reason: 'quota-axi unavailable' };
    text = result.stdout;
  }
  try {
    const data = JSON.parse(text);
    if (!data || !Array.isArray(data.providers)) throw new Error('shape');
    return { available: true, data };
  } catch {
    return { available: false, reason: 'quota telemetry malformed' };
  }
}

function quotaCandidate(providerName, quota, now, settings) {
  if (!quota.available) return { eligible: false, reason: quota.reason };
  const generated = Date.parse(quota.data.generatedAt || '');
  const age = Number.isFinite(generated) ? now - Math.floor(generated / 1000) : Number.POSITIVE_INFINITY;
  if (age < -60 || age > settings.telemetryMaxAgeSeconds) {
    return { eligible: false, reason: 'quota telemetry stale or undated' };
  }
  const provider = quota.data.providers.find((item) => item?.provider === providerName);
  if (!provider) return { eligible: false, reason: 'provider telemetry unavailable' };
  if (provider.state?.status !== 'fresh' || provider.state?.stale === true) {
    const evidence = `${provider.state?.status || ''} ${provider.state?.error || ''}`;
    return { eligible: false, reason: RATE_LIMIT_RE.test(evidence) ? 'provider quota/rate-limit evidence' : 'provider telemetry not fresh', cooldownEvidence: RATE_LIMIT_RE.test(evidence) };
  }
  const livePercentages = [];
  for (const window of provider.windows || []) {
    if (typeof window?.percentRemaining === 'number' && window.percentRemaining >= 0 && window.percentRemaining <= 100) {
      livePercentages.push(window.percentRemaining);
    }
  }
  if (!livePercentages.length) return { eligible: false, reason: 'provider telemetry has no usable live window percentage' };
  const values = [...livePercentages];
  for (const availability of provider.quotaSemantics?.effectiveAvailability || []) {
    if (availability?.status === 'known' && typeof availability.effectivePercentRemaining === 'number' && availability.effectivePercentRemaining >= 0 && availability.effectivePercentRemaining <= 100) {
      values.push(availability.effectivePercentRemaining);
    }
  }
  if (!values.length) return { eligible: false, reason: 'provider telemetry has no usable live percentage' };
  const headroom = Math.min(...values);
  if (headroom <= settings.reservePercent) {
    return { eligible: false, reason: `headroom ${headroom}% is at or below ${settings.reservePercent}% reserve`, headroom };
  }
  return { eligible: true, reason: `fresh quota headroom=${headroom}% reserve=${settings.reservePercent}%`, headroom };
}

function cooldownActive(state, provider, now) {
  const item = state.cooldowns[provider];
  return item && Number.isInteger(item.until) && item.until > now ? item : null;
}

function setCooldown(state, provider, reason, now, seconds) {
  state.cooldowns[provider] = { until: now + seconds, reason, recordedAt: now };
}

function tieKey(home, value) {
  return digest(`${home}\0${value}`);
}

function selectLeastRecent(items, lastUsed, home, identity) {
  return [...items].sort((a, b) => {
    const aLast = lastUsed[identity(a)] || 0;
    const bLast = lastUsed[identity(b)] || 0;
    if (aLast !== bLast) return aLast - bLast;
    return tieKey(home, identity(a)).localeCompare(tieKey(home, identity(b)));
  })[0];
}

function inputText(options) {
  if (options.positional.length > 1) die('expected at most one JSON argument');
  if (options.positional.length === 1) return options.positional[0];
  return fs.readFileSync(0, 'utf8');
}

function select(options, home, paths, settings, now, state) {
  const candidates = parseProfiles(inputText(options));
  const quota = readQuota(options);
  const byProvider = new Map();
  for (const candidate of candidates) {
    if (!byProvider.has(candidate.provider)) byProvider.set(candidate.provider, []);
    byProvider.get(candidate.provider).push(candidate);
  }

  const eligibleProviders = [];
  for (const [provider, providerCandidates] of byProvider) {
    const cooldown = cooldownActive(state, provider, now);
    if (cooldown) {
      log(`candidate provider=${provider} unavailable: cooldown until epoch ${cooldown.until}`);
      continue;
    }
    const readiness = quotaCandidate(provider, quota, now, settings);
    if (readiness.cooldownEvidence) setCooldown(state, provider, 'quota-telemetry-evidence', now, settings.cooldownSeconds);
    log(`candidate provider=${provider} ${readiness.eligible ? 'eligible' : 'unavailable'}: ${readiness.reason}`);
    if (readiness.eligible) eligibleProviders.push({ provider, candidates: providerCandidates });
  }
  if (!eligibleProviders.length) {
    saveState(paths.stateFile, state);
    die('no subscription candidate has current dispatch capacity evidence', 3);
  }

  const providerGroup = selectLeastRecent(eligibleProviders, state.lastSelected, home, (item) => item.provider);
  const candidate = selectLeastRecent(providerGroup.candidates, state.profileLastSelected, home, (item) => item.key);
  state.sequence += 1;
  state.lastSelected[providerGroup.provider] = state.sequence;
  state.profileLastSelected[candidate.key] = state.sequence;
  saveState(paths.stateFile, state);
  log(`selection provider=${providerGroup.provider} basis=least-recent eligible subscription sequence=${state.sequence}`);
  process.stdout.write(`${JSON.stringify(candidate.profile)}\n`);
}

function taskMetaProvider(paths, task) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(task)) die('task id has an unsafe shape');
  const metaFile = path.join(paths.stateDir, `${task}.meta`);
  const statusFile = path.join(paths.stateDir, `${task}.status`);
  let meta;
  let status;
  try {
    meta = fs.readFileSync(metaFile, 'utf8');
    status = fs.readFileSync(statusFile, 'utf8');
  } catch {
    die('record-failure requires readable task meta and status evidence');
  }
  const entries = new Map(meta.split('\n').map((line) => {
    const index = line.indexOf('=');
    return index < 0 ? [line, ''] : [line.slice(0, index), line.slice(index + 1)];
  }));
  const harness = entries.get('harness');
  const provider = entries.get('provider') || NATIVE_PROVIDER.get(harness);
  if (!provider || !PROVIDERS.has(provider)) die('record-failure requires a recorded claude, codex, or grok routing provider');
  const nativeProvider = NATIVE_PROVIDER.get(harness);
  if (nativeProvider && provider !== nativeProvider) die(`task ${task} has mismatched native harness and provider metadata`);
  if (harness === 'kimi') die('record-failure does not support Kimi tasks');
  if (!RATE_LIMIT_RE.test(status)) die('task status contains no rate-limit or quota-exhaustion evidence');
  return provider;
}

function recordFailure(options, paths, settings, now, state) {
  if (!options.provider || !PROVIDERS.has(options.provider)) die('record-failure needs --provider claude, codex, or grok');
  if (!options.task) die('record-failure needs --task');
  const actual = taskMetaProvider(paths, options.task);
  if (actual !== options.provider) die(`task ${options.task} is recorded on provider ${actual}, not ${options.provider}`);
  setCooldown(state, options.provider, 'verified-task-rate-limit-or-quota-evidence', now, settings.cooldownSeconds);
  saveState(paths.stateFile, state);
  log(`provider=${options.provider} cooldown recorded until epoch ${state.cooldowns[options.provider].until}`);
}

function clearProvider(options, paths, state) {
  if (!options.provider || !PROVIDERS.has(options.provider)) die('clear needs --provider claude, codex, or grok');
  delete state.cooldowns[options.provider];
  saveState(paths.stateFile, state);
  log(`provider=${options.provider} cooldown cleared`);
}

try {
  const options = parseArgs(process.argv.slice(2));
  if (!['select', 'record-failure', 'clear'].includes(options.command)) die(`unknown command ${options.command}`);
  const home = explicitHome();
  const paths = operationalPaths(home);
  const settings = settingsFromConfig(paths.configDir);
  const now = parseNow(options.now);
  const unlock = acquireLock(paths.lockDir);
  try {
    const state = loadState(paths.stateFile);
    if (options.command === 'select') select(options, home, paths, settings, now, state);
    else if (options.command === 'record-failure') recordFailure(options, paths, settings, now, state);
    else clearProvider(options, paths, state);
  } finally {
    unlock();
  }
} catch (error) {
  if (error instanceof CliError) {
    process.stderr.write(`fm-dispatch-select: ${error.message}\n`);
    process.exitCode = error.code;
  } else {
    process.stderr.write('fm-dispatch-select: unexpected internal failure\n');
    process.exitCode = 1;
  }
}
