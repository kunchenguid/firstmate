#!/usr/bin/env bash
# Opt-in record-age reminders through the watcher's real queue interface.
# No endpoint, harness process, model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-open-decisions)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
# Source ownership is machine-wide by default; keep every claim in this suite.
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$TMP_ROOT/drain-root"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

FM_OPEN_DECISION_OVERDUE_SECS=100
FM_OPEN_DECISION_BACKOFF_MAX_SECS=400

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  OPEN_DECISION_REMINDER=
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

test_disabled() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "disabled flag queued a reminder"
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "disabled flag folded status"
  pass "absent flag emits nothing and does not fold status"
}

test_oldest_and_backoff() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=older]: choose\nworking: continuing\n' > "$STATE/z-worker.status"
  printf 'blocked [at=1050] [key=newer]: help\n' > "$STATE/a-worker.status"
  open_decision_reminder_tick 1099
  [ "$(count_wakes)" = 0 ] || fail "not-yet-overdue key queued a reminder"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 1 ] || fail "oldest overdue key did not queue exactly one wake"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: z-worker key=older age=200s' ] \
    || fail "reminder did not select the oldest durable record: $OPEN_DECISION_REMINDER"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 2 ] || fail "another overdue key inherited the oldest key's backoff"
  open_decision_reminder_tick 1299
  [ "$(count_wakes)" = 2 ] || fail "same key repeated before its first backoff"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 3 ] || fail "first repeat did not become due"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 4 ] || fail "second key did not repeat independently"
  open_decision_reminder_tick 1499
  [ "$(count_wakes)" = 4 ] || fail "repeat interval did not double"
  open_decision_reminder_tick 1500
  open_decision_reminder_tick 1500
  [ "$(count_wakes)" = 6 ] || fail "doubled backoff did not expire"
  open_decision_reminder_tick 1899
  [ "$(count_wakes)" = 6 ] || fail "capped interval fired early"
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 2300
  open_decision_reminder_tick 2300
  [ "$(count_wakes)" = 10 ] || fail "backoff did not stay bounded at the cap"
  pass "oldest key surfaces once, and independent per-key backoff doubles up to its cap"
}

assert_distinct_reminder_identities() {  # <older-task> <older-key> <newer-task> <newer-key>
  local older_task=$1 older_key=$2 newer_task=$3 newer_key=$4 now count=0
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=%s]: choose\n' "$older_key" > "$STATE/$older_task.status"
  printf 'blocked [at=1050] [key=%s]: help\n' "$newer_key" >> "$STATE/$newer_task.status"
  for now in 1200 1300 1500 1900 2300; do
    if [ "$count" -gt 0 ]; then
      open_decision_reminder_tick "$((now - 1))"
      [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated before its backoff"
    fi
    open_decision_reminder_tick "$now"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "older numeric-looking identity did not become due"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $older_task key=$older_key age=$((now - 1000))s" ] \
      || fail "older numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "distinct numeric-looking identity inherited another identity's backoff"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $newer_task key=$newer_key age=$((now + 1 - 1050))s" ] \
      || fail "newer numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated without waiting"
  done
}

test_numeric_keys_are_distinct() {
  assert_distinct_reminder_identities worker 1 worker 01
  pass "keys 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_numeric_tasks_are_distinct() {
  assert_distinct_reminder_identities 1 api 01 api
  pass "tasks 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_resolution_and_reopen() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  printf 'resolved [at=1201] [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "resolved key kept generating reminders"
  printf 'blocked [at=1600] [key=api]: new episode\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1700
  [ "$(count_wakes)" = 2 ] || fail "reopened key inherited the resolved episode's backoff"
  pass "resolution stops reminders immediately and a later episode starts fresh"
}

test_wait_exemptions() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\npaused [at=1050]: validation in flight\n' > "$STATE/paused.status"
  printf 'needs-decision [at=1000] [key=api]: choose\ncaptain-held [at=1050] [key=api]: transferred\n' > "$STATE/transferred.status"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/backlog-held.status"
  # The watcher already delegates backlog ownership to this predicate.
  task_captain_call_open() { [ "$1" = backlog-held ]; }
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "a declared wait or captain hold queued a reminder"
  printf 'working [at=1201]: resumed\n' >> "$STATE/paused.status"
  open_decision_reminder_tick 1201
  [ "$(count_wakes)" = 1 ] || fail "ending a pause hid the still-open key"
  pass "paused waits, verified transfers, and backlog captain holds are exempt"
}

test_unknown_times_and_keyless() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [key=missing]: choose\nblocked [at=bad] [key=bad]: help\nblocked [at=1000]: legacy\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "unknown emission time or keyless record was inferred overdue"
  pass "only explicitly keyed records with valid source timestamps are aged"
}

test_timed_fold_is_incremental() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  export FM_OPEN_DECISIONS_READ_PROBE="$TMP_ROOT/fold.reads"
  : > "$FM_OPEN_DECISIONS_READ_PROBE"
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1201
  [ "$(wc -l < "$FM_OPEN_DECISIONS_READ_PROBE" | tr -d ' ')" = 1 ] \
    || fail "unchanged poll reread the task's history"
  printf 'resolved [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1202
  [ "$(tail -1 "$FM_OPEN_DECISIONS_READ_PROBE" | cut -f2)" = 29 ] \
    || fail "resolution poll folded more than newly appended bytes"
  [ "$(count_wakes)" = 1 ] || fail "incremental resolution left a reminder live"
  unset FM_OPEN_DECISIONS_READ_PROBE
  pass "quiet polls reuse the timed fold and only new status bytes are folded"
}

test_invalid_settings() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  if FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_tick 1200; then
    fail "zero threshold enabled an unbounded reminder loop"
  fi
  if FM_OPEN_DECISION_BACKOFF_MAX_SECS=99 open_decision_reminder_tick 1200; then
    fail "cap below the threshold was accepted"
  fi
  [ "$(count_wakes)" = 0 ] || fail "invalid settings queued a reminder"
  pass "invalid settings refuse the tick without queueing reminders"
}

test_timed_cursor_retirement() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  status_retire_presentation_task "$STATE" worker
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "task retirement left its timed cursor"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "retired task kept generating reminders"
  pass "task retirement removes the timed cursor and ends reminders"
}

# Run the real watcher for <dir> until its first actionable exit.
watch_once() {  # <dir> <out>
  local dir=$1 out=$2 pid i=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 FM_SIGNAL_GRACE=1 \
    bash "$ROOT/bin/fm-watch.sh" > "$out" 2> "$out.err" &
  pid=$!
  while [ "$i" -lt 300 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  wait "$pid"
}

drain() {  # <dir> [drain-args...]; the tangle check reads an inert root
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$TMP_ROOT/drain-root" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" "$ROOT/bin/fm-wake-drain.sh" "$@"
}

# A decision old enough to be overdue was surfaced as an ordinary signal when
# its worker wrote it, and firstmate drained and acknowledged that wake. Build
# that state through the real watcher and drain, with reminders still off.
reminder_case() {  # <dir>
  local dir=$1 sequence generation
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  fm_test_track_procevent_home "$dir" "$FM_PROCEVENT_CLAIM_ROOT"
  touch "$dir/state/home-summary.json"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  watch_once "$dir" "$dir/surface.out" || return 1
  grep -F 'signal:' "$dir/surface.out" >/dev/null || return 1
  drain "$dir" >/dev/null 2> "$dir/surface-drain.err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/surface-drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/surface-drain.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  drain "$dir" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 || return 1
  [ ! -s "$dir/state/.wake-queue" ]
}

queued_reminders() {  # <dir>
  awk -F '\t' '$3 == "check" && index($4, "open-decision:") == 1' "$1/state/.wake-queue" 2>/dev/null \
    | awk 'END { print NR + 0 }'
}

pe() {  # <dir> <command>...
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-procevent.sh" "$@"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop"
  reminder_case "$dir" || fail "could not surface and acknowledge the decision before it aged"
  touch "$dir/config/open-decision-reminders"
  watch_once "$dir" "$dir/out" \
    || fail "real watcher failed to wake on an overdue record: $(cat "$dir/out.err")"
  grep -F 'check: open decision overdue: worker key=api age=' "$dir/out" >/dev/null \
    || fail "real watcher did not print the reminder wake: $(cat "$dir/out")"
  [ "$(wc -l < "$dir/state/.wake-queue" | tr -d ' ')" = 1 ] \
    || fail "real watcher did not durably queue exactly one reminder"
  pass "the actual watcher wakes and exits on an overdue key without any recorded pane"
}

# A due reminder is queued at its own step but must not end the cycle there:
# with many open keys one is due on almost every poll, and an early exit then
# skipped process-event reconcile on every cycle. Reconcile is what refreshes
# the owner lease each runner's guard requires and restarts a registered source
# that has no live runner, as a guard that stopped it on a stale lease leaves it.
test_reminder_cycle_still_reconciles_procevent() {
  local dir="$TMP_ROOT/reminder-reconcile" lease before after owner i=0
  reminder_case "$dir" || fail "could not surface and acknowledge the decision before it aged"
  cat > "$dir/source.sh" <<'SH'
#!/usr/bin/env bash
# Blocks, bounded, until the trigger exists; nothing here completes on its own.
while [ ! -e "$1" ] && [ "$SECONDS" -lt 120 ]; do sleep 0.1; done
SH
  chmod +x "$dir/source.sh"
  pe "$dir" register lavish reminder-src -- "$dir/source.sh" "$dir/trigger" >/dev/null \
    || fail "could not register the process-event source"
  owner=$(pe "$dir" list | awk '$1 == "reminder-src" { print $3 }')
  [ "$owner" = none ] || fail "the fixture source already had a runner: $owner"
  lease=$(fm_procevent_owner_lease_path "$dir/state")
  before=$(cat "$lease") || fail "registration left no owner lease"
  touch "$dir/config/open-decision-reminders"
  watch_once "$dir" "$dir/out" \
    || fail "real watcher failed to wake on an overdue record: $(cat "$dir/out.err")"
  [ "$(queued_reminders "$dir")" = 1 ] || fail "the reminder was not durably queued exactly once"
  after=$(cat "$lease") || fail "the owner lease disappeared"
  awk -v a="$after" -v b="$before" 'BEGIN { exit !(a > b) }' \
    || fail "the reminder cycle never refreshed the process-event owner lease ($before -> $after)"
  # The launch is detached; only this watcher's reconcile could have made it.
  while [ "$i" -lt 100 ]; do
    owner=$(pe "$dir" list | awk '$1 == "reminder-src" { print $3 }')
    [ -z "$owner" ] || [ "$owner" = none ] || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$owner" ] && [ "$owner" != none ] \
    || fail "the reminder cycle never restarted the source that had no runner"
  pe "$dir" retire reminder-src >/dev/null 2>&1 || true
  pass "a cycle that queues a reminder still refreshes the owner lease and restarts a stopped source"
}

# The same cycle still delivers a process-event result a runner had already
# captured, and the reminder it queued reaches the same drain.
test_reminder_cycle_still_delivers_procevent_result() {
  local dir="$TMP_ROOT/reminder-delivery" i=0
  reminder_case "$dir" || fail "could not surface and acknowledge the decision before it aged"
  pe "$dir" register lavish delivery-src -- \
    /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null \
    || fail "could not register the process-event source"
  # Only the captured row matters here; a slow launch may miss its confirm window.
  pe "$dir" reconcile >/dev/null 2>&1 || true
  while [ "$i" -lt 300 ] \
    && ! grep -F 'procevent lavish delivery-src 1' "$dir/state/.wake-queue" >/dev/null 2>&1; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -F 'procevent lavish delivery-src 1' "$dir/state/.wake-queue" >/dev/null \
    || fail "the fixture captured no process-event result"
  # The runner publishes before it releases its claim; retire after that release.
  i=0
  while [ "$i" -lt 100 ] && [ -e "$FM_PROCEVENT_CLAIM_ROOT/delivery-src.claim" ]; do sleep 0.1; i=$((i + 1)); done
  pe "$dir" retire delivery-src >/dev/null || fail "could not retire the finished source"
  touch "$dir/config/open-decision-reminders"
  watch_once "$dir" "$dir/out" \
    || fail "real watcher failed to wake: $(cat "$dir/out.err")"
  grep -F 'check: process-event result captured: procevent:delivery-src:1' "$dir/out" >/dev/null \
    || fail "the reminder cycle did not deliver the captured process-event result: $(cat "$dir/out")"
  [ "$(queued_reminders "$dir")" = 1 ] || fail "the reminder was not durably queued exactly once"
  drain "$dir" > "$dir/drain.out" 2>/dev/null || fail "drain after the wake failed"
  grep -F 'procevent lavish delivery-src 1' "$dir/drain.out" >/dev/null \
    || fail "the drain did not present the process-event result"
  grep -F 'check: open decision overdue: worker key=api age=' "$dir/drain.out" >/dev/null \
    || fail "the drain did not present the reminder queued in the same cycle"
  pass "a cycle that queues a reminder still delivers a captured process-event result to the same drain"
}
fm_test_run test_disabled test_oldest_and_backoff test_numeric_keys_are_distinct \
  test_numeric_tasks_are_distinct test_resolution_and_reopen \
  test_wait_exemptions test_unknown_times_and_keyless test_timed_fold_is_incremental \
  test_invalid_settings test_timed_cursor_retirement test_watcher_loop \
  test_reminder_cycle_still_reconciles_procevent test_reminder_cycle_still_delivers_procevent_result
