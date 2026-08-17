#!/usr/bin/env bash
# Own durable routing cooldowns created by provider refusals or measured quota exhaustion.
# Usage: fm-quota-cooldown.sh record --scope <model-family|provider> --provider <name> [--harness <name> --model-family <name>] --evidence-kind <provider-refusal|quota-axi> --evidence <quote> --expires-at <zone-qualified ISO-8601>
#        fm-quota-cooldown.sh authorize --harness <name> [--provider <name>] [--model-family <name>] [--task-id <id> --override-reason <captain instruction>]
#        fm-quota-cooldown.sh list --json
#        fm-quota-cooldown.sh recover
#
# The canonical file is data/quota-cooldowns.json under FM_HOME, or under
# FM_DATA_OVERRIDE for isolated callers. Only this script writes it. A record is
# keyed by its exact proven scope and stores the evidence quote, evidence kind,
# recorded-at instant, provider-supplied expiry, and any explicit captain
# overrides. Re-recording the same scope replaces its prior entry, including an
# expired one, so repeated refusals publish the provider's new reset date without
# growing an incident log forever.
#
# Model-family scope is deliberately explicit: deterministic shell never derives
# family or provider from a model name. Callers pass the harness, provider, and
# catalog-established family. Provider scope omits harness and family and is valid
# only when the supplied evidence proves the whole provider window exhausted.
#
# Harness, provider, and model-family names are trimmed and case-folded before
# they are stored, keyed, and compared, because the recording moment and the
# dispatch moment are different callers reading the same vendor catalog: without
# one canonical form, `Cursor` at record time and `cursor` at dispatch time would
# be two scopes, which silently fails OPEN inside a fail-closed guard. That is
# canonicalization of a name the caller already established, never derivation of
# a family or provider from a model name.
#
# An unparseable or unsupported store makes every command refuse, because
# suppression cannot be proven from bytes this script cannot read; `recover` is
# the only way out and is deliberately narrow. It refuses a store that still
# validates, renames the invalid bytes beside the file as
# quota-cooldowns.json.corrupt.<recorded instant> for diagnosis, durably writes an
# empty store, and reports that every still-active cooldown must be recorded again
# from its provider evidence. It never edits or drops an individual entry.
#
# Every instant this script accepts or stores must be a zone-qualified ISO-8601
# value (2026-09-14T00:00:00Z, 2026-09-14T02:00:00+02:00) or a bare YYYY-MM-DD
# date, which is UTC. A local-time or locale-dependent form such as 9/14/2026 or
# 2026-09-14T00:00:00 is refused, because storing it would silently shift the
# provider's reset by the recording machine's timezone offset.
#
# `authorize` considers only records whose expires_at is later than the current
# instant. An explicit override is evaluated FIRST: it requires both --task-id and
# --override-reason, exits 0, and appends that departure to every active record it
# can identify as an exact match, so a captain is never blocked by an axis the
# automatic path would have demanded. Automatic selection instead exits 3 on an
# exact match, and missing scope axes fail closed for it whenever an active record
# could match; unrelated or expired entries are inert either way.
# FM_QUOTA_COOLDOWN_NOW is a test-only fixed ISO-8601 clock.
# Oracle-strength evidence for the suppression predicate lives in
# docs/verification/quota-cooldowns.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FILE="$DATA/quota-cooldowns.json"

case "${1:-}" in
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  record|authorize|list|recover) COMMAND=$1; shift ;;
  *) echo "error: expected record, authorize, list, recover, or --help" >&2; exit 2 ;;
esac

# Mutating commands hold the shared fm-wake-lib lock in this shell for the whole
# writer run: that helper owns portable stale-owner recovery, and a lock taken
# inside the node writer would survive every refusal, because process.exit skips
# a JavaScript finally.
LOCK="$FILE.lock"
LOCK_HELD=0

release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  LOCK_HELD=0
  fm_lock_release "$LOCK"
}

needs_lock=0
case "$COMMAND" in
  record|recover) needs_lock=1 ;;
  authorize)
    for token in "$@"; do
      case "$token" in
        --task-id|--task-id=*|--override-reason|--override-reason=*) needs_lock=1 ;;
      esac
    done
    ;;
esac

if [ "$needs_lock" -eq 1 ]; then
  [ -d "$DATA" ] || (umask 077; mkdir -p "$DATA")
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  trap release_lock EXIT
  fm_lock_acquire_wait "$LOCK"
  LOCK_HELD=1
fi

node - "$FILE" "$COMMAND" "$@" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const file = process.argv[2];
const command = process.argv[3];
const rawArgs = process.argv.slice(4);

function fail(message, code = 2) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(code);
}

function parseArgs(args) {
  const result = {};
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (!token.startsWith('--')) fail(`unexpected argument: ${token}`);
    if (token.includes('=')) {
      const split = token.indexOf('=');
      const key = token.slice(2, split);
      const value = token.slice(split + 1);
      if (!key || !value) fail(`${token.slice(0, split)} requires a non-empty value`);
      if (Object.hasOwn(result, key)) fail(`--${key} was passed more than once`);
      result[key] = value;
      continue;
    }
    const key = token.slice(2);
    const value = args[index + 1];
    if (key === 'json' && (value === undefined || value.startsWith('--'))) {
      if (Object.hasOwn(result, key)) fail('--json was passed more than once');
      result[key] = true;
      continue;
    }
    if (!key || value === undefined || value.startsWith('--')) fail(`--${key} requires a value`);
    if (Object.hasOwn(result, key)) fail(`--${key} was passed more than once`);
    result[key] = value;
    index += 1;
  }
  return result;
}

function allowOnly(args, allowed) {
  for (const key of Object.keys(args)) {
    if (!allowed.includes(key)) fail(`--${key} is not valid for ${command}`);
  }
}

function required(args, key) {
  if (!args[key]) fail(`--${key} requires a non-empty value`);
  return args[key];
}

const ISO_8601 = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:\d{2}))?$/;

// Axis identity is compared, keyed, and stored in one canonical form. Trimming
// and case-folding a name the caller already established is not the model-name
// derivation this script forbids: it never maps a model to a family or provider.
function canonical(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

function axis(args, key) {
  const value = canonical(required(args, key));
  if (!value) fail(`--${key} requires a non-empty value`);
  return value;
}

function isInstant(value) {
  return typeof value === 'string' && ISO_8601.test(value) && Number.isFinite(new Date(value).getTime());
}

function instant(value, label) {
  if (!value) fail(`${label} requires a non-empty ISO-8601 value`);
  if (typeof value !== 'string' || !ISO_8601.test(value)) {
    fail(`${label} must be a zone-qualified ISO-8601 instant (2026-09-14T00:00:00Z or 2026-09-14T02:00:00+02:00) or a YYYY-MM-DD date, not a local or locale-dependent form: ${value}`);
  }
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) fail(`${label} is not a valid ISO-8601 instant: ${value}`);
  return parsed;
}

function now() {
  return instant(process.env.FM_QUOTA_COOLDOWN_NOW || new Date().toISOString(), 'FM_QUOTA_COOLDOWN_NOW');
}

function emptyStore() {
  return {schema_version: 1, cooldowns: []};
}

function loadStore() {
  if (!fs.existsSync(file)) return {store: emptyStore()};
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) return {issue: `${file} must be a regular non-symlink file`};
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return {issue: `could not parse ${file}: ${error.message}`};
  }
  if (!parsed || parsed.schema_version !== 1 || !Array.isArray(parsed.cooldowns)) {
    return {issue: `${file} does not have the supported schema_version 1 cooldown list`};
  }
  for (const entry of parsed.cooldowns) {
    const issue = entryIssue(entry);
    if (issue) return {issue};
  }
  return {store: parsed};
}

function readStore() {
  const loaded = loadStore();
  if (loaded.issue) {
    fail(`${loaded.issue}; inspect that file, then quarantine it with fm-quota-cooldown.sh recover and re-record every still-active cooldown from its provider evidence`);
  }
  return loaded.store;
}

function entryIssue(entry) {
  if (!entry || typeof entry !== 'object' || typeof entry.id !== 'string') return `${file} contains an invalid cooldown entry`;
  if (!entry.scope || !['model-family', 'provider'].includes(entry.scope.kind)) return `${file} contains an invalid cooldown scope`;
  if (typeof entry.scope.provider !== 'string' || !canonical(entry.scope.provider)) return `${file} contains a cooldown without provider`;
  if (entry.scope.kind === 'model-family') {
    if (typeof entry.scope.harness !== 'string' || !canonical(entry.scope.harness) ||
        typeof entry.scope.model_family !== 'string' || !canonical(entry.scope.model_family)) {
      return `${file} contains a model-family cooldown without harness and model_family`;
    }
  }
  if (!entry.evidence || !['provider-refusal', 'quota-axi'].includes(entry.evidence.kind) ||
      typeof entry.evidence.quote !== 'string' || !entry.evidence.quote) {
    return `${file} contains invalid cooldown evidence`;
  }
  if (!isInstant(entry.recorded_at)) return `${file} contains a cooldown without a zone-qualified ISO-8601 recorded_at`;
  if (!isInstant(entry.expires_at)) return `${file} contains a cooldown without a zone-qualified ISO-8601 expires_at`;
  if (!Array.isArray(entry.overrides)) return `${file} contains invalid cooldown overrides`;
  return null;
}

function writeStore(store) {
  const directory = path.dirname(file);
  const temporary = `${file}.tmp.${process.pid}.${crypto.randomBytes(6).toString('hex')}`;
  const body = `${JSON.stringify(store, null, 2)}\n`;
  try {
    fs.mkdirSync(directory, {recursive: true, mode: 0o700});
    let handle = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
    try {
      fs.writeSync(handle, body, null, 'utf8');
      fs.fsyncSync(handle);
    } finally {
      fs.closeSync(handle);
    }
    fs.renameSync(temporary, file);
    fs.chmodSync(file, 0o600);
    handle = fs.openSync(directory, fs.constants.O_RDONLY);
    try {
      fs.fsyncSync(handle);
    } finally {
      fs.closeSync(handle);
    }
  } catch (error) {
    try {
      fs.unlinkSync(temporary);
    } catch (cleanupError) {
      if (cleanupError.code !== 'ENOENT') {
        fail(`could not write ${file}: ${error.message}; also could not remove ${temporary}: ${cleanupError.message}`);
      }
    }
    fail(`could not write ${file}: ${error.message}`);
  }
}

function scopeKey(scope) {
  return JSON.stringify([
    scope.kind,
    canonical(scope.provider),
    canonical(scope.harness) || null,
    canonical(scope.model_family) || null,
  ]);
}

function active(entry, at) {
  return instant(entry.expires_at, 'expires_at').getTime() > at.getTime();
}

function relation(entry, candidate) {
  const provider = canonical(entry.scope.provider);
  if (entry.scope.kind === 'provider') {
    if (!candidate.provider) return 'unknown';
    return provider === candidate.provider ? 'match' : 'different';
  }
  if (!candidate.harness || canonical(entry.scope.harness) !== candidate.harness) return 'different';
  if (candidate.provider && provider !== candidate.provider) return 'different';
  if (!candidate.provider || !candidate.modelFamily) return 'unknown';
  return canonical(entry.scope.model_family) === candidate.modelFamily ? 'match' : 'different';
}

const args = parseArgs(rawArgs);

if (command === 'record') {
  allowOnly(args, ['scope', 'provider', 'harness', 'model-family', 'evidence-kind', 'evidence', 'expires-at']);
  const kind = required(args, 'scope');
  if (!['model-family', 'provider'].includes(kind)) fail('--scope must be model-family or provider');
  const provider = axis(args, 'provider');
  const evidenceKind = required(args, 'evidence-kind');
  if (!['provider-refusal', 'quota-axi'].includes(evidenceKind)) {
    fail('--evidence-kind must be provider-refusal or quota-axi');
  }
  const evidence = required(args, 'evidence');
  const expiresAt = instant(required(args, 'expires-at'), '--expires-at').toISOString();
  let scope;
  if (kind === 'model-family') {
    scope = {
      kind,
      provider,
      harness: axis(args, 'harness'),
      model_family: axis(args, 'model-family'),
    };
  } else {
    if (args.harness || args['model-family']) fail('provider scope must not carry --harness or --model-family');
    scope = {kind, provider};
  }
  const recordedAt = now().toISOString();
  const id = `qcd_${crypto.createHash('sha256').update(scopeKey(scope)).digest('hex').slice(0, 24)}`;
  const store = readStore();
  const entry = {
    id,
    scope,
    evidence: {kind: evidenceKind, quote: evidence},
    recorded_at: recordedAt,
    expires_at: expiresAt,
    overrides: [],
  };
  const existing = store.cooldowns.findIndex((item) => scopeKey(item.scope) === scopeKey(scope));
  if (existing === -1) store.cooldowns.push(entry);
  else store.cooldowns[existing] = entry;
  writeStore(store);
  process.stdout.write(`recorded ${id} expires ${expiresAt}\n`);
  process.exit(0);
}

if (command === 'list') {
  allowOnly(args, ['json']);
  if (args.json !== true && args.json !== 'true') fail('list requires --json');
  const store = readStore();
  process.stdout.write(`${JSON.stringify(store)}\n`);
  process.exit(0);
}

if (command === 'recover') {
  allowOnly(args, []);
  const loaded = loadStore();
  if (!loaded.issue) {
    fail(`${file} is a valid cooldown store; recover only quarantines a store this script has proven invalid, so it never discards live suppressions`);
  }
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail(`${file} is not a regular non-symlink file; inspect and clear that path by hand before recovering the store`);
  }
  let quarantine = `${file}.corrupt.${now().toISOString().replace(/[:.]/g, '-')}`;
  while (fs.existsSync(quarantine)) quarantine = `${file}.corrupt.${crypto.randomBytes(6).toString('hex')}`;
  try {
    fs.renameSync(file, quarantine);
  } catch (error) {
    fail(`could not quarantine ${file}: ${error.message}`);
  }
  writeStore(emptyStore());
  process.stdout.write(`quarantined ${quarantine} after: ${loaded.issue}\n`);
  process.stdout.write(`${file} is now an empty store, so every still-active cooldown must be recorded again from its provider evidence\n`);
  process.exit(0);
}

allowOnly(args, ['harness', 'provider', 'model-family', 'task-id', 'override-reason']);
for (const key of ['provider', 'model-family']) {
  if (args[key] !== undefined && !canonical(args[key])) fail(`--${key} requires a non-empty value`);
}
const candidate = {
  harness: axis(args, 'harness'),
  provider: canonical(args.provider),
  modelFamily: canonical(args['model-family']),
};
const overrideSet = args['task-id'] !== undefined || args['override-reason'] !== undefined;
if (overrideSet && (!args['task-id'] || !args['override-reason'])) {
  fail('an override requires both --task-id and --override-reason');
}

const store = readStore();
const at = now();
const applicable = store.cooldowns.filter((entry) => active(entry, at));
const matched = applicable.filter((entry) => relation(entry, candidate) === 'match');
const unknown = applicable.filter((entry) => relation(entry, candidate) === 'unknown');

if (overrideSet) {
  const overrideAt = at.toISOString();
  for (const entry of matched) {
    entry.overrides.push({
      recorded_at: overrideAt,
      task_id: args['task-id'],
      reason: args['override-reason'],
    });
  }
  if (matched.length > 0) {
    writeStore(store);
    process.stdout.write(`routing cooldown overridden for ${matched.map((entry) => entry.id).join(',')}\n`);
  }
  process.exit(0);
}

if (unknown.length > 0) {
  const axes = [];
  if (!candidate.provider) axes.push('--provider (fm-spawn.sh: --dispatch-provider)');
  if (!candidate.modelFamily && unknown.some((entry) => entry.scope.kind === 'model-family')) {
    axes.push('--model-family (fm-spawn.sh: --dispatch-model-family)');
  }
  fail(`active routing cooldown could match; automatic selection requires ${axes.join(' and ')} from the catalog-established tuple, or an explicit captain --task-id and --override-reason`, 3);
}

if (matched.length === 0) process.exit(0);

const refused = matched[0];
process.stderr.write(`error: routing cooldown active for ${scopeKey(refused.scope)} until ${refused.expires_at}; automatic selection refused; evidence: ${refused.evidence.quote}\n`);
process.exit(3);
NODE
