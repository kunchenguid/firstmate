#!/usr/bin/env bash
# Behavior tests for loud OpenCode wake-delivery failures.
#
# A failed wake-injection promptAsync used to be swallowed silently by every
# OpenCode primary plugin. These cases pin the loud contract end to end:
# bin/fm-wake-delivery-alarm.sh owns the durable state/.wake-delivery-failures
# record, the notification cooldown, and its reuse of the wedge-alarm channels;
# .opencode/plugins/lib/fm-wake-delivery.js owns the bounded retry, the
# per-attempt accept timeout, and the never-reject delivery result; and the
# real plugins route their prompts through it, so a broken injection path is
# recorded and alarmed within one wake cycle while the healthy path stays at
# exactly one promptAsync call with no record and no alarm.
#
# NO test here posts a real notification: tests/wake-helpers.sh forces the
# FM_WEDGE_ALARM_EXEC seam to a recorder, and the assertions read that
# recorder's log.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ALARM="$ROOT/bin/fm-wake-delivery-alarm.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-delivery)
fm_git_identity fmtest fmtest@example.invalid

# A fixture firstmate-shaped repo plus an isolated FM_HOME, with the real
# operational-input encoder, the real alarm script, and its real channel lib
# installed so every failure path runs the production code.
make_delivery_case() {  # <name> -> echoes dir; sets nothing
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/repo/bin" "$dir/repo/.opencode/plugins/lib" "$dir/home/state" "$dir/home/config"
  git init -q "$dir/repo"
  ( cd "$dir/repo" && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  : > "$dir/repo/AGENTS.md"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/repo/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-wake-delivery-alarm.sh" "$dir/repo/bin/fm-wake-delivery-alarm.sh"
  cp "$ROOT/bin/fm-wedge-alarm-lib.sh" "$dir/repo/bin/fm-wedge-alarm-lib.sh"
  cp "$ROOT/.opencode/plugins/package.json" "$dir/repo/.opencode/plugins/package.json"
  cp "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$dir/repo/.opencode/plugins/fm-primary-turnend-guard.js"
  cp "$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" "$dir/repo/.opencode/plugins/fm-primary-sessionstart-nudge.js"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$dir/repo/.opencode/plugins/fm-primary-watch-arm.js"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$dir/repo/.opencode/plugins/lib/fm-operational-input.js"
  cp "$ROOT/.opencode/plugins/lib/fm-wake-delivery.js" "$dir/repo/.opencode/plugins/lib/fm-wake-delivery.js"
  chmod +x "$dir/repo/bin/"*.sh
  printf '%s\n' "$dir"
}

# --- alarm script: record, sanitize, channels, cooldown, trim ----------------

test_alarm_records_one_sanitized_line_and_fires_channel() {
  local dir state log line n
  dir=$(make_delivery_case alarm-record)
  state="$dir/home/state"
  log="$dir/alert.log"
  : > "$log"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WEDGE_ALARM_LOG="$log" \
    "$ALARM" --summary "$(printf 'line1\nline2\twith-tab')"
  expect_code 0 "$?" "alarm script must always exit 0"
  [ -s "$state/.wake-delivery-failures" ] || fail "alarm wrote no durable record"
  n=$(wc -l < "$state/.wake-delivery-failures")
  [ "$n" -eq 1 ] || fail "recorded $n lines for one failure, expected 1"
  line=$(tail -n 1 "$state/.wake-delivery-failures")
  case "$line" in
    20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) : ;;
    *) fail "record line lacks an iso stamp: $line" ;;
  esac
  case "$line" in
    *$'\t'*) : ;;
    *) fail "record line is not tab separated: $line" ;;
  esac
  case "$line" in
    *"line1 line2 with-tab"*) : ;;
    *) fail "record line did not flatten newlines/tabs: $line" ;;
  esac
  grep -F 'osascript' "$log" >/dev/null || fail "auto channel did not fire: $(cat "$log")"
  grep -F 'wake delivery FAILED' "$log" >/dev/null || fail "channel summary lost the failure text: $(cat "$log")"
  grep -F 'line1 line2 with-tab' "$log" >/dev/null || fail "channel summary lost the caller summary: $(cat "$log")"
  pass "alarm script records one sanitized line and fires the auto channel"
}

test_alarm_cooldown_limits_active_alerts_not_records() {
  local dir state log n
  dir=$(make_delivery_case alarm-cooldown)
  state="$dir/home/state"
  log="$dir/alert.log"
  : > "$log"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WEDGE_ALARM_LOG="$log" \
    "$ALARM" --summary "first failure"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WEDGE_ALARM_LOG="$log" \
    "$ALARM" --summary "second failure"
  n=$(grep -c . "$log")
  [ "$n" -eq 1 ] || fail "cooldown let $n active alerts through, expected 1"
  n=$(wc -l < "$state/.wake-delivery-failures")
  [ "$n" -eq 2 ] || fail "cooldown suppressed the durable record: $n lines, expected 2"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WEDGE_ALARM_LOG="$log" \
    FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS=0 "$ALARM" --summary "third failure"
  n=$(grep -c . "$log")
  [ "$n" -eq 2 ] || fail "cooldown=0 did not re-arm the active alert: $n alerts, expected 2"
  pass "alarm cooldown bounds active alerts while every failure is recorded"
}

test_alarm_off_channel_still_records() {
  local dir state log
  dir=$(make_delivery_case alarm-off)
  state="$dir/home/state"
  log="$dir/alert.log"
  : > "$log"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WEDGE_ALARM_LOG="$log" \
    FM_WEDGE_ALARM_CHANNEL=off "$ALARM" --summary "quiet failure"
  [ ! -s "$log" ] || fail "off channel still fired an alert: $(cat "$log")"
  [ -s "$state/.wake-delivery-failures" ] || fail "off channel suppressed the durable record"
  pass "alarm off channel records without any active alert"
}

test_alarm_trims_the_record_bounded() {
  local dir state n
  dir=$(make_delivery_case alarm-trim)
  state="$dir/home/state"
  local i
  for i in 1 2 3 4; do
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS=0 \
      FM_WAKE_DELIVERY_MAX_BYTES=1 FM_WAKE_DELIVERY_KEEP_LINES=2 \
      "$ALARM" --summary "failure $i"
  done
  [ -s "$state/.wake-delivery-failures" ] || fail "trim dropped the record entirely"
  n=$(wc -l < "$state/.wake-delivery-failures")
  [ "$n" -eq 2 ] || fail "trimmed record kept $n lines, expected 2"
  tail -n 1 "$state/.wake-delivery-failures" | grep -F 'failure 4' >/dev/null \
    || fail "trim dropped the newest line: $(cat "$state/.wake-delivery-failures")"
  pass "alarm record stays bounded and keeps the newest lines"
}

# A bare `tail | mv` trim reads a snapshot of the record and then swaps the
# file for that snapshot; a concurrent invocation's append that lands between
# the read and the swap is silently excluded from the swapped-in file and
# lost for good. Force every one of several truly concurrent invocations to
# attempt a trim (MAX_BYTES=1) with a keep-lines cap generous enough that
# none of them should be legitimately dropped, and assert every one of their
# distinct summaries survives.
test_alarm_concurrent_appends_survive_trim() {
  local dir state i count=20
  local -a pids=()
  dir=$(make_delivery_case alarm-concurrent-trim)
  state="$dir/home/state"
  for i in $(seq 1 "$count"); do
    (
      FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS=0 \
        FM_WAKE_DELIVERY_MAX_BYTES=1 FM_WAKE_DELIVERY_KEEP_LINES=100 \
        "$ALARM" --summary "concurrent-$i"
    ) &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent alarm invocation exited non-zero"
  done
  [ -s "$state/.wake-delivery-failures" ] || fail "concurrent trim dropped the record entirely"
  for i in $(seq 1 "$count"); do
    grep -qF "concurrent-$i" "$state/.wake-delivery-failures" \
      || fail "concurrent trim silently dropped failure concurrent-$i: $(cat "$state/.wake-delivery-failures")"
  done
  pass "concurrent invocations racing a forced trim never lose an appended failure"
}

# Reading the cooldown marker and then writing it are two separate steps; if
# they are not atomic, every concurrent invocation racing an already-expired
# cooldown can see it as expired before any of them records the claim, so all
# of them fire the active alert. Seed the marker far in the past (cooldown
# obviously expired) and race several truly concurrent invocations: exactly
# one active alert must fire while every durable record still lands.
test_alarm_concurrent_cooldown_fires_at_most_once() {
  local dir state log i n count=20
  local -a pids=()
  dir=$(make_delivery_case alarm-concurrent-cooldown)
  state="$dir/home/state"
  log="$dir/alert.log"
  : > "$log"
  printf '0\n' > "$state/.wake-delivery-alarm"
  for i in $(seq 1 "$count"); do
    (
      FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WEDGE_ALARM_LOG="$log" \
        FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS=600 \
        "$ALARM" --summary "race-$i"
    ) &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent alarm invocation exited non-zero"
  done
  n=$(wc -l < "$state/.wake-delivery-failures")
  [ "$n" -eq "$count" ] || fail "concurrent cooldown race lost a durable record: $n lines, expected $count"
  n=$(grep -c . "$log")
  [ "$n" -eq 1 ] || fail "concurrent cooldown race fired $n active alerts, expected exactly 1"
  pass "concurrent invocations racing an expired cooldown fire at most one active alert"
}

# --- plugin-driven delivery through the real lib -----------------------------

wait_for_file() {  # <file> <label>
  local file=$1 i
  for i in $(seq 1 200); do
    [ -s "$file" ] && return 0
    command sleep 0.02
  done
  fail "$2: $file never appeared"
}

# The turnend-guard plugin with a guard that demands a follow-up is the
# simplest full plugin path: coordinator absent -> guard runs -> exit 2 ->
# delivery attempted through lib/fm-wake-delivery.js.
write_exiting_guard() {  # <repo>
  cat > "$1/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard-fired\n' >&2
exit 2
SH
  chmod +x "$1/bin/fm-turnend-guard.sh"
}

test_guard_delivery_failure_is_recorded_and_alarmed() {
  local dir repo home state log out status
  dir=$(make_delivery_case guard-fail)
  repo="$dir/repo"
  home="$dir/home"
  state="$home/state"
  log="$dir/alert.log"
  : > "$log"
  write_exiting_guard "$repo"
  out=$(PLUGIN="$repo/.opencode/plugins/fm-primary-turnend-guard.js" \
    WORKTREE="$repo" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$state" \
    FM_WAKE_DELIVERY_RETRY_LIMIT=1 FM_WAKE_DELIVERY_RETRY_BASE_MS=5 FM_WAKE_DELIVERY_RETRY_MAX_MS=10 \
    FM_WAKE_DELIVERY_TIMEOUT_MS=2000 FM_WEDGE_ALARM_LOG="$log" node 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let calls = 0;
const client = {
  session: {
    promptAsync: async () => {
      calls += 1;
      throw new Error("stubbed API drift rejection");
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (calls !== 2) {
  console.error(`expected exactly 2 bounded attempts, got ${calls}`);
  process.exit(1);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "guard plugin must survive a rejecting client without crashing"
  [ -z "$out" ] || fail "guard failure test printed output: $out"
  wait_for_file "$state/.wake-delivery-failures" "guard failure record"
  grep -F 'turn-end guard follow-up' "$state/.wake-delivery-failures" >/dev/null \
    || fail "record lacks the delivery context: $(cat "$state/.wake-delivery-failures")"
  grep -F 'stubbed API drift rejection' "$state/.wake-delivery-failures" >/dev/null \
    || fail "record lacks the underlying reason: $(cat "$state/.wake-delivery-failures")"
  wait_for_file "$log" "guard failure alarm"
  grep -F 'wake delivery FAILED' "$log" >/dev/null || fail "alarm channel did not fire: $(cat "$log")"
  pass "turnend-guard delivery failure is retried once, recorded, and alarmed"
}

test_guard_delivery_success_stays_silent_and_single() {
  local dir repo home state log out status
  dir=$(make_delivery_case guard-ok)
  repo="$dir/repo"
  home="$dir/home"
  state="$home/state"
  log="$dir/alert.log"
  : > "$log"
  write_exiting_guard "$repo"
  out=$(PLUGIN="$repo/.opencode/plugins/fm-primary-turnend-guard.js" \
    WORKTREE="$repo" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$state" \
    FM_WAKE_DELIVERY_TIMEOUT_MS=2000 FM_WEDGE_ALARM_LOG="$log" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let calls = 0;
const client = {
  session: {
    promptAsync: async () => {
      calls += 1;
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
await new Promise((resolve) => setTimeout(resolve, 300));
if (calls !== 1) {
  console.error(`healthy delivery must stay one attempt, got ${calls}`);
  process.exit(1);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "guard plugin healthy path must be unchanged"
  [ -z "$out" ] || fail "guard healthy test printed output: $out"
  [ ! -e "$state/.wake-delivery-failures" ] || fail "healthy delivery wrote a failure record"
  [ ! -s "$log" ] || fail "healthy delivery fired an alarm: $(cat "$log")"
  pass "healthy guard delivery stays one attempt with no record and no alarm"
}

test_hanging_prompt_is_declared_by_timeout() {
  local dir repo home state out status
  dir=$(make_delivery_case delivery-hang)
  repo="$dir/repo"
  home="$dir/home"
  state="$home/state"
  write_exiting_guard "$repo"
  out=$(PLUGIN="$repo/.opencode/plugins/fm-primary-turnend-guard.js" \
    WORKTREE="$repo" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$state" \
    FM_WAKE_DELIVERY_RETRY_LIMIT=0 FM_WAKE_DELIVERY_TIMEOUT_MS=80 FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS=0 \
    node 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: () => new Promise(() => {}),
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const started = Date.now();
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const elapsed = Date.now() - started;
if (elapsed > 3000) {
  console.error(`hanging prompt was not bounded: ${elapsed}ms`);
  process.exit(1);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "a hanging promptAsync must not wedge the plugin"
  [ -z "$out" ] || fail "hang test printed output: $out"
  wait_for_file "$state/.wake-delivery-failures" "hang failure record"
  grep -F 'not accepted within 80ms' "$state/.wake-delivery-failures" >/dev/null \
    || fail "record lacks the timeout reason: $(cat "$state/.wake-delivery-failures")"
  pass "a hanging promptAsync is timeout-bounded and declared"
}

test_nudge_delivery_failure_is_recorded() {
  local dir repo home state out status
  dir=$(make_delivery_case nudge-fail)
  repo="$dir/repo"
  home="$dir/home"
  state="$home/state"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$repo/bin/fm-sessionstart-nudge.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$repo/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$repo/bin/fm-gate-refuse-lib.sh"
  chmod +x "$repo/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$repo/.opencode/plugins/fm-primary-sessionstart-nudge.js" \
    WORKTREE="$repo" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$state" \
    FM_WAKE_DELIVERY_RETRY_LIMIT=0 FM_WAKE_DELIVERY_RETRY_BASE_MS=5 \
    node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async () => {
      throw new Error("stale build cannot accept prompts");
    },
  },
};
const hooks = await mod.FmPrimarySessionstartNudge({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
await hooks.event({
  event: {
    type: "session.created",
    properties: { info: { id: "session-test" }, sessionID: "session-test" },
  },
});
EOF
  )
  status=$?
  expect_code 0 "$status" "nudge plugin must survive a rejecting client"
  [ -z "$out" ] || fail "nudge failure test printed output: $out"
  wait_for_file "$state/.wake-delivery-failures" "nudge failure record"
  grep -F 'session-start nudge' "$state/.wake-delivery-failures" >/dev/null \
    || fail "record lacks the nudge context: $(cat "$state/.wake-delivery-failures")"
  pass "a session-start nudge the running build cannot accept is recorded"
}

test_watch_arm_wake_cycle_failure_is_recorded() {
  local dir repo home state log out status
  dir=$(make_delivery_case watch-cycle)
  repo="$dir/repo"
  home="$dir/home"
  state="$home/state"
  log="$dir/alert.log"
  : > "$log"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# First cycle ends with an actionable wake; later successor probes report an
# external healthy watcher so restoration settles without another wake.
if [ -e "${FM_ARM_STATE_DIR:?}/armed" ]; then
  printf 'watcher: healthy pid=1 (beacon 0s)\n'
  command sleep 2
  exit 0
fi
mkdir -p "$FM_ARM_STATE_DIR"
: > "$FM_ARM_STATE_DIR/armed"
printf 'signal: test wake\n'
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/task.meta"
  out=$(PLUGIN="$repo/.opencode/plugins/fm-primary-watch-arm.js" \
    WORKTREE="$repo" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$state" \
    FM_ARM_STATE_DIR="$dir/arm-state" \
    FM_WAKE_DELIVERY_RETRY_LIMIT=0 FM_WAKE_DELIVERY_RETRY_BASE_MS=5 \
    FM_WATCH_REARM_RETRY_LIMIT=0 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    FM_WAKE_DELIVERY_TIMEOUT_MS=2000 FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS=0 \
    FM_WEDGE_ALARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async () => {
      throw new Error("stale TUI build rejects wake prompts");
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
const record = `${process.env.FM_STATE_OVERRIDE}/.wake-delivery-failures`;
for (let i = 0; i < 300 && !existsSync(record); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(record)) {
  console.error("actionable wake cycle recorded no delivery failure");
  process.exit(1);
}
const text = readFileSync(record, "utf8");
if (!text.includes("actionable wake") && !text.includes("watcher failure")) {
  console.error(`record lacks a watcher delivery context: ${text}`);
  process.exit(1);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "watch-arm cycle must declare an undeliverable wake"
  [ -z "$out" ] || fail "watch cycle failure test printed output: $out"
  wait_for_file "$log" "watch cycle alarm"
  grep -F 'wake delivery FAILED' "$log" >/dev/null || fail "wake cycle alarm did not fire: $(cat "$log")"
  pass "an actionable watcher wake the TUI cannot accept is recorded and alarmed within the cycle"
}

test_alarm_records_missing_script_summary_is_dropped() {
  local dir state status=0
  dir=$(make_delivery_case alarm-empty)
  state="$dir/home/state"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$ALARM" --summary "" || status=$?
  expect_code 0 "$status" "empty summary must still exit 0"
  [ ! -e "$state/.wake-delivery-failures" ] || fail "empty summary wrote a record"
  status=0
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$ALARM" || status=$?
  expect_code 0 "$status" "argument-less alarm must still exit 0"
  [ ! -e "$state/.wake-delivery-failures" ] || fail "missing --summary wrote a record"
  pass "empty or missing alarm summaries are dropped, never an error"
}

test_alarm_records_failure_keeps_record_writable() {
  local dir out status blocker
  dir=$(make_delivery_case alarm-ro-state)
  # A state directory that cannot exist (its parent is a regular file) still
  # exits 0 quietly: the alarm path is best-effort by contract and must never
  # disturb the caller's own failure handling.
  blocker="$dir/blocker"
  : > "$blocker"
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$blocker/state" "$ALARM" --summary "x" 2>&1)
  status=$?
  expect_code 0 "$status" "unwritable state must not fail the alarm"
  [ -z "$out" ] || fail "unwritable state printed: $out"
  pass "alarm stays silent and zero-exit when the record cannot be written"
}

test_alarm_records_failure_never_fires_real_channels() {
  # Sourcing the CHANNEL LIBRARY directly (never the away-mode daemon) means an
  # executed consumer fires real channels unless the seam is forced; this suite
  # inherits the wake-helpers recorder, so a real osascript here would fail the
  # assertion below. It pins that the alarm script routes through the seam.
  local dir log
  dir=$(make_delivery_case alarm-seam)
  log="$dir/alert.log"
  : > "$log"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS=0 \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_LOG="$log" "$ALARM" --summary "seam check"
  grep -F 'osascript' "$log" >/dev/null || fail "alarm did not route through the recorder seam"
  pass "alarm channels route through the FM_WEDGE_ALARM_EXEC recorder seam"
}

test_wake_delivery_records_failure_is_idempotent_per_failure() {
  # The same declared failure must append exactly one record line per alarm
  # invocation even when the summary contains shell-hostile characters.
  local dir state n
  dir=$(make_delivery_case alarm-hostile)
  state="$dir/home/state"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_WAKE_DELIVERY_ALARM_COOLDOWN_SECS=0 \
    "$ALARM" --summary 'quote"double and $dollar and `tick`'
  n=$(wc -l < "$state/.wake-delivery-failures")
  [ "$n" -eq 1 ] || fail "hostile summary recorded $n lines, expected 1"
  tail -n 1 "$state/.wake-delivery-failures" | grep -F '$dollar' >/dev/null \
    || fail "hostile summary was mangled: $(cat "$state/.wake-delivery-failures")"
  pass "shell-hostile summaries are recorded verbatim and single-line"
}

test_alarm_records_one_sanitized_line_and_fires_channel
test_alarm_cooldown_limits_active_alerts_not_records
test_alarm_off_channel_still_records
test_alarm_trims_the_record_bounded
test_alarm_concurrent_appends_survive_trim
test_alarm_concurrent_cooldown_fires_at_most_once
test_guard_delivery_failure_is_recorded_and_alarmed
test_guard_delivery_success_stays_silent_and_single
test_hanging_prompt_is_declared_by_timeout
test_nudge_delivery_failure_is_recorded
test_watch_arm_wake_cycle_failure_is_recorded
test_alarm_records_missing_script_summary_is_dropped
test_alarm_records_failure_keeps_record_writable
test_alarm_records_failure_never_fires_real_channels
test_wake_delivery_records_failure_is_idempotent_per_failure
