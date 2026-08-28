#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

mark_pr_check_migration_complete() { # <state>
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$1/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$1/.pr-check-migration-v1"
  chmod 0600 "$1/.pr-check-migration-scan-v1" "$1/.pr-check-migration-v1"
}

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

# T2: a handling successor must enter its poll loop immediately and surface a
# real crew event instead of sitting in a pre-loop wait that refreshes the
# liveness beacon and then exits with a synthetic rearm-resurface.
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
  while [ "$now" -lt 5 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within a poll interval or two (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
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

# T3: exercise the public present-daemon entry over two watcher cycles. The
# first real status wake exits its watcher and is delivered through the queue
# adapter fake. The daemon must start the replacement as the handling successor,
# which stays live across more than one former rapid-loop interval without
# emitting a synthetic rearm-resurface or changing the recovery generation.
test_present_daemon_rearms_one_live_successor_without_storm() {
  local dir state fakebin daemon_pid first_generation second_generation watcher_pid i deliveries
  local owner_identity identity_hash home_hash drain_out drain_err ack sequence generation
  dir="$TMP_ROOT/t3"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  mark_pr_check_migration_complete "$state"
  : > "$state/crew.meta"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = queue ] && [ "${2:-}" = --help ]; then
  printf 'Usage: codex queue --thread THREAD --message TEXT\n'
  exit 0
fi
[ "${1:-}" = queue ] || exit 2
printf '%s\n' "$*" >> "${FM_FAKE_DELIVERIES:?}"
exit 0
SH
  chmod +x "$fakebin/codex"
  owner_identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$")
  if command -v shasum >/dev/null 2>&1; then
    identity_hash=$(printf '%s' "$owner_identity" | shasum -a 256 | awk '{print $1}')
    home_hash=$(printf '%s' "$dir" | shasum -a 256 | awk '{print $1}')
  else
    identity_hash=$(printf '%s' "$owner_identity" | sha256sum | awk '{print $1}')
    home_hash=$(printf '%s' "$dir" | sha256sum | awk '{print $1}')
  fi
  printf '%s\n' "$$" > "$state/.lock"
  printf 'fm-session-lock-generation-v1\n%s\npresent-t3\n%s\n' "$$" "$identity_hash" > "$state/.lock-generation"
  printf 'fm-codex-primary-binding-v1\nthread_uuid=33333333-3333-4333-8333-333333333333\nhome_sha256=%s\nowner_pid=%s\nowner_identity_sha256=%s\nsession_generation=present-t3\nsource=startup\n' \
    "$home_hash" "$$" "$identity_hash" > "$state/.codex-primary-binding"
  chmod 0600 "$state/.lock-generation" "$state/.codex-primary-binding"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_SUPERVISE_PRESENT=1 FM_CODEX_QUEUE_ONLY=1 \
    FM_DAEMON_PRIMARY_HARNESS=codex FM_CODEX_QUEUE_BIN="$fakebin/codex" \
    FM_CODEX_TESTING=1 FM_CODEX_PRIMARY_OWNER_PID_OVERRIDE="$$" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCHER_STALE_GRACE=10 FM_HOUSEKEEPING_TICK=1 \
    FM_FAKE_DELIVERIES="$dir/deliveries" "$DAEMON" >"$dir/daemon.out" 2>"$dir/daemon.err" &
  daemon_pid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.last-watcher-beat" ] || {
    kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    fail "present daemon did not establish its first watcher"
  }
  printf 'done: one real present-mode wake\n' > "$state/crew.status"
  i=0
  while [ "$i" -lt 80 ]; do
    [ -s "$dir/deliveries" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$dir/deliveries" ] || {
    kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    fail "present daemon did not deliver the real status wake"
  }
  first_generation=$(recovery_marker_generation "$state/.watcher-down")
  sleep 4
  deliveries=$(wc -l < "$dir/deliveries" | tr -d ' ')
  second_generation=$(recovery_marker_generation "$state/.watcher-down")
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ "$deliveries" != 1 ]; then
    fail "present daemon re-delivered $deliveries times instead of coalescing one recovery episode: $(cat "$dir/deliveries")"
  elif [ -z "$first_generation" ] || [ "$second_generation" != "$first_generation" ]; then
    fail "present daemon successor churned the recovery generation ($first_generation -> $second_generation)"
  elif ! kill -0 "$watcher_pid" 2>/dev/null; then
    fail "present daemon did not leave a live successor watcher (pid $watcher_pid)"
  elif grep -F 'wake: check: rearm-resurface' "$state/.supervise-present.log" >/dev/null 2>&1; then
    fail "present daemon successor generated a recursive rearm-resurface wake"
  fi
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-wake-drain.sh" > "$drain_out" 2> "$drain_err" \
    || fail "present daemon E2E drain failed"
  assert_contains "$(cat "$drain_out")" "done: one real present-mode wake" \
    "present daemon E2E drain omitted the done signal"
  ack=$(grep '^WAKE_ACK_REQUIRED:' "$drain_err" | tail -1)
  sequence=$(printf '%s\n' "$ack" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p')
  generation=$(printf '%s\n' "$ack" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p')
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "present daemon E2E drain omitted its acknowledgement"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_SUPERVISION_MODEL=extension \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" \
    >/dev/null 2>&1 || fail "present daemon E2E acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "present daemon E2E acknowledgement left the done row queued"
  [ ! -e "$state/.codex-queue-outstanding" ] || fail "present daemon E2E acknowledgement left the queue doorbell outstanding"
  kill -0 "$watcher_pid" 2>/dev/null || fail "present daemon successor died across handling acknowledgement"
  pass "done signal reaches one queue turn, drain/ack, and a stable live successor"
  kill -TERM "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}

test_handling_successor_does_not_go_blind
test_present_daemon_rearms_one_live_successor_without_storm
test_unacknowledged_recovery_is_announced_once_per_generation
