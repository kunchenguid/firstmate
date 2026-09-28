#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

foreign_watch_bg() {  # <dir> <out> <handling-successor 0|1> [extra env assignments...]
  local dir=$1 out=$2 successor=$3
  shift 3
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WATCH_HANDLING_SUCCESSOR="$successor" \
    "$@" "$WATCH" > "$out" 2>&1 &
}

# Append a captain inbox note to <dir>'s own queue and print its queue key.
foreign_note() {  # <dir> <text>
  local dir=$1
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" "$ROOT/bin/fm-inbox.sh" note "$2" >/dev/null || return 1
  awk -F '\t' 'END { print $4 }' "$dir/state/.wake-queue"
}

# 0 when <pid> is still blocking after two further completed poll cycles.
stays_blocking() {  # <state> <pid>
  local beat="$1/.last-watcher-beat" seen=0 last="" now i=0
  rm -f "$beat"
  while [ "$i" -lt 80 ]; do
    kill -0 "$2" 2>/dev/null || return 1
    if [ "$(uname)" = Darwin ]; then
      now=$(stat -f %m "$beat" 2>/dev/null || true)
    else
      now=$(stat -c %Y "$beat" 2>/dev/null || true)
    fi
    if [ -n "$now" ] && [ "$now" != "$last" ]; then
      seen=$((seen + 1))
      last=$now
      [ "$seen" -lt 3 ] || return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# T3: a row another writer appends to the home's own queue while a handling
# successor blocks - a captain inbox note - must wake it within a poll, and
# exactly once: neither the rows its predecessor already handed over nor the
# surfaced row may make a later successor exit again while they stay queued.
test_handling_successor_surfaces_a_foreign_append_once() {
  local dir state out child first second
  dir=$(make_case foreign-append-successor)
  dir=$(cd "$dir" && pwd -P)
  state="$dir/state"
  out="$dir/watch.out"
  mkdir -p "$dir/data" "$dir/config"

  first=$(foreign_note "$dir" "first note") || fail "the first inbox note was not queued"
  foreign_watch_bg "$dir" "$out" 0
  child=$!
  wait_for_exit "$child" 100 || fail "the predecessor did not hand over the queued note: $(cat "$out")"
  grep -q '^check:' "$out" || fail "the predecessor closed without a wake: $(cat "$out")"

  foreign_watch_bg "$dir" "$out" 1
  child=$!
  stays_blocking "$state" "$child" \
    || fail "a handling successor re-surfaced a row its predecessor handed over: $(cat "$out")"

  second=$(foreign_note "$dir" "second note") || fail "the second inbox note was not queued"
  wait_for_exit "$child" 50 \
    || fail "a handling successor kept blocking after an inbox note was queued: $(cat "$out")"
  grep -Fx "check: undelivered queued wake: $second" "$out" >/dev/null \
    || fail "the successor did not name exactly the newly queued note: $(cat "$out")"
  grep -F "$first" "$out" >/dev/null \
    && fail "the successor re-announced the note its predecessor handed over: $(cat "$out")"

  foreign_watch_bg "$dir" "$out" 1
  child=$!
  stays_blocking "$state" "$child" \
    || fail "a later successor surfaced the same queued note again: $(cat "$out")"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  [ "$(grep -c "$(printf '\tcheck\tinbox:')" "$state/.wake-queue")" = 2 ] \
    || fail "surfacing changed the durable queue: $(cat "$state/.wake-queue")"
  pass "a handling successor surfaces a foreign queue append once, tied to its row sequence"
}

# T4: while the away-mode daemon owns triage the watcher stays one-shot on its
# own reasons only, so a foreign append is left to the daemon.
test_afk_successor_leaves_foreign_appends_to_the_daemon() {
  local dir state out child
  dir=$(make_case foreign-append-afk)
  dir=$(cd "$dir" && pwd -P)
  state="$dir/state"
  out="$dir/watch.out"
  mkdir -p "$dir/data" "$dir/config"
  : > "$state/.afk"
  foreign_watch_bg "$dir" "$out" 1
  child=$!
  stays_blocking "$state" "$child" || fail "the away-mode successor did not start blocking: $(cat "$out")"
  foreign_note "$dir" "away note" >/dev/null || fail "the away-mode inbox note was not queued"
  stays_blocking "$state" "$child" \
    || fail "the away-mode watcher exited for a foreign append: $(cat "$out")"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "the away-mode watcher leaves a foreign queue append to the daemon"
}

# A fake fm-crew-state.sh that queues one real captain inbox note the first
# time the watcher asks whether a crew is working, then reports no evidence,
# so the note lands after this cycle's queue check and before its signal close.
note_during_triage_crew_state() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
if [ ! -e "$dir/note-queued" ]; then
  : > "$dir/note-queued"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \\
    FM_CONFIG_OVERRIDE="$dir/config" "$ROOT/bin/fm-inbox.sh" note "note during a signal close" >/dev/null
fi
printf '%s\n' 'state: unknown · source: none · fake default'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
}

# T5: a signal, stale, or heartbeat close may be taken by a supervision branch
# that presents only its granted rows, so it must not hand over a captain inbox
# note that was queued just before it. The next handling successor surfaces
# exactly that note - never the watcher's own signal row - and only once.
test_signal_close_leaves_a_raced_note_to_the_successor() {
  local dir state out child note handed note_seq
  dir=$(make_case signal-close-raced-note)
  dir=$(cd "$dir" && pwd -P)
  state="$dir/state"
  out="$dir/watch.out"
  mkdir -p "$dir/data" "$dir/config"
  note_during_triage_crew_state "$dir"
  printf 'working: step 1\n' > "$state/crew.status"
  : > "$state/crew.meta"

  foreign_watch_bg "$dir" "$out" 1 FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh"
  child=$!
  wait_for_exit "$child" 100 || fail "the successor did not close on the crew signal: $(cat "$out")"
  [ -e "$dir/note-queued" ] || fail "the fixture never queued its note during triage: $(cat "$out")"
  grep -q '^signal:' "$out" || fail "the raced close was not a signal close: $(cat "$out")"
  note=$(awk -F '\t' '$3 == "check" && $4 ~ /^inbox:/ { print $4 }' "$state/.wake-queue")
  note_seq=$(awk -F '\t' '$3 == "check" && $4 ~ /^inbox:/ { print $2 }' "$state/.wake-queue")
  [ -n "$note" ] || fail "the raced note is not queued: $(cat "$state/.wake-queue")"
  handed=$(cat "$state/.watch-queue-handed" 2>/dev/null || echo 0)
  [ "${handed:-0}" -lt "$note_seq" ] \
    || fail "the signal close recorded the raced note (seq $note_seq) as handed over (record $handed)"

  foreign_watch_bg "$dir" "$out" 1
  child=$!
  wait_for_exit "$child" 50 \
    || fail "a handling successor kept blocking on a note a signal close did not hand over: $(cat "$out")"
  grep -Fx "check: undelivered queued wake: $note" "$out" >/dev/null \
    || fail "the successor did not surface exactly the raced note without the signal row: $(cat "$out")"

  foreign_watch_bg "$dir" "$out" 1
  child=$!
  stays_blocking "$state" "$child" \
    || fail "a later successor surfaced the raced note again: $(cat "$out")"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a note queued just before a signal close reaches main once through the next successor, without the signal row"
}

# T6: a note main's drain has already claimed is being handled, so a successor
# that starts before main acknowledges it must not wake main for it again.
test_main_claimed_note_is_not_surfaced_again() {
  local dir state out child
  dir=$(make_case main-claimed-note)
  dir=$(cd "$dir" && pwd -P)
  state="$dir/state"
  out="$dir/watch.out"
  mkdir -p "$dir/data" "$dir/config"
  foreign_note "$dir" "note main is handling" >/dev/null || fail "the inbox note was not queued"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 \
    || fail "main's drain could not present the note"

  foreign_watch_bg "$dir" "$out" 1
  child=$!
  stays_blocking "$state" "$child" \
    || fail "a successor surfaced a note main's drain had already claimed: $(cat "$out")"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  grep -q "$(printf '\tcheck\tinbox:')" "$state/.wake-queue" \
    || fail "the claimed note left the durable queue before acknowledgement"
  pass "a note main's drain already claimed is not surfaced again before acknowledgement"
}

test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
test_handling_successor_surfaces_a_foreign_append_once
test_afk_successor_leaves_foreign_appends_to_the_daemon
test_signal_close_leaves_a_raced_note_to_the_successor
test_main_claimed_note_is_not_surfaced_again
