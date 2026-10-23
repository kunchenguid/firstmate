#!/usr/bin/env bash
# tests/fm-backlog-record-resolution.test.sh - behavior tests for how
# bin/fm-backlog-transition-lib.sh's record transitions report and recover from
# an authorized directory that cannot be resolved.
#
# The defect this pins: a remote secondmate launch failed because the task
# record's existing state directory could not be canonicalized, and the error
# said only "cannot be resolved" - the failing component and errno were thrown
# away. The failed-dispatch rollback then ran the same authorization before
# removing a provisional record that was never published, so it reported
# "did not remove both task and busy records" although nothing was left.
#
# Proved here through the library's transition entry point:
#   - a publish whose authorized directory cannot be resolved names the
#     component lstat refused and its errno
#   - a rollback whose provisional record is provably absent completes even
#     when that directory cannot be resolved
#   - a rollback whose record may still exist behind a refused lookup still
#     reports the incomplete cleanup
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$ROOT/bin/fm-backlog-transition-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-record-resolution)
BUSY_OK="$TMP_ROOT/busy-ok"
cat > "$BUSY_OK" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BUSY_OK"

test_publish_names_the_unresolvable_component() {
  local state="$TMP_ROOT/publish/vanished/state" staged="$TMP_ROOT/publish/staged.meta"
  mkdir -p "$TMP_ROOT/publish"
  printf 'endpoint_task_id=t1\n' > "$staged"
  FM_BACKLOG_TRANSITION_ERROR=
  if fm_backlog_atomic_transition publish "$staged" "$state/t1.meta" "task record" "$state"; then
    fail "a publish into an unresolvable authorized directory succeeded"
  fi
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" \
    "task record staged record authorized directory cannot be resolved at $state ($TMP_ROOT/publish/vanished: No such file or directory)" \
    "the publish refusal did not name the missing component and its errno"
  pass "an unresolvable authorized directory names the failing component and errno"
}

test_rollback_of_an_unpublished_record_completes() {
  local state="$TMP_ROOT/rollback/vanished/state"
  mkdir -p "$TMP_ROOT/rollback"
  FM_BACKLOG_TRANSITION_ERROR=
  fm_backlog_atomic_transition rollback "$state/t2.meta" "$BUSY_OK" "$state" t2 "" \
    || fail "rollback of a never-published record reported incomplete cleanup: $FM_BACKLOG_TRANSITION_ERROR"
  pass "rollback treats a provably absent provisional record as removed"
}

test_rollback_still_reports_a_record_it_cannot_see() {
  local locked="$TMP_ROOT/locked" state out rc=0
  state="$locked/state"
  if [ "$(id -u)" -eq 0 ]; then
    pass "skipped: permission refusals do not apply to root"
    return 0
  fi
  mkdir -p "$state"
  printf 'endpoint_task_id=t3\n' > "$state/t3.meta"
  chmod 000 "$locked"
  FM_BACKLOG_TRANSITION_ERROR=
  fm_backlog_atomic_transition rollback "$state/t3.meta" "$BUSY_OK" "$state" t3 "" || rc=$?
  out=$FM_BACKLOG_TRANSITION_ERROR
  chmod 700 "$locked"
  [ "$rc" -ne 0 ] || fail "rollback reported success for a record a refused lookup could still hide"
  assert_contains "$out" "failed-dispatch cleanup did not remove both task and busy records for t3" \
    "rollback did not report the record it could not remove"
  [ -f "$state/t3.meta" ] || fail "the hidden record changed although the rollback refused"
  pass "rollback still refuses when a record may exist behind a refused lookup"
}

test_publish_names_the_unresolvable_component
test_rollback_of_an_unpublished_record_completes
test_rollback_still_reports_a_record_it_cannot_see
