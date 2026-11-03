#!/usr/bin/env bash
# Behavior tests for bin/fm-task.sh, the one writer and reader of the task contract.
#
# Every case drives the real command against a local stand-in for Dev 5001 (a small
# HTTP server in tests/fm-task-fake-api). The stand-in applies the rules the published tables
# carry: required and length rules on a root row and on each deep-insert child,
# unique keys answering 409 with details.existingId, a missing int stored as 0,
# server values, an undeclared verb answering 404, and OData $filter/$orderby/$top.
# It also counts requests, so a case can show that an event and its child travel in one.
# The same command runs against the real 5001 on probe rows for the scenario proofs
# (tr10 to tr15); that run is recorded with the delivery, not repeated here.
#
# Each case takes a bin directory. The mutation proofs at the end copy the command,
# remove one guard, and show the case that guards it go red.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { printf 'skip - node is not installed\n'; exit 0; }
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'

TMP_ROOT=$(fm_test_tmproot fm-task)
mkdir -p "$TMP_ROOT/fakebin"
# Every case runs under a temporary home: a write that keeps the legacy status file must never reach the caller's own
# FM_HOME. The caller's state/ listing is taken now and checked after the cases.
LIVE_HOME=${FM_HOME:-}
LIVE_STATE_BEFORE="$TMP_ROOT/live-state-before"
if [ -n "$LIVE_HOME" ] && [ -d "$LIVE_HOME/state" ]; then (cd "$LIVE_HOME/state" && find . -mindepth 1 -maxdepth 1) | sort > "$LIVE_STATE_BEFORE"; fi
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state"
live_home_untouched() {  # fail when the caller's state/ holds a file it did not hold before the cases ran
  [ -f "$LIVE_STATE_BEFORE" ] || return 0
  local added
  added=$( (cd "$LIVE_HOME/state" && find . -mindepth 1 -maxdepth 1) | sort | comm -13 "$LIVE_STATE_BEFORE" -)
  [ -z "$added" ] || fail "a case wrote into the caller's FM_HOME state/: $(tr '\n' ' ' <<<"$added")"
  pass "fm-task leaves the caller's FM_HOME state/ unchanged"
}
TOKEN="tok-$$-$RANDOM"
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"
chmod 600 "$TMP_ROOT/token"

# ---- the stand-in for Dev 5001 ------------------------------------------------

cat > "$TMP_ROOT/schema.json" <<'JSON'
{"fm_task":{"ops":["list","get","create","patch"],"f":{"assignee":{"t":"s","m":64},"blockKind":{"t":"s","n":1,"m":32},"blockReason":{"t":"s","n":1,"m":2000},"blockRepeats":{"t":"i"},"createdAt":{"t":"d","sv":"now"},"createdBy":{"t":"s","m":64,"sv":"callerId"},"holdUntil":{"t":"d","n":1},"issueUrl":{"t":"s","n":1,"m":2048},"kind":{"t":"s","m":32},"lastSeq":{"t":"i"},"nextActor":{"t":"s","m":32},"prUrl":{"t":"s","n":1,"m":2048},"repo":{"t":"s","n":1,"m":200},"state":{"t":"s","m":32},"surface":{"t":"s","n":1,"m":32},"taskId":{"t":"s","m":128},"title":{"t":"s","m":300}},"u":[["taskId"]]},"fm_task_event":{"ops":["list","get","create"],"f":{"actor":{"t":"s","m":64},"actorRole":{"t":"s","m":32},"body":{"t":"s","m":8000},"createdAt":{"t":"d","sv":"now"},"createdBy":{"t":"s","m":64,"sv":"callerId"},"idempotencyKey":{"t":"s","m":200},"kind":{"t":"s","m":32},"seq":{"t":"i"},"taskId":{"t":"s","m":128}},"u":[["seq"],["idempotencyKey"]]},"fm_event_done":{"ops":["list","get","create"],"f":{"changedFiles":{"t":"s","m":4000},"head":{"t":"s","n":1,"m":64},"prUrl":{"t":"s","n":1,"m":2048},"residualRisk":{"t":"s","m":2000},"rows":{"t":"s"},"summary":{"t":"s","m":4000},"verification":{"t":"s","m":4000}},"u":[["fmTaskEventId"]],"parent":["fmTaskEvent","done"]},"fm_event_question":{"ops":["list","get","create"],"f":{"document":{"t":"s","n":1,"m":2048},"options":{"t":"s","m":8000},"question":{"t":"s","m":2000},"recommendation":{"t":"s","m":2000},"why":{"t":"s","m":4000}},"u":[["fmTaskEventId"]],"parent":["fmTaskEvent","question"]},"fm_event_block":{"ops":["list","get","create"],"f":{"blockKind":{"t":"s","m":32},"nextActor":{"t":"s","m":32},"reason":{"t":"s","m":2000},"until":{"t":"d","n":1}},"u":[["fmTaskEventId"]],"parent":["fmTaskEvent","block"]},"fm_event_image":{"ops":["list","get","create"],"f":{"content":{"t":"s"},"label":{"t":"s","m":200},"mediaType":{"t":"s","m":32},"position":{"t":"i","n":1}},"u":[],"parent":["fmTaskEvent","images"]},"fm_task_check":{"ops":["list","get","create","patch"],"f":{"acceptanceDigest":{"t":"s","m":128},"checkedAt":{"t":"d","n":1},"controls":{"t":"s","m":2000},"data":{"t":"s","m":2000},"evidence":{"t":"s","n":1,"m":4000},"head":{"t":"s","n":1,"m":64},"line":{"t":"s","m":4000},"nextActor":{"t":"s","m":32},"page":{"t":"s","m":200},"proof":{"t":"s","m":4000},"scenarioId":{"t":"s","m":64},"status":{"t":"s","m":32},"surface":{"t":"s","m":32},"taskId":{"t":"s","m":128},"width":{"t":"s","m":32}},"u":[["taskId","scenarioId","width"]]},"fm_owner_check":{"ops":["list","get","create","patch"],"f":{"data":{"t":"s","m":4000},"decidedAt":{"t":"d","n":1},"expected":{"t":"s","m":4000},"note":{"t":"s","n":1,"m":4000},"pageTitle":{"t":"s","m":200},"scenarioId":{"t":"s","m":64},"status":{"t":"s","m":16},"steps":{"t":"s","m":8000},"taskId":{"t":"s","m":128},"url":{"t":"s","m":2048},"width":{"t":"s","m":32}},"u":[["taskId","scenarioId","width"]]},"fm_task_link":{"ops":["list","get","create","delete"],"f":{"childTaskId":{"t":"s","m":128},"parentTaskId":{"t":"s","m":128}},"u":[["parentTaskId","childTaskId"]]},"fm_task_delivery":{"ops":["list","get","create"],"f":{"consumer":{"t":"s","m":64},"deliveredAt":{"t":"d","sv":"now"},"seq":{"t":"i"}},"u":[["consumer","seq"]]}}
JSON
node - "$TMP_ROOT/schema.json" <<'JS'
const fs = require('fs');
const file = process.argv[2]; const s = JSON.parse(fs.readFileSync(file));
s.fm_event_document = {ops:['list','get','create'],f:{title:{t:'s',m:200},mediaType:{t:'s',m:100},content:{t:'s'}},u:[['fmTaskEventId']],parent:['fmTaskEvent','documents']};
s.fm_event_video = {ops:['list','get','create','delete'],f:{label:{t:'s',m:200},mediaType:{t:'s',m:32},size:{t:'i'},content:{t:'s'}},u:[],parent:['fmTaskEvent','videos']};
s.fm_model_rule = {ops:['list','get','create','patch','delete'],f:{state:{t:'s',n:1,m:16},harness:{t:'s',n:1,m:32},model:{t:'s',n:1,m:128},effort:{t:'s',n:1,m:16},rank:{t:'i',n:1},account:{t:'s',n:1,m:64},hours:{t:'s',n:1,m:64},scope:{t:'s',n:1,m:200},enabled:{t:'b',n:1},warning:{t:'s',n:1,m:200},note:{t:'s',n:1,m:300}},u:[]};
Object.assign(s.fm_task.f, {backlogHome:{t:'s',n:1,m:64},row:{t:'s',n:1},notes:{t:'s',n:1},section:{t:'s',n:1,m:32},
  stage:{t:'s',n:1,m:16},stageSince:{t:'d',n:1},lastEventAt:{t:'d',n:1},lastNote:{t:'s',n:1,m:300},reviewer:{t:'s',n:1,m:64},
  planSeq:{t:'i',n:1},planDecision:{t:'s',n:1,m:16},planDecidedAt:{t:'d',n:1}});
Object.assign(s.fm_task.f, Object.fromEntries(['workflowState','stepHarness','stepModel','stepEffort','stepAlive','setupBy'].map(k => [k,{t:'s',n:1}])));
Object.assign(s.fm_task.f, {workflowSince:{t:'d',n:1},setupAt:{t:'d',n:1}});
s.fm_task_step = {ops:['list','get','create','patch','delete'],u:[['taskId','state']],f:{taskId:{t:'s'},state:{t:'s'},position:{t:'i'},attempt:{t:'i'},status:{t:'s'},...Object.fromEntries(['harness','model','effort','fallbacks','source','ruleIds','account','alive','endReason'].map(k=>[k,{t:'s',n:1}])),...Object.fromEntries(['startedAt','lastHeartbeatAt','endedAt'].map(k=>[k,{t:'d',n:1}]))}};
fs.writeFileSync(file, JSON.stringify(s));
JS

cat > "$TMP_ROOT/fake-api.mjs" <<'JS'
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';

const [portFile, schemaFile, token] = process.argv.slice(2);
const SCHEMA = JSON.parse(fs.readFileSync(schemaFile, 'utf8'));
const camel = (s) => s.split('_').map((p, i) => (i ? p[0].toUpperCase() + p.slice(1) : p)).join('');
const pascal = (s) => s[0].toUpperCase() + s.slice(1);
const db = {};
const NAVS = {};
for (const table of Object.keys(SCHEMA)) db[table] = [];
for (const [table, def] of Object.entries(SCHEMA)) {
  if (!def.parent) continue;
  const parent = Object.keys(SCHEMA).find((t) => camel(t) === def.parent[0]);
  (NAVS[parent] ||= {})[def.parent[1]] = table;
}
let log = [];
let rivals = 0;
let lose = { mode: '', n: 0 };
let delay = { table: '', ms: 0, n: 0, verb: 'patch' };

const reply = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(body === undefined ? '' : JSON.stringify(body));
};
const refusal = (status, errorCode, message, details = null) => ({ status, body: { success: false, data: null, errorCode, message, details } });

function normalize(table, body, partial) {
  const errors = {};
  const row = {};
  for (const [name, f] of Object.entries(SCHEMA[table].f)) {
    const present = Object.prototype.hasOwnProperty.call(body, name);
    if (f.sv) {
      if (present) errors[pascal(name)] = 'INVALID_WRITE';
      continue;
    }
    if (!present) {
      if (partial) continue;
      if (f.t === 'i') row[name] = 0;
      else if (f.n) row[name] = null;
      else errors[pascal(name)] = `The ${pascal(name)} field is required.`;
      continue;
    }
    const v = body[name];
    if (v === null) {
      if (f.n) row[name] = null;
      else errors[pascal(name)] = `The ${pascal(name)} field is required.`;
      continue;
    }
    if (f.t === 's' && typeof v !== 'string') errors[pascal(name)] = `The ${pascal(name)} field must be a string.`;
    else if (f.t === 'i' && !Number.isInteger(v)) errors[pascal(name)] = `The ${pascal(name)} field must be an integer.`;
    else if (f.t === 'd' && Number.isNaN(Date.parse(v))) errors[pascal(name)] = `The ${pascal(name)} field must be a date.`;
    else if (f.m && typeof v === 'string' && v.length > f.m) errors[pascal(name)] = `The field ${pascal(name)} must be a string with a maximum length of ${f.m}.`;
    else row[name] = v;
  }
  return { errors, row };
}

function conflict(table, row, exceptId) {
  for (const group of SCHEMA[table].u) {
    const hit = db[table].find((r) => r.id !== exceptId && group.every((k) => r[k] === row[k]));
    if (hit) return refusal(409, 'UNIQUE_KEY_CONFLICT', `A ${table} row with the same (${group.join(', ')}) already exists.`, { key: group, existingId: hit.id });
  }
  return null;
}

function create(table, body) {
  const { errors, row } = normalize(table, body, false);
  const children = [];
  for (const [nav, childTable] of Object.entries(NAVS[table] || {})) {
    if (body[nav] === undefined) continue;
    if (!Array.isArray(body[nav])) {
      errors[pascal(nav)] = 'must be an array';
      continue;
    }
    body[nav].forEach((child, i) => {
      const n = normalize(childTable, child, false);
      for (const [k, v] of Object.entries(n.errors)) errors[`${pascal(nav)}[${i}].${k}`] = v;
      children.push([childTable, n.row]);
    });
  }
  if (Object.keys(errors).length) return refusal(400, 'VALIDATION_ERROR', 'One or more validation errors occurred.', errors);
  const clash = conflict(table, row, null);
  if (clash) return clash;
  const id = crypto.randomUUID();
  const stored = { id, ...row };
  for (const [name, f] of Object.entries(SCHEMA[table].f)) {
    if (f.sv === 'now') stored[name] = new Date().toISOString();
    if (f.sv === 'callerId') stored[name] = 'caller-1';
  }
  db[table].push(stored);
  for (const [childTable, childRow] of children) {
    const child = { id: crypto.randomUUID(), ...childRow, fmTaskEventId: id };
    for (const [name, f] of Object.entries(SCHEMA[childTable].f)) if (f.sv === 'now') child[name] = new Date().toISOString();
    db[childTable].push(child);
  }
  return { status: 201, body: { success: true, data: stored, errorCode: null, message: null, details: null } };
}

function patch(table, id, body) {
  const target = db[table].find((r) => r.id === id);
  if (!target) return refusal(404, 'NOT_FOUND', `${table} ${id} not found.`);
  const { errors, row } = normalize(table, body, true);
  if (Object.keys(errors).length) return refusal(400, 'VALIDATION_ERROR', 'One or more validation errors occurred.', errors);
  const next = { ...target, ...row };
  const clash = conflict(table, next, id);
  if (clash) return clash;
  Object.assign(target, row);
  return { status: 200, body: { success: true, data: target, errorCode: null, message: null, details: null } };
}

const literal = (text) => {
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text)) return { guid: text };
  if (/^'.*'$/s.test(text)) return text.slice(1, -1).replaceAll("''", "'");
  if (text === 'true') return true;
  if (text === 'false') return false;
  if (text === 'null') return null;
  return Number(text);
};

function list(table, query) {
  let rows = db[table];
  const filter = query.get('$filter');
  if (filter) {
    for (const clause of filter.split(/ and /)) {
      const m = /^(\w+) (eq|ne|gt|ge|lt|le) (.+)$/s.exec(clause.trim());
      if (!m || !(m[1] in SCHEMA[table].f || m[1] === 'id' || m[1] === 'fmTaskEventId')) return refusal(400, 'INVALID_QUERY', `Could not find a property named '${m ? m[1] : clause}' on type ${table}.`);
      let want = literal(m[3]);
      const isGuid = m[1] === 'id' || m[1] === 'fmTaskEventId';
      // the real API types these two as Edm.Guid: a quoted string is refused, a bare guid is the only literal
      if (isGuid !== (typeof want === 'object' && want !== null)) return refusal(400, 'INVALID_QUERY', `A binary operator with incompatible types was detected on '${m[1]}'.`);
      if (isGuid) want = want.guid;
      const op = { eq: (a) => a === want, ne: (a) => a !== want, gt: (a) => a > want, ge: (a) => a >= want, lt: (a) => a < want, le: (a) => a <= want }[m[2]];
      rows = rows.filter((r) => op(r[m[1]]));
    }
  }
  const order = query.get('$orderby');
  if (order) {
    const [field, dir] = order.split(' ');
    rows = [...rows].sort((a, b) => (a[field] > b[field] ? 1 : a[field] < b[field] ? -1 : 0) * (dir === 'desc' ? -1 : 1));
  }
  const top = query.has('$top') ? Number(query.get('$top')) : 100;
  if (top > 100) return refusal(400, 'INVALID_QUERY', `The limit of '100' for Top query has been exceeded. The value from the incoming request is '${top}'.`);
  const skip = Number(query.get('$skip') || 0);
  let sliced = rows.slice(skip, skip + top);
  const sel = query.get('$select');
  if (sel) {
    const fields = sel.split(',').map((s) => s.trim()).filter(Boolean);
    sliced = sliced.map((r) => Object.fromEntries(fields.filter((f) => f in r).map((f) => [f, r[f]])));
  }
  const out = { value: sliced };
  if (query.get('$count') === 'true') out['@odata.count'] = rows.length;
  return { status: 200, body: out };
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const url = new URL(req.url, 'http://x');
    const raw = Buffer.concat(chunks).toString('utf8');
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[0] === '__x') {
      if (parts[1] === 'rows') return reply(res, 200, db[parts[2]] || []);
      if (parts[1] === 'log') {
        if (req.method === 'POST') log = [];
        return reply(res, 200, log);
      }
      if (parts[1] === 'rival') {
        rivals = Number(url.searchParams.get('n') || 0);
        return reply(res, 200, { rivals });
      }
      if (parts[1] === 'lose') {
        lose = { mode: url.searchParams.get('mode') || '', n: Number(url.searchParams.get('n') || 1) };
        return reply(res, 200, lose);
      }
      if (parts[1] === 'delay') {
        delay = { table: parts[2], ms: Number(url.searchParams.get('ms') || 0), n: Number(url.searchParams.get('n') || 1), verb: url.searchParams.get('verb') || 'patch' };
        return reply(res, 200, delay);
      }
      if (parts[1] === 'drop') {
        db[parts[2]] = db[parts[2]].filter((r) => r.id !== parts[3]);
        return reply(res, 200, {});
      }
      if (parts[1] === 'reset') {
        for (const t of Object.keys(db)) db[t] = [];
        log = [];
        rivals = 0;
        lose = { mode: '', n: 0 };
        delay = { table: '', ms: 0, n: 0, verb: 'patch' };
        return reply(res, 200, {});
      }
      return reply(res, 404);
    }
    let body = {};
    try {
      body = raw ? JSON.parse(raw) : {};
    } catch {
      return reply(res, 400, { success: false, errorCode: 'INVALID_JSON' });
    }
    log.push({ method: req.method, path: url.pathname, body });
    const bearer = req.headers.authorization === `Bearer ${token}`;
    const cookie = /(?:^|;\s*)cfw\.auth\.session=([^;]*)/.exec(req.headers.cookie || '')?.[1] === token;
    if (!bearer && !cookie) return reply(res, 401, { success: false, data: null, errorCode: 'API_REQUIRES_SIGN_IN', message: 'requires a signed-in caller' });
    const [api, table, id] = parts;
    if (api !== 'api' || !SCHEMA[table]) return reply(res, 404);
    const verb = { GET: id ? 'get' : 'list', POST: 'create', PATCH: 'patch', DELETE: 'delete' }[req.method];
    if (!verb || !SCHEMA[table].ops.includes(verb)) return reply(res, 404);
    let out;
    if (verb === 'list' && delay.n > 0 && delay.verb === 'list' && delay.table === table) {
      // the read is held before it is answered, so a later call can finish first
      delay.n--;
      return setTimeout(() => {
        const late = list(table, url.searchParams);
        reply(res, late.status, late.body);
      }, delay.ms);
    }
    if (verb === 'list') out = list(table, url.searchParams);
    else if (verb === 'get') {
      const row = db[table].find((r) => r.id === id);
      out = row ? { status: 200, body: { success: true, data: row } } : refusal(404, 'NOT_FOUND', 'not found');
    } else if (verb === 'patch') {
      if (delay.n > 0 && delay.verb === 'patch' && delay.table === table) {
        // the patch is held before it is applied, so a later call can finish first
        delay.n--;
        return setTimeout(() => {
          const late = patch(table, id, body);
          reply(res, late.status, late.body);
        }, delay.ms);
      }
      out = patch(table, id, body);
    }
    else if (verb === 'delete') {
      db[table] = db[table].filter((r) => r.id !== id);
      return reply(res, 204);
    } else {
      if (table === 'fm_task_event' && lose.n > 0 && lose.mode === 'before') {
        lose.n--;
        return reply(res, 503, { success: false, errorCode: 'UNAVAILABLE' });
      }
      if (table === 'fm_task_event' && rivals > 0) {
        rivals--;
        const top = Math.max(0, ...db.fm_task_event.map((r) => r.seq));
        create('fm_task_event', { seq: top + 1, taskId: 'rival', kind: 'comment', actorRole: 'system', actor: 'rival', body: '{}', idempotencyKey: `rival-${crypto.randomUUID()}` });
      }
      out = create(table, body);
      if (table === 'fm_task_event' && lose.n > 0 && lose.mode === 'after') {
        lose.n--;
        return reply(res, 503, { success: false, errorCode: 'UNAVAILABLE' });
      }
    }
    return reply(res, out.status, out.body);
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(server.address().port)));
const parent = process.ppid;
setInterval(() => {
  try {
    process.kill(parent, 0);
  } catch {
    process.exit(0);
  }
}, 1000).unref();
setTimeout(() => process.exit(0), 20 * 60 * 1000).unref();
JS

cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = issue ] && [ "${2:-}" = view ] && [ "${4:-}" = --json ] && [ "${5:-}" = body ] || exit 2
jq -Rs '{body: .}' "$FAKE_GH_BODY_FILE"
SH
chmod +x "$TMP_ROOT/fakebin/gh"

node "$TMP_ROOT/fake-api.mjs" "$TMP_ROOT/port" "$TMP_ROOT/schema.json" "$TOKEN" &
for _ in $(seq 1 100); do [ -s "$TMP_ROOT/port" ] && break; sleep 0.1; done
[ -s "$TMP_ROOT/port" ] || fail 'the stand-in API did not start'
PORT=$(cat "$TMP_ROOT/port")
BASE="http://127.0.0.1:$PORT"
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null; fm_test_cleanup' EXIT

export FM_TASK_BASE_URL="$BASE" FM_TASK_TOKEN_FILE="$TMP_ROOT/token" FM_TASK_ACTOR=tester-bot
export FM_ACCEPTANCE_GH="$TMP_ROOT/fakebin/gh" FAKE_GH_BODY_FILE="$TMP_ROOT/issue.body"
unset FM_TASK_AUTH FM_TASK_ROLE
ISSUE=https://github.com/example/repo/issues/1

# ---- helpers ----------------------------------------------------------------------

BIN=$ROOT/bin
OUT='' ERR='' RC=0

ft() {  # <args...>: run the command; OUT, ERR and RC hold its stdout, stderr and exit code
  OUT=$("$BIN/fm-task.sh" "$@" 2>"$TMP_ROOT/err")
  RC=$?
  ERR=$(cat "$TMP_ROOT/err")
  return "$RC"
}
db() { curl -s "$BASE/__x/rows/$1"; }                       # all rows of a table
api() { curl -s -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' "$@"; }
reset_db() { curl -s -X POST "$BASE/__x/reset" >/dev/null; }
posts() { curl -s "$BASE/__x/log" | jq --arg m "$1" --arg p "/api/$2" '[.[] | select(.method == $m and .path == $p)] | length'; }
log_reset() { curl -s -X POST "$BASE/__x/log" >/dev/null; }
task_row() { db fm_task | jq -c --arg t "$1" '.[] | select(.taskId == $t)'; }
task_state() { task_row "$1" | jq -r .state; }
count() { db "$1" | jq length; }
seq_of() { sed -n 's/^seq=\([0-9][0-9]*\).*/\1/p' <<<"$OUT" | head -1; }
must() {  # <label> <expected-rc>: the last ft call exited with the code
  [ "$RC" -eq "$2" ] || { echo "$1: exit $RC, want $2: out=[$OUT] err=[$ERR]"; return 1; }
}

DONE_FLAGS=(--summary 'Built it' --changed-files 'bin/fm-task.sh' --verification 'ran the tests' --residual-risk 'none known')
ASK_FLAGS=(--question 'Which one?' --option 'Option A' --option 'Option B' --recommendation 'Option A' --why 'Both work; A is simpler')

mk_ready() { ft create "$1" --title "Task $1" --kind ship --repo example/repo && ft assign "$1" --to worker-1; }
mk_running() { mk_ready "$1" && ft start "$1"; }
cl_off() {  # <task> <item>...: turn checklist items off, so a case about other rows can approve
  local t=$1 item; shift
  for item in "$@"; do ft checklist "$t" off "$item" --reason 'not this case' >/dev/null || return 1; done
}

test_steer_read_mark() {
  reset_db
  mk_running steer-probe || return 1
  ft event steer-probe steer --note 'read this' --key steer:steer-probe:001.msg || return 1
  local seq
  seq=$(seq_of)
  ft read-mark steer-probe --key steer:steer-probe:001.msg || return 1
  ft read-mark steer-probe --key steer:steer-probe:001.msg || return 1
  [ "$(db fm_task_delivery | jq --argjson seq "$seq" '[.[] | select(.consumer == "read:steer-probe" and .seq == $seq)] | length')" = 1 ] || return 1
  ft read-mark other-task --key steer:steer-probe:001.msg && return 1
  [ "$RC" = 2 ]
}

test_inbox_validation() {
  reset_db
  ft inbox not-a-uuid --action task
  [ "$RC" = 2 ] || return 1
  ft inbox 00000000-0000-0000-0000-000000000000 --action invalid
  [ "$RC" = 2 ] || return 1
  [ "$(count fm_task)" = 0 ] || return 1
  [ "$(count fm_task_event)" = 0 ]
}

test_inbox_validation || fail 'invalid inbox requests create no task or event'
pass 'invalid inbox requests create no task or event'

test_steer_read_mark || fail 'steer read mark is task-scoped and idempotent'
pass 'steer read mark is task-scoped and idempotent'

# ---- issue bodies for the rows cases ----------------------------------------------

scenario() {  # <id> <surface> <page> <widths> <line> <proof>
  printf -- '- [ ] %s %s\n' "$1" "$5"
  printf '  - page: %s\n  - widths: %s\n' "$3" "$4"
  if [ "$3" = - ]; then printf '  - controls: -\n'; else printf '  - controls: button "Save"; textbox "Name"\n'; fi
  printf '  - env: Dev 5001\n  - proof: %s\n  - data: the probe row\n  - mock: none\n  - surface: %s\n' "$6" "$2"
}
issue_body() {  # <variant>
  local a1_line='WHEN a user acts, THE page SHALL answer.' a1_w='1440, 390' a2_proof='read the row back' a4=0
  case $1 in
    v2) a1_line='WHEN a user acts, THE page SHALL answer fast.'; a2_proof='read the row back twice'; a4=1 ;;
    v3) a1_line='WHEN a user acts, THE page SHALL answer fast.'; a1_w='1440'; a2_proof='read the row back twice' ;;
    v4) a1_line='WHEN a user acts, THE page SHALL answer fast.'; a1_w='1440'; a2_proof='read the row back twice'; a4=1 ;;
    v5) a1_line='WHEN a user acts, THE page SHALL answer fast.'; a2_proof='read the row back twice' ;;
  esac
  printf '## Context\n\nc\n\n## Requirements\n\nr\n\n## Definition of done\n\nd\n\n## Scenarios\n\n'
  scenario A1 user-visible home "$a1_w" "$a1_line" 'click Save'
  scenario A2 internal - - 'WHEN the writer runs, THE row SHALL be stored.' "$a2_proof"
  scenario A3 internal - - 'WHEN the writer fails, THE row SHALL stay.' 'run it twice'
  [ "$a4" = 0 ] || scenario A4 internal - - 'WHEN the key repeats, THE first row SHALL return.' 'send twice'
  printf '\n## Mockup\n\nnone\n\n## Links\n\nl\n\n## Decisions\n\nx\n'
}
use_issue() { issue_body "$1" > "$TMP_ROOT/issue.body"; }

# ---- cases: each returns 0 when the behavior holds -------------------------------

# TR10: a terminal call stores its event and child in one request and prints the seq;
# a missing template field prints the API's field and stores nothing.
case_terminal() {
  BIN=$1; reset_db
  local badfile docs_before doc_id
  printf '# Report\nUnicode: café\n' > "$TMP_ROOT/report.md"
  printf '<!doctype html><script>window.proof=1</script>café' > "$TMP_ROOT/report.html"
  for badfile in "$TMP_ROOT/report.md" "$TMP_ROOT/report.html"; do
    mk_running doc-valid >/dev/null || return 1
    log_reset
    ft "done" doc-valid "${DONE_FLAGS[@]}" --document "$badfile"
    must 'document deep insert' 0 || return 1
    doc_id=$(db fm_task_event | jq -r --argjson seq "$(seq_of)" '.[] | select(.seq == $seq) | .id')
    db fm_event_document | jq -e --arg id "$doc_id" --rawfile content "$badfile" --arg title "$(basename "$badfile")" '.[] | select(.fmTaskEventId == $id) | .content == $content and .title == $title and (.mediaType == "text/markdown" or .mediaType == "text/html")' >/dev/null || { echo 'document differs from input bytes'; return 1; }
    [ "$(posts POST fm_task_event)" = 1 ] && [ "$(posts POST fm_event_document)" = 0 ] || return 1
    reset_db
  done
  printf '\377' > "$TMP_ROOT/latin.md"
  : > "$TMP_ROOT/empty.md"
  printf 'plain' > "$TMP_ROOT/wrong.txt"
  mk_running doc-refusal >/dev/null || return 1
  for badfile in "$TMP_ROOT/latin.md" "$TMP_ROOT/empty.md" "$TMP_ROOT/wrong.txt" "$TMP_ROOT/missing.md"; do
    ft "done" doc-refusal "${DONE_FLAGS[@]}" --document "$badfile"
    must 'invalid document' 2 || return 1
    [ "$(task_state doc-refusal)" = running ] || return 1
  done
  node -e 'require("fs").writeFileSync(process.argv[1], Buffer.alloc(2*1024*1024+1, 65))' "$TMP_ROOT/large.md"
  badfile="$TMP_ROOT/large.md"
    docs_before=$(count fm_task_event)
    ft "done" doc-refusal "${DONE_FLAGS[@]}" --document "$badfile"
    must 'oversize document' 2 || return 1
    [ "$(count fm_task_event)" = "$docs_before" ] || return 1
  for badfile in duplicate title-alone empty-title multiline-title; do
    docs_before=$(count fm_task_event)
    case "$badfile" in
      duplicate) ft "done" doc-refusal "${DONE_FLAGS[@]}" --document "$TMP_ROOT/report.md" --document "$TMP_ROOT/report.html" ;;
      title-alone) ft "done" doc-refusal "${DONE_FLAGS[@]}" --document-title title ;;
      empty-title) ft "done" doc-refusal "${DONE_FLAGS[@]}" --document "$TMP_ROOT/report.md" --document-title '' ;;
      multiline-title) ft "done" doc-refusal "${DONE_FLAGS[@]}" --document "$TMP_ROOT/report.md" --document-title $'two\nlines' ;;
    esac
    must 'document option refusal' 2 || return 1
    [ "$(count fm_task_event)" = "$docs_before" ] || return 1
  done
  reset_db
  export FM_HOME="$TMP_ROOT/terminal-home"
  mkdir -p "$FM_HOME/state"
  rm -f "$FM_HOME/state/tk10.status"
  local t=tk10 id seq child events dones before f field
  mk_running $t >/dev/null || { echo "setup: $ERR"; return 1; }
  log_reset
  ft "done" $t "${DONE_FLAGS[@]}" --pr-url https://example.com/pr/1 --head abc123
  must 'done' 0 || return 1
  grep -q '^done \[at=[0-9]*\]: PR https://example.com/pr/1 Built it' "$FM_HOME/state/tk10.status" || { echo 'done did not write legacy status'; return 1; }
  local parsed_pr
  parsed_pr=$(bash -c 'source "$1/fm-dod-lib.sh"; fm_dod_pr_url_from_done_note "$2"' _ "$ROOT/bin" "$(grep '^done ' "$FM_HOME/state/tk10.status" | tail -n 1 | cut -d: -f2- | sed 's/^ //')") || return 1
  [ "$parsed_pr" = https://example.com/pr/1 ] || { echo 'legacy PR parser lost URL'; return 1; }
  seq=$(seq_of); [ -n "$seq" ] || { echo "no seq printed: $OUT"; return 1; }
  id=$(db fm_task_event | jq -r --argjson s "$seq" '.[] | select(.seq == $s and .kind == "done" and .taskId == "tk10") | .id')
  [ -n "$id" ] || { echo "no done event at seq $seq"; return 1; }
  child=$(db fm_event_done | jq -c --arg id "$id" '.[] | select(.fmTaskEventId == $id)')
  jq -e '.summary == "Built it" and .changedFiles == "bin/fm-task.sh" and .verification == "ran the tests" and .residualRisk == "none known" and .prUrl == "https://example.com/pr/1" and .head == "abc123" and (.rows | type == "string")' <<<"$child" >/dev/null \
    || { echo "stored done child: $child"; return 1; }
  # two event requests: the done event with its child, then the merge wait a PR-ready done declares (HG1)
  [ "$(posts POST fm_task_event)" = 2 ] && [ "$(posts POST fm_event_done)" = 0 ] || { echo "the event and its child did not travel in one request"; return 1; }
  curl -s "$BASE/__x/log" | jq -e '[.[] | select(.method == "POST" and .path == "/api/fm_task_event")][0].body | (.done | length) == 1 and .seq == '"$seq" >/dev/null \
    || { echo "the event request does not carry the done child"; return 1; }
  [ "$(task_state $t)" = review ] || { echo "done did not move the task to review: $(task_state $t)"; return 1; }
  # TR32: a replayed stream and a fresh process do not enqueue twice.
  ft deliver tk10 --consumer test-firstmate
  must 'deliver events' 0 || return 1
  [ "$(count fm_task_delivery)" = 0 ] || { echo 'activation replayed historical events'; return 1; }
  ft comment tk10 --note 'event after activation'
  must 'new event' 0 || return 1
  ft deliver tk10 --consumer test-firstmate
  must 'deliver after activation' 0 || return 1
  local deliveries
  deliveries=$(count fm_task_delivery)
  [ "$deliveries" -gt 0 ] || { echo 'no delivery rows'; return 1; }
  local wake_rows
  wake_rows=$(wc -l < "$FM_HOME/state/.wake-queue")
  ft deliver tk10 --consumer test-firstmate
  must 'replay delivery' 0 || return 1
  [ "$(wc -l < "$FM_HOME/state/.wake-queue")" = "$wake_rows" ] || { echo 'replay duplicated wake rows'; return 1; }
  [ "$(count fm_task_delivery)" = "$deliveries" ] || { echo 'replay duplicated deliveries'; return 1; }
  # Every ft invocation starts a fresh process: this is a delivery restart.
  ft comment tk10 --note 'event after delivery restart'
  must 'new event after restart' 0 || return 1
  ft deliver tk10 --consumer test-firstmate
  must 'deliver new event after restart' 0 || return 1
  [ "$(wc -l < "$FM_HOME/state/.wake-queue")" -eq "$((wake_rows + 1))" ] || { echo 'restart did not queue exactly the new event'; return 1; }
  # TR31: a status line cannot satisfy a terminal call; a heartbeat is not terminal.
  mk_running tk31 >/dev/null || return 1
  printf 'done: legacy-only\n' > "$FM_HOME/state/tk31.status"
  ft turn-end tk31 --turn first
  must 'missed terminal' 0 || return 1
  [[ "$OUT" = *ping-1 ]] || { echo "expected ping-1: $OUT"; return 1; }
  local violations
  violations=$(db fm_task_event | jq '[.[] | select(.taskId == "tk31" and .kind == "protocol_violation")] | length')
  ft turn-end tk31 --turn first
  must 'same turn replay' 0 || return 1
  [ "$(db fm_task_event | jq '[.[] | select(.taskId == "tk31" and .kind == "protocol_violation")] | length')" = "$violations" ] || return 1
  ft turn-end tk31 --turn second
  must 'second missed terminal' 0 || return 1
  ft turn-end tk31 --turn third
  must 'third missed terminal' 0 || return 1
  db fm_task | jq -e '.[] | select(.taskId == "tk31") | .blockKind == "capability" and .nextActor == "firstmate" and .state == "blocked"' >/dev/null || return 1
  ft turn-end tk31 --turn fourth
  must 'fourth missed terminal' 0 || return 1
  [ "$(db fm_task_event | jq '[.[] | select(.taskId == "tk31" and .kind == "blocked")] | length')" = 1 ] || { echo 'capability block repeated'; return 1; }
  # ask: one request, options stored as a JSON list, the task waits on its next actor
  mk_running tk10a >/dev/null; log_reset
  ft ask tk10a "${ASK_FLAGS[@]}"
  must 'ask' 0 || return 1
  id=$(db fm_task_event | jq -r --argjson s "$(seq_of)" '.[] | select(.seq == $s and .kind == "needs-decision") | .id')
  [ -n "$id" ] || { echo "no needs-decision event"; return 1; }
  db fm_event_question | jq -e --arg id "$id" '.[] | select(.fmTaskEventId == $id) | .question == "Which one?" and (.options | fromjson) == ["Option A","Option B"] and .recommendation == "Option A" and .why == "Both work; A is simpler"' >/dev/null \
    || { echo "stored question child wrong"; return 1; }
  [ "$(posts POST fm_event_question)" = 0 ] || { echo "question child was posted on its own"; return 1; }
  [ "$(task_state tk10a)" = blocked ] || { echo "ask did not block the task"; return 1; }
  # block: one request, the child carries kind, reason, next actor and until
  mk_running tk10b >/dev/null; log_reset
  ft block transient tk10b --reason 'waiting for the deploy' --next-actor firstmate --until 2026-10-26T08:00:00Z
  must 'block' 0 || return 1
  id=$(db fm_task_event | jq -r --argjson s "$(seq_of)" '.[] | select(.seq == $s and .kind == "blocked") | .id')
  [ -n "$id" ] || { echo "no blocked event"; return 1; }
  db fm_event_block | jq -e --arg id "$id" '.[] | select(.fmTaskEventId == $id) | .blockKind == "transient" and .reason == "waiting for the deploy" and .nextActor == "firstmate" and (.until | startswith("2026-10-26T08:00:00"))' >/dev/null \
    || { echo "stored block child wrong"; return 1; }
  [ "$(posts POST fm_event_block)" = 0 ] || { echo "block child was posted on its own"; return 1; }
  # a missing template field: the API's field is printed, nothing is stored, the task stays
  for field in summary changed-files verification residual-risk; do
    mk_running "tk10m-$field" >/dev/null
    events=$(count fm_task_event); dones=$(count fm_event_done)
    args=(); skip=0
    for f in "${DONE_FLAGS[@]}"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      if [ "$f" = "--$field" ]; then skip=1; continue; fi
      args+=("$f")
    done
    ft "done" "tk10m-$field" "${args[@]}"
    must "done without --$field" 4 || return 1
    case $(tr '[:upper:]' '[:lower:]' <<<"$ERR" | tr -d '-') in *"$(tr -d '-' <<<"$field")"*) ;; *) echo "the refusal does not name $field: $ERR"; return 1 ;; esac
    [ "$(count fm_task_event)" = "$events" ] && [ "$(count fm_event_done)" = "$dones" ] || { echo "a refused done stored rows (missing $field)"; return 1; }
    [ "$(task_state "tk10m-$field")" = running ] || { echo "a refused done moved the task"; return 1; }
  done
  mk_running tk10q >/dev/null; events=$(count fm_task_event)
  ft ask tk10q --option A --option B --recommendation A --why w
  must 'ask without --question' 4 || return 1
  case $ERR in *Question*) ;; *) echo "the refusal does not name Question: $ERR"; return 1 ;; esac
  mk_running tk10r >/dev/null
  ft block transient tk10r --next-actor firstmate
  must 'block without --reason' 4 || return 1
  case $ERR in *Reason*) ;; *) echo "the refusal does not name Reason: $ERR"; return 1 ;; esac
  before=$(count fm_event_block)
  ft block transient tk10r --reason r --next-actor firstmate --until not-a-date
  [ "$RC" -ne 0 ] && [ "$(count fm_event_block)" = "$before" ] || { echo "a bad --until was stored"; return 1; }
  ft ask tk10q --question q --option only --recommendation only --why w
  [ "$RC" -eq 5 ] || { echo "one option: exit $RC, want 5: $ERR"; return 1; }
  ft ask tk10q --question q --option 1 --option 2 --option 3 --option 4 --option 5 --option 6 --option 7 --recommendation 1 --why w
  [ "$RC" -eq 5 ] || { echo "seven options: exit $RC, want 5: $ERR"; return 1; }
  ft "done" tk10q --summary '' --changed-files f --verification v --residual-risk r
  if [ "$RC" -eq 0 ] || grep -q '^seq=' <<<"$OUT"; then echo "an empty --summary was stored"; return 1; fi
}

# TR11: 20 writers at once get consecutive seq values, a re-send returns the first event,
# a rival writer that takes the seq first is retried past, and a lost answer is not stored twice.
case_concurrent() {
  BIN=$1; reset_db
  local t=tk11 i first seqs want n
  local -a pids=()
  ft create $t --title t --kind ship >/dev/null || { echo "setup: $ERR"; return 1; }
  rm -f "$TMP_ROOT"/par.*
  for i in $(seq 1 20); do
    ( "$BIN/fm-task.sh" comment $t --note "c$i" > "$TMP_ROOT/par.$i" 2>&1; echo $? > "$TMP_ROOT/par.$i.rc" ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  for i in $(seq 1 20); do
    [ "$(cat "$TMP_ROOT/par.$i.rc" 2>/dev/null)" = 0 ] || { echo "writer $i failed: $(cat "$TMP_ROOT/par.$i" 2>&1)"; return 1; }
  done
  seqs=$(db fm_task_event | jq -c '[.[].seq] | sort')
  want=$(jq -nc '[range(1; 22)]')
  [ "$seqs" = "$want" ] || { echo "seq values are not 1..21 with no gap: $seqs"; return 1; }
  [ "$(db fm_task_event | jq '[.[] | select(.kind == "comment")] | length')" = 20 ] || { echo "a comment was lost"; return 1; }
  [ "$(task_row $t | jq .lastSeq)" = 21 ] || { echo "the task row does not show seq 21: $(task_row $t)"; return 1; }
  # a re-send with the same key returns the first event
  ft comment $t --note once --key k-once
  must 'first send' 0 || return 1
  first=$(seq_of); n=$(count fm_task_event)
  ft comment $t --note once --key k-once
  must 're-send' 0 || return 1
  [ "$(seq_of)" = "$first" ] || { echo "the re-send returned seq $(seq_of), not $first"; return 1; }
  [ "$(count fm_task_event)" = "$n" ] || { echo "the re-send stored a second event"; return 1; }
  # a re-sent transition returns its first event even though the task has moved on
  mk_ready tk11s >/dev/null
  ft start tk11s --key k-start
  must 'start' 0 || return 1
  first=$(seq_of)
  ft start tk11s --key k-start
  must 're-sent start' 0 || return 1
  [ "$(seq_of)" = "$first" ] || { echo "the re-sent start returned seq $(seq_of), not $first"; return 1; }
  # a rival takes the next seq three times: the writer retries past it
  curl -s -X POST "$BASE/__x/rival?n=3" >/dev/null
  n=$(count fm_task_event)
  ft comment $t --note after --key k-after
  must 'after rivals' 0 || return 1
  [ "$(seq_of)" = $((n + 3 + 1)) ] || { echo "seq after three rivals is $(seq_of), want $((n + 4))"; return 1; }
  # the answer is lost before the event is stored: nothing stored, exit 3, a re-run stores it once
  n=$(count fm_task_event)
  curl -s -X POST "$BASE/__x/lose?mode=before&n=1" >/dev/null
  ft comment $t --note lost-before --key k-before
  must 'lost before' 3 || return 1
  [ "$(count fm_task_event)" = "$n" ] || { echo "an event was stored though the request was refused"; return 1; }
  ft comment $t --note lost-before --key k-before
  must 're-run after lost-before' 0 || return 1
  # the event is stored but the answer is lost: the lookup by key finds it, no second event
  n=$(count fm_task_event)
  curl -s -X POST "$BASE/__x/lose?mode=after&n=1" >/dev/null
  ft comment $t --note lost-after --key k-after-lost
  must 'lost after' 0 || return 1
  [ "$(count fm_task_event)" = $((n + 1)) ] || { echo "a lost answer stored the event $(( $(count fm_task_event) - n )) times"; return 1; }
  [ "$(seq_of)" = "$(db fm_task_event | jq '[.[] | select(.idempotencyKey == "k-after-lost")][0].seq')" ] || { echo "the printed seq is not the stored one"; return 1; }
}

# TR12: the Hermes transitions, every state x command pair, then the block-repeat and parent rules.
declare -A EXPECT
for s in triage todo ready running blocked review 'done' archived; do
  for c in assign reassign reopen start heartbeat 'done' ask block unblock approve changes archive comment; do EXPECT[$s:$c]=-; done
done
EXPECT[triage:assign]=ready;   EXPECT[triage:unblock]=ready;   EXPECT[triage:archive]=archived;   EXPECT[triage:comment]=triage
EXPECT[todo:assign]=todo;      EXPECT[todo:archive]=archived;  EXPECT[todo:comment]=todo
EXPECT[ready:assign]=ready;    EXPECT[ready:start]=running;    EXPECT[ready:archive]=archived;    EXPECT[ready:comment]=ready
EXPECT[running:heartbeat]=running; EXPECT[running:done]=review; EXPECT[running:ask]=blocked;      EXPECT[running:block]=blocked
EXPECT[running:comment]=running
EXPECT[blocked:unblock]=ready; EXPECT[blocked:archive]=archived; EXPECT[blocked:comment]=blocked
EXPECT[review:approve]='done';   EXPECT[review:changes]=ready;  EXPECT[review:archive]=archived;   EXPECT[review:comment]=review
EXPECT['done':archive]=archived; EXPECT['done':comment]='done'
EXPECT[archived:comment]=archived
for s in triage todo ready running blocked review; do EXPECT[$s:reassign]=$s; done
EXPECT['done':reopen]=ready
CMDS='assign reassign reopen start heartbeat done ask block unblock approve changes archive comment'

put_in_state() {  # <task> <state>
  local t=$1
  case $2 in
    triage) ft create "$t" --title "T $t" --kind ship ;;
    todo) ft create "$t-parent" --title "P $t" --kind ship >/dev/null && ft create "$t" --title "T $t" --kind ship --after "$t-parent" ;;
    ready) mk_ready "$t" ;;
    running) mk_running "$t" ;;
    blocked) mk_running "$t" && ft block transient "$t" --reason waiting --next-actor firstmate ;;
    review) mk_running "$t" && ft "done" "$t" "${DONE_FLAGS[@]}" ;;
    done) mk_running "$t" && ft "done" "$t" "${DONE_FLAGS[@]}" && ft approve "$t" ;;
    archived) ft create "$t" --title "T $t" --kind ship && ft archive "$t" ;;
  esac
}
run_command() {  # <task> <command>
  case $2 in
    assign) ft assign "$1" --to worker-2 ;;
    reassign) ft reassign "$1" --to worker-2 --reason handoff ;;
    reopen) ft reopen "$1" --reason 'new work' ;;
    done) ft "done" "$1" "${DONE_FLAGS[@]}" ;;
    ask) ft ask "$1" "${ASK_FLAGS[@]}" ;;
    block) ft block transient "$1" --reason waiting --next-actor firstmate ;;
    changes) ft changes "$1" --note 'fix the label' ;;
    comment) ft comment "$1" --note hi ;;
    *) ft "$2" "$1" ;;
  esac
}

case_transitions() {
  BIN=$1; reset_db
  local s c t want allowed events state listed n=0
  for s in triage todo ready running blocked review 'done' archived; do
    allowed=''
    for c in $CMDS; do [ "${EXPECT[$s:$c]}" = - ] || allowed="$allowed $c"; done
    for c in $CMDS; do
      n=$((n + 1)); t="tr12-$n"
      put_in_state "$t" "$s" >/dev/null || { echo "setup $s: $ERR"; return 1; }
      [ "$(task_state "$t")" = "$s" ] || { echo "setup left $t in $(task_state "$t"), want $s"; return 1; }
      events=$(count fm_task_event); want=${EXPECT[$s:$c]}
      run_command "$t" "$c"
      if [ "$want" = - ]; then
        must "$c from $s" 5 || return 1
        listed=$(sed -n 's/.*allowed from [a-z]*: *//p' <<<"$ERR" | head -1 | tr -d ',' | tr ' ' '\n' | sort | tr '\n' ' ')
        [ "$listed" = "$(tr ' ' '\n' <<<"$allowed" | sed '/^$/d' | sort | tr '\n' ' ')" ] || { echo "$c from $s lists [$listed], want [$allowed]: $ERR"; return 1; }
        [ "$(count fm_task_event)" = "$events" ] || { echo "a refused $c from $s stored an event"; return 1; }
        [ "$(task_state "$t")" = "$s" ] || { echo "a refused $c from $s moved the task"; return 1; }
      else
        must "$c from $s" 0 || return 1
        [ "$(task_state "$t")" = "$want" ] || { echo "$c from $s gave $(task_state "$t"), want $want"; return 1; }
      fi
    done
  done
  return 0
}

case_block_rules() {
  BIN=$1; reset_db
  local t=tk12b row i
  # a third block of one kind goes to triage; a different kind starts the count again
  mk_running $t >/dev/null
  for i in 1 2; do
    ft block transient $t --reason "try $i" --next-actor firstmate; must "block $i" 0 || return 1
    [ "$(task_state $t)" = blocked ] || { echo "block $i: $(task_state $t)"; return 1; }
    ft unblock $t; must "unblock $i" 0 || return 1
    [ "$(task_row $t | jq -r .blockKind)" = null ] || { echo "unblock $i left blockKind: $(task_row $t)"; return 1; }
    ft start $t; must "start $i" 0 || return 1
  done
  ft block transient $t --reason 'try 3' --next-actor firstmate; must 'block 3' 0 || return 1
  row=$(task_row $t)
  [ "$(jq -r .state <<<"$row")" = triage ] && [ "$(jq -r .nextActor <<<"$row")" = firstmate ] && [ "$(jq -r .blockRepeats <<<"$row")" = 3 ] \
    || { echo "the third block of one kind did not go to triage: $row"; return 1; }
  t=tk12c; mk_running $t >/dev/null
  ft block transient $t --reason a --next-actor firstmate >/dev/null; ft unblock $t >/dev/null; ft start $t >/dev/null
  ft block external $t --reason b --next-actor firstmate >/dev/null; ft unblock $t >/dev/null; ft start $t >/dev/null
  ft block transient $t --reason c --next-actor firstmate >/dev/null
  row=$(task_row $t)
  [ "$(jq -r .state <<<"$row")" = blocked ] && [ "$(jq -r .blockRepeats <<<"$row")" = 1 ] || { echo "a different kind did not start the count again: $row"; return 1; }
  # a done call ends the streak
  t=tk12d; mk_running $t >/dev/null
  ft block transient $t --reason a --next-actor firstmate >/dev/null; ft unblock $t >/dev/null; ft start $t >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  [ "$(task_row $t | jq -r .blockRepeats)" = 0 ] || { echo "done did not reset the block count: $(task_row $t)"; return 1; }
  return 0
}

case_parents() {
  BIN=$1; reset_db
  local p=tk12p c=tk12c1 events links
  mk_running $p >/dev/null; mk_running $c >/dev/null
  # a dependency waits in todo on an open parent
  ft block dependency $c --on $p --reason 'needs the parent' --next-actor worker
  must 'block dependency' 0 || return 1
  [ "$(task_state $c)" = todo ] || { echo "a dependency did not wait in todo: $(task_state $c)"; return 1; }
  db fm_task_link | jq -e --arg p $p --arg c $c 'any(.[]; .parentTaskId == $p and .childTaskId == $c)' >/dev/null || { echo "no link row for the dependency"; return 1; }
  ft start $c
  must 'start a waiting task' 5 || return 1
  ft assign $c --to worker-9
  must 'assign a waiting task' 0 || return 1
  [ "$(task_state $c)" = todo ] || { echo "assign took a waiting task out of todo: $(task_state $c)"; return 1; }
  # the parent finishing releases the child to ready, with an event
  ft "done" $p "${DONE_FLAGS[@]}" >/dev/null; ft approve $p >/dev/null
  [ "$(task_state $c)" = ready ] || { echo "the child was not released when the parent was approved: $(task_state $c)"; return 1; }
  db fm_task_event | jq -e --arg c $c 'any(.[]; .taskId == $c and .kind == "promoted")' >/dev/null || { echo "no promoted event for the released child"; return 1; }
  # a dependency needs an open parent that exists
  mk_running tk12c2 >/dev/null
  ft block dependency tk12c2 --on $p --reason r --next-actor worker
  must 'dependency on a done parent' 5 || return 1
  ft block dependency tk12c2 --on no-such-task --reason r --next-actor worker
  must 'dependency on a missing parent' 5 || return 1
  ft block dependency tk12c2 --reason r --next-actor worker
  [ "$RC" -ne 0 ] && [ "$(task_state tk12c2)" = running ] || { echo "a dependency with no --on was stored"; return 1; }
  # create --after an open parent waits; a link cannot make a cycle
  mk_running tk12p2 >/dev/null
  ft create tk12c3 --title c3 --kind ship --after tk12p2
  must 'create --after' 0 || return 1
  [ "$(task_state tk12c3)" = todo ] || { echo "create --after an open parent: $(task_state tk12c3)"; return 1; }
  ft create tk12a --title a --kind ship >/dev/null; ft create tk12b --title b --kind ship >/dev/null
  ft link tk12a tk12b
  must 'link' 0 || return 1
  ft link tk12b tk12a
  must 'link cycle' 5 || return 1
  case $ERR in *waits*) ;; *) echo "the cycle refusal does not say who waits on whom: $ERR"; return 1 ;; esac
  ft link tk12p2 tk12p2
  must 'link to itself' 5 || return 1
  links=$(count fm_task_link); events=$(count fm_task_event)
  ft link tk12p2 tk12c3
  must 'repeat link' 0 || return 1
  [ "$(count fm_task_link)" = "$links" ] && [ "$(count fm_task_event)" = "$events" ] || { echo "a repeat link stored again"; return 1; }
}

# The value lists the API cannot check.
case_value_lists() {
  BIN=$1; reset_db
  local before
  mk_running tk-vl >/dev/null
  before=$(count fm_task_event)
  ft block nonsense tk-vl --reason r --next-actor firstmate;      must 'block kind' 5 || return 1
  ft block transient tk-vl --reason r --next-actor nobody;        must 'next actor' 5 || return 1
  ft comment tk-vl --note x --role boss;                           must 'role' 5 || return 1
  ft create tk-vl2 --title t --kind weird;                         must 'task kind' 5 || return 1
  ft event tk-vl bogus --note x;                                   must 'event kind' 5 || return 1
  ft event tk-vl "done" --note x;                                  must 'terminal kind through event' 5 || return 1
  ft event tk-vl blocked --note x;                                 must 'blocked through event' 5 || return 1
  ft "done" tk-vl "${DONE_FLAGS[@]}" --next-actor owner;             must 'done next actor' 5 || return 1
  ft check tk-vl A1@- --status maybe;                              must 'check status' 5 || return 1
  ft create 'bad id!' --title t --kind ship;                       must 'task id' 2 || return 1
  ft create tk-vl --title t --kind ship;                           must 'duplicate task' 5 || return 1
  ft comment tk-vl --note x --key "$(printf 'k%.0s' $(seq 1 201))"; must 'long key' 2 || return 1
  ft create tk-long --title "$(printf 't%.0s' $(seq 1 301))" --kind ship; must 'long title' 5 || return 1
  ft bogus-command;                                                must 'unknown command' 2 || return 1
  ft comment tk-vl --nonsense 1;                                   must 'unknown flag' 2 || return 1
  [ "$(count fm_task_event)" = "$before" ] || { echo "a refused call stored an event"; return 1; }
  [ "$(task_row tk-long)" = '' ] || { echo "a refused create stored a task"; return 1; }
}

# TR13: one check row per scenario x width; a re-run adds, retires and resets.
case_rows() {
  BIN=$1; reset_db
  local t=tk13 checks n events row
  ft create $t --title t --kind ship --issue "$t" >/dev/null
  use_issue v1
  [ "$(task_row "$t" | jq -r .issueUrl)" = "$t" ] || return 1
  ft rows $t "$ISSUE"
  must 'rows' 0 || return 1
  [ "$(task_row "$t" | jq -r .issueUrl)" = "$ISSUE" ] || { echo 'explicit issue URL did not replace bare task id'; return 1; }
  ft rows "$t" https://github.com/acme/project/issues/999 >/dev/null || return 1
  [ "$(task_row "$t" | jq -r .issueUrl)" = "$ISSUE" ] || { echo 'stored URL was replaced'; return 1; }
  checks=$(db fm_task_check)
  [ "$(jq length <<<"$checks")" = 4 ] || { echo "want 4 rows (A1 x2 widths, A2, A3), got: $(jq -c '[.[] | .scenarioId + "@" + .width]' <<<"$checks")"; return 1; }
  jq -e 'all(.[]; .taskId == "tk13" and .status == "pending" and (.acceptanceDigest | test("^[0-9a-f]{64}$")))' <<<"$checks" >/dev/null || { echo "row fields: $(jq -c '.[0]' <<<"$checks")"; return 1; }
  jq -e '[.[] | select(.scenarioId == "A1") | .nextActor] == ["tester","tester"] and ([.[] | select(.scenarioId != "A1") | .nextActor] | unique) == ["worker"]' <<<"$checks" >/dev/null || { echo "next actors: $(jq -c '[.[] | [.scenarioId, .width, .nextActor]]' <<<"$checks")"; return 1; }
  jq -e '(.[] | select(.scenarioId == "A1" and .width == "1440")) | .line == "WHEN a user acts, THE page SHALL answer." and .surface == "user-visible" and .page == "home" and .proof == "click Save"' <<<"$checks" >/dev/null || { echo "row content wrong"; return 1; }
  # a re-run with the issue unchanged stores nothing and keeps results
  ft check $t A1@1440 --status pass --evidence 'tester record 1'; must 'check pass' 0 || return 1
  ft check $t A2@- --status pass --evidence 'unit run'; must 'check pass A2' 0 || return 1
  ft check $t A3@- --status fail --evidence 'red'; must 'check fail A3' 0 || return 1
  events=$(count fm_task_event)
  ft rows $t "$ISSUE"
  must 'rows again' 0 || return 1
  [ "$(count fm_task_event)" = "$events" ] && [ "$(count fm_task_check)" = 4 ] || { echo "an unchanged re-run stored something"; return 1; }
  db fm_task_check | jq -e '([.[] | .status] | sort) == ["fail","pass","pass","pending"]' >/dev/null || { echo "an unchanged re-run changed a result"; return 1; }
  # the issue is edited: A1's line changes (passed row resets), A2's proof changes (digest only), A4 is new
  use_issue v2
  ft rows $t "$ISSUE"
  must 'rows after edit' 0 || return 1
  checks=$(db fm_task_check)
  [ "$(jq length <<<"$checks")" = 5 ] || { echo "the new scenario was not added: $(jq length <<<"$checks") rows"; return 1; }
  row=$(jq -c '.[] | select(.scenarioId == "A1" and .width == "1440")' <<<"$checks")
  [ "$(jq -r .status <<<"$row")" = pending ] && [ "$(jq -r .line <<<"$row")" = 'WHEN a user acts, THE page SHALL answer fast.' ] || { echo "a passed row with a new line was not reset: $row"; return 1; }
  row=$(jq -c '.[] | select(.scenarioId == "A2")' <<<"$checks")
  [ "$(jq -r .status <<<"$row")" = pending ] || { echo "a passed row with a new digest and the same line was not reset: $row"; return 1; }
  [ "$(jq -r '.[] | select(.scenarioId == "A3") | .status' <<<"$checks")" = fail ] || { echo "an unchanged row was touched"; return 1; }
  # a passed row stays passed when only another row changes
  ft check $t A2@- --status pass --evidence again >/dev/null
  # scenarios and widths leave the issue: their rows are retired, not deleted
  use_issue v3
  ft rows $t "$ISSUE"
  must 'rows after removal' 0 || return 1
  checks=$(db fm_task_check)
  [ "$(jq length <<<"$checks")" = 5 ] || { echo "a retired row was deleted"; return 1; }
  [ "$(jq -r '.[] | select(.scenarioId == "A4") | .status' <<<"$checks")" = retired ] && [ "$(jq -r '.[] | select(.scenarioId == "A1" and .width == "390") | .status' <<<"$checks")" = retired ] \
    || { echo "removed ids were not retired: $(jq -c '[.[] | [.scenarioId, .width, .status]]' <<<"$checks")"; return 1; }
  [ "$(jq -r '.[] | select(.scenarioId == "A2") | .status' <<<"$checks")" = pass ] || { echo "a passed row with no change was reset"; return 1; }
  # an id that comes back is open again
  use_issue v4
  ft rows $t "$ISSUE"
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A4") | .status')" = pending ] || { echo "a returned id stayed retired"; return 1; }
  [ "$(count fm_task_check)" = 5 ] || { echo "a returned id made a second row"; return 1; }
  # a refused issue stores nothing
  printf 'no scenarios here\n' > "$TMP_ROOT/issue.body"
  events=$(count fm_task_event)
  ft rows $t "$ISSUE"
  [ "$RC" -ne 0 ] && [ "$(count fm_task_event)" = "$events" ] || { echo "a refused issue was stored"; return 1; }
  # an open row blocks the approval
  mk_running tk13b >/dev/null; use_issue v1; ft rows tk13b "$ISSUE" >/dev/null
  ft "done" tk13b "${DONE_FLAGS[@]}" >/dev/null
  ft approve tk13b
  must 'approve with open rows' 5 || return 1
  [ "$(task_state tk13b)" = review ] || { echo "approve moved a task with open rows"; return 1; }
}

# TR15: an owner item is created with its check row's next actor; a refused item leaves the row alone.
case_owner() {
  BIN=$1; reset_db
  local t=tk15 row
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft owner-check $t A1@1440 --page-title 'Home page' --steps '1. open it' --data 'the probe row' --expected 'it loads'
  must 'owner-check without --url' 4 || return 1
  case $ERR in *Url*) ;; *) echo "the refusal does not name Url: $ERR"; return 1 ;; esac
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --data 'the probe row' --expected 'it loads'
  must 'owner-check without --steps' 4 || return 1
  case $ERR in *Steps*) ;; *) echo "the refusal does not name Steps: $ERR"; return 1 ;; esac
  [ "$(count fm_owner_check)" = 0 ] || { echo "a refused owner item was stored"; return 1; }
  row=$(db fm_task_check | jq -c '.[] | select(.scenarioId == "A1" and .width == "1440")')
  [ "$(jq -r .nextActor <<<"$row")" = tester ] || { echo "a refused owner item changed the check row: $row"; return 1; }
  ft owner-check $t A1@1440 --page-title 'Home page' --url '' --steps '1. open it' --data d --expected e
  [ "$RC" -ne 0 ] && [ "$(count fm_owner_check)" = 0 ] || { echo "an empty --url was stored"; return 1; }
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data 'the probe row' --expected 'it loads'
  must 'owner-check' 0 || return 1
  db fm_owner_check | jq -e '.[0] | .taskId == "tk15" and .scenarioId == "A1" and .width == "1440" and .pageTitle == "Home page" and .url == "http://100.88.10.58:5001/#home" and .steps == "1. open it" and .data == "the probe row" and .expected == "it loads" and .status == "pending"' >/dev/null \
    || { echo "owner item wrong: $(db fm_owner_check | jq -c '.[0]')"; return 1; }
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .nextActor')" = owner ] || { echo "the check row does not read owner"; return 1; }
  # no check row can read owner without its item
  ft check $t A2@- --status pending --next-actor owner
  must 'check next actor owner without an item' 5 || return 1
  ft check $t A1@1440 --status pending --next-actor owner
  must 'check next actor owner with its item' 0 || return 1
  ft owner-check $t NOPE@- --page-title p --url u --steps s --data d --expected e
  must 'owner-check for a missing row' 5 || return 1
  db fm_task_check | jq -e --argjson items "$(db fm_owner_check)" 'all(.[]; .nextActor != "owner" or (. as $r | any($items[]; .taskId == $r.taskId and .scenarioId == $r.scenarioId and .width == $r.width)))' >/dev/null \
    || { echo "a check row reads owner with no owner item"; return 1; }
  # the same call again finds its item and is not an error
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data 'the probe row' --expected 'it loads'
  must 'owner-check again' 0 || return 1
  [ "$(count fm_owner_check)" = 1 ] || { echo "owner-check again made a second item"; return 1; }
}

# TR14: resume gives the record in one screen; reproject rebuilds a damaged row from events.
case_resume() {
  BIN=$1; reset_db
  local t=tk14 lines events_shown row id before i
  ft create $t --title 'Resume me' --kind ship --repo example/repo --issue "$ISSUE" --surface internal >/dev/null
  use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft assign $t --to worker-1 >/dev/null; ft start $t >/dev/null
  ft heartbeat $t --note one >/dev/null; ft heartbeat $t --note two >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --pr-url https://example.com/pr/9 --head deadbeef >/dev/null
  ft resume $t
  must 'resume after done' 0 || return 1
  for want in 'state=review' 'assignee=worker-1' 'next=tester' 'Built it' 'bin/fm-task.sh' 'ran the tests' 'none known' 'https://example.com/pr/9' 'deadbeef' 'A1@1440' 'A2@-' 'A3@-'; do
    case $OUT in *"$want"*) ;; *) echo "resume lacks '$want':"; echo "$OUT"; return 1 ;; esac
  done
  lines=$(wc -l <<<"$OUT" | tr -d ' ')
  [ "$lines" -le 60 ] || { echo "resume is $lines lines, more than one screen"; return 1; }
  ft changes $t --note 'fix the label' >/dev/null; ft start $t >/dev/null
  ft ask $t "${ASK_FLAGS[@]}" >/dev/null
  for i in 1 2 3; do ft comment $t --note "extra $i" >/dev/null; done
  ft resume $t
  must 'resume after ask' 0 || return 1
  for want in 'state=blocked' 'needs-decision' 'Which one?' 'Option A' 'Option B' 'Both work; A is simpler'; do
    case $OUT in *"$want"*) ;; *) echo "resume lacks '$want':"; echo "$OUT"; return 1 ;; esac
  done
  case $OUT in *'Built it'*) echo "resume shows the older done call as the last terminal call"; return 1 ;; esac
  events_shown=$(sed -n '/^LAST 10 EVENTS/,$p' <<<"$OUT" | grep -c '^  #[0-9]')
  case $OUT in *'#1 created'*) echo "resume lists the first event, so it is not the last 10"; return 1 ;; esac
  [ "$events_shown" = 10 ] || { echo "resume lists $events_shown events, want the last 10:"; echo "$OUT"; return 1; }
  [ "$(wc -l <<<"$OUT" | tr -d ' ')" -le 60 ] || { echo "resume is more than one screen"; return 1; }
  case $OUT in *'open check rows'*|*'OPEN CHECK ROWS'*) ;; *) echo "resume has no open check rows section"; return 1 ;; esac
  # reproject: a damaged row is rebuilt from the events alone
  row=$(task_row $t); id=$(jq -r .id <<<"$row"); before=$(count fm_task_event)
  api -X PATCH "$BASE/api/fm_task/$id" -d '{"state":"archived","nextActor":"owner","title":"garbage","assignee":"nobody","lastSeq":0,"blockRepeats":9,"prUrl":"x"}' >/dev/null
  [ "$(task_state $t)" = archived ] || { echo "the test could not damage the row"; return 1; }
  ft reproject $t
  must 'reproject' 0 || return 1
  [ "$(jq -S 'del(.updatedAt)' <<<"$(task_row $t)")" = "$(jq -S 'del(.updatedAt)' <<<"$row")" ] || { echo "reproject did not restore the row:"; echo "want $row"; echo "got  $(task_row $t)"; return 1; }
  [ "$(count fm_task_event)" = "$before" ] || { echo "reproject wrote an event"; return 1; }
  # a task row that is gone is created again
  curl -s -X POST "$BASE/__x/drop/fm_task/$id" >/dev/null
  [ -z "$(task_row $t)" ] || { echo "the test could not drop the row"; return 1; }
  ft reproject $t
  must 'reproject a missing row' 0 || return 1
  [ "$(task_state $t)" = blocked ] || { echo "reproject did not create the missing row: $(task_row $t)"; return 1; }
  ft resume no-such-task
  must 'resume of a missing task' 5 || return 1
}

# A 5001 that does not answer is exit 3; a bad token file or token is refused with its reason.
case_connection() {
  BIN=$1; reset_db
  local cmd saved=$FM_TASK_BASE_URL
  export FM_TASK_BASE_URL=http://127.0.0.1:1
  for cmd in "show tk" "resume tk" "list" "create tk --title t --kind ship" "comment tk --note x"; do
    # shellcheck disable=SC2086 # the words are the arguments
    ft $cmd
    if [ "$RC" -ne 3 ] || grep -q '^seq=' <<<"$OUT"; then export FM_TASK_BASE_URL=$saved; echo "$cmd with no answer: exit $RC out=[$OUT] err=[$ERR]"; return 1; fi
  done
  export FM_TASK_BASE_URL=$saved
  FM_TASK_TOKEN_FILE="$TMP_ROOT/no-such-token" ft list
  must 'missing token file' 2 || return 1
  cp "$TMP_ROOT/token" "$TMP_ROOT/token.open"; chmod 644 "$TMP_ROOT/token.open"
  FM_TASK_TOKEN_FILE="$TMP_ROOT/token.open" ft list
  must 'token file open to others' 2 || return 1
  printf 'wrong\n' > "$TMP_ROOT/token.bad"; chmod 600 "$TMP_ROOT/token.bad"
  FM_TASK_TOKEN_FILE="$TMP_ROOT/token.bad" ft list
  must 'wrong token' 4 || return 1
  case $ERR in *401*) ;; *) echo "a wrong token does not show the HTTP status: $ERR"; return 1 ;; esac
  case $OUT$ERR in *"$TOKEN"*) echo "the token is printed"; return 1 ;; esac
  FM_TASK_AUTH=cookie ft list
  must 'cookie auth' 0 || return 1
}

# Reads, links, free events and images.
case_reads_and_images() {
  BIN=$1; reset_db
  local png="$TMP_ROOT/pixel.png" id
  printf '\x89PNG\r\n\x1a\n0000' > "$png"
  mk_ready tk-r1 >/dev/null; ft create tk-r2 --title second --kind scout >/dev/null
  ft show tk-r1 --json
  must 'show' 0 || return 1
  jq -e '.taskId == "tk-r1" and .state == "ready" and .assignee == "worker-1"' <<<"$OUT" >/dev/null || { echo "show --json: $OUT"; return 1; }
  ft list --state ready
  must 'list' 0 || return 1
  case $OUT in *tk-r1*) ;; *) echo "list lacks tk-r1: $OUT"; return 1 ;; esac
  case $OUT in *tk-r2*) echo "list --state ready shows a triage task"; return 1 ;; esac
  ft list --json
  jq -e 'length == 2' <<<"$OUT" >/dev/null || { echo "list --json: $OUT"; return 1; }
  ft event tk-r1 steer --note 'use the other base'
  must 'event steer' 0 || return 1
  db fm_task_event | jq -e 'any(.[]; .kind == "steer" and .taskId == "tk-r1")' >/dev/null || { echo "no steer event"; return 1; }
  log_reset
  ft comment tk-r1 --note 'see the picture' --image "$png" --image-label 'a pixel'
  must 'comment with an image' 0 || return 1
  id=$(db fm_task_event | jq -r --argjson s "$(seq_of)" '.[] | select(.seq == $s) | .id')
  db fm_event_image | jq -e --arg id "$id" '.[] | select(.fmTaskEventId == $id) | .label == "a pixel" and .mediaType == "image/png" and .position == 1 and (.content | length > 0)' >/dev/null || { echo "image child wrong"; return 1; }
  [ "$(posts POST fm_event_image)" = 0 ] || { echo "the image was posted on its own"; return 1; }
  ft comment tk-r1 --note x --image "$png"
  [ "$RC" -ne 0 ] || { echo "an image with no label was accepted"; return 1; }
  head -c 2200000 /dev/zero > "$TMP_ROOT/big.png"
  ft comment tk-r1 --note x --image "$TMP_ROOT/big.png" --image-label big
  [ "$RC" -ne 0 ] || { echo "an image over 2 MiB was accepted"; return 1; }
  ft heartbeat tk-r1
  must 'heartbeat from ready' 5 || return 1
  FM_TASK_ID=tk-r1 ft comment --note 'task from the environment'
  must 'task from FM_TASK_ID' 0 || return 1
}

# A re-sent check must not undo a newer result for the same row.
case_check_replay() {
  BIN=$1; reset_db
  local t=tk-replay row
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  st() { db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .status'; }
  ft check $t A2@- --status pass --key k-pass --evidence first; must 'pass' 0 || return 1
  ft check $t A2@- --status fail --key k-fail --evidence second; must 'fail' 0 || return 1
  ft check $t A2@- --status pass --key k-pass --evidence first
  must 'old pass re-sent' 0 || return 1
  [ "$(st)" = fail ] || { echo "a re-sent old pass overwrote the newer fail: $(st)"; return 1; }
  # the latest check re-sent still finishes its patch
  row=$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .id')
  api -X PATCH "$BASE/api/fm_task_check/$row" -d '{"status":"pending"}' >/dev/null
  ft check $t A2@- --status fail --key k-fail --evidence second
  must 'latest re-sent' 0 || return 1
  [ "$(st)" = fail ] || { echo "the latest check re-sent did not finish its patch: $(st)"; return 1; }
}

# When the last open row of a task in review passes, the task is routed to firstmate.
case_route() {
  BIN=$1; reset_db
  local t=tk-route row
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  [ "$(task_row $t | jq -r .nextActor)" = tester ] || { echo "done with user-visible rows open should wait on the tester: $(task_row $t)"; return 1; }
  ft check $t A1@1440 --status pass >/dev/null; ft check $t A1@390 --status pass >/dev/null; ft check $t A2@- --status pass >/dev/null
  [ "$(task_row $t | jq -r .nextActor)" = worker ] || { echo "with a worker row open the task should wait on the worker: $(task_row $t | jq -r .nextActor)"; return 1; }
  ft check $t A3@- --status pass
  must 'last pass' 0 || return 1
  [ "$(task_row $t | jq -r .nextActor)" = firstmate ] || { echo "the task stays with $(task_row $t | jq -r .nextActor) after the last row passed"; return 1; }
  ft list --actor firstmate
  case $OUT in *$t*) ;; *) echo "list --actor firstmate misses the task: $OUT"; return 1 ;; esac
  # the projection still equals the fold of the events
  row=$(task_row $t); ft reproject $t >/dev/null
  [ "$(task_row $t)" = "$row" ] || { echo "reproject changed the routed row"; return 1; }
}

# start refuses while a parent is open, even when the link was written but the child's todo event was not.
case_start_parent() {
  BIN=$1; reset_db
  mk_running tk-sp-parent >/dev/null; mk_ready tk-sp-child >/dev/null
  api -X POST "$BASE/api/fm_task_link" -d '{"parentTaskId":"tk-sp-parent","childTaskId":"tk-sp-child"}' >/dev/null
  [ "$(task_state tk-sp-child)" = ready ] || { echo "setup: the child is not ready"; return 1; }
  ft start tk-sp-child
  must 'start with an open parent' 5 || return 1
  case $ERR in *tk-sp-parent*) ;; *) echo "the refusal does not name the parent: $ERR"; return 1 ;; esac
  [ "$(task_state tk-sp-child)" = ready ] || { echo "start moved the child"; return 1; }
}

# approve needs rows for a user-visible task, passed on the head of the latest done.
case_approve_head() {
  BIN=$1; reset_db
  local t=tk-ah r
  ft create tk-ah0 --title t --kind ship --surface user-visible >/dev/null; ft assign tk-ah0 --to w >/dev/null; ft start tk-ah0 >/dev/null
  ft "done" tk-ah0 "${DONE_FLAGS[@]}" >/dev/null
  cl_off tk-ah0 ci mockup tester deploy || return 1
  ft approve tk-ah0
  must 'approve a user-visible task with no rows' 5 || return 1
  case $ERR in *'no check rows'*) ;; *) echo "the refusal does not say the rows are missing: $ERR"; return 1 ;; esac
  [ "$(task_state tk-ah0)" = review ] || { echo "approve moved a user-visible task with no rows"; return 1; }
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass --head h1 >/dev/null; done
  ft approve $t
  must 'approve on the head of the done' 0 || return 1
  # new work: changes, a new done on head h2, and the old passes no longer count
  mk_running tk-ah2 >/dev/null; ft rows tk-ah2 "$ISSUE" >/dev/null
  ft "done" tk-ah2 "${DONE_FLAGS[@]}" --head h1 >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check tk-ah2 $r --status pass --head h1 >/dev/null; done
  ft changes tk-ah2 --note again >/dev/null; ft start tk-ah2 >/dev/null
  ft "done" tk-ah2 "${DONE_FLAGS[@]}" --head h2 >/dev/null
  ft approve tk-ah2
  must 'approve on an older head' 5 || return 1
  case $ERR in *A1@1440*A1@390*|*A1@390*A1@1440*) ;; *) echo "the refusal does not name each stale row: $ERR"; return 1 ;; esac
  case $ERR in *A2@-*) echo "the refusal names an internal row: $ERR"; return 1 ;; esac
  for r in A1@1440 A1@390; do ft check tk-ah2 $r --status pass --head h2 >/dev/null; done
  ft approve tk-ah2
  must 'approve after the rows pass on h2' 0 || return 1
}

# A new owner item reopens a passed row, so approve cannot finish before the owner answers.
case_owner_pending() {
  BIN=$1; reset_db
  local t=tk-op
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  ft owner-check $t A1@1440 --page-title 'Home' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e
  must 'owner-check on a passed row' 0 || return 1
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A1" and .width == "1440") | .status == "pending" and .nextActor == "owner"' >/dev/null \
    || { echo "the paired row is not pending with next actor owner: $(db fm_task_check | jq -c '.[] | select(.scenarioId == "A1" and .width == "1440")')"; return 1; }
  ft approve $t
  must 'approve before the owner answers' 5 || return 1
  [ "$(task_state $t)" = review ] || { echo "approve finished before the owner answered"; return 1; }
}

# rows on a closed task would reopen passed rows under a task that stays done.
case_rows_closed() {
  BIN=$1; reset_db
  local before
  use_issue v1
  ft create tk-rc1 --title t --kind ship >/dev/null; ft rows tk-rc1 "$ISSUE" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check tk-rc1 $r --status pass >/dev/null; done
  ft archive tk-rc1 >/dev/null
  use_issue v2; before=$(db fm_task_check | jq -c '[.[] | [.scenarioId, .width, .status]]')
  ft rows tk-rc1 "$ISSUE"
  must 'rows on an archived task' 5 || return 1
  case $ERR in *archived*) ;; *) echo "the refusal does not say why: $ERR"; return 1 ;; esac
  [ "$(db fm_task_check | jq -c '[.[] | [.scenarioId, .width, .status]]')" = "$before" ] || { echo "rows changed an archived task's rows"; return 1; }
  mk_running tk-rc2 >/dev/null; ft "done" tk-rc2 "${DONE_FLAGS[@]}" >/dev/null; ft approve tk-rc2 >/dev/null
  ft rows tk-rc2 "$ISSUE"
  must 'rows on a done task' 5 || return 1
  [ "$(count fm_task_check)" = 4 ] || { echo "rows added rows to a done task"; return 1; }
}

# check and owner-check refuse a task that is done or archived.
case_check_closed() {
  BIN=$1; reset_db
  local t=tk-cc r
  use_issue v1
  ft create $t --title t --kind ship >/dev/null; ft rows $t "$ISSUE" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  ft archive $t >/dev/null
  ft check $t A2@- --status fail
  must 'check on an archived task' 5 || return 1
  case $ERR in *archived*) ;; *) echo "the refusal does not say the task is archived: $ERR"; return 1 ;; esac
  ft owner-check $t A1@1440 --page-title p --url u --steps s --data d --expected e
  must 'owner-check on an archived task' 5 || return 1
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .status')" = pass ] || { echo "check changed a row of an archived task"; return 1; }
  [ "$(count fm_owner_check)" = 0 ] || { echo "owner-check stored an item for an archived task"; return 1; }
  mk_running tk-cc2 >/dev/null; ft "done" tk-cc2 "${DONE_FLAGS[@]}" >/dev/null; ft approve tk-cc2 >/dev/null
  ft check tk-cc2 A1@- --status pass
  must 'check on a done task' 5 || return 1
}

# check and owner-check refuse a retired row.
case_row_retired() {
  BIN=$1; reset_db
  local t=tk-rr
  ft create $t --title t --kind ship >/dev/null
  use_issue v2; ft rows $t "$ISSUE" >/dev/null
  use_issue v3; ft rows $t "$ISSUE" >/dev/null
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "390") | .status')" = retired ] || { echo "setup: A1@390 is not retired"; return 1; }
  ft check $t A1@390 --status pass
  must 'check on a retired row' 5 || return 1
  case $ERR in *retired*) ;; *) echo "the refusal does not say the row is retired: $ERR"; return 1 ;; esac
  ft owner-check $t A1@390 --page-title p --url u --steps s --data d --expected e
  must 'owner-check on a retired row' 5 || return 1
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "390") | .status')" = retired ] || { echo "the retired row changed"; return 1; }
  [ "$(count fm_owner_check)" = 0 ] || { echo "an owner item was stored for a retired row"; return 1; }
}

# done waits on the tester unless every user-visible pass is on the head of this done.
case_done_head() {
  BIN=$1; reset_db
  local t r
  local -A HEADOF=([tk-dh1]=h1 [tk-dh2]=h1)
  use_issue v1
  for t in tk-dh1 tk-dh2 tk-dh3; do
    mk_running $t >/dev/null; ft rows $t "$ISSUE" >/dev/null
    for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass ${HEADOF[$t]:+--head "${HEADOF[$t]}"} >/dev/null; done
  done
  ft "done" tk-dh1 "${DONE_FLAGS[@]}" --head h2 >/dev/null
  [ "$(task_row tk-dh1 | jq -r .nextActor)" = tester ] || { echo "a pass on h1 counted for a done on h2: $(task_row tk-dh1 | jq -c '{state,nextActor}')"; return 1; }
  ft "done" tk-dh2 "${DONE_FLAGS[@]}" --head h1 >/dev/null
  [ "$(task_row tk-dh2 | jq -r .nextActor)" = firstmate ] || { echo "a pass on the same head did not count: $(task_row tk-dh2 | jq -c '{state,nextActor}')"; return 1; }
  ft "done" tk-dh3 "${DONE_FLAGS[@]}" >/dev/null
  [ "$(task_row tk-dh3 | jq -r .nextActor)" = firstmate ] || { echo "passes with no head and a done with no head should match: $(task_row tk-dh3 | jq -c '{state,nextActor}')"; return 1; }
}

# Routing goes both ways: a row that opens again on a review task sends it back to that row's actor.
case_route_back() {
  BIN=$1; reset_db
  local t=tk-rb r row
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  na() { task_row $t | jq -r .nextActor; }
  [ "$(na)" = firstmate ] || { echo "setup: not routed to firstmate: $(na)"; return 1; }
  ft check $t A2@- --status fail >/dev/null
  [ "$(na)" = worker ] || { echo "a failed row did not send the task back to the worker: $(na)"; return 1; }
  ft check $t A2@- --status pass >/dev/null
  [ "$(na)" = firstmate ] || { echo "the row passed again but the task stays with $(na)"; return 1; }
  ft check $t A1@1440 --status pending >/dev/null
  [ "$(na)" = tester ] || { echo "a user-visible row open again did not send the task to the tester: $(na)"; return 1; }
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .nextActor')" = tester ] || { echo "a reopened user-visible row reads another actor"; return 1; }
  ft check $t A1@1440 --status pass >/dev/null
  ft owner-check $t A1@390 --page-title p --url u --steps s --data d --expected e >/dev/null
  [ "$(na)" = owner ] || { echo "an owner item on a row did not send the task to the owner: $(na)"; return 1; }
  row=$(task_row $t); ft reproject $t >/dev/null
  [ "$(task_row $t)" = "$row" ] || { echo "reproject changed the routed row"; return 1; }
}

# A user-visible pass on another head than the latest done is still open: a later check does not undo the routing that done made.
case_route_stale() {
  BIN=$1; reset_db
  local t=tk-rst r
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  na() { task_row $t | jq -r .nextActor; }
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  for r in A1@1440 A1@390; do ft check $t $r --status pass --head h1 >/dev/null; done
  for r in A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  [ "$(na)" = firstmate ] || { echo "setup: not routed to firstmate: $(na)"; return 1; }
  ft changes $t --note again >/dev/null; ft start $t >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --head h2 >/dev/null
  [ "$(na)" = tester ] || { echo "done on a new head did not wait on the tester: $(na)"; return 1; }
  ft check $t A3@- --status pass --evidence again
  must 'a later check' 0 || return 1
  [ "$(na)" = tester ] || { echo "a later check sent the task to $(na) while the passes sit on head h1: want tester"; return 1; }
  ft check $t A1@1440 --status pass --head h2 >/dev/null; ft check $t A1@390 --status pass --head h2 >/dev/null
  [ "$(na)" = firstmate ] || { echo "passes on the latest head left the task with $(na)"; return 1; }
}

# TR40: the Tester's call names its result as a word, and the row shows status, evidence, head and next actor:
# worker on a fail, firstmate on a pass, and the task waits on firstmate once every row passes.
case_check_word() {
  BIN=$1; reset_db
  local t=tk-cw r row
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  ft check $t A1@1440 fail --evidence /tmp/shot-fail.png --head h1
  must 'check with the result as a word' 0 || return 1
  row=$(db fm_task_check | jq -c '.[] | select(.scenarioId == "A1" and .width == "1440")')
  jq -e '.status == "fail" and .evidence == "/tmp/shot-fail.png" and .head == "h1" and .nextActor == "worker"' <<<"$row" >/dev/null || { echo "a fail row reads: $row"; return 1; }
  [ "$(task_row $t | jq -r .nextActor)" = worker ] || { echo "a fail did not send the task to the worker: $(task_row $t | jq -c .)"; return 1; }
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r pass --evidence https://example.test/proof --head h1 >/dev/null || { echo "check $r pass: $ERR"; return 1; }; done
  row=$(db fm_task_check | jq -c '.[] | select(.scenarioId == "A1" and .width == "1440")')
  jq -e '.status == "pass" and .evidence == "https://example.test/proof" and .head == "h1" and .nextActor == "firstmate"' <<<"$row" >/dev/null || { echo "a pass row reads: $row"; return 1; }
  [ "$(task_row $t | jq -r .nextActor)" = firstmate ] || { echo "every row passed but the task waits on $(task_row $t | jq -r .nextActor)"; return 1; }
  ft check $t A1@390 maybe --head h1
  must 'an unknown result word' 5 || return 1
  ft check $t A1@390 pass --status fail --head h1
  must 'a result word and another --status' 2 || return 1
}

# A deploy event names the deployed head, and a user-visible pass counts on the newest head the task was built or
# deployed at: passes on the worker's head wait on the tester again until they pass on the deployed head.
case_deploy_head() {
  BIN=$1; reset_db
  local t=tk-dph r
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  na() { task_row $t | jq -r .nextActor; }
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r pass --head h1 >/dev/null; done
  [ "$(na)" = firstmate ] || { echo "setup: not routed to firstmate: $(na)"; return 1; }
  ft event $t deploy --note 'deployed main' --head d1
  must 'a deploy event with its head' 0 || return 1
  [ "$(na)" = tester ] || { echo "a new deployed head left the task with $(na); the passes sit on h1"; return 1; }
  ft approve $t
  must 'approve with passes on the worker head only' 5 || return 1
  for r in A1@1440 A1@390; do ft check $t $r pass --head d1 >/dev/null; done
  [ "$(na)" = firstmate ] || { echo "passes on the deployed head left the task with $(na)"; return 1; }
  ft event $t deploy --note 'a deploy event with no head changes nothing' >/dev/null
  [ "$(na)" = firstmate ] || { echo "a deploy event with no head moved the task to $(na)"; return 1; }
  ft approve $t
  must 'approve on the deployed head' 0 || return 1
  ft event tk-dph comment --head d2
  must 'a head on another event kind' 2 || return 1
}

# The Tester's rows: `rows --surface user-visible` writes only the user-visible rows (and retires the others), so a task
# the deploy-verify ask gives rows waits on the Tester alone and goes to firstmate once those rows pass.
case_rows_visible() {
  BIN=$1; reset_db
  local t=tk-rv r
  mk_running $t >/dev/null; use_issue v1
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  ft rows $t "$ISSUE" --surface user-visible
  must 'rows of the user-visible scenarios' 0 || return 1
  [ "$(db fm_task_check | jq -r '[.[] | select(.taskId == "tk-rv" and .status != "retired") | .scenarioId + "@" + .width] | sort | join(",")')" = 'A1@1440,A1@390' ] \
    || { echo "rows written: $(db fm_task_check | jq -c '[.[] | [.scenarioId, .width, .status]]')"; return 1; }
  ft event $t deploy --head d1 >/dev/null
  for r in A1@1440 A1@390; do ft check $t $r pass --evidence https://example.test/$r --head d1 >/dev/null; done
  [ "$(task_row $t | jq -r .nextActor)" = firstmate ] || { echo "the Tester's rows passed but the task waits on $(task_row $t | jq -r .nextActor)"; return 1; }
  ft approve $t
  must 'approve after the Tester rows pass' 0 || return 1
  # rows of another surface are left as they are; a user-visible row the issue dropped is retired
  mk_running tk-rv2 >/dev/null; ft rows tk-rv2 "$ISSUE" >/dev/null
  ft check tk-rv2 A2@- pass --evidence unit >/dev/null
  use_issue v3
  ft rows tk-rv2 "$ISSUE" --surface user-visible >/dev/null
  [ "$(db fm_task_check | jq -r '[.[] | select(.taskId == "tk-rv2") | .scenarioId + "@" + .width + ":" + .status] | sort | join(",")')" = 'A1@1440:pending,A1@390:retired,A2@-:pass,A3@-:pending' ] \
    || { echo "rows after a user-visible run: $(db fm_task_check | jq -c '[.[] | select(.taskId == "tk-rv2") | [.scenarioId, .width, .status]]')"; return 1; }
  use_issue v1
  ft rows tk-rv2 "$ISSUE" --surface some
  must 'an unknown surface' 5 || return 1
}

# Once a task has a deploy event, a user-visible pass counts only on a deployed head: passes on the worker's head from a
# draft round (whose deploy event names no head) cannot close the task before the deploy.
case_approve_deployed() {
  BIN=$1; reset_db
  local t=tk-ad r
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" --surface user-visible >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  ft event $t deploy --note 'draft round' >/dev/null
  for r in A1@1440 A1@390; do ft check $t $r pass --evidence https://example.test/$r --head h1 >/dev/null; done
  ft approve $t
  must 'approve on draft passes before a deploy' 5 || return 1
  case $ERR in *'no deployed head'*) ;; *) echo "the refusal does not name the missing deployed head: $ERR"; return 1 ;; esac
  ft event $t deploy --note 'deploy round' --head d1 >/dev/null
  for r in A1@1440 A1@390; do ft check $t $r pass --evidence https://example.test/$r --head d1 >/dev/null; done
  ft approve $t
  must 'approve on passes on the deployed head' 0 || return 1
  # new work after the deploy needs a new deployed head
  mk_running tk-ad2 >/dev/null; ft rows tk-ad2 "$ISSUE" --surface user-visible >/dev/null
  ft event tk-ad2 deploy --head d1 >/dev/null
  ft "done" tk-ad2 "${DONE_FLAGS[@]}" --head h2 >/dev/null
  for r in A1@1440 A1@390; do ft check tk-ad2 $r pass --evidence https://example.test/$r --head h2 >/dev/null; done
  ft approve tk-ad2
  must 'approve on a worker head newer than the deploy' 5 || return 1
}

# The gate's read: every user-visible row of the issue passes on the deployed head with its current digest and
# evidence, and an approved event is newer than the last row. It writes nothing.
case_gate() {
  BIN=$1; reset_db
  local t=tk-gt r events
  mkdir -p "$TMP_ROOT/tester/shots"; : > "$TMP_ROOT/tester/shots/a1.png"
  gate() { ft gate $t --issue "$ISSUE" --head d1 --evidence-root "$TMP_ROOT/tester"; }
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  ft event $t deploy --head d1 >/dev/null
  gate; must 'gate on pending rows' 5 || return 1
  case $OUT in *'A1@1440 is '"'"'pending'"'"', not pass'*) ;; *) echo "the gate does not name the pending row: $OUT"; return 1 ;; esac
  for r in A2@- A3@-; do ft check $t $r pass >/dev/null; done
  ft check $t A1@1440 pass --evidence shots/a1.png --head d1 >/dev/null
  ft check $t A1@390 pass --evidence shots/missing.png --head d1 >/dev/null
  gate; must 'gate with a missing evidence file' 5 || return 1
  case $OUT in *'A1@390 evidence path does not exist: shots/missing.png'*) ;; *) echo "the gate missed the evidence: $OUT"; return 1 ;; esac
  case $OUT in *A1@1440*) echo "the gate names a row that passes: $OUT"; return 1 ;; esac
  case $OUT in *A2@-*) echo "the gate judged an internal row: $OUT"; return 1 ;; esac
  ft check $t A1@390 pass --evidence https://example.test/a1-390 --head h1 >/dev/null
  gate; must 'gate with a pass on another head' 5 || return 1
  case $OUT in *'A1@390 passed on head h1, not the deployed head d1'*) ;; *) echo "the gate missed the head: $OUT"; return 1 ;; esac
  ft check $t A1@390 pass --evidence https://example.test/a1-390 --head d1 >/dev/null
  gate; must 'gate before the approval' 5 || return 1
  case $OUT in *'no approved event'*) ;; *) echo "the gate missed the approval: $OUT"; return 1 ;; esac
  ft approve $t >/dev/null || { echo "approve: $ERR"; return 1; }
  events=$(count fm_task_event)
  gate; must 'gate on a complete record' 0 || { echo "problems: $OUT"; return 1; }
  [ "$(count fm_task_event)" = "$events" ] || { echo "the gate wrote an event"; return 1; }
  ft gate $t --issue "$ISSUE" --head d2 --evidence-root "$TMP_ROOT/tester"
  must 'gate on another deployed head' 5 || return 1
  # a scenario edited after the Tester checked it is checked again
  use_issue v5
  gate; must 'gate after the scenario changed' 5 || return 1
  case $OUT in *'A1@1440'*'another version of the scenario'*) ;; *) echo "the gate missed the changed scenario: $OUT"; return 1 ;; esac
  # an approval older than the last row does not cover it
  use_issue v1
  ft reopen $t --reason again >/dev/null; ft start $t >/dev/null; ft "done" $t "${DONE_FLAGS[@]}" --head d1 >/dev/null
  ft check $t A1@1440 pass --evidence shots/a1.png --head d1 >/dev/null
  gate; must 'gate with an approval older than the last row' 5 || return 1
  case $OUT in *'not newer than the last row event'*) ;; *) echo "the gate missed the stale approval: $OUT"; return 1 ;; esac
  ft gate tk-none --issue "$ISSUE" --head d1
  must 'gate on a task the record does not hold' 5 || return 1
  case $OUT in *'the task record has no task tk-none'*) ;; *) echo "the gate does not say the task is missing: $OUT"; return 1 ;; esac
}

# rows routes a task in review again after it adds, resets or retires rows.
case_rows_route() {
  BIN=$1; reset_db
  local t=tk-rr r
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  na() { task_row $t | jq -r .nextActor; }
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  [ "$(na)" = firstmate ] || { echo "setup: not routed to firstmate: $(na)"; return 1; }
  use_issue v2; ft rows $t "$ISSUE"
  must 'rows with new and reset rows' 0 || return 1
  [ "$(na)" = worker ] || { echo "rows added and reset rows but the task waits on $(na); want worker"; return 1; }
  for r in A1@1440 A1@390 A2@-; do ft check $t $r --status pass >/dev/null; done
  [ "$(na)" = worker ] || { echo "setup: A4 is open but the task waits on $(na)"; return 1; }
  use_issue v5; ft rows $t "$ISSUE"
  must 'rows retiring the open row' 0 || return 1
  [ "$(na)" = firstmate ] || { echo "rows retired the open row but the task waits on $(na); want firstmate"; return 1; }
}

# A re-sent owner-check key finishes its own call and cannot undo a newer verdict.
case_owner_replay() {
  BIN=$1; reset_db
  local t=tk-ore id events
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  OC=(owner-check "$t" A1@1440 --page-title Home --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e)
  rowst() { db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .status + "/" + .nextActor'; }
  ft "${OC[@]}" --key k-oc >/dev/null; must 'owner-check' 0 || return 1
  id=$(db fm_owner_check | jq -r '.[0].id')
  api -X PATCH "$BASE/api/fm_owner_check/$id" -d '{"status":"pass"}' >/dev/null
  ft check $t A1@1440 --status pass --key k-verdict >/dev/null
  events=$(count fm_task_event)
  ft "${OC[@]}" --key k-oc; must 'owner-check re-sent' 0 || return 1
  [ "$(rowst)" = pass/firstmate ] || { echo "a re-sent owner-check undid the newer verdict: $(rowst)"; return 1; }
  [ "$(db fm_owner_check | jq -r '.[0].status')" = pass ] || { echo "a re-sent owner-check reopened the answered item"; return 1; }
  [ "$(count fm_task_event)" = "$events" ] || { echo "a re-sent owner-check stored an event"; return 1; }
  # the same key with another page or another row is another call
  ft owner-check $t A1@1440 --page-title Other --url 'http://100.88.10.58:5001/#home' --steps s --data d --expected e --key k-oc
  must 'owner-check re-sent with another page title' 5 || return 1
  ft "${OC[@]/A1@1440/A1@390}" --key k-oc
  must 'owner-check re-sent for another row' 5 || return 1
}

# A new result with no --head or --evidence keeps no head or evidence of an older one.
case_check_nulls() {
  BIN=$1; reset_db
  local t=tk-cn
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  rowv() { db fm_task_check | jq -c '.[] | select(.scenarioId == "A2") | {status, evidence, head}'; }
  ft check $t A2@- --status pass --evidence first --head h1 >/dev/null
  [ "$(rowv)" = '{"status":"pass","evidence":"first","head":"h1"}' ] || { echo "setup: $(rowv)"; return 1; }
  ft check $t A2@- --status pending >/dev/null
  ft check $t A2@- --status pass; must 'a pass with no head' 0 || return 1
  [ "$(rowv)" = '{"status":"pass","evidence":null,"head":null}' ] || { echo "a new pass kept the older evidence or head: $(rowv)"; return 1; }
}

# A check cannot be stored behind an approval that closed the task in between, and approve judges the rows from the newest check events.
case_check_close() {
  BIN=$1; reset_db
  local t=tk-cc r pid
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  # the check has read the open task and waits for its row; the approval lands first
  curl -s -X POST "$BASE/__x/delay/fm_task_check?ms=800&n=1&verb=list" >/dev/null
  ( "$BIN/fm-task.sh" check $t A2@- --status fail --evidence late > "$TMP_ROOT/cc.out" 2>&1; echo $? > "$TMP_ROOT/cc.rc" ) &
  pid=$!
  sleep 0.3
  ft approve $t; must 'approve' 0 || return 1
  wait $pid
  [ "$(cat "$TMP_ROOT/cc.rc")" = 5 ] || { echo "the check behind the approval exited $(cat "$TMP_ROOT/cc.rc"), want 5: $(cat "$TMP_ROOT/cc.out")"; return 1; }
  db fm_task_event | jq -e '[.[] | select(.kind == "check" and (.body | fromjson | .values.evidence == "late"))] | length == 0' >/dev/null \
    || { echo "a check event was stored after the task closed"; return 1; }
  [ "$(task_state $t)" = "done" ] || { echo "the task is $(task_state $t), want done"; return 1; }
}

# approve judges a row by its newest check event, also while that event's patch is still on its way.
case_approve_newest() {
  BIN=$1; reset_db
  local t=tk-an r pid
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  curl -s -X POST "$BASE/__x/delay/fm_task_check?ms=900&n=1" >/dev/null
  ( "$BIN/fm-task.sh" check $t A2@- --status fail --evidence late > "$TMP_ROOT/an.out" 2>&1 ) &
  pid=$!
  sleep 0.5
  ft approve $t
  must 'approve while a failed check is on its way' 5 || return 1
  wait $pid
  [ "$(task_state $t)" = review ] || { echo "the task is $(task_state $t) after a refused approve, want review"; return 1; }
  ft approve $t; must 'approve' 5 || return 1
}

# owner-check on a row that already has an item needs --url and --steps too, and changes nothing without them.
case_owner_update() {
  BIN=$1; reset_db
  local t=tk-ou events item
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e >/dev/null
  events=$(count fm_task_event); item=$(db fm_owner_check | jq -S -c .)
  local missing
  for missing in page-title url steps data expected; do
    local -a template=()
    local field
    for field in page-title url steps data expected; do
      [ "$field" = "$missing" ] || template+=("--$field" "value-$field")
    done
    ft owner-check $t A1@1440 "${template[@]}"
    must "update without --$missing" 5 || return 1
    [[ "$ERR" == *"--$missing"* ]] || return 1
    [ "$(count fm_task_event)" = "$events" ] && [ "$(db fm_owner_check | jq -S -c .)" = "$item" ] || return 1
  done
  ft owner-check $t A1@1440 --page-title 'New title' --steps '1. open it' --data d --expected e
  must 'update without --url' 5 || return 1
  case $ERR in *url*) ;; *) echo "the refusal does not name url: $ERR"; return 1 ;; esac
  ft owner-check $t A1@1440 --page-title 'New title' --url 'http://100.88.10.58:5001/#home' --data d --expected e
  must 'update without --steps' 5 || return 1
  case $ERR in *steps*) ;; *) echo "the refusal does not name steps: $ERR"; return 1 ;; esac
  [ "$(count fm_task_event)" = "$events" ] && [ "$(db fm_owner_check | jq -S -c .)" = "$item" ] || { echo "a refused update changed the record"; return 1; }
  ft owner-check $t A1@1440 --page-title 'New title' --url 'http://100.88.10.58:5001/#home2' --steps '2. open it' --data d --expected e
  must 'update with --url and --steps' 0 || return 1
  db fm_owner_check | jq -e '.[0] | .pageTitle == "New title" and .url == "http://100.88.10.58:5001/#home2" and .steps == "2. open it"' >/dev/null || { echo "the update was not stored"; return 1; }
}

# An owner-check cannot be stored behind an approval that closed the task in between.
case_owner_close() {
  BIN=$1; reset_db
  local t=tk-oc r pid
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  # the owner-check has read the open task and waits for its row; the approval lands first
  curl -s -X POST "$BASE/__x/delay/fm_task_check?ms=800&n=1&verb=list" >/dev/null
  ( "$BIN/fm-task.sh" owner-check $t A2@- --page-title p --url u --steps s --data d --expected e > "$TMP_ROOT/oc.out" 2>&1; echo $? > "$TMP_ROOT/oc.rc" ) &
  pid=$!
  sleep 0.3
  ft approve $t; must 'approve' 0 || return 1
  wait $pid
  [ "$(cat "$TMP_ROOT/oc.rc")" = 5 ] || { echo "the owner-check behind the approval exited $(cat "$TMP_ROOT/oc.rc"), want 5: $(cat "$TMP_ROOT/oc.out")"; return 1; }
  db fm_task_event | jq -e '[.[] | select(.kind == "owner-check")] | length == 0' >/dev/null || { echo "an owner-check event was stored after the task closed"; return 1; }
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .status + "/" + .nextActor')" = pass/firstmate ] || { echo "the owner-check changed a row of the closed task"; return 1; }
}

# import writes a task at the state an old source holds, once: a second call changes nothing, and a bad value is refused.
case_import() {
  BIN=$1; reset_db
  local events
  ft import tk-im1 --title 'Imported' --kind ship --repo example/repo --state blocked --assignee w1 --next-actor owner --block-kind needs-decision --block-reason 'pick one' --issue https://github.com/o/r/issues/1 --since 2026-10-20T08:00:00Z
  must 'import' 0 || return 1
  task_row tk-im1 | jq -e '.state == "blocked" and .nextActor == "owner" and .blockKind == "needs-decision" and .blockReason == "pick one" and .assignee == "w1" and .repo == "example/repo" and .issueUrl == "https://github.com/o/r/issues/1" and .lastSeq > 0' >/dev/null \
    || { echo "the imported row is wrong: $(task_row tk-im1)"; return 1; }
  events=$(count fm_task_event)
  ft import tk-im1 --title 'Changed' --kind scout --state running --assignee w2 --next-actor worker
  must 'import again' 0 || return 1
  case $OUT in *already*) ;; *) echo "import again does not say so: $OUT"; return 1 ;; esac
  [ "$(count fm_task_event)" = "$events" ] && [ "$(task_state tk-im1)" = blocked ] || { echo "a second import changed the record"; return 1; }
  ft import tk-im1 --title 'Other key' --kind ship --state running --assignee w3 --next-actor worker --key other-key
  must 'import under another key' 0 || return 1
  case $OUT in *'already present'*) ;; *) echo "import under another key does not say so: $OUT"; return 1 ;; esac
  [ "$(count fm_task_event)" = "$events" ] || { echo "an import under another key stored an event"; return 1; }
  ft import tk-im2 --title 'Done one' --kind ship --state "done" --assignee - --next-actor firstmate
  must 'import done' 0 || return 1
  [ "$(task_state tk-im2)" = "done" ] || { echo "done is $(task_state tk-im2)"; return 1; }
  ft import tk-im3 --title t --kind ship --state nowhere --assignee - --next-actor worker
  must 'import with a bad state' 5 || return 1
  ft import tk-im3 --title t --kind ship --state ready --assignee - --next-actor nobody
  must 'import with a bad actor' 5 || return 1
  ft import tk-im3 --title t --kind ship --state ready --assignee - --next-actor worker --block-kind sulking
  must 'import with a bad block kind' 5 || return 1
  [ "$(task_row tk-im3)" = '' ] || { echo "a refused import stored a row"; return 1; }
  ft reproject tk-im1 >/dev/null; task_row tk-im1 | jq -e '.state == "blocked"' >/dev/null || { echo "reproject changed the imported row"; return 1; }
  # an imported task works with the other commands: unblock moves it on
  ft unblock tk-im1 >/dev/null; must 'unblock an imported task' 0 || return 1
  [ "$(task_state tk-im1)" = ready ] || { echo "unblock gave $(task_state tk-im1)"; return 1; }
}

# A re-sent key carries the values of its first event; a retry with other values is refused.
case_check_values() {
  BIN=$1; reset_db
  local t=tk-cv ev row
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft check $t A2@- --status pass --key k-v --evidence e1 --head h1
  must 'first check' 0 || return 1
  ft check $t A2@- --status pass --key k-v --evidence e1 --head h1
  must 'identical re-send' 0 || return 1
  for ev in "--status fail --evidence e1 --head h1" "--status pass --evidence e2 --head h1" "--status pass --evidence e1 --head h2"; do
    # shellcheck disable=SC2086 # the words are the arguments
    ft check $t A2@- --key k-v $ev
    must "re-send with other values ($ev)" 5 || return 1
  done
  ft check $t A3@- --status pass --key k-v --evidence e1 --head h1
  must 're-send on another row' 5 || return 1
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A2") | .status == "pass" and .evidence == "e1" and .head == "h1"' >/dev/null || { echo "a refused re-send changed the row"; return 1; }
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A3") | .status == "pending"' >/dev/null || { echo "a refused re-send changed another row"; return 1; }
  # the row takes the values stored in its newest event, even when the row was damaged
  row=$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .id')
  api -X PATCH "$BASE/api/fm_task_check/$row" -d '{"status":"fail","evidence":"damaged"}' >/dev/null
  ft check $t A2@- --status pass --key k-v --evidence e1 --head h1
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A2") | .status == "pass" and .evidence == "e1"' >/dev/null || { echo "the re-send did not restore the stored values"; return 1; }
}

# Parallel checks on one row leave the values of the newest check event on the row.
case_check_parallel() {
  BIN=$1; reset_db
  local t=tk-cp round i st newest row pids
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  # the first call's patch is held until a second call has finished: the newest event still wins
  curl -s -X POST "$BASE/__x/delay/fm_task_check?ms=700&n=1" >/dev/null
  ( "$BIN/fm-task.sh" check $t A2@- --status pass --evidence slow --head hs > "$TMP_ROOT/cp.slow" 2>&1 ) &
  pids=($!)
  sleep 0.3
  ft check $t A2@- --status fail --evidence fast --head hf
  must 'the fast check' 0 || return 1
  wait "${pids[@]}"
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A2") | .status == "fail" and .evidence == "fast" and .head == "hf"' >/dev/null \
    || { echo "a slow older check overwrote the newest: $(db fm_task_check | jq -c '.[] | select(.scenarioId == "A2") | {status, evidence, head}')"; return 1; }
  for round in 1 2 3 4 5 6; do
    pids=()
    for i in 1 2 3 4 5 6 7 8; do
      st=pass; [ $((i % 2)) = 0 ] && st=fail
      ( "$BIN/fm-task.sh" check $t A2@- --status $st --evidence "r$round-$i" --head "h$round-$i" > "$TMP_ROOT/cp.$i" 2>&1 ) &
      pids+=($!)
    done
    wait "${pids[@]}"
    newest=$(db fm_task_event | jq -c '[.[] | select(.kind == "check" and (.body | fromjson | .row == "A2@-"))] | max_by(.seq) | .body | fromjson | .values')
    row=$(db fm_task_check | jq -c '.[] | select(.scenarioId == "A2") | {status, evidence, head}')
    [ "$(jq -c '{status, evidence, head}' <<<"$newest")" = "$row" ] || { echo "round $round: the row holds $row, the newest event stored $newest"; return 1; }
  done
}

# owner-check with unchanged fields changes nothing; a row reset to pending reopens its item.
case_owner_repeat() {
  BIN=$1; reset_db
  local t=tk-or events row_before item_before id
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  OC=(owner-check "$t" A1@1440 --page-title Home --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e)
  ft "${OC[@]}"; must 'owner-check' 0 || return 1
  events=$(count fm_task_event); item_before=$(db fm_owner_check | jq -S -c .); row_before=$(db fm_task_check | jq -S -c .)
  ft "${OC[@]}"; must 'owner-check repeated' 0 || return 1
  [ "$(count fm_task_event)" = "$events" ] || { echo "a repeat stored an event"; return 1; }
  [ "$(db fm_owner_check | jq -S -c .)" = "$item_before" ] || { echo "a repeat changed the item"; return 1; }
  [ "$(db fm_task_check | jq -S -c .)" = "$row_before" ] || { echo "a repeat changed the rows"; return 1; }
  # the owner answered; the row is set to pending again by hand: the item is pending again too
  id=$(db fm_owner_check | jq -r '.[0].id')
  api -X PATCH "$BASE/api/fm_owner_check/$id" -d '{"status":"pass"}' >/dev/null
  ft check $t A1@1440 --status pending --next-actor owner >/dev/null
  [ "$(db fm_owner_check | jq -r '.[0].status')" = pending ] || { echo "a row set to pending left its item at $(db fm_owner_check | jq -r '.[0].status')"; return 1; }
  # the row passed meanwhile; the same owner-check opens both again
  api -X PATCH "$BASE/api/fm_owner_check/$id" -d '{"status":"pass"}' >/dev/null
  ft check $t A1@1440 --status pass >/dev/null
  ft "${OC[@]}"; must 'owner-check after the row passed' 0 || return 1
  [ "$(db fm_owner_check | jq -r '.[0].status')" = pending ] && [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .status + "/" + .nextActor')" = pending/owner ] \
    || { echo "owner-check did not open the row and the item again"; return 1; }
  # a row reset by the issue edit reopens its item
  api -X PATCH "$BASE/api/fm_owner_check/$id" -d '{"status":"pass"}' >/dev/null
  ft check $t A1@1440 --status pass >/dev/null
  use_issue v2; ft rows $t "$ISSUE" >/dev/null
  [ "$(db fm_owner_check | jq -r '.[0].status')" = pending ] || { echo "rows reset the row but left the item at $(db fm_owner_check | jq -r '.[0].status')"; return 1; }
}

# A row reset by rows, or reopened by owner-check, supersedes its older check events: a re-sent old key cannot restore the old result.
case_reset_supersedes() {
  BIN=$1; reset_db
  local t=tk-rsup
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  st() { db fm_task_check | jq -r --arg s "$1" '.[] | select(.scenarioId == $s) | .status + "/" + .nextActor'; }
  ft check $t A2@- --status pass --key k-old --evidence first >/dev/null
  use_issue v2; ft rows $t "$ISSUE" >/dev/null
  [ "$(st A2)" = pending/worker ] || { echo "rows did not reset A2: $(st A2)"; return 1; }
  ft check $t A2@- --status pass --key k-old --evidence first
  must 'old pass re-sent after the reset' 0 || return 1
  [ "$(st A2)" = pending/worker ] || { echo "a re-sent old pass restored a reset row: $(st A2)"; return 1; }
  ft check $t A1@1440 --status pass --key k-a1 >/dev/null
  ft owner-check $t A1@1440 --page-title Home --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e >/dev/null
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .status + "/" + .nextActor')" = pending/owner ] || { echo "owner-check did not reopen A1@1440"; return 1; }
  ft check $t A1@1440 --status pass --key k-a1
  must 'old pass re-sent after owner-check' 0 || return 1
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .status + "/" + .nextActor')" = pending/owner ] \
    || { echo "a re-sent old pass restored a row the owner was asked about"; return 1; }
}

# A triage child linked to an open parent still reaches ready after assign once the parent has closed.
case_link_triage() {
  BIN=$1; reset_db
  mk_running tk-lt-p1 >/dev/null; ft create tk-lt-c1 --title c1 --kind ship >/dev/null
  ft link tk-lt-p1 tk-lt-c1; must 'link a triage child' 0 || return 1
  [ "$(task_state tk-lt-c1)" = triage ] || { echo "linking moved the triage child to $(task_state tk-lt-c1)"; return 1; }
  ft "done" tk-lt-p1 "${DONE_FLAGS[@]}" >/dev/null; ft approve tk-lt-p1 >/dev/null
  [ "$(task_state tk-lt-c1)" = triage ] || { echo "closing the parent moved the triage child to $(task_state tk-lt-c1)"; return 1; }
  ft assign tk-lt-c1 --to w; must 'assign after the parent closed' 0 || return 1
  [ "$(task_state tk-lt-c1)" = ready ] || { echo "assign after the parent closed gave $(task_state tk-lt-c1), want ready"; return 1; }
  ft start tk-lt-c1; must 'start the released child' 0 || return 1
  # assign while the parent is still open waits in todo, and the parent closing releases it
  mk_running tk-lt-p2 >/dev/null; ft create tk-lt-c2 --title c2 --kind ship >/dev/null
  ft link tk-lt-p2 tk-lt-c2 >/dev/null; ft assign tk-lt-c2 --to w >/dev/null
  [ "$(task_state tk-lt-c2)" = todo ] || { echo "assign with an open parent gave $(task_state tk-lt-c2), want todo"; return 1; }
  ft "done" tk-lt-p2 "${DONE_FLAGS[@]}" >/dev/null; ft approve tk-lt-p2 >/dev/null
  [ "$(task_state tk-lt-c2)" = ready ] || { echo "the parent closing left the child in $(task_state tk-lt-c2)"; return 1; }
}

# T7: a backlog row in the record (row, notes, section), verbatim; a long one travels in a document child.
# Long comments and skill replies keep their complete note in a document.
case_long_notes() {
  BIN=$1; reset_db
  ft create tk-row1 --title 'Long note task' --kind ship >/dev/null || { echo "setup: $ERR"; return 1; }
  local long_note question_seq
  long_note=$(head -c 7958 /dev/zero | tr '\0' c)
  ft comment tk-row1 --note "$long_note"; must '7958-character comment' 0 || return 1
  question_seq=$(seq_of)
  ft event tk-row1 steer --note "$long_note"; must '7958-character steer' 0 || return 1
  ft show tk-row1 --json; must 'read long steer' 0 || return 1
  [ "$(jq -r .lastNote <<<"$OUT")" = "${long_note:0:300}" ] || return 1
  ft thread tk-row1; must 'read long comment' 0 || return 1
  grep -Fx "$long_note" <<<"$OUT" >/dev/null || return 1
  long_note=$(head -c 20000 /dev/zero | tr '\0' r)
  ft comment tk-row1 --reply-to "$question_seq" --note "$long_note"; must '20000-character reply' 0 || return 1
  ft thread tk-row1; must 'read long reply' 0 || return 1
  grep -Fx "$long_note" <<<"$OUT" >/dev/null || return 1
  ft show tk-row1 --json; must 'show long reply' 0 || return 1
  [ "$(jq -r .lastNote <<<"$OUT")" = "${long_note:0:300}" ] || return 1
}

# T7: a status file the writer creates names the record on line 1; the status readers skip that line.
case_status_view() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/status-view-home"
  mkdir -p "$FM_HOME/state"; rm -f "$FM_HOME/state/tk-sv1.status" "$FM_HOME/state/tk-sv2.status"
  local first
  mk_running tk-sv1 >/dev/null || { echo "setup: $ERR"; return 1; }
  ft heartbeat tk-sv1 --note 'building'
  must 'heartbeat' 0 || return 1
  first=$(head -n 1 "$FM_HOME/state/tk-sv1.status")
  case $first in *'task record'*tk-sv1*) ;; *) echo "line 1 does not name the record: $first"; return 1 ;; esac
  sed -n '2p' "$FM_HOME/state/tk-sv1.status" | grep -q '^working \[at=[0-9]*\]: building' || { echo "line 2: $(sed -n '2p' "$FM_HOME/state/tk-sv1.status")"; return 1; }
  # shellcheck disable=SC2016 # the inner script reads its own arguments
  if bash -c 'source "$1/fm-classify-lib.sh"; status_prefix_unrecognized "$2"' _ "$ROOT/bin" "$first"; then echo "the readers take line 1 for a status prefix"; return 1; fi
  printf 'working [at=1]: older line\n' > "$FM_HOME/state/tk-sv2.status"
  mk_running tk-sv2 >/dev/null || return 1
  ft heartbeat tk-sv2 --note 'more'
  [ "$(head -n 1 "$FM_HOME/state/tk-sv2.status")" = 'working [at=1]: older line' ] || { echo "an existing status file got a new line 1"; return 1; }
}

# T7: a marked task's verify.md gets its deployed: and approved: lines from the record events, once each.
case_verify_view() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/verify-view-home"
  local v1 v2 v3
  rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state" "$FM_HOME/data/tk-vv1" "$FM_HOME/data/tk-vv2" "$FM_HOME/data/tk-vv3"
  v1="$FM_HOME/data/tk-vv1/verify.md" v2="$FM_HOME/data/tk-vv2/verify.md" v3="$FM_HOME/data/tk-vv3/verify.md"
  printf 'surface: user-visible\nissue: %s\nrecord: rows\n' "$ISSUE" > "$v1"
  printf 'surface: user-visible\nissue: %s\n' "$ISSUE" > "$v2"
  printf 'surface: internal\nrecord: rows\n' > "$v3"
  ft create tk-vv1 --title 'Marked' --kind ship >/dev/null || { echo "setup: $ERR"; return 1; }
  ft create tk-vv2 --title 'Unmarked' --kind ship >/dev/null || { echo "setup: $ERR"; return 1; }
  ft event tk-vv1 deploy --head abc123 --key vv-deploy-1
  must 'deploy' 0 || return 1
  ft event tk-vv1 deploy --head abc123 --key vv-deploy-1
  [ "$(grep -c '^deployed: abc123$' "$v1")" = 1 ] || { echo "deployed lines: $(grep -c '^deployed:' "$v1")"; return 1; }
  ft event tk-vv1 deploy --head def456
  [ "$(sed -n 's/^deployed: //p' "$v1" | tail -n 1)" = def456 ] || { echo "the newest deployed head is not last"; return 1; }
  ft event tk-vv1 deploy --head abc123 --key vv-deploy-1
  [ "$(sed -n 's/^deployed: //p' "$v1" | tail -n 1)" = def456 ] || { echo "a replayed older deploy wrote its head again: $(sed -n 's/^deployed: //p' "$v1" | tr '\n' ' ')"; return 1; }
  ft event tk-vv2 deploy --head abc123
  [ "$(cat "$v2")" = "$(printf 'surface: user-visible\nissue: %s' "$ISSUE")" ] || { echo "an unmarked verify file changed"; return 1; }
  mk_running tk-vv3 >/dev/null || { echo "setup: $ERR"; return 1; }
  ft "done" tk-vv3 "${DONE_FLAGS[@]}" >/dev/null || { echo "setup: $ERR"; return 1; }
  ft approve tk-vv3
  must 'approve' 0 || return 1
  grep -q '^approved: firstmate [0-9][0-9]*$' "$v3" || { echo "no approved line: $(cat "$v3")"; return 1; }
}

# HG1: a wait is one paused line keyed on its event, the watcher's reader takes it as a declared wait, and the record
# event that clears it appends one resolved line with the same key, also when another home wrote that event.
case_wait() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/wait-home"
  rm -rf "$FM_HOME" "$TMP_ROOT/wait-other"; mkdir -p "$FM_HOME/state" "$TMP_ROOT/wait-other/state"
  local f n line
  declared() { bash -c 'source "$1/fm-classify-lib.sh"; status_declared_wait_line "$2"' _ "$ROOT/bin" "$1"; }
  use_issue v1
  mk_running tk-w1 >/dev/null || { echo "setup: $ERR"; return 1; }
  ft rows tk-w1 "$ISSUE" >/dev/null || { echo "setup rows: $ERR"; return 1; }
  f="$FM_HOME/state/tk-w1.status"
  ft event tk-w1 wait --next-actor tester --clears-on rows --rows 'A1@1440,A1@390' --note 'A1 on head h1' --key w1-wait
  must 'wait' 0 || return 1
  n=$(seq_of)
  line=$(tail -n 1 "$f")
  [[ $line =~ ^paused\ \[at=[0-9]+\]\ \[key=wait-$n\]:\ waiting\ on\ tester:\ A1\ on\ head\ h1\ \(clears\ on\ rows\)\ \[event=$n\]$ ]] || { echo "paused line: $line"; return 1; }
  [ "$(declared "$f")" = "$line" ] || { echo "the watcher's reader does not take the wait: [$(declared "$f")]"; return 1; }
  ft event tk-w1 wait --next-actor tester --clears-on rows --rows 'A1@1440,A1@390' --note 'A1 on head h1' --key w1-wait
  [ "$(grep -c "key=wait-$n" "$f")" = 1 ] || { echo "a replayed wait wrote a second line"; return 1; }
  FM_HOME="$TMP_ROOT/wait-other" ft check tk-w1 A1@390 pending --evidence waiting --head h1 >/dev/null || return 1
  FM_HOME="$TMP_ROOT/wait-other" ft check tk-w1 A1@1440 pass --evidence e1 --head h1 >/dev/null || { echo "check: $ERR"; return 1; }
  ft deliver tk-w1 --consumer wait-test >/dev/null || { echo "deliver partial rows: $ERR"; return 1; }
  [ "$(declared "$f")" = "$line" ] || { echo 'partial row results cleared the declared wait'; return 1; }
  grep -q '^resolved .*wait-' "$f" && { echo "one of two asked rows resolved the wait"; return 1; }
  FM_HOME="$TMP_ROOT/wait-other" ft check tk-w1 A1@390 pass --evidence e2 --head h1 >/dev/null || { echo "check: $ERR"; return 1; }
  [ -e "$TMP_ROOT/wait-other/state/tk-w1.status" ] && { echo "another home got a status line for the wait"; return 1; }
  grep -q '^resolved .*wait-' "$f" && { echo "the wait resolved before this home read the record"; return 1; }
  ft deliver tk-w1 --consumer wait-test >/dev/null || { echo "deliver: $ERR"; return 1; }
  line=$(tail -n 1 "$f")
  [[ $line =~ ^resolved\ \[at=[0-9]+\]\ \[key=wait-$n\]:\ the\ wait\ on\ tester\ cleared:\ check\ event\ [0-9]+$ ]] || { echo "resolved line: $line"; return 1; }
  [ -z "$(declared "$f")" ] || { echo "the wait still reads as declared: $(declared "$f")"; return 1; }
  ft deliver tk-w1 --consumer wait-test >/dev/null
  [ "$(grep -c "^resolved .*key=wait-$n" "$f")" = 1 ] || { echo "a second read wrote a second resolved line"; return 1; }
  # WF4: a transient block refuses running PR checks; a CI event clears the declared wait.
  mk_running tk-ci >/dev/null || return 1
  ft event tk-ci pr --pr-url https://github.com/example/repo/pull/8 >/dev/null || return 1
  cat > "$TMP_ROOT/ci-gh" <<'SH'
#!/usr/bin/env bash
printf '[{"name":"build","state":"IN_PROGRESS"}]\n'
SH
  chmod +x "$TMP_ROOT/ci-gh"
  FM_TASK_GH="$TMP_ROOT/ci-gh" ft block transient tk-ci --reason 'CI running' --next-actor worker
  must 'transient CI block' 5 || return 1
  [[ "$ERR" == *'event tk-ci wait --next-actor ci --clears-on ci'* ]] || { echo "missing wait command: $ERR"; return 1; }
  [ "$(task_state tk-ci)" = running ] || { echo 'refused block changed task state'; return 1; }
  ft event tk-ci wait --next-actor ci --clears-on ci --note 'checks on h1' >/dev/null || return 1
  local ci_seq
  ci_seq=$(seq_of)
  ft event tk-ci ci --head h2 --note 'delivered CI failure on newer head' >/dev/null || { echo "$ERR"; return 1; }
  grep -q "^resolved .*key=wait-$ci_seq.*cleared: ci event" "$FM_HOME/state/tk-ci.status" || { echo 'CI result did not clear wait'; return 1; }
  ft event tk-ci wait --next-actor ci --clears-on ci --note 'checks on h3' >/dev/null || return 1
  ci_seq=$(seq_of)
  ft event tk-ci ci --head h3 --note 'CI green' >/dev/null || return 1
  grep -q "^resolved .*key=wait-$ci_seq.*cleared: ci event" "$FM_HOME/state/tk-ci.status" || { echo 'green CI did not clear wait'; return 1; }
  # A completed result can arrive just before the wait; only the live PR head counts.
  cat > "$TMP_ROOT/ci-head-gh" <<'SH'
#!/usr/bin/env bash
printf '{"headRefOid":"h3"}\n'
SH
  chmod +x "$TMP_ROOT/ci-head-gh"
  FM_TASK_GH="$TMP_ROOT/ci-head-gh" ft event tk-ci wait --next-actor ci --clears-on ci --note 'already completed h3' >/dev/null || return 1
  ci_seq=$(seq_of)
  grep -q "^resolved .*key=wait-$ci_seq.*cleared: ci event" "$FM_HOME/state/tk-ci.status" || { echo 'current-head CI result before wait did not clear it'; return 1; }
  # the owner's question waits on the answer
  mk_running tk-w2 >/dev/null || return 1
  ft ask tk-w2 "${ASK_FLAGS[@]}" --next-actor owner
  must 'ask owner' 0 || return 1
  line=$(tail -n 1 "$FM_HOME/state/tk-w2.status")
  [[ $line =~ ^paused\ .*waiting\ on\ owner:\ Which\ one\?\ \(clears\ on\ answer\) ]] || { echo "ask owner line: $line"; return 1; }
  ft unblock tk-w2 >/dev/null || return 1
  tail -n 1 "$FM_HOME/state/tk-w2.status" | grep -q '^resolved .*\[key=wait-[0-9]*\]: the wait on owner cleared: unblocked event' || { echo "answer: $(tail -n 1 "$FM_HOME/state/tk-w2.status")"; return 1; }
  # a PR-ready done waits on the merge
  mk_running tk-w3 >/dev/null || return 1
  ft "done" tk-w3 "${DONE_FLAGS[@]}" --pr-url https://github.com/example/repo/pull/7 --head h3
  must 'done pr' 0 || return 1
  sed -n '2p' "$FM_HOME/state/tk-w3.status" | grep -q '^done ' || { echo "the done line is not before the wait"; return 1; }
  tail -n 1 "$FM_HOME/state/tk-w3.status" | grep -q '^paused .*waiting on merge: PR https://github.com/example/repo/pull/7 (clears on merge)' || { echo "done pr: $(tail -n 1 "$FM_HOME/state/tk-w3.status")"; return 1; }
  ft event tk-w3 pr --note 'opened again' >/dev/null
  grep -q '^resolved .*wait-' "$FM_HOME/state/tk-w3.status" && { echo "a pr event that is no merge cleared the wait"; return 1; }
  ft event tk-w3 pr --note 'merged at m1' >/dev/null
  tail -n 1 "$FM_HOME/state/tk-w3.status" | grep -q '^resolved .*the wait on merge cleared: pr event' || { echo "merge: $(tail -n 1 "$FM_HOME/state/tk-w3.status")"; return 1; }
  ft event tk-w3 wait --next-actor tester --clears-on rows
  must 'wait without a note' 2 || return 1
  ft event tk-w3 wait --next-actor nobody --clears-on rows --note x
  must 'wait actor outside the list' 5 || return 1
  ft event tk-w3 comment --clears-on rows --note x
  must 'clears-on on another kind' 2 || return 1
}

# HG2: a pass on an earlier deployed head carries while no later deploy names its id; a deploy that names it, or that
# records nothing, brings the row back to the Tester; gate prints each carried pass with its head; checks reads it.
case_carry() {
  BIN=$1; reset_db
  unset FM_HOME
  local t=tk-carry na due
  na() { task_row $t | jq -r .nextActor; }
  due() { ft checks $t "$@" >/dev/null || return 1; jq -r '[.rows[] | select(.surface == "user-visible") | "\(.key)=\(.due)/\(.carried)"] | join(" ")' <<<"$OUT"; }
  use_issue v1
  mk_running $t >/dev/null || { echo "setup: $ERR"; return 1; }
  { ft rows $t "$ISSUE" >/dev/null && ft "done" $t "${DONE_FLAGS[@]}" --head b0 >/dev/null && ft event $t deploy --head D0 >/dev/null; } || { echo "setup: $ERR"; return 1; }
  { ft check $t A1@1440 pass --evidence https://e/1 --head D0 >/dev/null && ft check $t A1@390 pass --evidence https://e/2 --head D0 >/dev/null; } || { echo "check: $ERR"; return 1; }
  for r in A2@- A3@-; do ft check $t $r pass --evidence https://e/3 >/dev/null || { echo "check $r: $ERR"; return 1; }; done
  ft event $t deploy --head D1 --touched none
  must 'deploy touched none' 0 || return 1
  [ "$(due)" = 'A1@1440=false/true A1@390=false/true' ] || { echo "after a deploy that touched none: $(due)"; return 1; }
  [ "$(na)" = firstmate ] || { echo "a carried pass sent the task to $(na)"; return 1; }
  [ "$(due --as-deployed D9 --touched A1)" = 'A1@1440=true/false A1@390=true/false' ] || { echo "as deployed with A1 touched: $(due --as-deployed D9 --touched A1)"; return 1; }
  [ "$(due)" = 'A1@1440=false/true A1@390=false/true' ] || { echo "checks --as-deployed wrote to the record"; return 1; }
  ft approve $t --key carry-approve-probe
  must 'approve on carried passes' 0 || return 1
  ft gate $t --issue "$ISSUE" --head D1
  must 'gate on carried passes' 0 || return 1
  grep -qx 'A1@1440 carried: pass on head D0, and no later deployed PR names A1' <<<"$OUT" || { echo "gate does not print the carried pass: $OUT"; return 1; }
  # PR 223 review: a carried pass counts only for the latest recorded deployed head, not for any --head
  ft gate $t --issue "$ISSUE" --head D9
  must 'gate on carried passes for a head never deployed' 5 || return 1
  grep -q 'A1@1440 passed on head D0, not the deployed head D9' <<<"$OUT" || { echo "gate let a carried pass count for D9: $OUT"; return 1; }
  # a second task: a deploy that names the id, or records nothing, brings the row back
  t=tk-carry2
  mk_running $t >/dev/null || return 1
  { ft rows $t "$ISSUE" >/dev/null && ft "done" $t "${DONE_FLAGS[@]}" --head b0 >/dev/null && ft event $t deploy --head D0 >/dev/null; } || { echo "setup: $ERR"; return 1; }
  ft check $t A1@1440 pass --evidence https://e/1 --head D0 >/dev/null && ft check $t A1@390 pass --evidence https://e/2 --head D0 >/dev/null || return 1
  for r in A2@- A3@-; do ft check $t $r pass --evidence https://e/3 >/dev/null || return 1; done
  ft event $t deploy --head D1 --touched A1 >/dev/null || return 1
  [ "$(due)" = 'A1@1440=true/false A1@390=true/false' ] || { echo "after a deploy that named A1: $(due)"; return 1; }
  [ "$(na)" = tester ] || { echo "a touched row did not send the task to the Tester: $(na)"; return 1; }
  ft gate $t --issue "$ISSUE" --head D1
  grep -q 'A1@1440 passed on head D0, not the deployed head D1' <<<"$OUT" || { echo "gate let a touched row pass: $OUT"; return 1; }
  ft check $t A1@1440 pass --evidence https://e/1 --head D1 >/dev/null && ft check $t A1@390 pass --evidence https://e/2 --head D1 >/dev/null || return 1
  ft event $t deploy --head D2 >/dev/null || return 1
  [ "$(due)" = 'A1@1440=true/false A1@390=true/false' ] || { echo "a deploy that recorded nothing carried a pass: $(due)"; return 1; }
  ft event $t comment --touched none --note x
  must 'touched on another kind' 2 || return 1
  ft event $t deploy --head D3 --touched 'A1,bad id'
  must 'touched with a bad id' 2 || return 1
  # PR 223 review: the deploys a pass must outlive are those after its head was deployed, not after the check event.
  # A late check on D0, written after D1 touched A1, must not carry through a later deploy that touched none.
  t=tk-carry3
  mk_running $t >/dev/null || return 1
  { ft rows $t "$ISSUE" >/dev/null && ft "done" $t "${DONE_FLAGS[@]}" --head b0 >/dev/null && ft event $t deploy --head D0 >/dev/null; } || { echo "setup: $ERR"; return 1; }
  for r in A2@- A3@-; do ft check $t $r pass --evidence https://e/3 >/dev/null || return 1; done
  ft event $t deploy --head D1 --touched A1 >/dev/null || return 1
  ft check $t A1@1440 pass --evidence https://e/1 --head D0 >/dev/null && ft check $t A1@390 pass --evidence https://e/2 --head D0 >/dev/null || return 1
  ft event $t deploy --head D2 --touched none >/dev/null || return 1
  [ "$(due)" = 'A1@1440=true/false A1@390=true/false' ] || { echo "a late check on D0 carried past D1, which touched A1: $(due)"; return 1; }
  ft approve $t --key carry3-approve-probe
  must 'approve on a late check of a touched head' 5 || return 1
}


# cfw-modules#1678 TR52 (change 194): the board's writer operation runs the one writer as the signed-in owner. An
# answer comments and unblocks, a pass or fail by the owner also sets the row's owner item, and a call without the
# owner the script row appends writes nothing.
case_plan_task() {
  BIN=$1; reset_db
  local doc="$TMP_ROOT/plan.md"
  printf '## Context\nA plan.\n' > "$doc"
  ft create plan-probe --title plan --kind plan --repo demo; must create 0 || return 1
  ft describe plan-probe --document "$doc"; must describe 0 || return 1
  ft plan-check plan-probe; must unapproved 5 || return 1
  ft plan-approve plan-probe; must approve 0 || return 1
  ft plan-check plan-probe; must approved 0 || return 1
  printf '## Context\nChanged plan.\n' > "$doc"
  ft describe plan-probe --document "$doc"; must edit 0 || return 1
  ft plan-check plan-probe; must changed 5 || return 1
  printf '%s\n' '- Parent: shared-spec' > "$doc"
  ft describe plan-probe --document "$doc"; must parent 0 || return 1
  ft plan-spec plan-probe; must spec 0 || return 1
  [ "$OUT" = shared-spec ] || return 1
  ft create sibling --title sibling --kind ship --repo demo; must sibling 0 || return 1
  ft describe sibling --document "$doc"; must description 0 || return 1
  ft plan-approve plan-probe; must split 5 || return 1
}

case_description_thread() {
  BIN=$1; reset_db
  local t=tk-description before
  ft create "$t" --title t --kind other >/dev/null || return 1
  printf '# Probe\n\nFull description.\n' > "$TMP_ROOT/description.md"
  before=$(task_state "$t")
  ft describe "$t" --document "$TMP_ROOT/description.md"
  must 'description' 0 || return 1
  [ "$(task_state "$t")" = "$before" ] || return 1
  db fm_event_document | jq -e --rawfile content "$TMP_ROOT/description.md" '.[] | .title == "Description" and .content == $content and .mediaType == "text/markdown"' >/dev/null || return 1
  ft comment "$t" --note 'first full comment' --actor owner:u-1 --role owner >/dev/null || return 1
  local seq
  seq=$(db fm_task_event | jq '[.[] | select(.kind == "comment")][0].seq')
  ft comment "$t" --note $'second\nfull comment' --actor worker-1 --role worker >/dev/null || return 1
  ft thread "$t"
  must 'thread' 0 || return 1
  [[ "$OUT" == *'owner:u-1'* && "$OUT" == *'owner'* && "$OUT" == *'first full comment'* && "$OUT" == *$'second\nfull comment'* ]] || return 1
  [[ "$OUT" != *'Full description.'* ]] || return 1
  ft thread "$t" --since "$seq"
  must 'thread since' 0 || return 1
  [[ "$OUT" != *'first full comment'* && "$OUT" == *$'second\nfull comment'* ]] || return 1
  ft describe "$t" --document "$TMP_ROOT/missing.md"
  must 'missing description' 2 || return 1
}

case_owner_writer() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/owner-writer-home"
  rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
  local t=tk-ow1 before ow
  ow() { OUT=$("$BIN/fm-task-owner.sh" "$@" 2>"$TMP_ROOT/err"); RC=$?; ERR=$(cat "$TMP_ROOT/err"); }
  mk_running $t >/dev/null || { echo "setup: $ERR"; return 1; }
  ft ask $t "${ASK_FLAGS[@]}" --next-actor owner >/dev/null || { echo "setup ask: $ERR"; return 1; }
  before=$(count fm_task_event)
  local hashbin="$TMP_ROOT/hashbin" oldpath=$PATH
  mkdir -p "$hashbin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$hashbin/sha256sum"
  chmod +x "$hashbin/sha256sum"
  PATH="$hashbin:$oldpath" ow --action comment --task $t --note digest --owner u-1
  must 'failed digest' 2 || return 1
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hashbin/sha256sum"
  PATH="$hashbin:$oldpath" ow --action comment --task $t --note digest --owner u-1
  must 'empty digest' 2 || return 1
  [ "$(count fm_task_event)" = "$before" ] || return 1
  ow --action comment --task $t --note '   ' --owner u-1
  must 'whitespace comment' 2 || return 1
  [ "$(count fm_task_event)" = "$before" ] || return 1
  ow --action comment --task $t --note bad --owner u-1 --to missing-worker
  must 'dead recipient' 2 || return 1
  [ "$(count fm_task_event)" = "$before" ] || return 1
  local legacy_digest
  legacy_digest=$(printf '%s\0%s\0%s' u-1 'KO1 owner comment' "$(date -u +%Y-%m-%dT%H:%M)" | sha256sum)
  legacy_digest=${legacy_digest%% *}
  ft comment $t --note 'KO1 owner comment' --key "owner-comment:$t:$legacy_digest" --actor owner:u-1 --role owner
  must 'legacy owner comment' 0 || return 1
  ow --action comment --task $t --note 'KO1 owner comment' --owner u-1 --to firstmate
  must 'owner comment' 0 || return 1
  ow --action comment --task $t --note 'KO1 owner comment' --owner u-1
  must 'owner comment replay' 0 || return 1
  [ "$(count fm_task_event)" = "$((before + 1))" ] || return 1
  db fm_task_event | jq -e '.[] | select(.kind == "comment") | .actor == "owner:u-1" and .actorRole == "owner" and (.idempotencyKey | startswith("owner-comment:")) and (.body | fromjson | .note == "KO1 owner comment")' >/dev/null || return 1
  local question reply_seq skill
  for skill in why how wait-what; do
    ow --action comment --task $t --note 'Explain task' --ask "$skill" --owner u-1 --to firstmate
    must "question $skill" 0 || return 1
    question=$(db fm_task_event | jq -r --arg skill "$skill" '.[] | select((.body | fromjson | .ask) == $skill) | .seq')
    [ -n "$question" ] || return 1
    grep -R -F -- "Run the $skill skill on task $t. Reply with: bin/fm-task.sh comment $t --reply-to $question --role firstmate --note <output>" "$FM_HOME/state/inbox" >/dev/null || { echo 'missing skill delivery'; return 1; }
    ft comment $t --reply-to "$question" --role firstmate --note 'Skill output'; must 'linked reply' 0 || return 1
    reply_seq=$(seq_of)
    # the printed reply is drawn as Firstmate's on the board, not a worker's
    db fm_task_event | jq -e --argjson seq "$reply_seq" --argjson q "$question" '.[] | select(.seq == $seq) | (.body | fromjson | .replyTo) == $q and .actorRole == "firstmate"' >/dev/null || return 1
  done
  before=$(count fm_task_event)
  ft comment $t --reply-to 1 --note 'not a comment'; must 'noncomment target' 5 || return 1
  ft comment $t --reply-to 999999 --note 'missing'; must 'missing target' 5 || return 1
  ft comment $t --reply-to 1.5 --note 'fraction'; must 'invalid sequence' 2 || return 1
  ft create tk-foreign --title foreign --kind ship; must 'foreign setup' 0 || return 1
  ft comment tk-foreign --note foreign; must 'foreign comment' 0 || return 1
  question=$(seq_of)
  ft comment $t --reply-to "$question" --note 'foreign target'; must 'foreign task target' 5 || return 1
  before=$((before + 2))
  ow --action comment --task $t --note bad --ask unknown --owner u-1
  must 'unknown skill' 2 || return 1
  ow --action answer --task $t --option 'Option A' --ask why --owner u-1
  must 'ask on answer' 2 || return 1
  [ "$(count fm_task_event)" = "$before" ] || return 1
  ow --action answer --task $t --option 'Option A'
  must 'no owner' 2 || return 1
  jq -e '.ok == false and (.error | test("owner"))' <<<"$OUT" >/dev/null || { echo "no-owner answer: $OUT"; return 1; }
  ow --action approve --task $t --owner u-1
  must 'an action outside the list' 2 || return 1
  ow --action answer --task $t --owner u-1
  must 'answer without an option' 2 || return 1
  [ "$(count fm_task_event)" = "$before" ] || { echo "a refused call wrote an event"; return 1; }
  ow --action answer --task $t --option 'Option A' --note 'go' --owner u-1
  must 'answer' 0 || return 1
  jq -e '.ok and .action == "answer" and (.writes | length) == 2' <<<"$OUT" >/dev/null || { echo "answer reply: $OUT"; return 1; }
  [ "$(task_state $t)" = ready ] || { echo "the answer did not unblock: $(task_state $t)"; return 1; }
  db fm_task_event | jq -e --arg t $t '[.[] | select(.taskId == $t and (.kind == "comment" or .kind == "unblocked") and (.body | fromjson | has("replyTo") | not) and ((.idempotencyKey // "") | startswith("owner-comment:") | not))] | length == 2 and all(.actor == "owner:u-1" and .actorRole == "owner") and (map(select(.kind == "comment"))[0].body | fromjson | .note == "answer: Option A - go")' >/dev/null \
    || { echo "the answer events: $(db fm_task_event | jq -c --arg t $t '[.[] | select(.taskId == $t) | {kind, actor, actorRole}]')"; return 1; }
  tail -n 1 "$FM_HOME/state/$t.status" | grep -q '^resolved ' || { echo "the answer wrote no resolved line: $(tail -n 2 "$FM_HOME/state/$t.status")"; return 1; }
  ow --action answer --task $t --option 'Option A' --owner u-1
  must 'answer on a task that is not blocked' 5 || return 1
  jq -e '.ok == false and (.error | test("unblock is not allowed"))' <<<"$OUT" >/dev/null || { echo "a refused unblock: $OUT"; return 1; }
  # an owner row: the owner's pass sets the item, a Tester's check does not
  t=tk-ow2
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e >/dev/null || { echo "setup: $ERR"; return 1; }
  ft check $t A1@1440 pass --evidence tester-shot >/dev/null || return 1
  [ "$(db fm_owner_check | jq -r '.[] | select(.taskId == "tk-ow2") | .status')" = pending ] || { echo "a Tester check set the owner item"; return 1; }
  ow --action fail --task $t --row A1@1440 --owner u-1
  must 'fail without a note' 2 || return 1
  ow --action pass --task $t --row A1@1440 --note 'looks right' --owner u-1
  must 'pass' 0 || return 1
  db fm_owner_check | jq -e '.[] | select(.taskId == "tk-ow2") | .status == "pass" and .note == "looks right" and (.decidedAt | type == "string")' >/dev/null || { echo "owner item after pass: $(db fm_owner_check | jq -c '.[] | select(.taskId == "tk-ow2")')"; return 1; }
  ow --action fail --task $t --row A1@1440 --note 'the title is cut' --owner u-1
  must 'fail' 0 || return 1
  db fm_owner_check | jq -e '.[] | select(.taskId == "tk-ow2") | .status == "fail" and .note == "the title is cut"' >/dev/null || { echo "owner item after fail: $(db fm_owner_check | jq -c '.[] | select(.taskId == "tk-ow2")')"; return 1; }
  [ "$(db fm_task_check | jq -r '.[] | select(.taskId == "tk-ow2" and .scenarioId == "A1" and .width == "1440") | .status')" = fail ] || { echo "the check row did not take the fail"; return 1; }
}

# CL1-CL4 (task-checklist-template T3): create writes the kind's checklist, items pass from the record's evidence,
# off needs a reason and only a cl: row takes it, rows and gate skip cl: rows, and approve refuses an open item.
case_checklist() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/checklist-home"
  rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
  local t=tk-cl1 doc="$TMP_ROOT/cl-plan.md" img="$TMP_ROOT/cl-mock.png" cl seq rows
  ow() { OUT=$("$BIN/fm-task-owner.sh" "$@" 2>"$TMP_ROOT/err"); RC=$?; ERR=$(cat "$TMP_ROOT/err"); }
  clrow() { db fm_task_check | jq -c --arg t "$1" --arg id "cl:$2" '.[] | select(.taskId == $t and .scenarioId == $id)'; }
  printf '# Plan\nok\n' > "$doc"
  printf '\x89PNG\r\n\x1a\n' > "$img"
  ft create $t --title 'Plan probe' --kind plan; must 'create plan' 0 || return 1
  cl=$(db fm_task_check | jq -c --arg t $t '[.[] | select(.taskId == $t)]')
  jq -e '(map(.scenarioId) | sort) == ["cl:decision","cl:mockup","cl:plan","cl:tester"] and all(.[]; .width == "-" and .surface == "checklist" and .nextActor == "firstmate")' <<<"$cl" >/dev/null || { echo "plan template rows: $cl"; return 1; }
  jq -e '(map(select(.status == "pending") | .scenarioId) | sort) == ["cl:decision","cl:mockup","cl:plan"] and (.[] | select(.scenarioId == "cl:tester") | .status == "off" and .evidence == "Plan task: Tester verifies the ship slices it files")' <<<"$cl" >/dev/null || { echo "plan template values: $cl"; return 1; }
  ft checklist $t apply; must 'apply again' 0 || return 1
  [ "$OUT" = 'checklist added=0 total=4' ] && [ "$(count fm_task_check)" = 4 ] || { echo "apply is not idempotent: $OUT, $(count fm_task_check) rows"; return 1; }
  ft create tk-cl0 --title 'No template' --kind ship >/dev/null; ft create tk-cl0b --title 'Other' --kind other >/dev/null
  ft checklist tk-cl0 apply; must 'apply on an internal ship' 0 || return 1
  [ "$OUT" = 'checklist added=0 total=0' ] && [ "$(count fm_task_check)" = 4 ] || { echo "a kind without a template got rows: $OUT"; return 1; }
  # off needs a reason and an existing cl: item; check never writes off
  ft checklist $t off mockup; must 'off without a reason' 2 || return 1
  ft checklist $t off nothing --reason r; must 'off on a missing item' 5 || return 1
  # CL2: a done document passes Plan document with the event that holds it
  ft assign $t --to w1 >/dev/null && ft start $t >/dev/null || return 1
  ft "done" $t "${DONE_FLAGS[@]}" --document "$doc" --document-title '[probe] T3 plan'; must 'done with a document' 0 || return 1
  seq=$(seq_of)
  clrow $t plan | jq -e --arg ev "event:$seq#document" '.status == "pass" and .evidence == $ev' >/dev/null || { echo "plan item: $(clrow $t plan)"; return 1; }
  # a comment image labelled mockup passes Prototype / mockup
  ft comment $t --image "$img" --image-label 'mockup 390'; must 'mockup comment' 0 || return 1
  seq=$(seq_of)
  clrow $t mockup | jq -e --arg ev "event:$seq#image:1" '.status == "pass" and .evidence == $ev' >/dev/null || { echo "mockup item: $(clrow $t mockup)"; return 1; }
  # CL4: approve names the open item
  ft approve $t; must 'approve with an open item' 5 || return 1
  case $ERR in *'cl:decision'*) ;; *) echo "the refusal does not name cl:decision: $ERR"; return 1 ;; esac
  # CL3 through the owner's button: off needs a note, and an off item no longer blocks approve
  ow --action checklist --task $t --item decision --off --owner u-1; must 'owner off without a note' 2 || return 1
  ow --action checklist --task $t --item decision --owner u-1; must 'owner checklist without on or off' 2 || return 1
  ow --action checklist --task $t --item decision --off --note '[probe] no question' --owner u-1; must 'owner off' 0 || return 1
  clrow $t decision | jq -e '.status == "off" and .evidence == "[probe] no question"' >/dev/null || { echo "decision item: $(clrow $t decision)"; return 1; }
  db fm_task_event | jq -e --arg t $t '[.[] | select(.taskId == $t and .kind == "checklist" and .actor == "owner:u-1" and .actorRole == "owner")] | length == 1' >/dev/null || { echo "the owner's off is not an owner event"; return 1; }
  ft approve $t; must 'approve after the items close' 0 || return 1
  # an owner question passes Owner decision once answered; on sets it pending and the record passes it again
  t=tk-cl3
  ft create $t --title 'Plan question' --kind plan >/dev/null && ft assign $t --to w1 >/dev/null && ft start $t >/dev/null || return 1
  ft ask $t "${ASK_FLAGS[@]}" --next-actor owner >/dev/null || return 1
  [ "$(clrow $t decision | jq -r .status)" = pending ] || { echo "an open question passed the item"; return 1; }
  ow --action answer --task $t --option 'Option A' --owner u-1; must 'owner answer' 0 || return 1
  seq=$(db fm_task_event | jq --arg t $t '[.[] | select(.taskId == $t and .kind == "unblocked")] | max_by(.seq).seq')
  clrow $t decision | jq -e --arg ev "event:$seq" '.status == "pass" and .evidence == $ev' >/dev/null || { echo "decision item: $(clrow $t decision)"; return 1; }
  ow --action checklist --task $t --item decision --off --note '[probe] later' --owner u-1; must 'owner off before on' 0 || return 1
  ow --action checklist --task $t --item decision --on --owner u-1; must 'owner on' 0 || return 1
  [ "$(clrow $t decision | jq -r .status)" = pass ] || { echo "an item set on did not pass again: $(clrow $t decision)"; return 1; }
  [ "$(db fm_task_event | jq --arg t $t '[.[] | select(.taskId == $t and .kind == "checklist" and (.body | fromjson | .values.status == "pass"))] | length')" = 2 ] || { echo "the second pass is not its own event"; return 1; }
  # any open question keeps the item open, also after an answered owner question
  ft checklist $t off decision --reason later >/dev/null && ft start $t >/dev/null && ft ask $t "${ASK_FLAGS[@]}" >/dev/null || return 1
  ft checklist $t on decision; must 'on with a question open' 0 || return 1
  [ "$(clrow $t decision | jq -r .status)" = pending ] || { echo "an open question passed the item: $(clrow $t decision)"; return 1; }
  # firstmate's unblock is not the owner's answer; the owner's approval of the current plan is
  t=tk-cl4
  ft create $t --title 'Plan unblock' --kind plan >/dev/null && ft assign $t --to w1 >/dev/null && ft start $t >/dev/null || return 1
  ft ask $t "${ASK_FLAGS[@]}" --next-actor owner >/dev/null && ft unblock $t >/dev/null || return 1
  [ "$(clrow $t decision | jq -r .status)" = pending ] || { echo "firstmate's unblock passed the decision item: $(clrow $t decision)"; return 1; }
  ft plan $t --document "$doc" >/dev/null || return 1
  seq=$(seq_of)
  ft plan-decision $t --decision approve --plan-seq "$seq"; must 'owner plan approval' 0 || return 1
  clrow $t decision | jq -e --arg ev "event:$(seq_of)" '.status == "pass" and .evidence == $ev' >/dev/null || { echo "plan approval did not pass the decision item: $(clrow $t decision)"; return 1; }
  # a revised plan takes the approval back; the owner's changes on it keep the item pending
  ft plan $t --document "$doc" >/dev/null || return 1
  [ "$(clrow $t decision | jq -r .status)" = pending ] || { echo "a revised plan kept the decision pass: $(clrow $t decision)"; return 1; }
  ft plan-decision $t --decision changes --plan-seq "$(seq_of)" >/dev/null || return 1
  [ "$(clrow $t decision | jq -r .status)" = pending ] || { echo "the owner's changes passed the decision item: $(clrow $t decision)"; return 1; }
  # cl:ci follows the head of the newest done call, whatever order the ci results arrive in
  t=tk-cl6
  ft create $t --title 'Ship heads' --kind ship --surface user-visible >/dev/null && ft assign $t --to w1 >/dev/null && ft start $t >/dev/null || return 1
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null && ft event $t ci --head h1 --note 'CI green on the PR at head h1' >/dev/null || return 1
  [ "$(clrow $t ci | jq -r .status)" = pass ] || { echo "green ci on the built head did not pass: $(clrow $t ci)"; return 1; }
  ft changes $t --note 'push h2' >/dev/null && ft start $t >/dev/null && ft "done" $t "${DONE_FLAGS[@]}" --head h2 >/dev/null || return 1
  [ "$(clrow $t ci | jq -r .status)" = pending ] || { echo "a new built head kept the old head's ci pass: $(clrow $t ci)"; return 1; }
  ft event $t ci --head h2 --note 'CI green on the PR at head h2' >/dev/null || return 1
  clrow $t ci | jq -e --arg ev "event:$(seq_of)" '.status == "pass" and .evidence == $ev' >/dev/null || { echo "green ci on the new head did not pass: $(clrow $t ci)"; return 1; }
  ft event $t ci --head h1 --note 'CI failed on the PR at head h1: 1 check(s) did not pass' >/dev/null || return 1
  [ "$(clrow $t ci | jq -r .status)" = pass ] || { echo "a late result for an older head reset the pass: $(clrow $t ci)"; return 1; }
  # a done call without --head: the head the ci result reports
  t=tk-cl7
  ft create $t --title 'Ship no head' --kind ship --surface user-visible >/dev/null && ft assign $t --to w1 >/dev/null && ft start $t >/dev/null || return 1
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null && ft event $t ci --head h9 --note 'CI green on the PR at head h9' >/dev/null || return 1
  clrow $t ci | jq -e --arg ev "event:$(seq_of)" '.status == "pass" and .evidence == $ev' >/dev/null || { echo "green ci after a done without a head did not pass: $(clrow $t ci)"; return 1; }
  # a user-visible ship: rows and gate skip cl: rows; tester, deploy and ci pass from the record
  t=tk-cl2
  ft create $t --title 'Ship probe' --kind ship --surface user-visible >/dev/null || return 1
  [ "$(db fm_task_check | jq -c --arg t $t '[.[] | select(.taskId == $t) | .scenarioId] | sort')" = '["cl:ci","cl:deploy","cl:mockup","cl:tester"]' ] || { echo "ship template: $(db fm_task_check | jq -c --arg t $t '[.[] | select(.taskId == $t)]')"; return 1; }
  use_issue v1
  ft rows $t "$ISSUE"; must 'rows' 0 || return 1
  case $OUT in *'total=4') ;; *) echo "rows counted cl: rows: $OUT"; return 1 ;; esac
  use_issue v3
  ft rows $t "$ISSUE" >/dev/null || return 1
  [ "$(db fm_task_check | jq --arg t $t '[.[] | select(.taskId == $t and (.scenarioId | startswith("cl:")) and .status == "retired")] | length')" = 0 ] || { echo "rows retired a cl: row"; return 1; }
  use_issue v1
  ft rows $t "$ISSUE" >/dev/null || return 1
  ft check $t cl:ci@- pass; must 'check on a cl: row' 2 || return 1
  ft check $t A2@- off; must 'check off on a scenario row' 5 || return 1
  ft assign $t --to w1 >/dev/null && ft start $t >/dev/null && ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null || return 1
  for rows in A1@1440 A1@390 A2@- A3@-; do ft check $t $rows pass --evidence https://example.com/e.png --head h1 >/dev/null || return 1; done
  [ "$(clrow $t tester | jq -r .status)" = pass ] && [ "$(clrow $t deploy | jq -r .status)" = pending ] || { echo "tester/deploy before the deploy: $(clrow $t tester) $(clrow $t deploy)"; return 1; }
  ft event $t deploy --head h1 --note deployed; must 'deploy' 0 || return 1
  clrow $t deploy | jq -e --arg ev "event:$(seq_of)" '.status == "pass" and .evidence == $ev' >/dev/null || { echo "deploy item: $(clrow $t deploy)"; return 1; }
  ft event $t ci --head h1 --note 'CI failed on the PR at head h1: 1 check(s) did not pass' >/dev/null || return 1
  [ "$(clrow $t ci | jq -r .status)" = pending ] || { echo "a failed ci passed the item"; return 1; }
  ft event $t ci --head h1 --note 'CI green on the PR at head h1' >/dev/null || return 1
  [ "$(clrow $t ci | jq -r .status)" = pass ] || { echo "a green ci did not pass the item: $(clrow $t ci)"; return 1; }
  ft gate $t --issue "$ISSUE" --head h1; must 'gate before approve' 5 || return 1
  case $OUT in *cl:*) echo "gate names a cl: row: $OUT"; return 1 ;; esac
  ft approve $t; must 'approve with mockup open' 5 || return 1
  case $ERR in *'cl:mockup@- (pending)'*) ;; *) echo "the refusal does not name cl:mockup: $ERR"; return 1 ;; esac
  ft checklist $t off mockup --reason '[probe] task không có UI' >/dev/null || return 1
  ft checklist $t off tester --reason later >/dev/null && ft checklist $t on tester >/dev/null || return 1
  [ "$(clrow $t tester | jq -r .status)" = pass ] || { echo "an item set on did not pass from the rows: $(clrow $t tester)"; return 1; }
  ft approve $t; must 'approve with every item closed' 0 || return 1
  ft checklist $t on mockup; must 'checklist on a closed task' 5 || return 1
}

# D1 (plan v2 section 3): setup writes one step row per state the task needs, move follows only that setup, and the
# step calls carry the running state's runtime and liveness onto the card, keyed by the spawn generation.
case_workflow() {
  BIN=$1; reset_db
  local step_of
  step_of() { db fm_task_step | jq -c --arg s "$1" '.[] | select(.taskId == "tk-flow" and .state == $s)'; }
  mk_running tk-flow >/dev/null || return 1
  [ "$(task_row tk-flow | jq -r .workflowState)" = queued ] || { echo "a new task is not queued: $(task_row tk-flow)"; return 1; }
  printf '%s' '{"steps":[{"state":"implement","harness":"pi","model":"example","effort":"high","fallbacks":[{"harness":"claude","model":"backup","effort":"low"}]},{"state":"merge"}]}' > "$TMP_ROOT/setup.json"
  printf '%s' '{"steps":[{"state":"merge"},{"state":"implement","harness":"pi","model":"example"}]}' > "$TMP_ROOT/setup-order.json"
  ft setup tk-flow --file "$TMP_ROOT/setup-order.json"; must 'states out of workflow order' 5 || return 1
  ft setup tk-flow --file "$TMP_ROOT/setup.json"; must setup 0 || return 1
  step_of implement | jq -e '.status == "pending" and .position == 0 and .attempt == 0 and (.fallbacks | fromjson | .[0].model == "backup")' >/dev/null || { echo "implement row: $(step_of implement)"; return 1; }
  step_of merge | jq -e '.harness == null and .model == null' >/dev/null || { echo "merge carries a model: $(step_of merge)"; return 1; }
  printf '%s' '{"steps":[{"state":"implement","harness":"pi","model":"example","effort":"high"}]}' > "$TMP_ROOT/setup-one.json"
  ft setup tk-flow --file "$TMP_ROOT/setup-one.json"; must 'skip pending merge' 0 || return 1
  step_of merge | jq -e '.status == "skipped"' >/dev/null || { echo "a removed pending state is not skipped: $(step_of merge)"; return 1; }
  ft setup tk-flow --file "$TMP_ROOT/setup.json"; must 'restore setup selection' 0 || return 1
  ft move tk-flow --to testing; must 'a state outside the setup' 5 || return 1
  ft move tk-flow --to implement; must move 0 || return 1
  printf '%s' '{"steps":[{"state":"implement","harness":"claude","model":"edited","effort":"low"},{"state":"merge"}]}' > "$TMP_ROOT/setup-edit.json"
  ft setup tk-flow --file "$TMP_ROOT/setup-edit.json"; must 'edit the current pending state' 0 || return 1
  task_row tk-flow | jq -e '.stepModel == "edited" and .stepHarness == "claude" and .stepEffort == "low"' >/dev/null || { echo "the card kept the old runtime of its pending state: $(task_row tk-flow)"; return 1; }
  ft setup tk-flow --file "$TMP_ROOT/setup.json"; must 'restore the current pending state' 0 || return 1
  ft step tk-flow start --harness pi --model example --effort high --generation g1; must start 0 || return 1
  task_row tk-flow | jq -e '.workflowState == "implement" and .stepModel == "example" and .stepEffort == "high" and .stepAlive == "alive"' >/dev/null || { echo "card after start: $(task_row tk-flow)"; return 1; }
  [ "$(db fm_task_step | jq '[.[] | select(.taskId == "tk-flow")] | length')" = 2 ] || { echo "a state outside the setup has a row"; return 1; }
  printf '%s' '{"steps":[{"state":"implement","harness":"pi","model":"other"},{"state":"merge"}]}' > "$TMP_ROOT/setup-started.json"
  ft setup tk-flow --file "$TMP_ROOT/setup-started.json"; must 'a setup edit after the start' 0 || return 1
  step_of implement | jq -e '.model == "example" and .status == "running"' >/dev/null || { echo "a setup edit rewrote the running state: $(step_of implement)"; return 1; }
  ft setup tk-flow --file "$TMP_ROOT/setup-one.json"; must 'a started setup keeps its states' 5 || return 1
  ft move tk-flow --to testing; must 'unconfigured state refused while running' 5 || return 1
  [ "$(task_row tk-flow | jq -r .workflowState)" = implement ] || { echo "a refused move moved the card"; return 1; }
  ft step tk-flow start --harness pi --model example --generation g1; must 'the same incarnation again' 0 || return 1
  [ "$OUT" = 'step tk-flow: unchanged' ] || { echo "a repeated start wrote: $OUT"; return 1; }
  # a relaunch: the new incarnation takes the running attempt over; the old one can no longer report
  ft step tk-flow start --harness claude --model opus --effort xhigh --generation g2; must 'relaunch start' 0 || return 1
  step_of implement | jq -e '.attempt == 1 and .model == "opus" and .status == "running"' >/dev/null || { echo "relaunch did not re-point the attempt: $(step_of implement)"; return 1; }
  [ "$(task_row tk-flow | jq -r .stepModel)" = opus ] || { echo "card model after relaunch: $(task_row tk-flow)"; return 1; }
  ft step tk-flow dead --generation g1; must 'stale incarnation refused' 5 || return 1
  [ "$(task_row tk-flow | jq -r .stepAlive)" = alive ] || { echo "a stale report changed the dot"; return 1; }
  ft step tk-flow alive --generation g2; must 'unchanged liveness' 0 || return 1
  [ "$OUT" = 'step tk-flow: unchanged' ] || { echo "an unchanged liveness wrote: $OUT"; return 1; }
  ft step tk-flow dead --generation g2; must dead 0 || return 1
  [ "$(task_row tk-flow | jq -r .stepAlive)" = dead ] || { echo "card dot after dead: $(task_row tk-flow)"; return 1; }
  ft step tk-flow end --reason cleanup --generation g2; must cleanup 0 || return 1
  step_of implement | jq -e '.status == "done" and .endReason == "cleanup" and .endedAt != null' >/dev/null || { echo "cleanup did not end the step: $(step_of implement)"; return 1; }
  ft step tk-flow end --reason cleanup; must 'end with nothing running' 0 || return 1
  [ "$OUT" = 'step tk-flow: unchanged' ] || { echo "a second end wrote: $OUT"; return 1; }
  ft move tk-flow --to merge; must merge 0 || return 1
  task_row tk-flow | jq -e '.workflowState == "merge" and .stepModel == null' >/dev/null || { echo "card at merge: $(task_row tk-flow)"; return 1; }
  ft step tk-flow start --harness pi --model example --generation g3; must 'Merge has no worker' 5 || return 1
  # the owner's Approve & start: setup by owner, then the task moves to its first state
  export FM_HOME="$TMP_ROOT/workflow-home"; rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
  mk_running tk-own >/dev/null || return 1
  OUT=$("$BIN/fm-task-owner.sh" --action setup --task tk-own --setup "$(cat "$TMP_ROOT/setup.json")" --owner u-1 2>"$TMP_ROOT/err"); RC=$?; ERR=$(cat "$TMP_ROOT/err")
  must 'owner setup' 0 || return 1
  jq -e '.ok == true and (.writes | length) == 2' <<<"$OUT" >/dev/null || { echo "owner setup reply: $OUT"; return 1; }
  task_row tk-own | jq -e '.workflowState == "implement" and .setupBy == "owner" and .stepModel == "example"' >/dev/null || { echo "owner setup did not start the flow: $(task_row tk-own)"; return 1; }
  OUT=$("$BIN/fm-task-owner.sh" --action setup --task tk-own --setup "$(cat "$TMP_ROOT/setup-order.json")" --owner u-1 2>"$TMP_ROOT/err"); RC=$?
  must 'owner setup refused' 5 || return 1
  jq -e '.ok == false and (.error | length) > 0' <<<"$OUT" >/dev/null || { echo "a refused owner setup reply: $OUT"; return 1; }
  # leaving a running state ends its attempt; a re-approved setup keeps the state the task is in
  ft step tk-own start --harness pi --model example --effort high --generation o1; must 'owner task start' 0 || return 1
  ft move tk-own --to merge; must 'move on' 0 || return 1
  db fm_task_step | jq -e '.[] | select(.taskId == "tk-own" and .state == "implement") | .status == "done" and .alive == "dead" and .endReason == "moved to merge"' >/dev/null \
    || { echo "the state left behind still runs: $(db fm_task_step | jq -c '.[] | select(.taskId == "tk-own")')"; return 1; }
  OUT=$("$BIN/fm-task-owner.sh" --action setup --task tk-own --setup "$(cat "$TMP_ROOT/setup.json")" --owner u-1 2>"$TMP_ROOT/err"); RC=$?
  must 'owner re-approves under way' 0 || return 1
  jq -e '.ok == true and (.writes | length) == 1' <<<"$OUT" >/dev/null || { echo "a re-approval moved the task: $OUT"; return 1; }
  [ "$(task_row tk-own | jq -r .workflowState)" = merge ] || { echo "a re-approval changed the state: $(task_row tk-own)"; return 1; }
  # approve closes the flow from any state: a state that never started is skipped
  printf '%s' '{"steps":[{"state":"implement","harness":"pi","model":"example","effort":"high"},{"state":"merge"},{"state":"verify","harness":"pi","model":"example"}]}' > "$TMP_ROOT/setup-verify.json"
  mk_running tk-close >/dev/null || return 1
  ft setup tk-close --file "$TMP_ROOT/setup-verify.json"; must 'close setup' 0 || return 1
  ft move tk-close --to implement; must 'close move' 0 || return 1
  ft step tk-close start --harness pi --generation c1; must 'start on the harness default model' 0 || return 1
  db fm_task_step | jq -e '.[] | select(.taskId == "tk-close" and .state == "implement") | .model == "example" and .effort == "high"' >/dev/null \
    || { echo "a start with no model lost the configured one: $(db fm_task_step | jq -c '.[] | select(.taskId == "tk-close")')"; return 1; }
  ft "done" tk-close "${DONE_FLAGS[@]}"; must 'close done' 0 || return 1
  ft approve tk-close; must 'approve before the last state' 0 || return 1
  task_row tk-close | jq -e '.state == "done" and .workflowState == "done" and .stepAlive == null' >/dev/null || { echo "approve did not close the flow: $(task_row tk-close)"; return 1; }
  db fm_task_step | jq -e '[.[] | select(.taskId == "tk-close")] | map({(.state): .status}) | add | .verify == "skipped" and .merge == "skipped" and .implement == "done"' >/dev/null \
    || { echo "approve left steps open: $(db fm_task_step | jq -c '.[] | select(.taskId == "tk-close")')"; return 1; }
  # testing fails back to implement: implement ran last although testing sits later in the setup
  printf '%s' '{"steps":[{"state":"implement","harness":"pi","model":"example"},{"state":"testing","harness":"pi","model":"example"},{"state":"merge"}]}' > "$TMP_ROOT/setup-test.json"
  mk_running tk-back >/dev/null || return 1
  ft setup tk-back --file "$TMP_ROOT/setup-test.json"; must 'back setup' 0 || return 1
  ft move tk-back --to implement; must 'back implement' 0 || return 1
  ft step tk-back start --harness pi --generation b1; must 'back start implement' 0 || return 1
  ft move tk-back --to testing; must 'back testing' 0 || return 1
  ft step tk-back start --harness pi --generation b2; must 'back start testing' 0 || return 1
  api -X POST "$BASE/api/fm_task_check" -d '{"taskId":"tk-back","scenarioId":"T1","width":"1440","status":"fail","nextActor":"worker","surface":"user-visible","page":"p","line":"l","controls":"-","data":"-","proof":"-","acceptanceDigest":"d"}' >/dev/null
  ft move tk-back --to implement; must 'back to implement on a failed row' 0 || return 1
  ft step tk-back start --harness pi --generation b3; must 'back start implement again' 0 || return 1
  api -X PATCH "$BASE/api/fm_task_check/$(db fm_task_check | jq -r '.[] | select(.taskId == "tk-back") | .id')" -d '{"status":"pass"}' >/dev/null
  ft "done" tk-back "${DONE_FLAGS[@]}"; must 'back done' 0 || return 1
  ft approve tk-back; must 'back approve' 0 || return 1
  ft reopen tk-back --reason 'again'; must 'back reopen' 0 || return 1
  [ "$(task_row tk-back | jq -r .workflowState)" = implement ] || { echo "reopen picked the state by position, not by the last run: $(task_row tk-back)"; return 1; }
  ft reopen tk-close --reason 'one more round'; must reopen 0 || return 1
  [ "$(task_row tk-close | jq -r .workflowState)" = implement ] || { echo "reopen did not return to the last state that ran: $(task_row tk-close)"; return 1; }
  db fm_task_step | jq -e '[.[] | select(.taskId == "tk-close")] | map({(.state): .status}) | add | .verify == "pending" and .merge == "pending"' >/dev/null \
    || { echo "reopen left the approved skips: $(db fm_task_step | jq -c '.[] | select(.taskId == "tk-close")')"; return 1; }
  export FM_HOME="$TMP_ROOT/home"
}

# SG1 (#176 Step 5): every write folds the board card's step onto the row: stage by the step rule, stageSince only
# when the step changes, lastEventAt and lastNote from the newest event that is not a backlog view row event,
# reviewer from the newest check, owner-check, approved or changes event.
case_stage() {
  BIN=$1; reset_db
  local t=tk-sg row since prev long
  at_of() { db fm_task_event | jq -r --arg t "$1" --argjson s "$2" '.[] | select(.taskId == $t and .seq == $s) | .createdAt'; }
  step() {  # <label> <want stage> <stageSince: same|new>: the row after the last ft call
    must "$1" 0 || return 1
    row=$(task_row $t); local seq; seq=$(seq_of)
    db fm_task_event | jq -e --argjson seq "$seq" --arg stage "$2" '.[] | select(.seq == $seq) | (.body | fromjson | .stage) == $stage' >/dev/null || { echo "$1: event stage differs from projection"; return 1; }
    [ "$(jq -r .stage <<<"$row")" = "$2" ] || { echo "$1: stage $(jq -r .stage <<<"$row"), want $2: $row"; return 1; }
    [ "$(jq -r .lastEventAt <<<"$row")" = "$(at_of $t "$seq")" ] || { echo "$1: lastEventAt is not the newest event's time: $row"; return 1; }
    since=$(jq -r .stageSince <<<"$row")
    if [ "$3" = new ]; then [ "$since" = "$(at_of $t "$seq")" ] || { echo "$1: stageSince did not move to this event: $row"; return 1; }
    else [ "$since" = "$prev" ] || { echo "$1: stageSince moved inside the step ($prev -> $since)"; return 1; }; fi
    prev=$since
  }
  ft create $t --title t --kind ship --repo example/repo; step 'created: triage is queued' queued new || return 1
  ft assign $t --to worker-1; step 'assigned: ready stays queued' queued same || return 1
  ft start $t; step 'started: running is working' working new || return 1
  ft heartbeat $t --note 'still building'; step 'a heartbeat stays working' working same || return 1
  [ "$(task_row $t | jq -r .lastNote)" = 'still building' ] || { echo "lastNote is not the newest note: $(task_row $t)"; return 1; }
  ft event $t pr --note 'opened' --pr-url https://github.com/example/repo/pull/1; step 'a pr event after started is pr' pr new || return 1
  ft block transient $t --reason 'waiting on CI' --next-actor firstmate; step 'blocked keeps its step' pr same || return 1
  [ "$(task_state $t)" = blocked ] || { echo "the block did not block: $(task_row $t)"; return 1; }
  ft unblock $t; step 'unblocked: ready is queued' queued new || return 1
  ft start $t; step 'started again: no pr since the newest started is working' working new || return 1
  ft "done" $t "${DONE_FLAGS[@]}"; step 'done with no deploy is pr' pr new || return 1
  ft changes $t --note 'fix the label' --actor reviewer-1; step 'changes: ready is queued' queued new || return 1
  [ "$(task_row $t | jq -r .reviewer)" = reviewer-1 ] || { echo "reviewer is not the actor of the newest changes: $(task_row $t)"; return 1; }
  ft start $t; step 'started after changes' working new || return 1
  ft "done" $t "${DONE_FLAGS[@]}"; step 'done again is pr' pr new || return 1
  ft event $t deploy --note 'deployed' --head abc123; step 'a deploy after the newest done is dev' dev new || return 1
  ft comment $t --note 'looks fine'; step 'a comment stays dev' dev same || return 1
  ft approve $t --actor firstmate-1; step 'approved: done is passed' passed new || return 1
  [ "$(task_row $t | jq -r .reviewer)" = firstmate-1 ] || { echo "reviewer is not the actor of the newest approved: $(task_row $t)"; return 1; }
  ft archive $t; step 'archived keeps its step' passed same || return 1
  # lastNote is cut to 300; an event with no note clears it
  t=tk-sg2; prev=''
  mk_running $t >/dev/null || { echo "setup: $ERR"; return 1; }
  long=$(printf 'x%.0s' $(seq 1 400))
  ft comment $t --note "$long"; must 'long note' 0 || return 1
  [ "$(task_row $t | jq -r '.lastNote | length')" = 300 ] || { echo "lastNote is not cut to 300: $(task_row $t | jq -r '.lastNote | length')"; return 1; }
  [ "$(task_row $t | jq -r .reviewer)" = null ] || { echo "a task with no review event has a reviewer: $(task_row $t)"; return 1; }
  # a backlog view row event is not a real event: lastNote and lastEventAt stay on the newest other event
  ft comment $t --note 'real note'; must 'real note' 0 || return 1
  local real_at; real_at=$(at_of $t "$(seq_of)")
  # tasks-axi's cfw5001 backend writes the row event; post one the same way, then reproject from the events
  local next; next=$(( $(db fm_task_event | jq '[.[].seq] | max') + 1 ))
  jq -n --arg t "$t" --argjson seq "$next" '{seq: $seq, taskId: $t, kind: "row", actorRole: "firstmate", actor: "tasks-axi",
      body: ({set: {section: "In flight", row: ($t + " - row text")}} | tojson), idempotencyKey: ("row:" + $t)}' \
    | curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data @- "$BASE/api/fm_task_event"
  ft reproject $t; must 'row event' 0 || return 1
  task_row $t | jq -e --arg at "$real_at" '.lastNote == "real note" and .lastEventAt == $at and .section == "In flight"' >/dev/null \
    || { echo "a row event moved lastNote or lastEventAt: $(task_row $t)"; return 1; }
  # an import's source stamp ({"source","sha256"} under a backfill:<task>: key, fm-task-backfill-lib.mjs) points at a note
  # and is not one: lastNote stays
  local stamp='{"source":"backlog","sha256":"0123abcd"}'
  ft event $t comment --note "$stamp" --key "backfill:$t:backlog:0123abcd"; must 'source stamp' 0 || return 1
  task_row $t | jq -e --arg at "$(at_of $t "$(seq_of)")" '.lastNote == "real note" and .lastEventAt == $at' >/dev/null \
    || { echo "a source stamp became lastNote: $(task_row $t)"; return 1; }
  # the same JSON in a real comment, with no backfill key, is a note
  ft comment $t --note "$stamp"; must 'real comment with stamp JSON' 0 || return 1
  task_row $t | jq -e --arg note "$stamp" '.lastNote == $note' >/dev/null \
    || { echo "a real comment shaped like a stamp did not become lastNote: $(task_row $t)"; return 1; }
  ft comment $t --note 'different prior note'; must 'different prior note' 0 || return 1
  ft comment $t --note "$stamp" --key 'backfill:another-task:backlog:0123abcd'; must 'stamp under another task key' 0 || return 1
  task_row $t | jq -e --arg note "$stamp" '.lastNote == $note' >/dev/null \
    || { echo 'a foreign task key hid a real note'; return 1; }
  ft comment $t --note 'real note'; must 'real note again' 0 || return 1  # the note SG2 expects reproject to restore
  # a reconcile divergence ({"field","oldSource","record"} under a reconcile:<task>: key, fm-task-reconcile-lib.mjs) is a
  # comparison record, not a note: lastNote stays
  local diverged='{"field":"nextActor","oldSource":"tester","record":"worker"}'
  ft event $t divergence --note "$diverged" --key "reconcile:$t:nextActor:0123abcd"; must 'reconcile divergence' 0 || return 1
  task_row $t | jq -e --arg at "$(at_of $t "$(seq_of)")" '.lastNote == "real note" and .lastEventAt == $at' >/dev/null \
    || { echo "a reconcile divergence became lastNote: $(task_row $t)"; return 1; }
  # SG2: reproject --all fills the step fields of every row, and a second run repairs nothing
  api -X PATCH "$BASE/api/fm_task/$(task_row tk-sg | jq -r .id)" -d '{"stage":null,"stageSince":null}' >/dev/null
  api -X PATCH "$BASE/api/fm_task/$(task_row tk-sg2 | jq -r .id)" -d '{"lastNote":null}' >/dev/null
  ft reproject --all; must 'reproject --all' 0 || return 1
  grep -q '^reproject --all: 2 tasks, 2 repaired$' <<<"$OUT" || { echo "reproject --all did not repair both rows: $OUT"; return 1; }
  [ "$(task_row tk-sg | jq -r .stage)" = passed ] && [ "$(task_row tk-sg2 | jq -r .lastNote)" = 'real note' ] || { echo "reproject --all left a row unfilled: $(task_row tk-sg) $(task_row tk-sg2)"; return 1; }
  ft reproject --all; must 'reproject --all again' 0 || return 1
  [ "$OUT" = 'reproject --all: 2 tasks, 0 repaired' ] || { echo "a second reproject --all repaired again: $OUT"; return 1; }
  return 0
}

# Slice C: plan and plan-decision, done --document for scout/plan, comment --video and approve video cleanup,
# check --evidence-image and gate event: references, event link --url, and fm-task-owner.sh --action plan.
case_slice_c() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/slice-c-home"
  rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state" "$FM_HOME/data"
  local t=tk-sc1 plan_file="$TMP_ROOT/plan.html" doc_file="$TMP_ROOT/report.md" vid_file="$TMP_ROOT/clip.mp4" img_file="$TMP_ROOT/shot.png"
  printf '<h1>Plan v1</h1>\n' > "$plan_file"
  printf '# Scout report\nAll good.\n' > "$doc_file"
  printf 'fake-mp4-video-bytes-12345' > "$vid_file"
  printf '\x89PNG\r\n\x1a\n' > "$img_file"

  # 1. plan and plan-decision
  ft create "$t" --title 'Slice C plan task' --kind ship >/dev/null || return 1
  ft plan "$t"
  must 'plan without --document' 2 || return 1
  ft plan-decision "$t" --decision approve --plan-seq 1
  must 'plan-decision when task has no plan' 5 || return 1
  ft plan "$t" --document "$plan_file" --document-title 'Plan v1'
  must 'plan v1' 0 || return 1
  local pseq1
  pseq1=$(seq_of)
  task_row "$t" | jq -e --argjson s "$pseq1" '.planSeq == $s and .planDecision == null and .planDecidedAt == null' >/dev/null || { echo "planSeq projection failed: $(task_row "$t")"; return 1; }
  db fm_task_event | jq -e --argjson s "$pseq1" '.[] | select(.seq == $s) | .kind == "plan" and .actorRole == "planner"' >/dev/null || { echo "plan event role/kind mismatch"; return 1; }
  db fm_event_document | jq -e '.[] | select(.title == "Plan v1") | .mediaType == "text/html" and (.content | test("Plan v1"))' >/dev/null || { echo "plan document missing"; return 1; }
  ft plan-decision "$t" --decision approve --plan-seq $((pseq1 + 99))
  must 'plan-decision with wrong plan-seq' 5 || return 1
  ft plan-decision "$t" --decision changes --plan-seq "$pseq1" --note 'split step 2'
  must 'plan-decision changes' 0 || return 1
  task_row "$t" | jq -e --argjson s "$pseq1" '.planSeq == $s and .planDecision == "changes" and (.planDecidedAt | type == "string") and .state == "triage"' >/dev/null || { echo "plan-decision projection failed: $(task_row "$t")"; return 1; }

  # Second plan resets planDecision and planDecidedAt
  printf '<h1>Plan v2</h1>\n' > "$plan_file"
  ft plan "$t" --document "$plan_file" --document-title 'Plan v2'
  must 'plan v2' 0 || return 1
  local pseq2
  pseq2=$(seq_of)
  task_row "$t" | jq -e --argjson s "$pseq2" '.planSeq == $s and .planDecision == null and .planDecidedAt == null' >/dev/null || { echo "plan v2 reset failed: $(task_row "$t")"; return 1; }

  # fm-task-owner.sh --action plan delivers inbox note and steers planner when registered
  local steer_log="$TMP_ROOT/planner-steer.log" fake_assist="$TMP_ROOT/fake-assistance.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$steer_log" > "$fake_assist"
  chmod +x "$fake_assist"
  printf -- '- planner - Planner assistance (home: %s/planner)\n' "$TMP_ROOT" > "$FM_HOME/data/assistances.md"
  ow() { OUT=$(FM_TASK_OWNER_ASSISTANCE="$fake_assist" "$BIN/fm-task-owner.sh" "$@" 2>"$TMP_ROOT/err"); RC=$?; ERR=$(cat "$TMP_ROOT/err"); }
  ow --action plan --task "$t" --decision approve --plan-seq "$pseq1" --owner u-1
  must 'owner plan with stale seq' 5 || return 1
  ow --action plan --task "$t" --decision approve --plan-seq "$pseq2" --note 'looks great' --owner u-1
  must 'owner plan approve' 0 || return 1
  task_row "$t" | jq -e --argjson s "$pseq2" '.planSeq == $s and .planDecision == "approve" and (.planDecidedAt | type == "string")' >/dev/null || { echo "owner plan approve failed: $(task_row "$t")"; return 1; }
  grep -R -F -- "approved the plan of task $t (plan seq $pseq2): looks great" "$FM_HOME/state/inbox" >/dev/null || { echo "missing firstmate inbox note for plan"; return 1; }
  grep -F -- "steer planner" "$steer_log" >/dev/null || { echo "missing planner steer: $(cat "$steer_log" 2>/dev/null)"; return 1; }
  grep -F -- "looks great" "$steer_log" >/dev/null || { echo "missing planner words: $(cat "$steer_log" 2>/dev/null)"; return 1; }

  # 2. done --document required for scout and plan tasks
  local ts=tk-sc-scout tp=tk-sc-plan
  ft create "$ts" --title 'Scout task' --kind scout >/dev/null && ft assign "$ts" --to w1 >/dev/null && ft start "$ts" >/dev/null || return 1
  ft "done" "$ts" "${DONE_FLAGS[@]}"
  must 'done on scout without --document' 5 || return 1
  ft "done" "$ts" "${DONE_FLAGS[@]}" --document "$doc_file" --document-title 'Scout Report'
  must 'done on scout with --document' 0 || return 1
  ft create "$tp" --title 'Plan task' --kind plan >/dev/null && ft assign "$tp" --to w1 >/dev/null && ft start "$tp" >/dev/null || return 1
  ft "done" "$tp" "${DONE_FLAGS[@]}"
  must 'done on plan without --document' 5 || return 1
  ft "done" "$tp" "${DONE_FLAGS[@]}" --document "$plan_file" --document-title 'Plan Deliverable'
  must 'done on plan with --document' 0 || return 1
  cl_off "$tp" mockup decision || return 1
  ft approve "$tp" >/dev/null || return 1
  ft plan "$tp" --document "$plan_file"
  must 'plan on closed task' 5 || return 1

  # 3. event link --url
  ft event "$t" link
  must 'event link without --url' 5 || return 1
  ft event "$t" link --url 'javascript:alert(1)'
  must 'event link with unsafe url' 5 || return 1
  ft event "$t" comment --url 'https://example.com'
  must '--url on non-link event' 2 || return 1
  ft event "$t" link --url 'https://example.com/preview' --note 'Preview link'
  must 'event link valid' 0 || return 1
  db fm_task_event | jq -e --arg t "$t" '.[] | select(.taskId == $t and .kind == "link") | (.body | fromjson | .url == "https://example.com/preview" and .note == "Preview link")' >/dev/null || { echo "link event missing"; return 1; }

  # 4. comment --video, check --evidence-image, gate event: reference, and approve video cleanup
  local tv=tk-sc-vid
  ft create "$tv" --title 'Video and evidence task' --kind ship --surface user-visible >/dev/null || return 1
  use_issue v1
  ft rows "$tv" "$ISSUE" >/dev/null || return 1
  cl_off "$tv" ci mockup || return 1
  ft assign "$tv" --to w1 >/dev/null && ft start "$tv" >/dev/null || return 1
  ft comment "$tv" --video "$vid_file"
  must 'video without label' 2 || return 1
  ft comment "$tv" --video "$plan_file" --video-label 'not a video'
  must 'video with bad extension' 5 || return 1
  ft comment "$tv" --video "$vid_file" --video-label 'C4 recording'
  must 'comment with video' 0 || return 1
  local vseq
  vseq=$(seq_of)
  [ "$(count fm_event_video)" = 1 ] || { echo "expected 1 fm_event_video row, got $(count fm_event_video)"; return 1; }
  db fm_event_video | jq -e '.[] | .label == "C4 recording" and .mediaType == "video/mp4" and .size == 26' >/dev/null || { echo "video row mismatch: $(db fm_event_video)"; return 1; }
  ft comment "$tv" --image "$img_file" --image-label 'Desktop screenshot A1@1440' --role tester >/dev/null || return 1
  ft "done" "$tv" "${DONE_FLAGS[@]}" --head h-vid >/dev/null || return 1
  ft event "$tv" deploy --note 'deployed' --head h-vid >/dev/null || return 1

  # Pass rows: A1@390 and A2@- with --evidence-image, A1@1440 initially pointing to the video
  ft check "$tv" A1@1440 pass --evidence "event:${vseq}#video:1" --head h-vid
  must 'check with video evidence' 0 || return 1
  ft check "$tv" A1@390 pass --evidence https://example.com/a1-390.png --head h-vid >/dev/null || return 1
  ft check "$tv" A2@- pass --evidence https://example.com/a2.png --head h-vid >/dev/null || return 1
  ft check "$tv" A3@- pass --evidence https://example.com/a3.png --head h-vid >/dev/null || return 1
  # Approve refuses when a check row references a video and there is no Tester screenshot on the task yet
  ft approve "$tv"
  must 'approve with video evidence and no screenshot' 5 || return 1
  [ "$(count fm_event_video)" = 1 ] || { echo "video was deleted on refused approve"; return 1; }

  # Now check A1@390 with --evidence-image (which writes an fm_event_image comment and records event:<seq>#image:1)
  ft check "$tv" A1@390 pass --evidence-image "$img_file" --evidence-label 'A1@390 screenshot' --head h-vid
  must 'check with --evidence-image' 0 || return 1
  local img_ev
  img_ev=$(db fm_task_check | jq -r '.[] | select(.taskId == "tk-sc-vid" and .scenarioId == "A1" and .width == "390") | .evidence')
  [[ "$img_ev" =~ ^event:[0-9]+#image:1$ ]] || { echo "expected event:<seq>#image:1, got $img_ev"; return 1; }
  ft approve "$tv"
  must 'mobile screenshot cannot replace desktop video evidence' 5 || return 1
  [ "$(count fm_event_video)" = 1 ] || return 1
  ft comment "$tv" --image "$img_file" --image-label 'Desktop screenshot A1@1440' --role tester
  must 'attach exact desktop screenshot' 0 || return 1
  img_ev="event:$(db fm_task_event | jq '[.[] | select(.taskId == "tk-sc-vid" and .kind == "comment")] | max_by(.seq).seq')#image:1"
  rm -f "$img_file"

  # Competing approvals must never append a replacement check after Done.
  "$BIN/fm-task.sh" approve "$tv" --key sc-approve-a >"$TMP_ROOT/sc-approve-a.log" 2>&1 &
  local approve_a=$!
  "$BIN/fm-task.sh" approve "$tv" --key sc-approve-b >"$TMP_ROOT/sc-approve-b.log" 2>&1 &
  local approve_b=$!
  wait "$approve_a" || true
  wait "$approve_b" || true
  db fm_task_event | jq -e '[.[] | select(.taskId == "tk-sc-vid")] as $e | ($e | map(select(.kind == "approved")) | min_by(.seq).seq) as $approved | $approved != null and all($e[]; .kind != "check" or .seq < $approved)' >/dev/null || { echo 'check appended after competing approval'; return 1; }
  [ "$(count fm_event_video)" = 0 ] || { echo "expected 0 fm_event_video rows after approve, got $(count fm_event_video)"; return 1; }
  db fm_task_check | jq -e --arg ev "$img_ev" '.[] | select(.taskId == "tk-sc-vid" and .scenarioId == "A1" and .width == "1440") | .evidence == $ev' >/dev/null \
    || { echo "video evidence was not replaced by Tester screenshot: $(db fm_task_check)"; return 1; }
  db fm_task_event | jq -e '.[] | select(.taskId == "tk-sc-vid" and .kind == "comment") | (.body | fromjson | .note == "1 video deleted after Verify")' >/dev/null \
    || { echo "missing video cleanup comment event"; return 1; }

  # Gate resolves event:<seq>#image:1 even after local img_file was deleted
  ft gate "$tv" --issue "$ISSUE" --head h-vid
  must 'gate with event:<seq>#image:1 evidence' 0 || return 1

  # Gate refuses a broken event:<seq>#image:99 reference
  local tg=tk-sc-gate
  ft create "$tg" --title 'Gate bad event ref' --kind ship --surface user-visible >/dev/null || return 1
  ft rows "$tg" "$ISSUE" >/dev/null && ft assign "$tg" --to w1 >/dev/null && ft start "$tg" >/dev/null || return 1
  cl_off "$tg" ci mockup || return 1
  ft "done" "$tg" "${DONE_FLAGS[@]}" --head h-g >/dev/null && ft event "$tg" deploy --note d --head h-g >/dev/null || return 1
  ft check "$tg" A1@1440 pass --evidence 'event:999999#image:1' --head h-g >/dev/null || return 1
  ft check "$tg" A1@390 pass --evidence https://example.com/1.png --head h-g >/dev/null || return 1
  ft check "$tg" A2@- pass --evidence https://example.com/2.png --head h-g >/dev/null || return 1
  ft check "$tg" A3@- pass --evidence https://example.com/3.png --head h-g >/dev/null || return 1
  ft approve "$tg" >/dev/null || return 1
  ft gate "$tg" --issue "$ISSUE" --head h-g
  must 'gate refuses missing event:<seq>#image:1 reference' 5 || return 1
  return 0
}

# Plan v2 D2: the owner's model rules. rule writes fm_model_rule and logs a rules event on fm-model-rules; rules reads
# the candidates of a state in rank order (enabled, in hours, account, scope), and with --task stops a task that has none.
case_backlog_home() {
  # create and import write this firstmate home's backlog home (config/tasks-axi/.tasks.toml, else .tasks.toml) under the
  # cfw5001 backend, `main` when [cfw5001] names none, and none under another backend: the board reads one backlog home.
  BIN=$1; reset_db
  local cfg="$FM_HOME/config/tasks-axi" rc=0
  mkdir -p "$cfg"
  ft create tk-bh0 --title 'No config' --kind plan; must 'create without config' 0 || return 1
  [ "$(task_row tk-bh0 | jq -r .backlogHome)" = null ] || { echo "no config: $(task_row tk-bh0)"; return 1; }
  printf 'backend = "cfw5001"\n\n[cfw5001]\nhome = "probe-x"\n' > "$cfg/.tasks.toml"
  ft create tk-bh1 --title 'Home probe-x' --kind plan; must 'create in probe-x' 0 || rc=1
  [ "$(task_row tk-bh1 | jq -r .backlogHome)" = probe-x ] || { echo "create: $(task_row tk-bh1)"; rc=1; }
  ft import tk-bh2 --title 'Imported' --kind ship --state ready --assignee - --next-actor worker; must 'import in probe-x' 0 || rc=1
  [ "$(task_row tk-bh2 | jq -r .backlogHome)" = probe-x ] || { echo "import: $(task_row tk-bh2)"; rc=1; }
  printf 'backend = "cfw5001"\n' > "$cfg/.tasks.toml"
  ft create tk-bh3 --title 'Default home' --kind ship; must 'create with no home named' 0 || rc=1
  [ "$(task_row tk-bh3 | jq -r .backlogHome)" = main ] || { echo "default: $(task_row tk-bh3)"; rc=1; }
  printf 'backend = "markdown"\n\n[cfw5001]\nhome = "probe-x"\n' > "$cfg/.tasks.toml"
  ft create tk-bh4 --title 'Markdown home' --kind ship; must 'create under markdown' 0 || rc=1
  [ "$(task_row tk-bh4 | jq -r .backlogHome)" = null ] || { echo "markdown: $(task_row tk-bh4)"; rc=1; }
  rm -rf "$FM_HOME/config"
  # home: the backfill sets the home of a task that has none, once; another home or an archived task is refused
  ft home tk-bh0 --home main; must 'home on a task with none' 0 || rc=1
  [ "$(task_row tk-bh0 | jq -r .backlogHome)" = main ] || { echo "home: $(task_row tk-bh0)"; rc=1; }
  ft home tk-bh0 --home main; must 'the same home again' 0 || rc=1
  [[ $OUT == *'(already)'* ]] || { echo "same home: $OUT"; rc=1; }
  ft home tk-bh1 --home main; must 'another home' 5 || rc=1
  [ "$(task_row tk-bh1 | jq -r .backlogHome)" = probe-x ] || { echo "another home: $(task_row tk-bh1)"; rc=1; }
  ft archive tk-bh4 >/dev/null; ft home tk-bh4 --home main; must 'home on an archived task' 5 || rc=1
  [ "$(task_row tk-bh4 | jq -r .backlogHome)" = null ] || { echo "archived: $(task_row tk-bh4)"; rc=1; }
  return $rc
}

case_owner_hold() {
  # hold and release: the owner's board buttons run fm-captain-hold.sh and tell firstmate; a refused hold tells no one
  BIN=$1
  export FM_HOME="$TMP_ROOT/owner-hold-home"
  rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
  local stub="$TMP_ROOT/owner-hold-stub" log="$TMP_ROOT/owner-hold.log" inbox="$TMP_ROOT/owner-hold-inbox.log" rc=0
  : > "$log"; : > "$inbox"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
printf '%s|' "\$@" >> "$log"
if [ "\$1" = answer ]; then shift 2; [ "\$1" = --decision-file ] && printf 'file=%s' "\$(cat "\$2")" >> "$log"; fi
echo >> "$log"
[ -z "\${HOLD_REFUSE:-}" ] || { echo 'refused: closed' >&2; exit 5; }
echo held
STUB
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$inbox" > "$TMP_ROOT/owner-hold-inbox"
  chmod +x "$stub" "$TMP_ROOT/owner-hold-inbox"
  ohold() { OUT=$(FM_TASK_OWNER_HOLD="$stub" FM_TASK_OWNER_INBOX="$TMP_ROOT/owner-hold-inbox" "$BIN/fm-task-owner.sh" "$@" 2>"$TMP_ROOT/err"); RC=$?; }
  ohold --action hold --task tk-oh1 --note 'wait for the API' --owner u-1; must 'hold' 0 || rc=1
  grep -qx 'hold|tk-oh1|--reason|wait for the API|' "$log" || { echo "hold call: $(cat "$log")"; rc=1; }
  jq -e '.ok and .action == "hold" and .writes == ["held"]' <<<"$OUT" >/dev/null || { echo "hold reply: $OUT"; rc=1; }
  grep -q 'The owner held task tk-oh1 on the board: wait for the API' "$inbox" || { echo "hold note: $(cat "$inbox")"; rc=1; }
  ohold --action release --task tk-oh1 --note 'go on' --owner u-1; must 'release' 0 || rc=1
  grep -q '^answer|tk-oh1|--decision-file|.*|--release|file=go on$' "$log" || { echo "release call: $(cat "$log")"; rc=1; }
  grep -q 'The owner released the hold on task tk-oh1 on the board: go on' "$inbox" || { echo "release note: $(cat "$inbox")"; rc=1; }
  : > "$inbox"
  HOLD_REFUSE=1 ohold --action hold --task tk-oh1 --note 'again' --owner u-1; must 'refused hold' 5 || rc=1
  jq -e '.ok == false and .error == "refused: closed"' <<<"$OUT" >/dev/null || { echo "refused reply: $OUT"; rc=1; }
  [ ! -s "$inbox" ] || { echo "a refused hold told firstmate: $(cat "$inbox")"; rc=1; }
  ohold --action hold --task tk-oh1 --note x; must 'hold without an owner' 2 || rc=1
  return $rc
}

# ACT1-ACT4 (task-checklist-template T5): the board's Done and Approve & start write one owner request each, delivered
# to firstmate as a wake that names bin/fm-owner-request.sh; that command answers the request with one result event.
case_owner_request() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/owner-request-home"
  rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
  local t=tk-or1 rc=0 stubs="$TMP_ROOT/owner-request-stubs" calls="$TMP_ROOT/owner-request-calls.log" seq before
  mkdir -p "$stubs"; : > "$calls"
  for name in teardown spawn backlog; do
    cat > "$stubs/$name" <<STUB
#!/usr/bin/env bash
printf '$name|%s\n' "\$*" >> "$calls"
if [ "$name" = backlog ] && [ "\$1" = show ]; then
  [ -z "\${BACKLOG_SHOW_FAIL:-}" ] || { printf 'Error: %s\n' "\$BACKLOG_SHOW_FAIL" >&2; exit 1; }
  printf 'task:\n  id: %s\n  state: queued\n' "\$2"; exit 0
fi
[ -z "\${REFUSE_$name:-}" ] || { printf 'error: %s\n' "\$REFUSE_$name" >&2; exit 1; }
STUB
    chmod +x "$stubs/$name"
  done
  ow() { OUT=$("$BIN/fm-task-owner.sh" "$@" 2>"$TMP_ROOT/err"); RC=$?; ERR=$(cat "$TMP_ROOT/err"); }
  orq() { OUT=$(FM_OWNER_REQUEST_TEARDOWN="$stubs/teardown" FM_OWNER_REQUEST_SPAWN="$stubs/spawn" FM_OWNER_REQUEST_BACKLOG="$stubs/backlog" \
    "$BIN/fm-owner-request.sh" "$@" 2>"$TMP_ROOT/err"); RC=$?; ERR=$(cat "$TMP_ROOT/err"); }
  open_seq() { "$BIN/fm-task.sh" requests "$1" --json | jq -r --arg k "$2" '[.requests[] | select(.kind == $k)][0].seq // empty'; }
  last_kind() { db fm_task_event | jq -r --arg t "$1" '[.[] | select(.taskId == $t)] | sort_by(.seq) | last | .kind'; }
  last_note() { db fm_task_event | jq -r --arg t "$1" '[.[] | select(.taskId == $t)] | sort_by(.seq) | last | .body | fromjson | .note'; }

  # a hold needs his reason
  ow --action hold --task $t --owner u-1; must 'hold without a reason' 2 || rc=1
  ow --action hold --task $t --note '   ' --owner u-1; must 'hold with a blank reason' 2 || rc=1

  # ACT3: Done on a reviewed task whose cleanup refuses: close-refused with the refusal text, the task stays in review
  mk_running $t >/dev/null || { echo "setup: $ERR"; return 1; }
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null || { echo "setup done: $ERR"; return 1; }
  ow --action close --task $t --owner u-1; must 'close' 0 || rc=1
  jq -e '.ok and .action == "close"' <<<"$OUT" >/dev/null || { echo "close reply: $OUT"; rc=1; }
  seq=$(open_seq $t close-request)
  [ -n "$seq" ] || { echo 'no open close-request'; return 1; }
  [ "$(task_row $t | jq -r .nextActor)" = firstmate ] || { echo "close-request next actor: $(task_row $t | jq -r .nextActor)"; rc=1; }
  # the first delivery of a task delivers an open request all the same, and its wake names the command
  grep -F "owner request $seq: $t close-request - run bin/fm-owner-request.sh $t --seq $seq" "$FM_HOME/state/.wake-queue" >/dev/null \
    || { echo "no request wake: $(cat "$FM_HOME/state/.wake-queue" 2>/dev/null)"; rc=1; }
  before=$(count fm_task_event)
  ow --action close --task $t --owner u-1; must 'close replay in the same minute' 0 || rc=1
  [ "$(count fm_task_event)" = "$before" ] || { echo 'a replayed close wrote a second request'; rc=1; }
  [ "$(grep -c "owner request $seq:" "$FM_HOME/state/.wake-queue")" = 1 ] || { echo 'a replayed close woke firstmate twice'; rc=1; }
  : > "$FM_HOME/state/$t.meta"
  REFUSE_teardown='refusing: worktree has uncommitted changes' orq $t --seq "$seq"; must 'refused cleanup' 0 || rc=1
  [ "$(last_kind $t)" = close-refused ] && [ "$(last_note $t)" = 'error: refusing: worktree has uncommitted changes' ] \
    || { echo "refused result: $(last_kind $t) $(last_note $t)"; rc=1; }
  [ "$(task_state $t)" = review ] && [ "$(task_row $t | jq -r .nextActor)" = owner ] || { echo "after a refused cleanup: $(task_row $t)"; rc=1; }
  orq $t --seq "$seq"; must 'an answered request' 0 || rc=1
  grep -q '^result=none' <<<"$OUT" || { echo "an answered request ran again: $OUT"; rc=1; }

  # ACT2: Done again by the same owner in the same minute is a new request after the refusal; the cleanup runs, then
  # approve, then closed
  : > "$calls"
  before=$seq
  ow --action close --task $t --note 'ship it' --owner u-1; must 'second close' 0 || rc=1
  seq=$(open_seq $t close-request)
  [ -n "$seq" ] && [ "$seq" != "$before" ] || { echo "a close asked again after its refusal was a replay: seq=$seq"; rc=1; }
  # one open request per kind: a second owner's Done waits for the first answer
  ow --action close --task $t --owner u-2; must 'a second open close-request' 5 || rc=1
  orq $t --seq "$seq"; must 'close' 0 || rc=1
  grep -qx "teardown|$t" "$calls" || { echo "teardown call: $(cat "$calls")"; rc=1; }
  [ "$(task_state $t)" = "done" ] && [ "$(last_kind $t)" = closed ] || { echo "after close: $(task_state $t) $(last_kind $t)"; rc=1; }
  db fm_task_event | jq -e --arg t $t '[.[] | select(.taskId == $t and .kind == "approved")] | length == 1' >/dev/null || { echo 'approve did not run once'; rc=1; }
  ow --action close --task $t --owner u-3; must 'close on a done task' 5 || rc=1
  # a run stopped between approve and its result: the request is still open on a done task, and a re-run closes it
  t=tk-or6
  mk_running $t >/dev/null || return 1
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null || return 1
  ow --action close --task $t --owner u-1; must 'close' 0 || rc=1
  seq=$(open_seq $t close-request)
  ft approve $t >/dev/null || return 1
  orq $t --seq "$seq"; must 'close after a stopped run' 0 || rc=1
  [ "$(last_kind $t)" = closed ] || { echo "after a stopped run: $(last_kind $t) $(last_note $t)"; rc=1; }

  # a task approve would refuse: nothing is cleaned up and the refusal is the result
  t=tk-or2; : > "$calls"
  mk_running $t >/dev/null || return 1
  ow --action close --task $t --owner u-1; must 'close a running task' 0 || rc=1
  orq $t --seq "$(open_seq $t close-request)"; must 'refused approve' 0 || rc=1
  if ! { [ "$(last_kind $t)" = close-refused ] && grep -q 'approve is not allowed from state running' <<<"$(last_note $t)"; }; then echo "approve refusal: $(last_note $t)"; rc=1; fi
  [ ! -s "$calls" ] || { echo "a refused approve still cleaned up: $(cat "$calls")"; rc=1; }
  [ "$(task_state $t)" = running ] || rc=1
  ft approve $t --check; must 'approve --check on a running task' 5 || rc=1
  # a task with no worker in this home: the cleanup closes its open backlog item; a backlog read that fails refuses
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null || return 1
  ow --action close --task $t --owner u-3; must 'close with an unreadable backlog' 0 || rc=1
  BACKLOG_SHOW_FAIL='backlog adapter unavailable' orq $t --seq "$(open_seq $t close-request)"; must 'unreadable backlog' 0 || rc=1
  if ! { [ "$(last_kind $t)" = close-refused ] && grep -q 'backlog adapter unavailable' <<<"$(last_note $t)" && [ "$(task_state $t)" = review ]; }; then
    echo "an unreadable backlog closed the task: $(last_kind $t) $(task_state $t) $(last_note $t)"; rc=1
  fi
  ow --action close --task $t --owner u-2; must 'close without a worker' 0 || rc=1
  orq $t --seq "$(open_seq $t close-request)"; must 'close without a worker' 0 || rc=1
  if ! { grep -qx "backlog|done $t" "$calls" && ! grep -q '^teardown' "$calls"; }; then echo "cleanup without a worker: $(cat "$calls")"; rc=1; fi
  [ "$(task_state $t)" = "done" ] || rc=1

  # the result kinds need an open request of their kind, a refusal needs its text, and closed needs a done task
  t=tk-or3
  mk_running $t >/dev/null || return 1
  ft event $t closed; must 'closed with no request' 5 || rc=1
  ft event $t close-refused --note x; must 'close-refused with no request' 5 || rc=1
  ft event $t close-refused; must 'close-refused without its text' 2 || rc=1
  ft event $t start-request; must 'start-request on a running task' 5 || rc=1
  ft event $t close-request; must 'close-request' 0 || rc=1
  ft event $t close-request; must 'a second open close-request' 5 || rc=1
  ft event $t closed; must 'closed on a task not done' 5 || rc=1
  ft event $t start-refused --note x; must 'start-refused for a close-request' 5 || rc=1

  # ACT4: Approve & start with an edited setup, then the spawn on the step's runtime; a refused spawn is the result
  t=tk-or4; : > "$calls"
  ft create $t --title "Task $t" --kind ship --repo example/repo >/dev/null || return 1
  ow --action start --task $t --setup '{"steps":[{"state":"implement","harness":"claude","model":"claude-opus-5-5","effort":"high"},{"state":"merge"}]}' --owner u-1
  must 'start with a setup' 0 || rc=1
  db fm_task_step | jq -e --arg t $t '.[] | select(.taskId == $t and .state == "implement") | .source == "owner" and .model == "claude-opus-5-5"' >/dev/null || { echo "owner setup: $(db fm_task_step)"; rc=1; }
  seq=$(open_seq $t start-request)
  [ -n "$seq" ] || { echo "no open start-request: $OUT"; return 1; }
  "$BIN/fm-task.sh" requests $t --json | jq -e '.requests[0].step == {state: "implement", harness: "claude", model: "claude-opus-5-5", effort: "high"}' >/dev/null || { echo "request step: $("$BIN/fm-task.sh" requests $t --json)"; rc=1; }
  # a second owner's Start with another setup is refused before it writes, so the open request keeps its runtime
  ow --action start --task $t --setup '{"steps":[{"state":"implement","harness":"codex","model":"other-model"},{"state":"merge"}]}' --owner u-2
  must 'a second start with another setup' 5 || rc=1
  "$BIN/fm-task.sh" requests $t --json | jq -e '.requests[0].step.model == "claude-opus-5-5"' >/dev/null || { echo "a refused start changed the pending setup: $("$BIN/fm-task.sh" requests $t --json)"; rc=1; }
  orq $t --seq "$seq"; must 'a start without the spawn' 2 || rc=1
  orq $t --seq "$seq" -- /p --mode direct-PR --yolo off --model other; must 'a start that names its own model' 2 || rc=1
  [ "$(task_row $t | jq -r .workflowState)" = queued ] || { echo 'a refused start moved the task'; rc=1; }
  REFUSE_spawn='claude account pin needs a login' orq $t --seq "$seq" -- /p --mode direct-PR --yolo off; must 'refused spawn' 0 || rc=1
  [ "$(last_kind $t)" = start-refused ] && [ "$(last_note $t)" = 'error: claude account pin needs a login' ] || { echo "spawn refusal: $(last_kind $t) $(last_note $t)"; rc=1; }
  grep -qx "spawn|$t /p --mode direct-PR --yolo off --harness claude --model claude-opus-5-5 --effort high" "$calls" || { echo "spawn call: $(cat "$calls")"; rc=1; }
  [ "$(task_row $t | jq -r .workflowState)" = implement ] || { echo "the start did not move to the first state: $(task_row $t)"; rc=1; }
  # still in triage: without the record hook, the start assigns the task before it writes started
  [ "$(task_state $t)" = triage ] || { echo "setup: $(task_state $t)"; return 1; }
  ow --action start --task $t --owner u-3; must 'start again without an edit' 0 || rc=1
  seq=$(open_seq $t start-request)
  orq $t --seq "$seq" -- /p --mode direct-PR --yolo off; must 'start' 0 || rc=1
  [ "$(task_state $t)" = running ] && [ "$(last_kind $t)" = started ] || { echo "after start: $(task_state $t) $(last_kind $t)"; rc=1; }
  [ -z "$(open_seq $t start-request)" ] || { echo 'started did not answer the start-request'; rc=1; }
  ow --action start --task $t --owner u-2; must 'start on a running task' 5 || rc=1
  # --refuse answers either request with firstmate's own reason
  t=tk-or5
  ft create $t --title "Task $t" --kind ship >/dev/null || return 1
  ow --action start --task $t --owner u-1; must 'start' 0 || rc=1
  orq $t --seq "$(open_seq $t start-request)" --refuse 'no capacity on this project now'; must 'refuse' 0 || rc=1
  [ "$(last_kind $t)" = start-refused ] && [ "$(last_note $t)" = 'no capacity on this project now' ] || rc=1
  return $rc
}

case_model_rules() {
  BIN=$1; reset_db
  export TZ=UTC
  local night=2026-11-03T20:00:00Z day=2026-11-03T10:00:00Z sat=2026-10-31T10:00:00Z id1 id2 id3 n row q
  rid() { sed -n 's/^rule=\([^ ]*\) .*/\1/p' <<<"$OUT"; }
  ft rule add --state implement --harness opencode --model ds-flash --rank 1 --hours 17-07,sat,sun --note '[probe] D5'
  must 'rule add' 0 || return 1
  id1=$(rid)
  ft rule add --state implement --harness pi --model sol --effort high --rank 2; id2=$(rid)
  ft rule add --state implement --harness claude --model sonnet --rank 3 --account claude3; id3=$(rid)
  ft rule add --state plan --harness claude --model opus --rank 1 >/dev/null
  [ "$(count fm_model_rule)" = 4 ] || { echo "rules stored: $(count fm_model_rule)"; return 1; }
  # the change log: a rules event per change on the record task, kept out of the board's home
  [ "$(db fm_task_event | jq '[.[] | select(.taskId == "fm-model-rules" and .kind == "rules")] | length')" = 4 ] || { echo "rules events: $(db fm_task_event | jq -c '[.[] | select(.taskId == "fm-model-rules")]')"; return 1; }
  [ "$(task_row fm-model-rules | jq -r .backlogHome)" = system ] || { echo "record task home: $(task_row fm-model-rules)"; return 1; }
  # candidates: rank order, hours wrap past midnight, a day token, the account filter
  ft rules --state implement --repo firstmate --at "$night"; must 'rules at night' 0 || return 1
  [ "$(cut -d" " -f1 <<<"$OUT" | tr '\n' ' ')" = 'rank=1 rank=2 rank=3 ' ] && [[ $(head -1 <<<"$OUT") == *"model=ds-flash"*"id=$id1"* ]] || { echo "night: $OUT"; return 1; }
  ft rules --state implement --repo firstmate --at "$day"
  [[ $OUT != *ds-flash* ]] && [[ $(head -1 <<<"$OUT") == *"id=$id2"* ]] || { echo "an out-of-hours rule ran by day: $OUT"; return 1; }
  ft rules --state implement --repo firstmate --at "$sat"
  [[ $(head -1 <<<"$OUT") == *"id=$id1"* ]] || { echo "the sat token did not hold: $OUT"; return 1; }
  ft rules --state implement --at "$night" --account claude2
  [[ $OUT != *"id=$id3"* ]] || { echo "an account-bound rule ran for another account: $OUT"; return 1; }
  # switched off, it is no candidate; the replayed key changes nothing again
  ft rule set "$id1" --enabled false --key off-1; must 'rule set' 0 || return 1
  ft rule set "$id1" --enabled true --key off-1; must 'rule set replay' 0 || return 1
  [ "$(db fm_model_rule | jq -r --arg id "$id1" '.[] | select(.id == $id) | .enabled')" = false ] || { echo "a replayed key wrote the rule again"; return 1; }
  ft rules --state implement --repo firstmate --at "$night"
  [[ $OUT != *ds-flash* ]] || { echo "an off rule is still a candidate: $OUT"; return 1; }
  # value checks: nothing stored
  n=$(count fm_model_rule)
  ft rule add --state implement --harness h --model m; must 'rule add without rank' 2 || return 1
  ft rule add --state build --harness h --model m --rank 1; must 'rule add of an unknown state' 5 || return 1
  ft rule add --state implement --harness h --model m --rank 1 --hours 'noon'; must 'rule add of bad hours' 5 || return 1
  ft rule set no-such-id --rank 2; must 'rule set of a missing rule' 5 || return 1
  [ "$(count fm_model_rule)" = "$n" ] || { echo "a refused rule was stored"; return 1; }
  # a repo some rule names in its scope uses only those rules; all off, the task stops with the owner question
  ft rule add --state implement --harness opencode --model ds-flash --rank 1 --scope probe-kdb --enabled false >/dev/null
  ft rules --state implement --repo probe-kdb --at "$night"
  [ -z "$OUT" ] || { echo "a scoped repo used the general rules: $OUT"; return 1; }
  ft rules --state implement --repo firstmate --at "$night"
  [[ $OUT == *"id=$id2"* ]] || { echo "the scoped rule hid the general rules from another repo: $OUT"; return 1; }
  mk_ready tk-nm >/dev/null
  ft rules --state implement --repo probe-kdb --at "$night" --task tk-nm
  must 'no candidate with --task' 5 || return 1
  row=$(task_row tk-nm)
  [ "$(jq -r .state <<<"$row")" = blocked ] && [ "$(jq -r .nextActor <<<"$row")" = owner ] && [ "$(jq -r .blockReason <<<"$row")" = 'Không còn model cho Implement' ] \
    || { echo "the task did not stop for the owner: $row"; return 1; }
  q=$(db fm_event_question | jq -c '.[-1]')
  jq -e '(.options | fromjson) == ["Bật opencode ds-flash", "Chờ quota"]' <<<"$q" >/dev/null || { echo "question options: $q"; return 1; }
  grep -q 'waiting on owner: Không còn model cho Implement' "$FM_HOME/state/tk-nm.status" || { echo "no owner wait line"; return 1; }
  n=$(count fm_task_event)
  ft rules --state implement --repo probe-kdb --at "$night" --task tk-nm
  must 'no candidate again' 5 || return 1
  [ "$(count fm_task_event)" = "$n" ] || { echo "a second stop asked the owner twice"; return 1; }
  # the board's owner actions run the same writer as the owner; empty values are left out
  local ow_out
  ow_out=$("$BIN/fm-task-owner.sh" --action rule-add --task fm-model-rules --state verify --harness claude --model opus --rank 4 --effort '' --hours '' --note '[probe] owner' --owner u-1 2>&1)
  jq -e '.ok == true' <<<"$ow_out" >/dev/null || { echo "owner rule-add: $ow_out"; return 1; }
  db fm_model_rule | jq -e '[.[] | select(.state == "verify" and .model == "opus" and .rank == 4 and .enabled == true and .effort == null and .note == "[probe] owner")] | length == 1' >/dev/null || { echo "owner rule row: $(db fm_model_rule)"; return 1; }
  db fm_task_event | jq -e '.[-1] | .kind == "rules" and .actor == "owner:u-1" and .actorRole == "owner"' >/dev/null || { echo "owner rules event: $(db fm_task_event | jq -c '.[-1]')"; return 1; }
  ow_out=$("$BIN/fm-task-owner.sh" --action rule-set --task fm-model-rules --rule "$id2" --enabled false --owner u-1 2>&1)
  jq -e '.ok == true' <<<"$ow_out" >/dev/null && [ "$(db fm_model_rule | jq -r --arg id "$id2" '.[] | select(.id == $id) | .enabled')" = false ] || { echo "owner rule-set: $ow_out"; return 1; }
  ow_out=$("$BIN/fm-task-owner.sh" --action rule-set --task tk-nm --rule "$id2" --enabled true --owner u-1 2>&1)
  jq -e '.ok == false' <<<"$ow_out" >/dev/null || { echo "a rule action on another task ran: $ow_out"; return 1; }
  # delete
  ft rule delete "$id3"; must 'rule delete' 0 || return 1
  db fm_model_rule | jq -e --arg id "$id3" 'all(.[]; .id != $id)' >/dev/null || { echo "the deleted rule is still stored"; return 1; }
  return 0
}

# Plan v2 D3: a round of owner questions on one task, each answered by its seq; owner questions never go to triage,
# while a worker's third block of one kind to firstmate still does (D8, D9, D12).
case_question_round() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/round-home"
  rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
  local t=tk-qr q1 q2 q3 row f ow_out
  q() { ft ask $t --question "$1" --option 'Yes' --option 'No' --recommendation 'Yes' --why 'probe' --next-actor owner; }
  mk_running $t >/dev/null || return 1
  q '[probe] Q1'; must 'first owner ask' 0 || return 1; q1=$(seq_of)
  q '[probe] Q2'; must 'second owner ask from blocked' 0 || return 1; q2=$(seq_of)
  q '[probe] Q3'; must 'third owner ask from blocked' 0 || return 1; q3=$(seq_of)
  row=$(task_row $t)
  [ "$(jq -r .state <<<"$row")" = blocked ] && [ "$(jq -r .nextActor <<<"$row")" = owner ] && [ "$(jq -r .blockRepeats <<<"$row")" = 0 ] \
    || { echo "a round of owner asks left: $row"; return 1; }
  [ "$(db fm_task_event | jq --arg t $t '[.[] | select(.taskId == $t and .kind == "needs-decision")] | length')" = 3 ] || { echo "the round is not three questions"; return 1; }
  ft resume $t
  [[ $OUT == *'OPEN QUESTIONS (3)'*'[probe] Q1'*'[probe] Q2'*'[probe] Q3'* ]] || { echo "resume: $OUT"; return 1; }
  # only an owner question joins the round
  ft ask $t "${ASK_FLAGS[@]}"; must 'a question to firstmate from blocked' 5 || return 1
  # an answer names an open question and one of its options
  ft answer $t --question 999999 --option Yes; must 'answer to no open question' 5 || return 1
  ft answer $t --question "$q1" --option Maybe; must 'answer with an option the question lacks' 5 || return 1
  ft answer $t --question "$q1"; must 'answer with neither option nor note' 2 || return 1
  ft answer $t --question "$q1" --option Yes --key a1; must 'answer one' 0 || return 1
  [ "$(task_state $t)" = blocked ] && [ "$(task_row $t | jq -r .nextActor)" = owner ] || { echo "the first answer moved the task: $(task_row $t)"; return 1; }
  [ "$(task_row $t | jq -r .blockReason)" = '[probe] Q2' ] || { echo "the reason is not the next open question: $(task_row $t)"; return 1; }
  ft answer $t --question "$q1" --option No; must 'a second answer to an answered question' 5 || return 1
  f="$FM_HOME/state/$t.status"
  [ "$(grep -c '^resolved .*the wait on owner cleared: answered' "$f")" = 1 ] || { echo "the first answer cleared $(grep -c '^resolved' "$f") waits"; return 1; }
  ft answer $t --question "$q2" --option No --note 'not now'; must 'answer two' 0 || return 1
  [ "$(task_state $t)" = blocked ] || { echo "the second answer moved the task"; return 1; }
  # the board's one tap: the owner script answers by seq
  ow_out=$("$BIN/fm-task-owner.sh" --action answer --task $t --question "$q3" --option Yes --owner u-1 2>&1)
  jq -e '.ok == true' <<<"$ow_out" >/dev/null || { echo "owner answer: $ow_out"; return 1; }
  row=$(task_row $t)
  [ "$(jq -r .state <<<"$row")" = ready ] && [ "$(jq -r .nextActor <<<"$row")" = worker ] && [ "$(jq -r .blockKind <<<"$row")" = null ] || { echo "the last answer did not return the task: $row"; return 1; }
  db fm_task_event | jq -e --arg t $t --argjson q1 "$q1" --argjson q2 "$q2" --argjson q3 "$q3" '[.[] | select(.taskId == $t and .kind == "answered") | (.body | fromjson | .answer.question)] == [$q1, $q2, $q3]' >/dev/null \
    || { echo "answered events: $(db fm_task_event | jq -c --arg t $t '[.[] | select(.taskId == $t and .kind == "answered") | .body]')"; return 1; }
  db fm_task_event | jq -e --arg t $t '[.[] | select(.taskId == $t and .kind == "answered")][-1] | .actor == "owner:u-1" and .actorRole == "owner"' >/dev/null || { echo "the owner answer is not the owner's"; return 1; }
  [ "$(grep -c '^resolved .*the wait on owner cleared: answered' "$f")" = 3 ] || { echo "not every question's wait cleared"; return 1; }
  ft resume $t; [[ $OUT == *'OPEN QUESTIONS (0)'* ]] || { echo "resume after the round: $OUT"; return 1; }
  # a transient block is no owner round: an owner ask is refused there
  ft start $t >/dev/null; ft block transient $t --reason waiting --next-actor firstmate >/dev/null
  q '[probe] Q4'; must 'an owner ask on a transient block' 5 || return 1
  # D12: a worker's third failure block to firstmate still goes to triage
  ft unblock $t >/dev/null; ft start $t >/dev/null
  local i
  for i in 1 2; do
    ft block failure $t --reason 'same blocker' --next-actor firstmate >/dev/null; ft unblock $t >/dev/null; ft start $t >/dev/null
  done
  ft block failure $t --reason 'same blocker' --next-actor firstmate; must 'third failure block' 0 || return 1
  row=$(task_row $t)
  [ "$(jq -r .state <<<"$row")" = triage ] && [ "$(jq -r .nextActor <<<"$row")" = firstmate ] || { echo "the third failure block did not go to triage: $row"; return 1; }
  return 0
}

# Plan v2 D2 x D1: a setup built from the model rules; a rule switched off leaves the next setup's candidates (D6), and a
# state with no candidate stops the task with the owner question (D7).
case_setup_rules() {
  BIN=$1; reset_db
  export FM_HOME="$TMP_ROOT/setup-rules-home" TZ=UTC
  rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
  local at=2026-11-03T10:00:00Z ida idb idc row step
  rid() { sed -n 's/^rule=\([^ ]*\) .*/\1/p' <<<"$OUT"; }
  step() { db fm_task_step | jq -c --arg t "$1" --arg s "$2" '.[] | select(.taskId == $t and .state == $s)'; }
  ft rule add --state implement --harness opencode --model m-a --rank 1; ida=$(rid)
  ft rule add --state implement --harness pi --model m-b --effort high --rank 2; idb=$(rid)
  ft rule add --state implement --harness claude --model m-c --rank 3 --scope other-repo; idc=$(rid)
  ft rule add --state implement --harness claude --model m-d --rank 4 >/dev/null
  mk_ready tk-sr1 >/dev/null || return 1
  ft setup tk-sr1 --from-rules --states implement,merge --at "$at"; must 'setup from rules' 0 || return 1
  step tk-sr1 implement | jq -e --arg a "$ida" --arg b "$idb" '.harness == "opencode" and .model == "m-a" and .source == "rule"
    and (.fallbacks | fromjson) == [{"harness":"pi","model":"m-b","effort":"high"},{"harness":"claude","model":"m-d"}]
    and (.ruleIds | split(",") | .[0] == $a and .[1] == $b)' >/dev/null || { echo "implement step: $(step tk-sr1 implement)"; return 1; }
  step tk-sr1 merge | jq -e '.harness == null and .model == null' >/dev/null || { echo "merge step: $(step tk-sr1 merge)"; return 1; }
  ft setup tk-sr1 --from-rules --file x --states implement; must 'both --file and --from-rules' 2 || return 1
  ft setup tk-sr1 --from-rules; must 'from rules without states' 2 || return 1
  # D6: the first rule switched off, the next setup leaves it out of the step and the fallbacks
  ft rule set "$ida" --enabled false >/dev/null || return 1
  mk_ready tk-sr2 >/dev/null || return 1
  ft setup tk-sr2 --from-rules --states implement,merge --at "$at"; must 'setup after switch-off' 0 || return 1
  step tk-sr2 implement | jq -e '.model == "m-b" and ([.fallbacks | fromjson | .[].model] | index("m-a") | not)' >/dev/null || { echo "switched-off rule still a candidate: $(step tk-sr2 implement)"; return 1; }
  # D7: no candidate for a state stops the task with the owner question
  ft rule set "$idb" --enabled false >/dev/null; ft rule add --state implement --harness h --model m-off --rank 9 --enabled false >/dev/null
  db fm_model_rule | jq -r '.[] | select(.model == "m-d") | .id' | while read -r id; do ft rule set "$id" --enabled false >/dev/null; done
  mk_ready tk-sr3 >/dev/null || return 1
  ft setup tk-sr3 --from-rules --states implement,merge --at "$at"; must 'setup with no candidate' 5 || return 1
  row=$(task_row tk-sr3)
  [ "$(jq -r .state <<<"$row")" = blocked ] && [ "$(jq -r .nextActor <<<"$row")" = owner ] && [ "$(jq -r .blockReason <<<"$row")" = 'Không còn model cho Implement' ] || { echo "no-model stop: $row"; return 1; }
  [ -z "$(step tk-sr3 implement)" ] || { echo "a stopped setup wrote a step row"; return 1; }
  [ -n "$idc" ] || return 1
  return 0
}

CASES=${FM_TASK_CASES:-"plan_task description_thread terminal concurrent transitions block_rules parents value_lists rows owner resume connection reads_and_images check_replay route start_parent approve_head owner_pending rows_closed check_closed row_retired done_head route_back check_values check_parallel owner_repeat link_triage reset_supersedes route_stale rows_route owner_replay check_nulls check_close approve_newest owner_update owner_close import check_word deploy_head gate rows_visible approve_deployed long_notes status_view verify_view owner_writer workflow stage wait carry slice_c model_rules checklist question_round setup_rules backlog_home owner_hold owner_request"}

# ---- real command -------------------------------------------------------------------

for c in $CASES; do
  out=$(case_"$c" "$ROOT/bin" 2>&1) || fail "case $c failed on the real command: $out"
  pass "fm-task $c"
done

live_home_untouched

# FM_TASK_CASES="a b" runs just those cases and skips the mutation proofs.
[ -z "${FM_TASK_CASES:-}" ] || exit 0

# ---- mutation proofs: remove one guard, the case guarding it goes red -----------------------

MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
for f in fm-task.sh fm-task-lib.mjs fm-acceptance.mjs fm-task-owner.sh; do cp "$ROOT/bin/$f" "$TMP_ROOT/$f.orig"; done
cp "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh"; chmod +x "$MBIN/fm-task-owner.sh"
cp "$TMP_ROOT/fm-acceptance.mjs.orig" "$MBIN/fm-acceptance.mjs"
cp "$TMP_ROOT/fm-task.sh.orig" "$MBIN/fm-task.sh"
cp "$ROOT/bin/fm-task-sources-lib.mjs" "$MBIN/fm-task-sources-lib.mjs"
cp "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$ROOT/bin/fm-inbox.sh" "$MBIN/"
cp "$ROOT/bin/fm-owner-request.sh" "$TMP_ROOT/fm-owner-request.sh.orig"; cp "$ROOT/bin/fm-owner-request.sh" "$MBIN/"
chmod +x "$MBIN/fm-task.sh"
LIB="$MBIN/fm-task-lib.mjs"

mutate() {  # <label> <case> <exact source text> <replacement>
  cp "$TMP_ROOT/fm-task-lib.mjs.orig" "$LIB"
  S="$3" R="$4" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$LIB"
  cmp -s "$TMP_ROOT/fm-task-lib.mjs.orig" "$LIB" && fail "mutation '$1' changed nothing"
  if out=$(case_"$2" "$MBIN" 2>&1); then
    fail "removing the guard '$1' left case $2 green"
  fi
  case "$out" in *ERR_MODULE_NOT_FOUND*|*'Cannot find module'*) fail "mutation '$1' failed to load: $out" ;; esac
  pass "guard '$1' is needed: case $2 goes red without it"
}

mutate 'thread prints full comments' description_thread "bodyOf(event).note ?? ''}" "''}"
mutate 'the event and its child travel in one request' terminal 'Object.assign(body, spec.children || {});' ';'
mutate 'an empty value is refused' terminal "if (value === '') throw usage" 'if (false) throw usage'
mutate 'the option count is checked' terminal 'if (options.length < 2 || options.length > 6)' 'if (false)'
mutate 'a seq taken by another writer is retried' concurrent 'if (res.status === 409) {' 'if (false) {'
mutate 'a re-send finds its first event before the rules run' concurrent 'if (prior) {' 'if (false) {'
mutate 'the key makes a re-send return the first event' concurrent 'args.flags.key ||' ''
mutate 'a lost answer is looked up by its key' concurrent 'if (found) return { event: found, replayed: false };' 'if (false) return { event: found, replayed: false };'
mutate 'a refused move is refused' transitions 'if (!TRANSITIONS[command].includes(task.state)) {' 'if (false) {'
mutate 'the third block of one kind goes to triage' block_rules "const triage = kind !== 'dependency' && repeats >= 3;" 'const triage = false;'
mutate 'a different kind starts the count again' block_rules 'streakKind(events) === kind ? task.blockRepeats + 1 : 1' 'task.blockRepeats + 1'
mutate 'a dependency waits in todo on an open parent' parents "state: waiting ? 'todo' : 'ready'" "state: 'ready'"
mutate 'a closed parent releases its children' parents 'if (!child || child.state !== '"'"'todo'"'"' || (await openParents(link.childTaskId)).length) continue;' 'continue;'
mutate 'a dependency needs an open parent' parents 'if (CLOSED.includes(parent.state)) throw rule(`parent ${f.on}' 'if (false) throw rule(`parent ${f.on}'
mutate 'a link cannot make a cycle' parents 'if (!existing && (await wouldCycle(parent, child)))' 'if (false)'
mutate 'a value outside its list is refused' value_lists 'if (!list.includes(value))' 'if (false)'
mutate 'plan approval binds the current Description' plan_task 'bodyOf(approval).descriptionSha256 !== hash' 'false'
mutate 'a changed digest resets a passed row' rows 'row.line !== want.line || row.acceptanceDigest !== want.acceptanceDigest' 'row.line !== want.line'
mutate 'a changed line resets a passed row' rows "changed && row.status === 'pass'" 'false'
mutate 'a removed id is retired' rows "if (wanted.has(key) || row.status === 'retired' ||" "if (true ||"
mutate 'an issue with no template is refused' rows ", 'parse', issue, '--strict']" ", 'parse', issue]"
mutate 'open rows block the approval' rows 'if (open.length) throw rule(`approve is refused' 'if (false) throw rule(`approve is refused'
mutate 'a check row cannot read owner without its item' owner 'if (nextActor === '"'"'owner'"'"' && !(await ownerItem(taskId, target)))' 'if (false)'
mutate 'the owner item and the owner row go together' owner "ok(await http('POST', '/api/fm_owner_check', item), 'the owner item');" "await http('POST', '/api/fm_owner_check', item);"
mutate 'resume lists the last 10 events' resume 'events.slice(-10)' 'events'
mutate 'resume gives the last terminal call with its fields' resume 'for (const field of TEMPLATE_FIELDS[last.kind])' 'for (const field of [])'
mutate 'reproject rebuilds a damaged row' resume 'if (diff.length) {' 'if (false) {'
mutate 'an API that does not answer is exit 3' connection 'throw new Fail(3, `${method} ${pathname}: no answer' 'throw new Fail(1, `${method} ${pathname}: no answer'
mutate 'the last passed row routes the task to firstmate' route 'if (!(await needed())) return;' 'return;'
mutate 'start waits for an open parent' start_parent 'if (parents.length) throw rule(`start is refused' 'if (false) throw rule(`start is refused'
mutate 'a user-visible task needs check rows to be approved' approve_head 'if (task.surface === '"'"'user-visible'"'"' && !visible.length)' 'if (false)'
mutate 'a pass counts only on the head of the latest done' approve_head 'if (stale.length) throw rule(`approve is refused' 'if (false) throw rule(`approve is refused'
mutate 'an owner item reopens its row' owner_pending "values: { status: 'pending', nextActor: 'owner'" "values: { status: row.status, nextActor: 'owner'"
mutate 'rows are refused on a closed task' rows_closed 'if (CLOSED.includes(task.state)) throw rule(`rows is refused' 'if (false) throw rule(`rows is refused'
mutate 'check and owner-check refuse a closed task' check_closed 'if (CLOSED.includes(task.state)) throw rule(`${command} is refused' 'if (false) throw rule(`${command} is refused'
mutate 'a retired row takes no check' row_retired "if (row.status === 'retired') throw rule(\`check row" "if (false) throw rule(\`check row"
mutate 'a pass counts for the head it was taken on' done_head "&& !(r.status === 'pass' && (r.head ?? null) === (f.head ?? null))" "&& r.status !== 'pass'"
mutate 'a row that opens again sends the task back' route_back "return ['worker', 'tester', 'owner'].find((a) => waiting.includes(a)) ?? 'firstmate';" "return 'firstmate';"
mutate 'a re-sent key with other values is refused' check_values 'if (differs.length) throw rule(`the key' 'if (false) throw rule(`the key'
mutate 'a re-sent check cannot undo a newer result' check_replay "const newest = rowEvent(await taskEvents(taskId), row);" "const newest = rowEvent((await taskEvents(taskId)).filter((e) => bodyOf(e).values?.status === 'pass'), row);"
mutate 'the newest check event wins over a slower older call' check_parallel 'if (!v || newest.seq === applied) return;' 'if (!v || applied) return;'
mutate 'an owner-check that changes nothing writes nothing' owner_repeat "row.nextActor === 'owner' && row.status === 'pending') {" "false) {"
mutate 'a row set to pending reopens its item' owner_repeat "if (v.status === 'pending') await reopenItem(taskId" "if (false) await reopenItem(taskId"
mutate 'a row reset by rows supersedes its older check events' reset_supersedes "await resetEvent(key, actorFor(want.surface));
      ok(await http('PATCH', \`/api/fm_task_check/\${row.id}\`, { ...text, ...fresh, nextActor: actorFor(want.surface) }), \`reset the check row" "ok(await http('PATCH', \`/api/fm_task_check/\${row.id}\`, { ...text, ...fresh, nextActor: actorFor(want.surface) }), \`reset the check row"
mutate 'an owner-check supersedes the older check events of its row' reset_supersedes "extra: { row: rowKey(row), values: { status: 'pending', nextActor: 'owner'" "extra: { row: 'none', values: { status: 'pending', nextActor: 'owner'"
mutate 'a pass on another head than the latest done is still open for routing' route_stale "(passedOnOtherHead(r, head, events) ? 'tester' : r.nextActor)" "(r.nextActor)"
mutate 'rows routes a task in review again' rows_route "set: sets }), () => routeReview(taskId, who));" "set: sets }));"
mutate 'a re-sent owner-check does not write its item again' owner_replay "const existing = prior ? null : await ownerItem(taskId, target);" "const existing = await ownerItem(taskId, target);"
mutate 'a re-sent owner-check key with another call is refused' owner_replay "if (prior && (prior.taskId !== taskId ||" "if (false && (prior.taskId !== taskId ||"
mutate 'a new result clears the head and evidence of an older one' check_nulls "evidence: v.evidence ?? null, head: v.head ?? null };" "...(v.evidence ? { evidence: v.evidence } : {}), ...(v.head ? { head: v.head } : {}) };"
mutate 'a check on a task that closed meanwhile is refused' check_close "if (CLOSED.includes(task.state)) throw rule(\`check is refused:" "if (false) throw rule(\`check is refused:"
mutate 'blocked keeps the step it had' stage "task.stage ?? 'queued'" "'queued'"
mutate 'a deploy after the newest done is dev' stage "if (event.kind === 'deploy') deployed = true;" ";"
mutate 'a pr event after the newest started is pr' stage "if (event.kind === 'pr') pullRequest = true;" ";"
mutate 'stageSince moves only when the step changes' stage "if (stage !== task.stage) Object.assign(task, { stage, stageSince: event.createdAt ?? null });" "Object.assign(task, { stage, stageSince: event.createdAt ?? null });"
mutate 'a move outside the setup is refused' workflow "if (!target || (next?.state !== to && !retry))" "if (!target && false)"
mutate 'a report from an older incarnation is refused' workflow "if (generation && started && generation !== started) throw rule(" "if (false) throw rule("
mutate 'a relaunch start marks its incarnation as the running one' workflow "patch: { ...runtime, status: 'running', alive: 'alive', lastHeartbeatAt: now }" "patch: { ...runtime, alive: 'alive', lastHeartbeatAt: now }"
mutate 'a removed pending state is skipped' workflow "...removed.map(s => ({ state: s.state, status: 'skipped' }))" "...[]"
mutate 'reopen lets the states approve skipped wait again' workflow "s.status === 'skipped' && s.endReason === 'approved').map(" "false).map("
mutate 'a start with no model keeps the configured model' workflow "model: args.flags.model || current.model," "model: args.flags.model,"
mutate 'a setup edit leaves a state that ran as it ran' workflow "ran(s.state) ? { state: s.state, position: s.position }" "false ? { state: s.state, position: s.position }"
mutate 'a setup edit of the current pending state shows on the card' workflow "setupAt: new Date().toISOString(), ...card }" "setupAt: new Date().toISOString() }"
mutate 'reopen returns to the state that ran last in event order' workflow "const last = steps.find(s => s.state === lastRan);" "const last = steps.filter(s => ['done', 'failed', 'running'].includes(s.status)).at(-1);"
mutate 'approve skips the states that never started' workflow ": s.status === 'pending' ? [{ state: s.state, status: 'skipped', endReason: 'approved' }] : []);" ": []);"
mutate 'a move ends the running attempt of the state left behind' workflow "const stepWrites = left ? [{ state: left.state, status: 'done'" "const stepWrites = false ? [{ state: left.state, status: 'done'"
mutate 'the reviewer is the actor of the newest review event' stage "if (REVIEWER_KINDS.includes(event.kind)) task.reviewer = event.actor ?? null;" ";"
mutate 'a row event does not move lastNote or lastEventAt' stage "if (event.kind !== 'row' && event.kind !== 'checklist') {" "if (event.kind !== 'checklist') {"
mutate 'a machine record does not become lastNote' stage "if (!isMachineRecord(event, note)) task.lastNote" "task.lastNote"
mutate 'a machine record is one only under its own key' stage "if (!Object.hasOwn(MACHINE_RECORDS, prefix) || taskId !== event.taskId) return false;" ";"
mutate 'a reconcile divergence is a machine record' stage "{ backfill: 'sha256,source', reconcile: 'field,oldSource,record' }" "{ backfill: 'sha256,source' }"
mutate 'lastNote is cut to 300' stage "task.lastNote = note.slice(0, 300) || null" "task.lastNote = note || null"
mutate 'reproject --all repairs every row' stage "      const result = await project(taskId);
      if (!result?.changed.length) continue;" "      continue;"
mutate 'approve judges a row by its newest check event' approve_newest "return v ? { ...r, status: v.status," "return false ? { ...r, status: v.status,"
mutate 'an owner-check update needs --url and --steps' owner_update "if (missing.length) throw rule(" "if (false) throw rule("
mutate 'an owner-check on a task that closed meanwhile is refused' owner_close "if (CLOSED.includes(task.state)) throw rule(\`owner-check is refused:" "if (false) throw rule(\`owner-check is refused:"
mutate 'done document is carried by the event deep insert' terminal '...(documents ? { documents: [documents] } : {})' '...{}'
mutate 'document byte limit is checked before writing' terminal 'bytes.length > 2 * 1024 * 1024' 'false'
mutate 'document UTF-8 is strict' terminal 'fatal: true, ignoreBOM: true' 'fatal: false, ignoreBOM: true'
mutate 'document title requires a document' terminal "if (f['document-title'] !== undefined) throw usage" 'if (false) throw usage'
mutate 'capability block is emitted once' terminal 'if (count === 3) {' 'if (count >= 3) {'
mutate 'an import leaves a task that is already there as it is' import "if (existing) throw rule(\`task \${taskId} already present\`);" "if (false) throw rule(\`task \${taskId} already present\`);"
mutate 'an import checks the state list' import "const state = oneOf(STATES, f.state, 'state');" "const state = f.state;"
mutate 'the result word is the check status' check_word 'oneOf(CHECK_STATUSES, args.pos.status ?? f.status,' 'oneOf(CHECK_STATUSES, f.status,'
mutate 'a result word and another --status are refused' check_word 'if (args.pos.status !== undefined && f.status !== undefined && args.pos.status !== f.status)' 'if (false)'
mutate 'a deploy event head is the head passes count on' deploy_head " || (e.kind === 'deploy' && bodyOf(e).head));" ');'
mutate 'a deploy event head routes a review task again' deploy_head 'head ? () => routeReview(taskId, who) : undefined);' 'undefined);'
mutate 'only deploy and ci events take a head' deploy_head "if (head !== undefined && !headKind)" 'if (false)'
mutate 'the gate needs every user-visible row to pass' gate "problems.push(\`\${key} is '\${row.status}', not pass\`);" ';'
mutate 'the gate checks the evidence path' gate '!fs.existsSync(path.resolve(f['"'"'evidence-root'"'"'] || '"'"'.'"'"', ev))' 'false'
mutate 'the gate needs the deployed head' gate 'if ((row.head ?? null) !== f.head) problems.push' 'if (false) problems.push'
mutate 'the gate needs the current digest' gate 'if (row.line !== want.line || row.acceptanceDigest !== want.acceptanceDigest) problems.push' 'if (false) problems.push'
mutate 'the gate needs an approved event' gate 'if (!approved) problems.push' 'if (false) problems.push'
mutate 'the gate needs the approval newer than the last row' gate 'else if (lastRow && approved.seq < lastRow.seq) problems.push' 'else if (false) problems.push'
mutate 'the gate refuses a task the record does not hold' gate '  if (!fold(events)) {
    out(' '  if (false) {
    out('
mutate 'rows --surface user-visible writes only the Tester rows' rows_visible "surface === 'all' || want.surface === surface" 'true'
mutate 'rows of another surface are left as they are' rows_visible "|| (surface !== 'all' && row.surface !== surface)) continue;" ') continue;'
mutate 'a deployed task needs a deployed head to approve' approve_deployed "&& lastHeadEvent(events)?.kind !== 'deploy') {" '&& false) {'
mutate 'long comments travel in documents' long_notes 'if (spec.note && JSON.stringify({ v: 1, note: spec.note, set: spec.set || {}, ...spec.extra }).length > 8000 - EVENT_STAGE_BUDGET)' 'if (false)'
mutate 'a replayed older deploy adds no deployed line' verify_view 'if (newer.some((e) => bodyOf(e).head)) return;' ';'
mutate 'a status file the writer creates names the record on line 1' status_view 'const head = prior === null ?' 'const head = false ?'
mutate 'only a marked verify file is written' verify_view "if (!/^record: rows\$/m.test(text)) return;" ';'
mutate 'a replayed deploy adds no second deployed line' verify_view "if (lines.filter((l) => l.startsWith('deployed: ')).at(-1) === line) return;" ';'
mutate 'an approved event adds the approved line' verify_view "line = \`approved: firstmate" "return; line = \`approved: firstmate"
mutate 'a wait writes its keyed paused line' wait "if (event.kind === 'wait') {" "if (false) {"
mutate 'a cleared wait gets its resolved line' wait "    if (!by) continue;" "    continue;"
mutate 'rows clear a wait only when every asked row has a result' wait "asked.every((key) =>" "asked.some((key) =>"
mutate 'deliver resolves a wait that another home cleared' wait "  await waitView(taskIdOf(args), taskStream);" ""
mutate 'a question to the owner waits on the answer' wait "nextActor === 'owner' ? (result) => waitOn(" "false ? (result) => waitOn("
mutate 'a PR-ready done waits after its own line' wait "  if (wait) await wait(result);
  await waitView(taskId);" "  await waitView(taskId);"
mutate 'only a merged pr event clears a merge wait' wait "e.kind === 'pr' && /\\bmerged\\b/i.test(" "e.kind === 'pr' && /./.test("
mutate 'a pass carries while no later deploy names its id' carry "  return later.every((e) => Array.isArray(bodyOf(e).touched) && !bodyOf(e).touched.includes(row.scenarioId));" "  return false;"
mutate 'a deploy that names an id brings its row back' carry "Array.isArray(bodyOf(e).touched) && !bodyOf(e).touched.includes(row.scenarioId)" "Array.isArray(bodyOf(e).touched)"
mutate 'a deploy that records nothing touches every row' carry "Array.isArray(bodyOf(e).touched) && !bodyOf(e).touched.includes(row.scenarioId)" "!(bodyOf(e).touched || []).includes(row.scenarioId)"
mutate 'the gate prints each carried pass with its head' carry "&& carried(row, events)) out(" "&& false) out("
mutate 'a carried pass counts the deploys after its head was deployed' carry "const own = [...deploys].reverse().find((e) => bodyOf(e).head === row.head);" "const own = rowEvent(events, row);"
mutate 'a carried pass counts only for the latest deployed head' carry '&& f.head === deployedHead && carried(row, events)) out(' '&& carried(row, events)) out('
mutate 'checks --as-deployed reads a next deploy' carry "const view = as ? [" "const view = false ? ["
mutate 'an owner pass or fail sets the owner item' owner_writer "if (who.role === 'owner' && status !== 'pending') await ownerVerdict(" "if (false) await ownerVerdict("
mutate 'plan-decision refuses a task without a plan' slice_c 'if (!task.planSeq) throw rule' 'if (false) throw rule'
mutate 'plan-decision refuses a mismatched plan-seq' slice_c 'if (task.planSeq !== planSeq) throw rule' 'if (false) throw rule'
mutate 'done on a scout or plan task requires --document' slice_c "if ((task.kind === 'scout' || task.kind === 'plan') && !documents && !/^(shadow|backfill):/.test(who.key)) throw rule" 'if (false) throw rule'
mutate 'approve deletes event videos' slice_c "for (const v of currentVideos) ok(await http('DELETE'" "for (const v of []) ok(await http('DELETE'"
mutate 'approve replaces video evidence with Tester screenshot' slice_c 'if (!replacement) throw rule' 'if (false) throw rule'
mutate 'check --evidence-image records event:<seq>#image:1' slice_c 'evidence = `event:${imgRes.event.seq}#image:1`;' 'evidence = null;'
mutate 'gate checks event:<seq>#image:<n> references' slice_c 'if (!(await eventEvidenceExists(events, ev))) problems.push' 'if (false) problems.push'
mutate 'link event requires http or https --url' slice_c "if (kind === 'link' && (!url || !/^https?:\\/\\/\\S+\$/.test(url) || url.length > 2048)) throw rule" 'if (false) throw rule'
mutate 'create writes the checklist template' checklist 'await applyChecklist(taskId);
    },' '},'
mutate 'rows leaves cl: rows alone' checklist '.filter((row) => !isChecklist(row)).map((row) => [rowKey(row), row]));' '.map((row) => [rowKey(row), row]));'
mutate 'a write passes the items the record proves' checklist 'if (await syncChecklist(taskId)) projected = await project(taskId);' ';'
mutate 'checklist off needs a reason' checklist "if (verb === 'off' && !reason?.trim()) throw usage" 'if (false) throw usage'
mutate 'an open question keeps the decision item open' checklist "if (task.blockKind === 'needs-decision' && task.state === 'blocked') return null;" ''
mutate 'only a green ci passes the ci item' checklist '/\bCI green\b/.test(bodyOf(ci).note' 'true || (bodyOf(ci).note'
mutate 'firstmate'"'"'s unblock is not the owner'"'"'s answer' checklist "e.kind === 'unblocked' && e.actorRole === 'owner'" "e.kind === 'unblocked'"
mutate 'the owner'"'"'s plan approval passes the decision item' checklist 'if (approval) return' 'if (false) return'
mutate 'a passed ci or decision item is checked again' checklist "(r.status === 'pass' && RECHECKED.includes(r.scenarioId))" 'false'
mutate 'a done without a head reads the ci result'"'"'s head' checklist "const head = built ?? (" "const head = built ?? (false && "
mutate 'ci reads only the built head' checklist "newest((e) => e.kind === 'ci' && bodyOf(e).head === head)" "newest((e) => e.kind === 'ci')"
mutate 'rules lists only enabled rules' model_rules "r.enabled === true && inHours(" "inHours("
mutate 'an hour range wraps past midnight' model_rules ": hour >= from || hour < to;" ": false;"
mutate 'a repo named in a scope uses only its scoped rules' model_rules "(scoped.length ? scoped : forState.filter((r) => !r.scope))" "forState"
mutate 'rules with --task stops a task that has no candidate' model_rules "  await stopForNoModel(taskIdOf(args)" "  if (false) await stopForNoModel(taskIdOf(args)"
mutate 'a missing model asks the owner once while it is open' model_rules ".some((e) => bodyOf(e).set?.blockReason === question)) throw rule" ".some(() => false)) throw rule"
mutate 'a re-sent rule key writes nothing again' model_rules "  const prior = await eventByKey(who.key);
  if (prior) {
    out(" "  const prior = null;
  if (prior) {
    out("
mutate 'a block streak survives the unblock that clears blockKind' block_rules "const repeats = streakKind(events) === kind ?" "const repeats = task.blockKind === kind ?"
mutate 'a setup from rules takes the first candidate and the rest as fallbacks' setup_rules "const [first, ...rest] = live;" "const [first, ...rest] = [...live].reverse();"
mutate 'a setup from rules stops a state with no candidate' setup_rules "    if (!live.length) {" "    if (false) {"
mutate 'an owner ask joins a round of open owner questions' question_round "    if (!round) guard('ask', task);" "    guard('ask', task);"
mutate 'an owner question leaves blockRepeats as it was' question_round "    const set = nextActor === 'owner'" "    const set = false"
mutate 'an answered event closes only its question' question_round "    else if (e.kind === 'answered') open = open.filter((call) => call.seq !== bodyOf(e).answer?.question);" ""
mutate 'only the last answer returns the task to its worker' question_round "    const set = left.length
      ?" "    const set = false
      ?"
mutate 'an answer must be one of the question options' question_round "if (!options.includes(f.option)) throw rule" "if (false) throw rule"
mutate 'each owner question waits on its own answer' question_round "(question ? bodyOf(e).answer?.question === question :" "(question ? true :"
mutate 'home refuses a task that is in another home' backlog_home "if (task.backlogHome && task.backlogHome !== home) throw rule" "if (false) throw rule"
mutate 'home refuses an archived task' backlog_home "if (task.state === 'archived') throw rule(\`home is refused" "if (false) throw rule(\`home is refused"
mutate_owner() {  # <label> <exact wrapper text> <replacement>: the owner_writer case goes red
  cp "$TMP_ROOT/fm-task-lib.mjs.orig" "$LIB"
  cp "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh"
  S="$2" R="$3" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$MBIN/fm-task-owner.sh"
  cmp -s "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh" && fail "mutation '$1' changed nothing"
  if out=$(case_owner_writer "$MBIN" 2>&1); then fail "removing the guard '$1' left case owner_writer green"; fi
  cp "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh"
  pass "guard '$1' is needed: case owner_writer goes red without it"
}
mutate_owner 'the writer operation needs the owner the row appends' "case \"\$OWNER\" in ''|" "case \"\$OWNER\" in x|"
mutate_owner 'the writer runs as the owner' 'FM_TASK_ROLE=owner' 'FM_TASK_ROLE=worker'
mutate_owner_hold() {  # <label> <exact source text> <replacement>
  cp "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh"
  S="$2" R="$3" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$MBIN/fm-task-owner.sh"
  cmp -s "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh" && fail "mutation '$1' changed nothing"
  if out=$(case_owner_hold "$MBIN" 2>&1); then fail "removing the guard '$1' left case owner_hold green"; fi
  cp "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh"
  pass "guard '$1' is needed: case owner_hold goes red without it"
}
mutate_owner_hold 'release lifts the hold rather than closing the task' 'run answer "$TASK" --decision-file "$decision_file" --release' 'run answer "$TASK" --decision-file "$decision_file"'
mutate_owner_hold 'only a stored hold tells firstmate' '    if [ "$RC" -eq 0 ]; then
      verb=$([ "$ACTION" = hold ]' '    if true; then
      verb=$([ "$ACTION" = hold ]'
mutate_owner 'an answer unblocks after its comment' 'run comment "$TASK" --note "$text" && run unblock "$TASK" || RC=$?' 'run comment "$TASK" --note "$text" || RC=$?'
mutate 'the first delivery still delivers an open owner request' owner_request '|| open.has(e.seq)' ''
mutate 'a result needs an open request of its kind' owner_request "if (!openRequests(events).some((e) => e.kind === RESULT_REQUEST[kind])) throw rule" "if (false) throw rule"
mutate 'a refused result points the owner at the refusal' owner_request "set: kind === 'closed' ? {} : { nextActor: 'owner' }" 'set: {}'
mutate_owner_request() {  # <label> <exact handler text> <replacement>: the owner_request case goes red
  cp "$TMP_ROOT/fm-task-lib.mjs.orig" "$LIB"
  cp "$TMP_ROOT/fm-owner-request.sh.orig" "$MBIN/fm-owner-request.sh"
  S="$2" R="$3" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$MBIN/fm-owner-request.sh"
  cmp -s "$TMP_ROOT/fm-owner-request.sh.orig" "$MBIN/fm-owner-request.sh" && fail "mutation '$1' changed nothing"
  if out=$(case_owner_request "$MBIN" 2>&1); then fail "removing the guard '$1' left case owner_request green"; fi
  cp "$TMP_ROOT/fm-owner-request.sh.orig" "$MBIN/fm-owner-request.sh"
  pass "guard '$1' is needed: case owner_request goes red without it"
}
mutate_owner_request 'nothing is cleaned up for a task approve would refuse' 'try "$WRITER" approve "$TASK" --check || refuse' 'true || refuse'
mutate_request_owner() {  # <label> <exact owner script text> <replacement>: the owner_request case goes red
  cp "$TMP_ROOT/fm-task-lib.mjs.orig" "$LIB"
  cp "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh"
  S="$2" R="$3" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$MBIN/fm-task-owner.sh"
  cmp -s "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh" && fail "mutation '$1' changed nothing"
  if out=$(case_owner_request "$MBIN" 2>&1); then fail "removing the guard '$1' left case owner_request green"; fi
  cp "$TMP_ROOT/fm-task-owner.sh.orig" "$MBIN/fm-task-owner.sh"
  pass "guard '$1' is needed: case owner_request goes red without it"
}
mutate_request_owner 'a request asked again after its answer is new' '"$(date -u +%Y-%m-%dT%H:%M)" "${answered:-0}"' '"$(date -u +%Y-%m-%dT%H:%M)"'
mutate 'a setup waits for the open start-request' owner_request 'if (pending) throw rule' 'if (false) throw rule'
mutate 'one open request per kind' owner_request 'if (open) throw rule' 'if (false) throw rule'
mutate_owner_request 'a failed backlog read refuses the close' 'refuse "The backlog item could not be read' 'backlog_state="" || refuse "The backlog item could not be read'
mutate_owner_request 'a triage task is assigned before started' 'triage|todo) "$WRITER" assign' 'never) "$WRITER" assign'
mutate_owner_request 'a cleanup refusal leaves the task open' 'try "$TEARDOWN" "$TASK" || refuse "$(refusal_text "$ERR")"' 'try "$TEARDOWN" "$TASK" || true'
mutate_owner_request "the owner's setup names the spawn's runtime" 'runtime=(--harness "$harness")' 'runtime=()'
pass 'every guarded behavior has a red mutation proof'
live_home_untouched
