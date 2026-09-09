#!/usr/bin/env bash
# Behavior tests for fm-time.sh: propose from synthetic signals, approval
# (as-is and corrected), retroactive log entries, live start/stop, split, and
# the month-end report's grouping and after-hours split.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FMTIME="$ROOT/bin/fm-time.sh"
TMP_ROOT=$(fm_test_tmproot fm-time)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# touch_at <path> <YYYY-MM-DD> <HH:MM>: portable POSIX `touch -t` mtime set.
touch_at() {
  local path=$1 date=$2 hm=$3 stamp
  stamp="${date//-/}${hm/:/}"
  touch -t "$stamp" "$path"
}

# ---------------------------------------------------------------- propose

test_propose_clusters_synthetic_status_and_meta_evidence() {
  local home
  home=$(make_home propose-basic)

  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
kind=ship
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30

  cat > "$home/state/demo-task.status" <<'EOF'
working: doing the thing
done: fixed the widget
EOF
  touch_at "$home/state/demo-task.status" 2026-09-05 18:40

  local out
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on synthetic status+meta evidence"
  assert_contains "$out" "1 proposed window" "close-together meta+status pings did not merge into one window"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list failed"
  assert_contains "$list" "[p1]" "proposal id p1 missing from list"
  assert_contains "$list" "project  FnO" "proposal did not attribute the project from state/<id>.meta"
  assert_contains "$list" "task     demo-task" "proposal did not attribute the task id"
  assert_contains "$list" "evidence: " "proposal listed no evidence for the captain to judge"
  assert_contains "$list" "task record touched" "meta-touch evidence line missing"
  assert_contains "$list" "done: fixed the widget" "status-line evidence text missing"

  pass "propose clusters close synthetic status+meta pings into one evidenced window"
}

test_propose_wide_gap_produces_two_windows() {
  local home
  home=$(make_home propose-gap)

  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 09:00

  cat > "$home/state/demo-task.status" <<'EOF'
done: unrelated later work
EOF
  touch_at "$home/state/demo-task.status" 2026-09-05 20:00

  local out
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on wide-gap evidence"
  assert_contains "$out" "2 proposed window" "pings 11 hours apart (past the default gap) incorrectly merged"

  pass "propose starts a new window once the gap exceeds the configured threshold"
}

test_propose_refuses_second_batch_without_replace() {
  local home out err status
  home=$(make_home propose-pending)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 09:00

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null \
    || fail "first propose failed"

  status=0
  err=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" 2>&1 >/dev/null) || status=$?
  expect_code 1 "$status" "propose with a pending batch and no --replace"
  assert_contains "$err" "--replace" "refusal did not mention the --replace escape hatch"

  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" --replace) \
    || fail "propose --replace should succeed over a pending batch"
  assert_contains "$out" "proposed window" "propose --replace did not regenerate a batch"

  pass "propose refuses a second batch while one is pending, unless --replace is given"
}

test_propose_reads_reported_scout_completions_from_backlog() {
  local home
  home=$(make_home propose-reported)

  cat > "$home/data/backlog.md" <<'EOF'
- [x] carry-scout-example - Diagnose the thing data/carry-scout-example/report.md (repo: FnO) (reported 2026-09-05)
EOF

  local out
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on a scout-style (reported ...) backlog completion"
  assert_contains "$out" "1 proposed window" "a (reported ...) backlog completion produced no proposal"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list failed"
  assert_contains "$list" "project  FnO" "reported-completion proposal did not attribute the (repo: ...) project"
  assert_contains "$list" "task     carry-scout-example" "reported-completion proposal did not attribute the task id"

  pass "propose reads (reported YYYY-MM-DD) scout completions from the backlog, not only (done ...)"
}

test_propose_reads_merged_completions_from_backlog() {
  local home
  home=$(make_home propose-merged)

  # tasks-axi writes "(merged YYYY-MM-DD)" instead of "(done ...)" for a task
  # closed with `done <id> --pr <url>` (verified against a real tasks-axi
  # binary); without handling this marker, every PR-linked completion is
  # invisible to propose.
  cat > "$home/data/backlog.md" <<'EOF'
- [x] carry-ship-example - Ship the thing https://github.com/o/r/pull/42 (repo: FnO) (merged 2026-09-05)
EOF

  local out
  out=$(FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00") \
    || fail "propose failed on a (merged ...) backlog completion"
  assert_contains "$out" "1 proposed window" "a (merged ...) backlog completion produced no proposal"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list failed"
  assert_contains "$list" "project  FnO" "merged-completion proposal did not attribute the (repo: ...) project"
  assert_contains "$list" "task     carry-ship-example" "merged-completion proposal did not attribute the task id"
  assert_not_contains "$list" "merged 2026-09-05" "merged-completion evidence text leaked the raw marker instead of the description"

  pass "propose reads (merged YYYY-MM-DD) PR completions from the backlog, not only (done ...)"
}

# ---------------------------------------------------------------- approve / correction

test_approve_records_entry_and_advances_cursor() {
  local home
  home=$(make_home approve-basic)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null

  local out
  out=$(FM_HOME="$home" "$FMTIME" approve p1) || fail "approve p1 failed"
  assert_contains "$out" "approved p1" "approve did not report success"
  assert_grep "task=demo-task" "$home/data/time-tracking/entries.md" \
    "approved entry missing task attribution"
  assert_present "$home/data/time-tracking/cursor" "approving the only pending proposal did not advance the cursor"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list after approve failed"
  assert_contains "$list" "no pending proposals" "approved proposal still shows as pending"

  pass "approve records the window as a durable entry and clears it from pending"
}

test_approve_correction_overrides_proposed_fields() {
  local home
  home=$(make_home approve-correct)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30
  cat > "$home/state/demo-task.status" <<'EOF'
working: first pass
EOF
  touch_at "$home/state/demo-task.status" 2026-09-05 18:35

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null
  FM_HOME="$home" "$FMTIME" approve p1 \
    --start "2026-09-05 18:00" --end "2026-09-05 19:30" --desc "corrected description" \
    || fail "corrected approve failed"

  assert_grep "start=2026-09-05 18:00" "$home/data/time-tracking/entries.md" \
    "corrected start time was not recorded"
  assert_grep "end=2026-09-05 19:30" "$home/data/time-tracking/entries.md" \
    "corrected end time was not recorded"
  assert_grep "desc=corrected description" "$home/data/time-tracking/entries.md" \
    "corrected description was not recorded"

  pass "approve accepts start/end/desc corrections over the proposed defaults"
}

test_reject_drops_without_recording() {
  local home
  home=$(make_home reject-basic)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null
  FM_HOME="$home" "$FMTIME" reject p1 || fail "reject p1 failed"

  if [ -e "$home/data/time-tracking/entries.md" ]; then
    assert_no_grep "demo-task" "$home/data/time-tracking/entries.md" \
      "rejected proposal was recorded as an entry anyway"
  fi
  pass "reject drops a proposal without recording anything"
}

test_split_divides_evidence_at_the_boundary() {
  local home
  home=$(make_home split-basic)
  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:00
  cat > "$home/state/demo-task.status" <<'EOF'
working: part one
EOF
  touch_at "$home/state/demo-task.status" 2026-09-05 18:10

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null
  FM_HOME="$home" "$FMTIME" split p1 --at "2026-09-05 18:05" || fail "split failed"

  local list
  list=$(FM_HOME="$home" "$FMTIME" list) || fail "list after split failed"
  assert_contains "$list" "[p1-a]" "split did not produce the first half"
  assert_contains "$list" "[p1-b]" "split did not produce the second half"
  assert_contains "$list" "end      2026-09-05 18:05" "split first half did not end at the boundary"
  assert_contains "$list" "start    2026-09-05 18:05" "split second half did not start at the boundary"

  FM_HOME="$home" "$FMTIME" approve p1-a --desc first >/dev/null || fail "approve p1-a failed"
  FM_HOME="$home" "$FMTIME" approve p1-b --desc second >/dev/null || fail "approve p1-b failed"
  assert_grep "desc=first" "$home/data/time-tracking/entries.md" "first half not recorded"
  assert_grep "desc=second" "$home/data/time-tracking/entries.md" "second half not recorded"

  pass "split divides a proposal's evidence at the given boundary into two approvable halves"
}

# ---------------------------------------------------------------- start / stop / log

test_start_stop_records_a_live_session() {
  local home out
  home=$(make_home live-session)

  out=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788800000 "$FMTIME" start --project firstmate --task demo --desc "building") \
    || fail "start failed"
  assert_present "$home/data/time-tracking/active" "start did not create an active-session record"

  out=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788805000 "$FMTIME" stop) || fail "stop failed"
  assert_contains "$out" "stopped" "stop did not report success"
  assert_absent "$home/data/time-tracking/active" "stop left the active-session record behind"
  assert_grep "desc=building" "$home/data/time-tracking/entries.md" "start/stop entry missing its description"

  local status err
  status=0
  FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788810000 "$FMTIME" start --desc again >/dev/null \
    || fail "second start after a stop should succeed"
  err=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788810000 "$FMTIME" start --desc other 2>&1 >/dev/null) \
    && status=0 || status=$?
  expect_code 1 "$status" "starting a second live session while one is already running"
  assert_contains "$err" "already running" "double-start refusal used the wrong message"
  FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788810120 "$FMTIME" stop >/dev/null

  pass "start/stop records a live-tracked entry and refuses a concurrent second start"
}

test_stop_refuses_same_minute_session() {
  local home out status
  home=$(make_home live-session-same-minute)

  FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788800000 "$FMTIME" start --desc "blink" >/dev/null \
    || fail "start failed"

  status=0
  out=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788800000 "$FMTIME" stop 2>&1) || status=$?
  expect_code 1 "$status" "stop within the same wall-clock minute as start"
  assert_contains "$out" "wait" "same-minute stop refusal used the wrong message"
  assert_present "$home/data/time-tracking/active" \
    "a refused same-minute stop must leave the live session running, not discard it"
  if [ -e "$home/data/time-tracking/entries.md" ]; then
    assert_no_grep "blink" "$home/data/time-tracking/entries.md" \
      "a refused same-minute stop must not record a zero-duration entry"
  fi

  out=$(FM_HOME="$home" FM_TIME_NOW_OVERRIDE=1788800061 "$FMTIME" stop) \
    || fail "stop should succeed once a minute has actually elapsed"
  assert_contains "$out" "stopped" "stop did not report success once past the same-minute window"
  assert_grep "desc=blink" "$home/data/time-tracking/entries.md" \
    "session was not recorded once stopped past the same-minute window"

  pass "stop refuses a same-minute session instead of silently recording a lost, zero-duration entry"
}

test_log_records_a_retroactive_entry() {
  local home out
  home=$(make_home retro-log)
  out=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 21:30" \
    --project FnO --task carry-widget-fix --desc "retroactively logged debugging") \
    || fail "log failed"
  assert_contains "$out" "logged" "log did not report success"
  assert_grep "desc=retroactively logged debugging" "$home/data/time-tracking/entries.md" \
    "retroactive log entry missing its description"
  assert_grep "task=carry-widget-fix" "$home/data/time-tracking/entries.md" \
    "retroactive log entry missing its task"

  pass "log records a retroactive entry directly, with no proposal step"
}

test_log_without_project_or_task_is_not_blocked() {
  local home out
  home=$(make_home retro-log-no-task)
  out=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 20:30" \
    --desc "quick email reply, no task tied to it") \
    || fail "log without --project/--task should not be blocked"
  assert_contains "$out" "logged" "log did not report success"

  out=$(FM_HOME="$home" "$FMTIME" report --month 2026-09) || fail "report failed"
  assert_contains "$out" "(unattributed)" "report did not render a missing project/task as readable prose"
  assert_contains "$out" "quick email reply" "unattributed entry's description is missing from the report"

  pass "a missing task id never blocks recording, and the report renders it as readable prose"
}

test_log_refuses_end_before_start() {
  local home status
  home=$(make_home retro-log-bad)
  status=0
  FM_HOME="$home" "$FMTIME" log --start "2026-09-04 21:00" --end "2026-09-04 20:00" \
    --desc bad >/dev/null 2>/tmp/fm-time-test-err3 || status=$?
  expect_code 1 "$status" "log with end before start"
  assert_contains "$(cat /tmp/fm-time-test-err3)" "after" "end-before-start refusal used the wrong message"
  rm -f /tmp/fm-time-test-err3
  pass "log refuses an entry whose end is not after its start"
}

# ---------------------------------------------------------------- own lock

test_lock_blocks_while_owner_process_is_still_alive() {
  local home lock_dir sleeper_pid status err elapsed start_s
  home=$(make_home lock-live-owner)
  mkdir -p "$home/data/time-tracking"
  lock_dir="$home/data/time-tracking/.lock"
  mkdir "$lock_dir"

  sleep 60 &
  sleeper_pid=$!
  printf '%s\n' "$sleeper_pid" > "$lock_dir/pid"
  # A far-past mtime: an age-only staleness check (the pre-fix behavior)
  # would treat this as abandoned and steal it even though its recorded
  # owner is still running.
  touch -t 202001010000 "$lock_dir"

  status=0
  start_s=$SECONDS
  err=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 20:30" --desc x 2>&1) \
    || status=$?
  elapsed=$((SECONDS - start_s))

  kill "$sleeper_pid" 2>/dev/null
  wait "$sleeper_pid" 2>/dev/null

  expect_code 1 "$status" "log against a lock recorded as held by a still-alive owner"
  assert_contains "$err" "appears to be running" "a live lock owner's hold was stolen instead of respected"
  [ "$elapsed" -ge 5 ] || fail "the lock was released far too quickly for a live owner to have been respected (waited ${elapsed}s)"

  pass "tt_lock never reclaims a lock whose recorded owner process is still alive, no matter its age"
}

test_lock_reclaimed_promptly_from_a_dead_owner() {
  local home lock_dir dead_pid status out elapsed start_s
  home=$(make_home lock-dead-owner)
  mkdir -p "$home/data/time-tracking"
  lock_dir="$home/data/time-tracking/.lock"
  mkdir "$lock_dir"

  ( exit 0 ) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null
  printf '%s\n' "$dead_pid" > "$lock_dir/pid"
  # Deliberately fresh mtime: an age-only staleness check would refuse to
  # reclaim this for LOCK_STALE_SECS even though the recorded owner is
  # already dead; liveness must decide this, not age.

  start_s=$SECONDS
  out=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 20:30" --desc reclaimed 2>&1)
  status=$?
  elapsed=$((SECONDS - start_s))

  expect_code 0 "$status" "log against a lock abandoned by a dead owner"
  assert_contains "$out" "logged" "log did not succeed once the dead owner's lock was reclaimed"
  [ "$elapsed" -lt 5 ] || fail "a lock with a dead recorded owner should reclaim immediately, not wait out a staleness timer (took ${elapsed}s)"

  pass "tt_lock reclaims a lock immediately once its recorded owner is confirmed dead, even when the lock is fresh"
}

test_lock_reclaimed_when_owner_pid_was_reused() {
  local home lock_dir live_pid status out elapsed start_s
  home=$(make_home lock-reused-pid)
  mkdir -p "$home/data/time-tracking"
  lock_dir="$home/data/time-tracking/.lock"
  mkdir "$lock_dir"

  # A live process, but recorded alongside a start timestamp that does not
  # match its real one: this is what a reused pid looks like on disk after
  # its original owner exited and an unrelated process picked up the same
  # pid number. kill -0 alone cannot tell this apart from a genuine live
  # owner; only the recorded start time can.
  sleep 60 &
  live_pid=$!
  printf '%s\n' "$live_pid" > "$lock_dir/pid"
  printf '%s\n' "Mon Jan  1 00:00:00 1990" > "$lock_dir/start"
  touch -t 202001010000 "$lock_dir"

  start_s=$SECONDS
  out=$(FM_HOME="$home" "$FMTIME" log --start "2026-09-04 20:00" --end "2026-09-04 20:30" --desc reclaimed 2>&1)
  status=$?
  elapsed=$((SECONDS - start_s))

  kill "$live_pid" 2>/dev/null
  wait "$live_pid" 2>/dev/null

  expect_code 0 "$status" "log against a lock whose recorded owner pid was reused by an unrelated live process"
  assert_contains "$out" "logged" "log did not succeed once the reused-pid lock was reclaimed"
  [ "$elapsed" -lt 5 ] || fail "a lock whose owner start time no longer matches should reclaim immediately (took ${elapsed}s)"

  pass "tt_lock reclaims a lock whose live recorded pid no longer matches its recorded start time (pid reuse)"
}

# ---------------------------------------------------------------- report

test_report_groups_by_month_and_splits_after_hours() {
  local home
  home=$(make_home report-basic)

  # After-hours: a weekday evening entry (2026-09-02 is a Wednesday).
  FM_HOME="$home" "$FMTIME" log --start "2026-09-02 19:00" --end "2026-09-02 20:00" \
    --project FnO --task widget-fix --desc "evening fix" >/dev/null
  # Business hours: same day, mid-afternoon.
  FM_HOME="$home" "$FMTIME" log --start "2026-09-02 14:00" --end "2026-09-02 15:00" \
    --project FnO --task widget-fix --desc "afternoon follow-up" >/dev/null
  # A different month entirely, must not appear in the September report.
  FM_HOME="$home" "$FMTIME" log --start "2026-08-15 10:00" --end "2026-08-15 11:00" \
    --project FnO --task widget-fix --desc "august work" >/dev/null

  local out
  out=$(FM_HOME="$home" "$FMTIME" report --month 2026-09) || fail "report failed"
  assert_contains "$out" "2026-09" "report header missing the requested month"
  assert_contains "$out" "total: 2h00m" "report total did not sum both September entries"
  assert_contains "$out" "after hours" "report did not label after-hours time"
  assert_contains "$out" "1h00m" "report is missing the 1-hour after-hours contribution"
  assert_not_contains "$out" "august work" "August entry leaked into the September report"

  pass "report sums entries for the requested month only and separates after-hours time"
}

test_report_month_boundary_uses_entry_start_date() {
  local home out
  home=$(make_home report-boundary)
  FM_HOME="$home" "$FMTIME" log --start "2026-08-31 23:00" --end "2026-09-01 01:00" \
    --project FnO --task overnight --desc "crossed midnight into September" >/dev/null

  out=$(FM_HOME="$home" "$FMTIME" report --month 2026-08) || fail "august report failed"
  assert_contains "$out" "total: 2h00m" "an entry starting in August was not counted in the August report"

  out=$(FM_HOME="$home" "$FMTIME" report --month 2026-09) || fail "september report failed"
  assert_contains "$out" "no entries recorded" "an entry that only ENDS in September was wrongly counted there too"

  pass "report attributes a midnight-crossing entry to its start month, not its end month"
}

test_time_tracking_never_writes_supervision_state() {
  local home before_lock before_wake
  home=$(make_home no-supervision-touch)
  printf 'pid-marker\n' > "$home/state/.lock"
  printf '111\t1\tcheck\tk\tp\n' > "$home/state/.wake-queue"
  before_lock=$(cat "$home/state/.lock")
  before_wake=$(cat "$home/state/.wake-queue")

  cat > "$home/state/demo-task.meta" <<EOF
project=$home/projects/FnO
EOF
  touch_at "$home/state/demo-task.meta" 2026-09-05 18:30

  FM_HOME="$home" "$FMTIME" propose --since "2026-09-01 00:00" >/dev/null
  FM_HOME="$home" "$FMTIME" approve p1 >/dev/null
  FM_HOME="$home" "$FMTIME" report --month 2026-09 >/dev/null

  [ "$(cat "$home/state/.lock")" = "$before_lock" ] || fail "fm-time.sh modified the session lock file"
  [ "$(cat "$home/state/.wake-queue")" = "$before_wake" ] || fail "fm-time.sh modified the durable wake queue"

  pass "propose/approve/report only read state/.lock and state/.wake-queue, never write them"
}

test_propose_clusters_synthetic_status_and_meta_evidence
test_propose_wide_gap_produces_two_windows
test_propose_refuses_second_batch_without_replace
test_propose_reads_reported_scout_completions_from_backlog
test_propose_reads_merged_completions_from_backlog
test_approve_records_entry_and_advances_cursor
test_approve_correction_overrides_proposed_fields
test_reject_drops_without_recording
test_split_divides_evidence_at_the_boundary
test_start_stop_records_a_live_session
test_stop_refuses_same_minute_session
test_log_records_a_retroactive_entry
test_log_without_project_or_task_is_not_blocked
test_log_refuses_end_before_start
test_lock_blocks_while_owner_process_is_still_alive
test_lock_reclaimed_promptly_from_a_dead_owner
test_lock_reclaimed_when_owner_pid_was_reused
test_report_groups_by_month_and_splits_after_hours
test_report_month_boundary_uses_entry_start_date
test_time_tracking_never_writes_supervision_state
