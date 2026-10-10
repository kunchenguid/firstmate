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

# T3: a durable row appended while a handling successor is already running
# (a captain inbox note, a merge outcome) has no predecessor-delivered wake on
# the way, so the running cycle itself must surface it. Rows the predecessor
# already delivered must still not re-announce.
test_handling_successor_surfaces_mid_cycle_append() {
  local dir home state fakebin child out now rc
  dir=$(make_case midcycle-append-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'pending:handling:handed.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '%s\t1\tcheck\tdelivered\tcheck: predecessor delivered\n' "$(date +%s)" > "$state/.wake-queue"
  printf '1\n' > "$state/.wake-queue.seq"
  printf '1\n' > "$state/.wake-queue.drained-seq"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
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
  sleep 2.5
  if ! is_live_non_zombie "$child"; then
    wait "$child" 2>/dev/null || true
    fail "handling successor re-announced the predecessor-delivered episode: $(cat "$out")"
  fi
  append_wake "$state" check inbox:note-1 "check: captain inbox note note-1 - mid-cycle" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "could not append the mid-cycle wake row"; }
  wait_for_exit "$child" 100
  rc=$?
  expect_code 0 "$rc" "handling successor must close on a durable row appended mid-cycle: $(cat "$out")"
  grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
    || fail "handling successor did not surface the mid-cycle row: $(cat "$out")"
  grep -F 'inbox:note-1' "$state/.wake-queue" >/dev/null \
    || fail "mid-cycle row left the durable queue before acknowledgement"
  case "$(cat "$state/.watcher-down")" in
    announced:downtime:*) ;;
    *) fail "mid-cycle surface did not announce its downtime episode: $(cat "$state/.watcher-down")" ;;
  esac
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T3_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T3_MARKER=%s\n' "$(cat "$state/.watcher-down")"
  fi
  pass "a handling successor surfaces a durable row appended mid-cycle without re-announcing delivered work"
}

# T4: a row appended after the drain of the last delivered wake but before a
# handling successor starts (an adapter retry's backoff) has no wake on the
# way. The successor's start announces that episode, so it must surface the row itself rather than swallow it.
test_handling_successor_surfaces_pre_start_append() {
  local dir home state fakebin child out rc
  dir=$(make_case prestart-append-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'acked:handling:drained.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '1\n' > "$state/.wake-queue.seq"
  printf '1\n' > "$state/.wake-queue.drained-seq"
  append_wake "$state" check inbox:note-2 "check: captain inbox note note-2 - during retry backoff" \
    || fail "could not append the pre-start wake row"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  wait_for_exit "$child" 100
  rc=$?
  expect_code 0 "$rc" "handling successor must close on a row appended before it started: $(cat "$out")"
  grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
    || fail "handling successor did not surface the pre-start row: $(cat "$out")"
  grep -F 'inbox:note-2' "$state/.wake-queue" >/dev/null \
    || fail "pre-start row left the durable queue before acknowledgement"
  case "$(cat "$state/.watcher-down")" in
    announced:downtime:*) ;;
    *) fail "pre-start surface did not keep its downtime episode announced: $(cat "$state/.watcher-down")" ;;
  esac
  [ "$(cat "$state/.wake-queue.delivered-seq")" = 2 ] \
    || fail "surfacing close did not record the sequence it delivered: $(cat "$state/.wake-queue.delivered-seq")"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T4_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T4_MARKER=%s\n' "$(cat "$state/.watcher-down")"
  fi
  pass "a handling successor surfaces a durable row appended before it started past the last delivery"
}

# T5: a delivering close that cannot record its delivery must drop the drain
# record, or a later handling successor would treat the delivery as drained.
test_failed_delivered_record_drops_drain_record() {
  local dir state holder lib="$ROOT/bin/fm-wake-lib.sh" i
  dir=$(make_case delivered-record-failure)
  state="$dir/state"
  printf '5\n' > "$state/.wake-queue.drained-seq"
  printf '5\n' > "$state/.wake-queue.seq"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
    : > "$2"
    sleep 30
  ' _ "$lib" "$dir/held" &
  holder=$!
  i=0
  while [ ! -e "$dir/held" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$dir/held" ] || { kill "$holder" 2>/dev/null; fail "queue lock holder did not start"; }
  if FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_queue_delivered_record 1' _ "$lib"; then
    kill "$holder" 2>/dev/null
    fail "delivered record reported success while the queue lock was held"
  fi
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null || true
  [ ! -e "$state/.wake-queue.drained-seq" ] \
    || fail "failed delivered record left the drain record: $(cat "$state/.wake-queue.drained-seq")"
  pass "a failed delivered record drops the drain record"
}

# T6: a row appended after the predecessor's wake was delivered but before the
# agent drains it is covered by that drain, so the successor must not wake a
# second time; a row appended after the real drain still surfaces. A <variant>
# of norow models a wake that appended no queue row of its own (a procevent),
# so its delivery sits at the sequence the previous turn's drain recorded.
test_handling_successor_leaves_undrained_delivery_to_its_drain() {  # <row|norow>
  local variant=$1 dir home state fakebin child out rc
  dir=$(make_case "undrained-delivery-successor-$variant")
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'pending:downtime:delivered.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  if [ "$variant" = row ]; then
    printf '%s\t1\tcheck\tdelivered\tcheck: predecessor delivered\n' "$(date +%s)" > "$state/.wake-queue"
    printf '1\n' > "$state/.wake-queue.seq"
    printf '0\n' > "$state/.wake-queue.drained-seq"
  else
    printf '5\n' > "$state/.wake-queue.seq"
    printf '5\n' > "$state/.wake-queue.drained-seq"
  fi
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_queue_delivered_record 2' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail "could not record the predecessor delivery"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  append_wake "$state" check inbox:note-3 "check: captain inbox note note-3 - before the drain" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "could not append the pre-drain wake row"; }
  sleep 2.5
  if ! is_live_non_zombie "$child"; then
    wait "$child" 2>/dev/null || true
    fail "handling successor woke for a row its predecessor's undrained wake covers: $(cat "$out")"
  fi
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "drain failed: $(cat "$dir/drain.err")"; }
  grep -F 'note-3' "$dir/drain.out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "drain did not present the pre-drain row: $(cat "$dir/drain.out")"; }
  sleep 2.5
  if ! is_live_non_zombie "$child"; then
    wait "$child" 2>/dev/null || true
    fail "handling successor woke a second time after the drain consumed the row: $(cat "$out")"
  fi
  append_wake "$state" check inbox:note-4 "check: captain inbox note note-4 - after the drain" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "could not append the post-drain wake row"; }
  wait_for_exit "$child" 100
  rc=$?
  expect_code 0 "$rc" "handling successor must close on a row appended after the drain: $(cat "$out")"
  grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
    || fail "handling successor did not surface the post-drain row: $(cat "$out")"
  pass "a handling successor leaves an undrained $variant delivery to its drain and surfaces rows appended after it"
}

# T7: a delivered wake the supervision branch handles is consumed by the
# branch's drain, so a main-owned row appended afterwards has no wake on the
# way and the successor must surface it rather than wait on main's drain.
# A <when> of prestart appends the main-owned row before the successor starts,
# so the successor's own start announces it while the delivery is outstanding.
# A <when> of preclose appends it before the predecessor's delivering close, so
# it sits below the delivered sequence while the branch grant leaves it out.
test_handling_successor_surfaces_after_branch_drained_delivery() {  # <midcycle|prestart|preclose>
  local when=$1 dir home state fakebin child out rc now stale_seq
  dir=$(make_case "branch-drained-delivery-successor-$when")
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'pending:downtime:branch.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '0\n' > "$state/.wake-queue.drained-seq"
  stale_seq=1
  if [ "$when" = preclose ]; then
    append_wake "$state" check inbox:note-5 "check: captain inbox note note-5 - before the close" \
      || fail "could not append the main-owned wake row"
    stale_seq=2
  fi
  append_wake "$state" stale fm-window "stale: fm-window" || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_queue_delivered_record 2' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail "could not record the predecessor delivery"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$$" branch-drained \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish branch-drained "$stale_seq" \
    || fail "branch grant publication failed"
  if [ "$when" = prestart ]; then
    append_wake "$state" check inbox:note-5 "check: captain inbox note note-5 - before the successor" \
      || fail "could not append the main-owned wake row"
  fi
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
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
  sleep 1
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-wake-drain.sh" \
    > "$dir/drain.out" 2> "$dir/drain.err" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "branch drain failed: $(cat "$dir/drain.err")"; }
  grep -F 'fm-window' "$dir/drain.out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "branch drain did not present the delivered row: $(cat "$dir/drain.out")"; }
  if [ "$when" = midcycle ]; then
    sleep 2.5
    if ! is_live_non_zombie "$child"; then
      wait "$child" 2>/dev/null || true
      fail "handling successor woke for the branch-drained delivery: $(cat "$out")"
    fi
    append_wake "$state" check inbox:note-5 "check: captain inbox note note-5 - after the branch drain" \
      || { kill -TERM "$child" 2>/dev/null || true; fail "could not append the main-owned wake row"; }
  fi
  wait_for_exit "$child" 100
  rc=$?
  expect_code 0 "$rc" "handling successor must close on a main-owned row after a branch drain: $(cat "$out")"
  grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
    || fail "handling successor did not surface the main-owned row: $(cat "$out")"
  pass "a handling successor surfaces a $when main-owned row once the branch drained the delivered wake"
}

test_handling_successor_does_not_go_blind
test_handling_successor_surfaces_mid_cycle_append
test_handling_successor_surfaces_after_branch_drained_delivery midcycle
test_handling_successor_surfaces_after_branch_drained_delivery prestart
test_handling_successor_surfaces_after_branch_drained_delivery preclose
test_handling_successor_leaves_undrained_delivery_to_its_drain row
test_handling_successor_leaves_undrained_delivery_to_its_drain norow
test_failed_delivered_record_drops_drain_record
test_handling_successor_surfaces_pre_start_append
test_unacknowledged_recovery_is_announced_once_per_generation
