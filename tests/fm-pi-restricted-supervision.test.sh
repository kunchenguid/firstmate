#!/usr/bin/env bash
# Tests for the opt-in restricted Pi supervision extension
# (.pi/extensions/restricted/fm-restricted-supervision.ts): it stays inert
# unless selected, refuses to act beside a general shell tool or without the
# session lock, acquires the lock with no model-callable tool, drains and
# acknowledges only what it presented itself, forwards no model-provider key,
# and serializes its delivery passes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-pi-restricted-supervision)
EXT_REL=.pi/extensions/restricted/fm-restricted-supervision.ts
# Node warns when a test-only dynamic import loads a tracked TypeScript module
# from a checkout without a package.json; the warning is not under test.
export NODE_NO_WARNINGS=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PI_RESTRICTED_SUPERVISION

# A firstmate root holding the real extension and recording stubs for the three
# engine commands it may run. Each stub appends one line naming its arguments,
# so a case can assert exactly what ran and with which input.
make_root() {  # <name> -> root path
  local repo="$TMP_ROOT/$1"
  mkdir -p "$repo/.pi/extensions/restricted" "$repo/.pi/extensions/lib" "$repo/bin" \
    "$repo/home/state" "$repo/node_modules/typebox"
  cp "$ROOT/$EXT_REL" "$repo/$EXT_REL"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties, options = {}) { return { type: "object", properties, ...options }; },
  Optional(schema) { return { ...schema, optional: true }; },
  Boolean() { return { type: "boolean" }; },
};
JS
  cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf 'lock %s\n' "$#" >> "$FM_HOME/calls"
env > "$FM_HOME/lock-env"
if [ -e "$FM_HOME/lock-anchors-child" ]; then
  printf '%s\n' "$$" > "$FM_STATE_OVERRIDE/.lock"
else
  printf '%s\n' "$PPID" > "$FM_STATE_OVERRIDE/.lock"
fi
SH
  cat > "$repo/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
printf 'drain %s\n' "$*" >> "$FM_HOME/calls"
if [ "$#" -gt 0 ]; then
  echo "wake drain: acknowledged"
  exit 0
fi
printf '1\t100\tsignal\ttask-a\tdone: PR ready\n'
if [ -e "$FM_HOME/drain-floods" ]; then
  head -c 70000 /dev/zero | tr '\0' 'x'
  echo
fi
echo 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 42 --recovery-generation gen-7' >&2
SH
  cat > "$repo/bin/fm-deliver-cycle.sh" <<'SH'
#!/usr/bin/env bash
printf 'deliver %s\n' "$#" >> "$FM_HOME/calls"
[ ! -e "$FM_HOME/deliver-slow" ] || sleep 1
echo "armed merge monitoring for task-a on https://github.com/acme/widget/pull/7"
SH
  chmod +x "$repo/bin/"*.sh
  printf '%s\n' "$repo"
}

# Runs <node-script> against a fake Pi with the extension loaded. The script
# sees `pi`, `tools`, `handlers`, `notes`, `ctx`, `setActive`, `waitFor`, and
# `calls()`; it prints its findings, and any thrown error fails the case.
run_pi() {  # <root> <enabled 0|1> <node-script>
  local repo=$1 enabled=$2 script=$3 extra=()
  [ "$enabled" = 1 ] && extra=(FM_PI_RESTRICTED_SUPERVISION=1)
  env ${extra[@]+"${extra[@]}"} EXT="$repo/$EXT_REL" FM_HOME="$repo/home" FM_ROOT_OVERRIDE="$repo" \
    ANTHROPIC_API_KEY=sk-test-model-key FM_PI_RESTRICTED_DELIVER_INTERVAL_MS="${RUN_PI_INTERVAL_MS:-3600000}" \
    node --input-type=module -e "
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const tools = new Map();
const handlers = new Map();
const notes = [];
let active = ['fm_drain', 'fm_deliver', 'fm_watch_arm_pi'];
const setActive = (names) => { active = names; };
const pi = {
  on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); },
  registerTool(tool) { tools.set(tool.name, tool); },
  getActiveTools() { return active; },
};
const ctx = { ui: { notify(message, type) { notes.push({ type, message }); } } };
const calls = () => { try { return readFileSync(process.env.FM_HOME + '/calls', 'utf8'); } catch { return ''; } };
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 200; i += 1) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error('timed out waiting for ' + label + '; calls=' + JSON.stringify(calls()));
};
const emit = async (name, event = {}) => { for (const fn of handlers.get(name) ?? []) await fn(event, ctx); };
const call = async (name, params = {}) => {
  const result = await tools.get(name).execute('call-1', params, undefined, undefined, ctx);
  return result.content.map((item) => item.text).join('\n');
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
$script
"
}

test_inert_unless_selected() {
  local repo out
  repo=$(make_root inert)
  out=$(run_pi "$repo" 0 "
console.log('tools=' + tools.size + ' handlers=' + handlers.size);
") || fail "loading the unselected extension failed: $out"
  assert_equals "tools=0 handlers=0" "$out" "without FM_PI_RESTRICTED_SUPERVISION=1 nothing is registered"
  pass "the extension registers nothing unless explicitly selected"
}

test_tool_inputs_are_closed() {
  local repo out
  repo=$(make_root schema)
  out=$(run_pi "$repo" 1 "
const drain = tools.get('fm_drain').parameters;
const deliver = tools.get('fm_deliver').parameters;
console.log([...tools.keys()].sort().join(','));
console.log(JSON.stringify(Object.keys(drain.properties)) + ' ' + drain.properties.acknowledge.type + ' ' + drain.additionalProperties);
console.log(JSON.stringify(Object.keys(deliver.properties)) + ' ' + deliver.additionalProperties);
") || fail "schema inspection failed: $out"
  assert_equals $'fm_deliver,fm_drain\n["acknowledge"] boolean false\n[] false' "$out" \
    "fm_drain takes only a boolean and fm_deliver takes nothing"
  pass "only fm_drain and fm_deliver are registered, with closed inputs"
}

test_unrestricted_session_refuses_everything() {
  local repo out
  repo=$(make_root unrestricted)
  out=$(run_pi "$repo" 1 "
setActive(['bash', 'read', 'fm_drain', 'fm_deliver']);
await emit('session_start', { reason: 'startup' });
await emit('agent_end');
console.log(await call('fm_drain'));
console.log(await call('fm_deliver'));
await new Promise((r) => setTimeout(r, 200));
console.log('notes=' + notes.map((n) => n.type).join(','));
console.log('calls=' + JSON.stringify(calls()));
") || fail "unrestricted session case failed: $out"
  assert_contains "$out" "this session also exposes bash, read" "the extra tools are named"
  assert_contains "$out" "notes=error" "the refusal reaches the captain's screen"
  assert_contains "$out" 'calls=""' "no lock, drain, or delivery command runs beside a general shell tool"
  pass "a session exposing a general shell tool takes no lock and runs nothing"
}

test_restricted_session_locks_drains_and_acknowledges() {
  local repo out
  repo=$(make_root restricted)
  out=$(run_pi "$repo" 1 "
await emit('session_start', { reason: 'startup' });
console.log('--- present');
console.log(await call('fm_drain'));
console.log('--- ack');
console.log(await call('fm_drain', { acknowledge: true }));
console.log('--- again');
console.log(await call('fm_drain', { acknowledge: true }));
console.log('--- calls');
process.stdout.write(calls());
") || fail "restricted session case failed: $out"
  assert_contains "$out" $'--- calls\nlock 0\ndrain \ndrain --ack-through 42 --recovery-generation gen-7' \
    "the lock runs with no arguments, and the acknowledgement is exactly the one the drain printed"
  assert_contains "$out" $'1\t100\tsignal\ttask-a\tdone: PR ready' "the presented wake reaches the model"
  assert_contains "$out" "call fm_drain with acknowledge: true" "the model is told how to acknowledge"
  assert_contains "$out" "nothing to acknowledge" "a second acknowledgement runs nothing"
  assert_no_grep "sk-test-model-key" "$repo/home/lock-env" "the model-provider key is not forwarded"
  assert_grep "FM_HOME=$repo/home" "$repo/home/lock-env" "the home is forwarded"
  pass "a restricted session locks at start, presents wakes, and acknowledges only what it presented"
}

test_incomplete_presentation_stores_no_acknowledgement() {
  local repo out
  repo=$(make_root flood)
  : > "$repo/home/drain-floods"
  out=$(run_pi "$repo" 1 "
await emit('session_start', { reason: 'startup' });
const shown = await call('fm_drain');
console.log(shown.includes('output truncated') ? 'truncated' : 'whole');
console.log(shown.split('\n').slice(-1)[0]);
console.log(await call('fm_drain', { acknowledge: true }));
console.log('ack-calls=' + calls().split('\n').filter((l) => l.startsWith('drain --ack')).length);
") || fail "flooded drain case failed: $out"
  assert_contains "$out" "truncated" "an oversized presentation is cut for the model"
  assert_contains "$out" "every presented wake stays queued" "the model is told nothing was consumed"
  assert_contains "$out" "ack-calls=0" "no acknowledgement runs for wakes the model could not see"
  pass "a presentation too large to show whole never acknowledges unseen wakes"
}

test_lock_held_by_a_short_lived_child_is_not_ownership() {
  local repo out
  repo=$(make_root child-anchor)
  : > "$repo/home/lock-anchors-child"
  out=$(run_pi "$repo" 1 "
await emit('session_start', { reason: 'startup' });
console.log(await call('fm_drain'));
await new Promise((r) => setTimeout(r, 200));
console.log('notes=' + notes.map((n) => n.type + ':' + n.message.split('\n')[0]).join('|'));
console.log('calls=' + JSON.stringify(calls()));
") || fail "child-anchored lock case failed: $out"
  assert_contains "$out" "does not hold this home's session lock" "draining is refused without the lock"
  assert_contains "$out" "notes=error:restricted supervision: the session lock was not acquired" "the missing lock is surfaced"
  assert_contains "$out" 'calls="lock 0\n"' "nothing but the lock attempt runs"
  pass "a lock anchored to a short-lived child is not treated as this Pi process's lock"
}

test_delivery_passes_are_serialized_and_follow_each_run() {
  local repo out
  repo=$(make_root serialized)
  out=$(run_pi "$repo" 1 "
const passes = () => calls().split('deliver').length - 1;
await emit('session_start', { reason: 'startup' });
await new Promise((r) => setTimeout(r, 200));
console.log('after-start=' + passes());
await emit('agent_end');
await waitFor(() => passes() === 1, 'the post-run delivery pass');
await new Promise((r) => setTimeout(r, 100));
await emit('agent_end');
await waitFor(() => passes() === 2, 'the second post-run delivery pass');
await new Promise((r) => setTimeout(r, 100));
const { writeFileSync } = await import('node:fs');
writeFileSync(process.env.FM_HOME + '/deliver-slow', '');
const [first, second] = await Promise.all([call('fm_deliver'), call('fm_deliver')]);
console.log('first=' + first);
console.log('second=' + second);
console.log('passes=' + passes());
console.log('notes=' + notes.length);
await emit('session_shutdown', { reason: 'quit' });
") || fail "serialized delivery case failed: $out"
  assert_contains "$out" "after-start=0" "session start takes the lock but runs no pass before the watcher arms"
  assert_contains "$out" "first=armed merge monitoring for task-a" "one manual pass runs and reports its result"
  assert_contains "$out" "second=fm_deliver: a delivery pass is already running" "an overlapping pass is skipped"
  assert_contains "$out" "passes=3" "each agent run and one manual call each ran one pass"
  assert_contains "$out" "notes=1" "an unchanged background result is shown to the captain once"
  pass "delivery passes follow each agent run, one at a time"
}

test_interval_runs_passes_until_shutdown() {
  local repo out
  repo=$(make_root interval)
  out=$(RUN_PI_INTERVAL_MS=100 run_pi "$repo" 1 "
const passes = () => calls().split('deliver').length - 1;
await emit('session_start', { reason: 'startup' });
await waitFor(() => passes() >= 2, 'two interval passes');
await emit('session_shutdown', { reason: 'quit' });
await new Promise((r) => setTimeout(r, 100));
const settled = passes();
await new Promise((r) => setTimeout(r, 400));
console.log('stopped=' + (passes() === settled));
") || fail "interval case failed: $out"
  assert_contains "$out" "stopped=true" "no pass runs after shutdown"
  pass "the interval runs delivery passes without a model turn and stops at shutdown"
}

test_inert_unless_selected
test_tool_inputs_are_closed
test_unrestricted_session_refuses_everything
test_restricted_session_locks_drains_and_acknowledges
test_incomplete_presentation_stores_no_acknowledgement
test_lock_held_by_a_short_lived_child_is_not_ownership
test_delivery_passes_are_serialized_and_follow_each_run
test_interval_runs_passes_until_shutdown
