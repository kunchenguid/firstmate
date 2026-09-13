#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh --record-only: the explicitly selected,
# record-only archival/retirement operation for a completed ship or scout
# task whose pooled Treehouse worktree slot was already reused by another
# task before ordinary teardown ever ran on it.
#
# Every fixture here is synthetic: a throwaway git repo, a fabricated pool
# layout, and a fabricated slot-owner claim naming another synthetic task.
# None of this refers to any real task, incident, or path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-record-only)
ID=task-x1

# Build a fresh sandbox for one test case:
#   $dir/home/{state,data,config}/  - the firstmate home teardown runs against
#   $dir/fakebin/                   - mocks for tmux, treehouse, gh
#   $dir/project/                   - a throwaway project clone with one commit
#   $dir/pool/1/project             - a linked worktree of that clone
#   $dir/worktree -> pool/1/project - the recorded worktree= path
# Echoes the case dir.
make_case() {  # <name>
  local name=$1
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  : > "$dir/runtime.log"
  git init -q "$dir/project"
  git -C "$dir/project" commit -q --allow-empty -m init

  mkdir -p "$dir/pool/1"
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  ln -s "pool/1/project" "$dir/worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"

  # Default tmux mock: no server at all, so the recorded endpoint reads
  # "missing" - one of the two states record-only accepts as confidently gone.
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
echo "no server running on /tmp/fake.sock" >&2
exit 1
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  # Default gh mock: no PR found. Ship-kind happy-path tests call
  # set_pr_merged to override this.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = pr ] && [ "$2" = view ]; then
  echo "error: pull request not found" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse" "$dir/fakebin/gh"
  printf '%s\n' "$dir"
}

# Make the recorded endpoint read "alive-ish" (unreadable, never dead/missing)
# by having tmux fail with an error fm_backend_tmux_agent_state does not
# recognize as a dead or missing server.
make_endpoint_unreadable() {  # <dir>
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux <%s>\n' "$*" >> "${FM_RUNTIME_LOG:?}"
echo "boom: unexpected tmux failure" >&2
exit 1
SH
}

set_pr_merged() {  # <dir>
  cat > "$1/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = pr ] && [ "$2" = view ]; then
  echo MERGED
  exit 0
fi
exit 0
SH
}

set_pr_open() {  # <dir>
  cat > "$1/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = pr ] && [ "$2" = view ]; then
  echo OPEN
  exit 0
fi
exit 0
SH
}

claim_pool_slot() {  # <dir> <task-id> [home]
  local dir=$1 id=$2 home=${3:-$1/home}
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$dir/pool/1/.fm-slot-owner"
}

write_meta() {  # <dir> <kind> [extra key=val ...]
  local dir=$1 kind=$2
  shift 2
  fm_write_meta "$dir/home/state/$ID.meta" \
    "window=firstmate:fm-$ID" \
    "endpoint_task_id=$ID" \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "spawn_gen=record-only-test-$ID" \
    "$@"
}

write_done_status() {  # <dir> [line]
  printf 'working: setup\n%s\n' "${2:-done: shipped}" > "$1/home/state/$ID.status"
}

seed_backlog_in_flight() {  # <dir> [kind]
  local dir=$1 kind=${2:-ship}
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$dir/home/data/backlog.md"
  tasks-axi add "$ID" "record-only fixture task" --kind "$kind" \
    --file "$dir/home/data/backlog.md" >/dev/null
  tasks-axi start "$ID" --file "$dir/home/data/backlog.md" >/dev/null
}

backlog_row_state() {  # <dir>
  tasks-axi show "$ID" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

run_record_only() {  # <dir> [extra args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_DATA_OVERRIDE="$dir/home/data" \
  FM_CONFIG_OVERRIDE="$dir/home/config" \
  FM_HOME="$dir/home" \
  FM_RUNTIME_LOG="$dir/runtime.log" \
  PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$ID" --record-only "$@"
}

assert_refused_without_mutation() {  # <dir> <description>
  local dir=$1 description=$2 rc
  set +e
  run_record_only "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: --record-only unexpectedly succeeded: $(cat "$dir/stdout")"
  assert_present "$dir/home/state/$ID.meta" "$description: refusal removed the task record"
  ! grep -Fq "treehouse <" "$dir/runtime.log" \
    || fail "$description: refusal reached the pool: $(cat "$dir/runtime.log")"
}

test_record_only_refuses_combined_flags() {
  local dir rc
  dir=$(make_case combined-flags)
  write_meta "$dir" ship
  set +e
  run_record_only "$dir" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--record-only --force should be refused"
  assert_contains "$(cat "$dir/stderr")" "cannot be combined" \
    "combined-flags: wrong refusal message"
  pass "fm-teardown --record-only refuses when combined with --force or --legacy-record"
}

test_record_only_refuses_for_secondmate_kind() {
  local dir
  dir=$(make_case secondmate-kind)
  write_meta "$dir" secondmate
  assert_refused_without_mutation "$dir" "secondmate kind"
  assert_contains "$(cat "$dir/stderr")" "ship or scout" "secondmate-kind: wrong refusal reason"
  pass "fm-teardown --record-only refuses a secondmate task record"
}

test_record_only_refuses_when_slot_still_mine() {
  local dir
  dir=$(make_case slot-mine)
  write_meta "$dir" ship
  claim_pool_slot "$dir" "$ID"
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  assert_refused_without_mutation "$dir" "slot still mine"
  assert_contains "$(cat "$dir/stderr")" "still names $ID as its own claim" \
    "slot-mine: wrong refusal reason"
  pass "fm-teardown --record-only refuses when the pool slot was never reassigned"
}

test_record_only_refuses_when_slot_claim_absent() {
  local dir
  dir=$(make_case slot-absent)
  write_meta "$dir" ship
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  assert_refused_without_mutation "$dir" "slot claim absent"
  assert_contains "$(cat "$dir/stderr")" "no owner claim" "slot-absent: wrong refusal reason"
  pass "fm-teardown --record-only refuses when reuse cannot be proven (no slot claim)"
}

test_record_only_refuses_when_not_a_pool_slot() {
  local dir
  dir=$(make_case not-pool)
  rm -f "$dir/pool/treehouse-state.json"
  write_meta "$dir" ship
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  assert_refused_without_mutation "$dir" "not a pool slot"
  assert_contains "$(cat "$dir/stderr")" "not a pooled Treehouse slot" \
    "not-pool: wrong refusal reason"
  pass "fm-teardown --record-only refuses a worktree that is not a genuine pool slot"
}

test_record_only_refuses_when_endpoint_not_confidently_gone() {
  local dir
  dir=$(make_case endpoint-alive)
  make_endpoint_unreadable "$dir"
  write_meta "$dir" ship
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  assert_refused_without_mutation "$dir" "endpoint not confidently gone"
  assert_contains "$(cat "$dir/stderr")" "not confidently dead or agent-less" \
    "endpoint-alive: wrong refusal reason"
  pass "fm-teardown --record-only refuses when the recorded endpoint does not read dead or missing"
}

test_record_only_refuses_without_valid_spawn_gen() {
  local dir
  dir=$(make_case no-spawn-gen)
  fm_write_meta "$dir/home/state/$ID.meta" \
    "window=firstmate:fm-$ID" "endpoint_task_id=$ID" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=ship" "mode=no-mistakes"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  assert_refused_without_mutation "$dir" "no spawn_gen"
  assert_contains "$(cat "$dir/stderr")" "spawn_gen" "no-spawn-gen: wrong refusal reason"
  pass "fm-teardown --record-only refuses a record with no exact incarnation"
}

test_record_only_refuses_a_legacy_incarnation_stamp() {
  local dir
  dir=$(make_case legacy-stamp)
  fm_write_meta "$dir/home/state/$ID.meta" \
    "window=firstmate:fm-$ID" "endpoint_task_id=$ID" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=legacy-20240101T000000Z-999"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  assert_refused_without_mutation "$dir" "legacy incarnation stamp"
  assert_contains "$(cat "$dir/stderr")" "legacy incarnation stamp" \
    "legacy-stamp: wrong refusal reason"
  pass "fm-teardown --record-only refuses a legacy- stamp left by an abandoned --legacy-record teardown"
}

test_record_only_refuses_when_status_not_done() {
  local dir
  dir=$(make_case status-not-done)
  write_meta "$dir" ship
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir" "blocked: waiting"
  set_pr_merged "$dir"
  assert_refused_without_mutation "$dir" "status not done"
  assert_contains "$(cat "$dir/stderr")" "does not end in a completed" \
    "status-not-done: wrong refusal reason"
  pass "fm-teardown --record-only refuses a task whose status history did not end in done:"
}

test_record_only_refuses_ship_without_merged_pr() {
  local dir
  dir=$(make_case ship-no-pr)
  write_meta "$dir" ship
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  assert_refused_without_mutation "$dir" "ship with no recorded pr="
  assert_contains "$(cat "$dir/stderr")" "cannot confirm landed evidence" \
    "ship-no-pr: wrong refusal reason"
  pass "fm-teardown --record-only refuses a ship task with no recorded pr= and not local-only"
}

test_record_only_refuses_ship_with_open_pr() {
  local dir
  dir=$(make_case ship-open-pr)
  write_meta "$dir" ship "pr=https://github.com/example/repo/pull/9"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_open "$dir"
  assert_refused_without_mutation "$dir" "ship with an open (not merged) PR"
  assert_contains "$(cat "$dir/stderr")" "does not read MERGED" "ship-open-pr: wrong refusal reason"
  pass "fm-teardown --record-only refuses a ship task whose recorded PR is not merged"
}

test_record_only_refuses_ship_local_only() {
  local dir
  dir=$(make_case ship-local-only)
  fm_write_meta "$dir/home/state/$ID.meta" \
    "window=firstmate:fm-$ID" "endpoint_task_id=$ID" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=ship" \
    "mode=local-only" "spawn_gen=record-only-test-$ID"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  assert_refused_without_mutation "$dir" "local-only ship"
  assert_contains "$(cat "$dir/stderr")" "local-only; record-only archival cannot confirm" \
    "ship-local-only: wrong refusal reason"
  pass "fm-teardown --record-only refuses a local-only ship task (no inspectable worktree to confirm content)"
}

test_record_only_refuses_scout_without_report() {
  local dir
  dir=$(make_case scout-no-report)
  write_meta "$dir" scout "decisions_reviewed=1"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" scout
  write_done_status "$dir"
  assert_refused_without_mutation "$dir" "scout with no report"
  assert_contains "$(cat "$dir/stderr")" "has no report at" "scout-no-report: wrong refusal reason"
  pass "fm-teardown --record-only refuses a scout task with no report.md"
}

test_record_only_refuses_scout_without_completion_gate() {
  local dir
  dir=$(make_case scout-no-gate)
  write_meta "$dir" scout
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" scout
  write_done_status "$dir"
  mkdir -p "$dir/home/data/$ID"
  printf 'findings\n' > "$dir/home/data/$ID/report.md"
  assert_refused_without_mutation "$dir" "scout without decisions_reviewed"
  assert_contains "$(cat "$dir/stderr")" "captain-call completion gate" \
    "scout-no-gate: wrong refusal reason"
  pass "fm-teardown --record-only refuses a scout task that never passed the captain-call completion gate"
}

test_record_only_refuses_when_captain_hold_open() {
  local dir
  dir=$(make_case captain-held)
  write_meta "$dir" ship "pr=https://github.com/example/repo/pull/3"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
  FM_CONFIG_OVERRIDE="$dir/home/config" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$ID" --reason "needs a captain decision" \
    >/dev/null || fail "captain-held fixture: could not hold the backlog item"
  assert_refused_without_mutation "$dir" "backlog item held for the captain"
  assert_contains "$(cat "$dir/stderr")" "still held for the captain" \
    "captain-held: wrong refusal reason"
  pass "fm-teardown --record-only refuses while the backlog row is held for the captain"
}

test_record_only_refuses_when_pending_reply_unresolved() {
  local dir
  dir=$(make_case pending-reply)
  write_meta "$dir" ship "pr=https://github.com/example/repo/pull/4"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  mkdir -p "$dir/home/state/pending-replies"
  fm_write_meta "$dir/home/state/pending-replies/corr-1" \
    "task_id=$ID" "phase=awaiting_report"
  assert_refused_without_mutation "$dir" "unresolved pending-reply"
  assert_contains "$(cat "$dir/stderr")" "unresolved pending-reply record" \
    "pending-reply: wrong refusal reason"
  pass "fm-teardown --record-only refuses while an unresolved pending-reply record names this task"
}

# --- happy paths, archival content, idempotence, and crash recovery --------

test_record_only_archives_a_completed_ship_task_and_is_idempotent() {
  local dir out out2 archive
  dir=$(make_case ship-happy)
  write_meta "$dir" ship "pr=https://github.com/example/repo/pull/42"
  claim_pool_slot "$dir" other-task "$dir/other-home"
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"
  : > "$dir/home/state/$ID.turn-ended"
  : > "$dir/home/state/$ID.check.sh"
  chmod 700 "$dir/home/state/$ID.check.sh"

  out=$(run_record_only "$dir") || fail "ship-happy: --record-only failed: $(cat "$dir/stderr" 2>/dev/null)"

  assert_absent "$dir/home/state/$ID.meta" "ship-happy: task record was not archived"
  assert_absent "$dir/home/state/$ID.turn-ended" "ship-happy: volatile artifact left behind"
  assert_absent "$dir/home/state/$ID.check.sh" "ship-happy: registered check artifact left behind"
  assert_equals "done" "$(backlog_row_state "$dir")" "ship-happy: backlog row was not closed"
  assert_grep 'https://github.com/example/repo/pull/42' "$dir/home/data/backlog.md" \
    "ship-happy: closed backlog item did not record the task's PR"

  archive="$dir/home/state/archived-records/$ID.record"
  assert_present "$archive" "ship-happy: no archive record was written"
  assert_grep 'schema=fm-record-only-archive.v1' "$archive" "ship-happy: archive missing schema"
  assert_grep "task_id=$ID" "$archive" "ship-happy: archive missing task_id"
  assert_grep 'slot_owner_task=other-task' "$archive" "ship-happy: archive missing slot owner evidence"
  assert_grep "slot_owner_home=$dir/other-home" "$archive" "ship-happy: archive missing slot owner home"
  assert_grep 'reason=confirmed-pooled-location-reused' "$archive" "ship-happy: archive missing reason"
  assert_present "$dir/home/state/archived-records/$ID.status" \
    "ship-happy: status history was not preserved in the archive"

  # Never touched the reused location, its git content, or the pool.
  ! grep -Fq "treehouse <" "$dir/runtime.log" \
    || fail "ship-happy: record-only touched the pool: $(cat "$dir/runtime.log")"
  assert_present "$dir/pool/1/.fm-slot-owner" "ship-happy: the other task's slot claim was removed"
  assert_grep 'task=other-task' "$dir/pool/1/.fm-slot-owner" \
    "ship-happy: the other task's slot claim was overwritten"
  [ "$(git -C "$dir/project" worktree list | wc -l)" -ge 2 ] \
    || fail "ship-happy: the reused worktree was returned to the pool"
  assert_contains "$out" "$dir/worktree" "ship-happy: success line should name the pool slot"
  assert_contains "$out" "other-task" "ship-happy: success line should name the slot's new owner"

  # Idempotent: a second run reports prior success and changes nothing further.
  out2=$(run_record_only "$dir") || fail "ship-happy: re-run after success failed: $out2"
  assert_contains "$out2" "already complete" "ship-happy: re-run did not report idempotent success"

  pass "fm-teardown --record-only archives a completed ship task's records, never touches its reused pool slot, and is idempotent"
}

test_record_only_archives_a_completed_scout_task() {
  local dir
  dir=$(make_case scout-happy)
  write_meta "$dir" scout "decisions_reviewed=1"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" scout
  write_done_status "$dir"
  mkdir -p "$dir/home/data/$ID"
  printf 'the investigation found nothing actionable\n' > "$dir/home/data/$ID/report.md"

  run_record_only "$dir" >/dev/null || fail "scout-happy: --record-only failed: $(cat "$dir/stderr" 2>/dev/null)"

  assert_absent "$dir/home/state/$ID.meta" "scout-happy: task record was not archived"
  assert_equals "done" "$(backlog_row_state "$dir")" "scout-happy: backlog row was not closed"
  assert_grep "report" "$dir/home/data/backlog.md" "scout-happy: closed backlog item lost its report link"
  assert_present "$dir/home/data/$ID/report.md" "scout-happy: the scout's own report was removed"
  ! grep -Fq "treehouse <" "$dir/runtime.log" \
    || fail "scout-happy: record-only touched the pool: $(cat "$dir/runtime.log")"
  pass "fm-teardown --record-only archives a completed scout task's records without touching its report"
}

test_record_only_resumes_after_an_interrupted_archive() {
  local dir
  dir=$(make_case crash-recovery)
  write_meta "$dir" ship "pr=https://github.com/example/repo/pull/5"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"

  # Simulate a kill right after the archive record was durably written but
  # before the rest of cleanup and the backlog close ran: the task record and
  # its close marker are still exactly as a normal in-flight task would leave
  # them, but the archive evidence already exists.
  mkdir -p "$dir/home/state/archived-records"
  printf 'schema=fm-record-only-archive.v1\ntask_id=%s\nreason=confirmed-pooled-location-reused\n' \
    "$ID" > "$dir/home/state/archived-records/$ID.record"

  run_record_only "$dir" >/dev/null || fail "crash-recovery: resumed run failed: $(cat "$dir/stderr" 2>/dev/null)"
  assert_absent "$dir/home/state/$ID.meta" "crash-recovery: resumed run did not finish archiving"
  assert_equals "done" "$(backlog_row_state "$dir")" "crash-recovery: resumed run did not close the backlog row"
  # The pre-existing archive evidence was kept, not clobbered mid-flight.
  assert_grep 'reason=confirmed-pooled-location-reused' \
    "$dir/home/state/archived-records/$ID.record" "crash-recovery: archive evidence lost"
  pass "fm-teardown --record-only resumes cleanly after a kill between writing the archive record and finishing cleanup"
}

test_record_only_control_lock_contention_refuses_before_mutation() {
  local dir lock holder i=0 rc
  dir=$(make_case control-lock)
  write_meta "$dir" ship "pr=https://github.com/example/repo/pull/6"
  claim_pool_slot "$dir" other-task
  seed_backlog_in_flight "$dir" ship
  write_done_status "$dir"
  set_pr_merged "$dir"

  lock="$dir/home/state/.control-$ID.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held control lock"
  }

  set +e
  run_record_only "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "contended --record-only unexpectedly succeeded"
  assert_present "$dir/home/state/$ID.meta" "contended --record-only removed the task record"
  assert_contains "$(cat "$dir/stderr")" "another lifecycle action is already running" \
    "control-lock: wrong refusal reason"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown --record-only serializes on the same per-task control lock as ordinary teardown"
}

test_record_only_refuses_combined_flags
test_record_only_refuses_for_secondmate_kind
test_record_only_refuses_when_slot_still_mine
test_record_only_refuses_when_slot_claim_absent
test_record_only_refuses_when_not_a_pool_slot
test_record_only_refuses_when_endpoint_not_confidently_gone
test_record_only_refuses_without_valid_spawn_gen
test_record_only_refuses_a_legacy_incarnation_stamp
test_record_only_refuses_when_status_not_done
test_record_only_refuses_ship_without_merged_pr
test_record_only_refuses_ship_with_open_pr
test_record_only_refuses_ship_local_only
test_record_only_refuses_scout_without_report
test_record_only_refuses_scout_without_completion_gate
test_record_only_refuses_when_captain_hold_open
test_record_only_refuses_when_pending_reply_unresolved
test_record_only_archives_a_completed_ship_task_and_is_idempotent
test_record_only_archives_a_completed_scout_task
test_record_only_resumes_after_an_interrupted_archive
test_record_only_control_lock_contention_refuses_before_mutation
