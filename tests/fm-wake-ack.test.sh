#!/usr/bin/env bash
# tests/fm-wake-ack.test.sh - the pending acknowledgement of a pre-drained wake
# (bin/fm-wake-ack.sh, docs/watcher-continuity.md "Pre-drained wakes and the
# turn-end acknowledgement"). Portable: the script's commands and exit codes are
# exercised against a fixture drain that records what it was asked to run, so
# the record, hold, void, session binding, single-flight claim, and failure
# direction are pinned without a harness or the real queue.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-ack)

make_home() {  # <name> -> dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/bin" "$dir/state"
  cp "$ROOT/bin/fm-wake-ack.sh" "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/drain-calls"
[ ! -e "$FM_HOME/state/drain-fail" ] || exit 1
prev=
for a in "$@"; do
  [ "$prev" != --commit-stage ] || rm -f -- "$a"
  prev=$a
done
exit 0
SH
  chmod +x "$dir/bin/fm-wake-ack.sh" "$dir/bin/fm-wake-drain.sh"
  printf '4242\n' > "$dir/state/.lock"
  printf '%s\n' "$dir"
}

ack() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir" "$dir/bin/fm-wake-ack.sh" "$@"
}

stage_receipt() {  # <dir>
  printf 'schema=fm-wake-stage.v1\nack_through=7\nrecovery_generation=gen-a\n' > "$1/state/.wake-ack-pending.receipt"
}

record() {  # <dir> [generation]
  local dir=$1 gen=${2-gen-a}
  stage_receipt "$dir"
  ack "$dir" record --ack-through 7 --recovery-generation "$gen" --receipt "$dir/state/.wake-ack-pending.receipt" \
    --session-pid 4242 --generation 3 --session-id sess-one >/dev/null \
    || fail "record failed in $dir"
}

test_commit_runs_the_recorded_acknowledgement() {
  local dir rc=0 out
  dir=$(make_home commit)
  record "$dir"
  out=$(ack "$dir" commit --session-id sess-one 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "commit must exit 0 after a successful acknowledgement, got $rc: $out"
  grep -Fx -- "--ack-through 7 --recovery-generation gen-a --commit-stage $dir/state/.wake-ack-pending.receipt" "$dir/state/drain-calls" >/dev/null \
    || fail "commit did not run the recorded acknowledgement with its receipt: $(cat "$dir/state/drain-calls")"
  [ ! -e "$dir/state/.wake-ack-pending" ] || fail "the pending record must be removed after commit"
  [ ! -e "$dir/state/.wake-ack-pending.receipt" ] || fail "the receipt must be gone after commit"
  grep -q 'committed' "$dir/state/wake-ack.log" || fail "the log must record the commit"
  rc=0
  ack "$dir" commit --session-id sess-one >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "a second commit with nothing pending must exit 3, got $rc"
  pass "commit runs the recorded acknowledgement once and removes the record"
}

test_commit_without_generation_commits_the_stage_alone() {
  local dir
  dir=$(make_home no-generation)
  record "$dir" ''
  ack "$dir" commit --session-id sess-one >/dev/null 2>&1 || fail "commit without a generation must still succeed"
  grep -Fx -- "--commit-stage $dir/state/.wake-ack-pending.receipt" "$dir/state/drain-calls" >/dev/null \
    || fail "an empty generation must commit the stage alone: $(cat "$dir/state/drain-calls")"
  pass "a record with no episode commits only the staged presentation"
}

test_hold_leaves_the_wake_queued_and_is_consumed() {
  local dir rc=0
  dir=$(make_home hold)
  record "$dir"
  ack "$dir" hold "needs another turn" >/dev/null || fail "hold failed"
  [ -e "$dir/state/.wake-ack-hold" ] || fail "hold must write its marker"
  ack "$dir" commit --session-id sess-one >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 4 ] || fail "a held commit must exit 4, got $rc"
  [ ! -e "$dir/state/drain-calls" ] || fail "a held commit must not run the acknowledgement: $(cat "$dir/state/drain-calls")"
  [ ! -e "$dir/state/.wake-ack-hold" ] || fail "the hold must be consumed by the turn end it held"
  [ ! -e "$dir/state/.wake-ack-pending" ] || fail "the held record must be dropped so a later turn cannot run it"
  [ ! -e "$dir/state/.wake-ack-pending.receipt" ] || fail "the held receipt must be dropped"
  pass "hold drops the acknowledgement unrun and is consumed once"
}

test_void_drops_the_record_unrun() {
  local dir rc=0
  dir=$(make_home void)
  record "$dir"
  ack "$dir" hold >/dev/null
  printf '{"session_id":"sess-one","prompt":"hello"}\n' | ack "$dir" void --claude prompt || fail "void must exit 0"
  [ ! -e "$dir/state/.wake-ack-pending" ] || fail "void must drop the pending record"
  [ ! -e "$dir/state/.wake-ack-pending.receipt" ] || fail "void must drop the receipt"
  [ ! -e "$dir/state/.wake-ack-hold" ] || fail "void must consume a hold"
  [ ! -e "$dir/state/drain-calls" ] || fail "void must never run the acknowledgement"
  ack "$dir" commit --session-id sess-one >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "a commit after void must find nothing pending, got $rc"
  grep -q 'void' "$dir/state/wake-ack.log" || fail "the log must record the void"
  pass "a prompt voids the pending acknowledgement and leaves the wake queued"
}

test_void_keeps_the_record_on_its_own_rewake_delivery() {
  local dir nonce prompt
  dir=$(make_home void-delivery)
  stage_receipt "$dir"
  nonce=$(ack "$dir" record --ack-through 7 --recovery-generation gen-a --receipt "$dir/state/.wake-ack-pending.receipt" \
    --session-pid 4242 --generation 3 --session-id sess-one) || fail "record failed"
  prompt="<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\nStop hook blocking error from command \\\"Stop\\\": firstmate watcher wake\nWake acknowledgement id: $nonce\n\n</system-reminder>"
  printf '{"session_id":"sess-one","prompt":"%s"}\n' "$prompt" | ack "$dir" void --claude prompt || fail "void must exit 0"
  [ -e "$dir/state/.wake-ack-pending" ] || fail "the record's own rewake delivery must not void it"
  [ -e "$dir/state/.wake-ack-pending.receipt" ] || fail "the record's own rewake delivery must keep its receipt"
  ack "$dir" commit --session-id sess-one >/dev/null 2>&1 || fail "the turn end after the delivery must commit the record"
  grep -q -- '--ack-through 7' "$dir/state/drain-calls" || fail "the acknowledgement must run after its own delivery"
  pass "void keeps a record whose nonce its rewake prompt carries"
}

test_record_prints_a_fresh_nonce() {
  local dir first second
  dir=$(make_home nonce)
  stage_receipt "$dir"
  first=$(ack "$dir" record --ack-through 7 --recovery-generation gen-a --receipt "$dir/state/.wake-ack-pending.receipt" \
    --session-pid 4242 --generation 3) || fail "first record failed"
  stage_receipt "$dir"
  second=$(ack "$dir" record --ack-through 8 --recovery-generation gen-a --receipt "$dir/state/.wake-ack-pending.receipt" \
    --session-pid 4242 --generation 4) || fail "second record failed"
  [ -n "$first" ] && [ "$first" != "$second" ] || fail "each record must print a fresh nonce: '$first' '$second'"
  grep -qx "nonce=$second" "$dir/state/.wake-ack-pending" || fail "the record must store its printed nonce"
  pass "record prints and stores a fresh nonce per record"
}

test_void_on_a_foreign_host_payload_is_inert() {
  local dir
  dir=$(make_home void-foreign)
  record "$dir"
  printf '{"cursor_version":"1.0","prompt":"hello"}\n' | ack "$dir" void --claude prompt || fail "void must exit 0"
  [ -e "$dir/state/.wake-ack-pending" ] || fail "a Cursor-delivered prompt payload must not void a Claude record"
  pass "void stands down on a foreign host payload"
}

test_void_with_nothing_pending_is_silent() {
  local dir out
  dir=$(make_home void-empty)
  out=$(printf '{}\n' | ack "$dir" void --claude 2>&1) || fail "void must exit 0 with nothing pending"
  [ -z "$out" ] || fail "void with nothing pending must print nothing: $out"
  [ ! -e "$dir/state/wake-ack.log" ] || fail "void with nothing pending must not log"
  pass "void is a silent no-op without a record"
}

test_session_id_mismatch_drops_the_record() {
  local dir rc=0
  dir=$(make_home session-id)
  record "$dir"
  ack "$dir" commit --session-id sess-two >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 5 ] || fail "a session id mismatch must exit 5, got $rc"
  [ ! -e "$dir/state/drain-calls" ] || fail "a mismatched session must not acknowledge"
  [ ! -e "$dir/state/.wake-ack-pending" ] || fail "a mismatched record must be dropped"
  grep -q 'session id changed' "$dir/state/wake-ack.log" || fail "the log must name the mismatch"
  pass "a record bound to another session id is dropped unrun"
}

test_session_lock_mismatch_drops_the_record() {
  local dir rc=0
  dir=$(make_home session-lock)
  record "$dir"
  printf '5151\n' > "$dir/state/.lock"
  ack "$dir" commit --session-id sess-one >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 5 ] || fail "a session-lock mismatch must exit 5, got $rc"
  [ ! -e "$dir/state/drain-calls" ] || fail "a mismatched lock must not acknowledge"
  pass "a record bound to another session-lock pid is dropped unrun"
}

test_commit_without_session_id_binds_by_lock_pid_only() {
  local dir
  dir=$(make_home no-session-id)
  record "$dir"
  ack "$dir" commit >/dev/null 2>&1 || fail "a commit with no session id must rely on the lock pid and succeed"
  grep -q -- '--ack-through 7' "$dir/state/drain-calls" || fail "the acknowledgement must have run"
  pass "without a session id the lock pid alone binds the record"
}

test_failed_acknowledgement_drops_the_record_and_reports() {
  local dir rc=0
  dir=$(make_home failed)
  record "$dir"
  : > "$dir/state/drain-fail"
  ack "$dir" commit --session-id sess-one >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "a failed acknowledgement must exit 1, got $rc"
  [ ! -e "$dir/state/.wake-ack-pending" ] || fail "a failed acknowledgement must not leave the record for a later turn"
  grep -q 'failed' "$dir/state/wake-ack.log" || fail "the log must record the failure"
  pass "a failed acknowledgement is dropped and reported, leaving the wake to the next drain"
}

test_record_replaces_an_earlier_unreached_record() {
  local dir
  dir=$(make_home replace)
  record "$dir"
  stage_receipt "$dir"
  ack "$dir" record --ack-through 9 --recovery-generation gen-b --receipt "$dir/state/.wake-ack-pending.receipt" \
    --session-pid 4242 --generation 4 >/dev/null || fail "second record failed"
  grep -q '^ack_through=9$' "$dir/state/.wake-ack-pending" || fail "the newer record must replace the older one"
  grep -q 'replaced' "$dir/state/wake-ack.log" || fail "the replacement must be logged"
  pass "a new record replaces one whose turn never reached its end"
}

test_record_refuses_without_a_receipt() {
  local dir rc=0
  dir=$(make_home no-receipt)
  ack "$dir" record --ack-through 7 --recovery-generation gen-a --receipt "$dir/state/missing" \
    --session-pid 4242 --generation 3 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "record without a receipt must exit 2, got $rc"
  [ ! -e "$dir/state/.wake-ack-pending" ] || fail "no record may be written without its receipt"
  pass "record refuses a missing receipt"
}

test_parallel_commits_acknowledge_once() {
  local dir calls
  dir=$(make_home parallel)
  record "$dir"
  for _ in 1 2 3 4 5 6; do
    ack "$dir" commit --session-id sess-one >/dev/null 2>&1 &
  done
  wait
  calls=$(grep -c -- '--ack-through' "$dir/state/drain-calls" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "six parallel commits must acknowledge exactly once, got $calls: $(cat "$dir/state/drain-calls")"
  pass "parallel commits claim the record once"
}

test_commit_runs_the_recorded_acknowledgement
test_commit_without_generation_commits_the_stage_alone
test_hold_leaves_the_wake_queued_and_is_consumed
test_void_keeps_the_record_on_its_own_rewake_delivery
test_record_prints_a_fresh_nonce
test_void_drops_the_record_unrun
test_void_on_a_foreign_host_payload_is_inert
test_void_with_nothing_pending_is_silent
test_session_id_mismatch_drops_the_record
test_session_lock_mismatch_drops_the_record
test_commit_without_session_id_binds_by_lock_pid_only
test_failed_acknowledgement_drops_the_record_and_reports
test_record_replaces_an_earlier_unreached_record
test_record_refuses_without_a_receipt
test_parallel_commits_acknowledge_once
