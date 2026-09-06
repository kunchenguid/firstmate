#!/usr/bin/env bash
# Behavior tests for automatic merge-queue re-queue and its one-attempt bound.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

ENQUEUE="$ROOT/bin/fm-pr-enqueue.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-enqueue)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    case " $* " in
      *enqueuePullRequest*)
        [ "${FM_TEST_GH_ENQUEUE_FAIL:-0}" = 0 ] || exit 1
        printf '%s\n' "${FM_TEST_GH_ENQUEUE_ID:-ME_kwDOQueued}"
        exit 0
        ;;
      *reviewThreads*)
        [ "${FM_TEST_GH_READ_FAIL:-0}" = 0 ] || exit 1
        prev=
        for arg in "$@"; do
          if [ "$prev" = -F ]; then
            case "$arg" in
              owner=true|owner=false|owner=null|name=true|name=false|name=null|owner=[0-9]*|name=[0-9]*)
                exit 1
                ;;
            esac
          fi
          prev=$arg
        done
        if [ -n "${FM_TEST_GH_PR_READ_JSON:-}" ] && [ -f "$FM_TEST_GH_PR_READ_JSON" ]; then
          filter=
          prev=
          for arg in "$@"; do
            [ "$prev" = -q ] && filter=$arg
            prev=$arg
          done
          jq -r "$filter" < "$FM_TEST_GH_PR_READ_JSON"
          exit 0
        fi
        if [ -n "${FM_TEST_GH_PR_READ_FILE:-}" ] && [ -f "$FM_TEST_GH_PR_READ_FILE" ]; then
          line=$(head -n 1 "$FM_TEST_GH_PR_READ_FILE")
          tail -n +2 "$FM_TEST_GH_PR_READ_FILE" > "$FM_TEST_GH_PR_READ_FILE.next"
          mv "$FM_TEST_GH_PR_READ_FILE.next" "$FM_TEST_GH_PR_READ_FILE"
          printf '%s\n' "$line"
          exit 0
        fi
        if [ -n "${FM_TEST_GH_PR_READ+x}" ]; then
          printf '%s\n' "$FM_TEST_GH_PR_READ"
        else
          line=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\tSUCCESS\t0\tfalse'
          printf '%s\n' "$line"
        fi
        exit 0
        ;;
    esac
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

write_dequeued_marker() {
  local dir=$1 provider=${2:-github} host=${3:-github.com} path=${4:-o/r}
  local number=${5:-1} reason=${6:-failed_checks} created=${7:-2026-09-04T10:00:00Z}
  fm_pr_poll_dequeued_mark_notified "$dir/home/state" task-a \
    "$provider" "$host" "$path" "$number" "$reason" "$created" \
    || fail "could not write the ejection marker"
}

write_ready_meta() {
  local dir=$1 url=${2:-https://github.com/o/r/pull/1} reason=${3:-failed_checks}
  local created=${4:-2026-09-04T10:00:00Z}
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=$url"
  fm_pr_url_parse "$url" || fail "ready-meta fixture URL was invalid"
  write_dequeued_marker "$dir" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    "$reason" "$created"
}

run_enqueue() {
  local dir=$1 reason=$2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" \
    "$ENQUEUE" task-a "$reason"
}

test_green_failed_checks_requeues_once() {
  local dir rc
  dir=$(make_case green-requeue)
  write_ready_meta "$dir"
  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "green failed_checks should requeue: $(cat "$dir/stderr")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "requeue did not print the canonical URL: $(cat "$dir/stdout")"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "requeue did not call enqueuePullRequest"
  ! grep -E 'pr merge| --auto' "$dir/gh.log" >/dev/null \
    || fail "requeue used a merge command"
  [ -f "$dir/home/state/task-a.pr-poll-enqueued" ] || fail "requeue did not record the attempt"

  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout2" 2> "$dir/stderr2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "second automatic requeue should escalate"
  [ "$(cat "$dir/stdout2")" = 'escalate: failed_checks already requeued once' ] \
    || fail "second attempt did not name the bound: $(cat "$dir/stdout2")"
  count=$(grep -c enqueuePullRequest "$dir/gh.log")
  [ "$count" -eq 1 ] || fail "the bound still called enqueuePullRequest again"
  pass "green failed_checks requeues once and then escalates"
}

test_merge_conflict_escalates_without_enqueue() {
  local dir rc
  dir=$(make_case conflict)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 merge_conflict
  set +e
  run_enqueue "$dir" merge_conflict > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "merge_conflict should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: merge_conflict is not an automatic re-queue reason' ] \
    || fail "merge_conflict did not keep the forge reason: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "merge_conflict called enqueuePullRequest"
  [ ! -e "$dir/home/state/task-a.pr-poll-enqueued" ] || fail "conflict recorded an enqueue attempt"
  pass "merge_conflict escalates without enqueueing"
}

test_red_checks_escalate() {
  local dir rc
  dir=$(make_case red-checks)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\tFAILURE\t0\tfalse' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "red checks should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks checks are not green' ] \
    || fail "red checks did not say so: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "red checks called enqueuePullRequest"
  pass "red checks escalate instead of requeueing"
}

test_unresolved_threads_escalate() {
  local dir rc
  dir=$(make_case unresolved)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 checks_timed_out
  set +e
  FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\tSUCCESS\t2\tfalse' \
    run_enqueue "$dir" checks_timed_out > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unresolved threads should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: checks_timed_out unresolved review threads' ] \
    || fail "unresolved threads did not say so: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "unresolved threads called enqueuePullRequest"
  pass "unresolved review threads escalate instead of requeueing"
}

test_already_queued_is_idempotent() {
  local dir rc
  dir=$(make_case already-queued)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\ttrue\tMERGEABLE\t\tSUCCESS\t0\tfalse' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "already-queued should succeed"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "already-queued did not print queued: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "already-queued still mutated"
  [ ! -e "$dir/home/state/task-a.pr-poll-enqueued" ] \
    || fail "already-queued counted against the bound"
  pass "a pull request already in the queue is reported queued without a mutation"
}

test_forge_spelled_reason_requeues() {
  local dir rc
  dir=$(make_case forge-spelling)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 CI_FAILURE
  set +e
  run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the forge's own spelling should requeue: $(cat "$dir/stdout")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "CI_FAILURE did not requeue: $(cat "$dir/stdout")"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "CI_FAILURE did not call enqueuePullRequest"

  dir=$(make_case forge-spelling-timeout)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 CI_TIMEOUT
  set +e
  run_enqueue "$dir" ci_timeout > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a folded timeout reason should requeue: $(cat "$dir/stdout")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "ci_timeout did not requeue: $(cat "$dir/stdout")"
  pass "a transient check failure requeues in the forge's spelling and in firstmate's"
}

test_reason_disagreeing_with_the_marker_is_refused() {
  local dir rc
  dir=$(make_case reason-disagrees)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 merge_conflict
  set +e
  run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a reason that contradicts the marker should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: CI_FAILURE does not match the recorded ejection reason merge_conflict' ] \
    || fail "the contradiction did not name both reasons: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" \
    || fail "a contradicted reason called enqueuePullRequest"
  [ ! -e "$dir/home/state/task-a.pr-poll-enqueued" ] \
    || fail "a contradicted reason recorded an attempt"
  pass "a typed reason that contradicts the recorded ejection reason is refused with both values"
}

test_each_ejection_gets_its_own_automatic_attempt() {
  local dir rc count
  dir=$(make_case per-ejection-bound)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 checks_timed_out 2026-09-04T10:00:00Z
  set +e
  run_enqueue "$dir" checks_timed_out > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the first ejection should requeue: $(cat "$dir/stdout")"

  write_dequeued_marker "$dir" github github.com o/r 1 checks_timed_out 2026-09-04T11:00:00Z
  set +e
  run_enqueue "$dir" checks_timed_out > "$dir/stdout2" 2> "$dir/stderr2"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a second ejection should requeue again: $(cat "$dir/stdout2")"
  [ "$(cat "$dir/stdout2")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "the second ejection did not requeue: $(cat "$dir/stdout2")"
  count=$(grep -c enqueuePullRequest "$dir/gh.log")
  [ "$count" -eq 2 ] || fail "the second ejection did not get its own attempt: $count"

  set +e
  run_enqueue "$dir" checks_timed_out > "$dir/stdout3" 2> "$dir/stderr3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a repeat of the second ejection should escalate"
  [ "$(cat "$dir/stdout3")" = 'escalate: checks_timed_out already requeued once' ] \
    || fail "the per-ejection bound did not hold: $(cat "$dir/stdout3")"
  count=$(grep -c enqueuePullRequest "$dir/gh.log")
  [ "$count" -eq 2 ] || fail "the bound still called enqueuePullRequest again"
  pass "each ejection gets one automatic attempt and no more"
}

test_automatic_attempts_stop_at_the_ceiling() {
  local dir rc count eject
  dir=$(make_case attempt-ceiling)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 CI_FAILURE 2026-09-04T10:00:00Z
  set +e
  run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the first ejection should requeue: $(cat "$dir/stdout")"

  for eject in 11 12; do
    write_dequeued_marker "$dir" github github.com o/r 1 CI_FAILURE "2026-09-04T${eject}:00:00Z"
    set +e
    run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "ejection at $eject:00 should requeue: $(cat "$dir/stdout")"
  done
  count=$(grep -c enqueuePullRequest "$dir/gh.log")
  [ "$count" -eq 3 ] || fail "three ejections did not produce three requeues: $count"

  write_dequeued_marker "$dir" github github.com o/r 1 CI_FAILURE 2026-09-04T13:00:00Z
  set +e
  run_enqueue "$dir" CI_FAILURE > "$dir/stdout4" 2> "$dir/stderr4"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "the fourth ejection should escalate"
  [ "$(cat "$dir/stdout4")" = 'escalate: CI_FAILURE reached the automatic re-queue ceiling of 3 after 3 attempts on this pull request' ] \
    || fail "the ceiling did not name itself and the attempts: $(cat "$dir/stdout4")"
  count=$(grep -c enqueuePullRequest "$dir/gh.log")
  [ "$count" -eq 3 ] || fail "the ceiling still called enqueuePullRequest again"
  pass "a delivery ejected past the ceiling stops being requeued automatically"
}

test_ceiling_does_not_mask_the_forge_reason() {
  local dir rc eject
  dir=$(make_case ceiling-vs-reason)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 CI_FAILURE 2026-09-04T10:00:00Z
  set +e
  run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the first ejection should requeue: $(cat "$dir/stdout")"
  for eject in 11 12; do
    write_dequeued_marker "$dir" github github.com o/r 1 CI_FAILURE "2026-09-04T${eject}:00:00Z"
    set +e
    run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "ejection at $eject:00 should requeue: $(cat "$dir/stdout")"
  done

  write_dequeued_marker "$dir" github github.com o/r 1 merge_conflict 2026-09-04T13:00:00Z
  set +e
  run_enqueue "$dir" merge_conflict > "$dir/stdout4" 2> "$dir/stderr4"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a conflict past the ceiling should escalate"
  [ "$(cat "$dir/stdout4")" = 'escalate: merge_conflict is not an automatic re-queue reason' ] \
    || fail "the ceiling masked the forge reason: $(cat "$dir/stdout4")"
  [ "$(grep -c enqueuePullRequest "$dir/gh.log")" -eq 3 ] \
    || fail "the conflict ejection requeued anyway"
  pass "an ejection past the ceiling is reported by its forge reason, not as a spent budget"
}

test_unreadable_marker_is_replaced_and_counted() {
  local dir rc
  dir=$(make_case unreadable-marker)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 CI_FAILURE 2026-09-04T10:00:00Z
  # A well-formed marker body left world-readable, as an archive extraction or a
  # restore that does not preserve modes produces.
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    fm-pr-poll-enqueued-v1 github github.com o/r 1 2026-09-03T10:00:00Z 1 CI_FAILURE \
    > "$dir/home/state/task-a.pr-poll-enqueued"
  chmod 0644 "$dir/home/state/task-a.pr-poll-enqueued"
  set +e
  run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "an unreadable marker must not block the requeue: $(cat "$dir/stdout")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "an unreadable marker was reported as unrecorded: $(cat "$dir/stdout")"
  [ "$(fm_pr_file_mode "$dir/home/state/task-a.pr-poll-enqueued")" = 600 ] \
    || fail "the marker was not replaced with a private one"

  set +e
  run_enqueue "$dir" CI_FAILURE > "$dir/stdout2" 2> "$dir/stderr2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "the healed marker did not bound the same ejection"
  [ "$(cat "$dir/stdout2")" = 'escalate: CI_FAILURE already requeued once' ] \
    || fail "the healed marker did not carry the attempt: $(cat "$dir/stdout2")"
  [ "$(grep -c enqueuePullRequest "$dir/gh.log")" -eq 1 ] \
    || fail "the healed marker still allowed a second attempt"
  pass "a present but unreadable marker is replaced and its attempt counted"
}

test_attempt_ceiling_is_overridable() {
  local dir rc count
  dir=$(make_case attempt-ceiling-override)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 CI_FAILURE 2026-09-04T10:00:00Z
  set +e
  FM_PR_ENQUEUE_ATTEMPT_CEILING=1 run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the first ejection should requeue: $(cat "$dir/stdout")"

  write_dequeued_marker "$dir" github github.com o/r 1 CI_FAILURE 2026-09-04T11:00:00Z
  set +e
  FM_PR_ENQUEUE_ATTEMPT_CEILING=1 run_enqueue "$dir" CI_FAILURE > "$dir/stdout2" 2> "$dir/stderr2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a ceiling of one should escalate on the second ejection"
  [ "$(cat "$dir/stdout2")" = 'escalate: CI_FAILURE reached the automatic re-queue ceiling of 1 after 1 attempts on this pull request' ] \
    || fail "the configured ceiling was not honoured: $(cat "$dir/stdout2")"
  count=$(grep -c enqueuePullRequest "$dir/gh.log")
  [ "$count" -eq 1 ] || fail "a ceiling of one still requeued twice"
  pass "the automatic attempt ceiling is environment-overridable"
}

test_a_new_delivery_starts_its_own_attempts() {
  local dir rc count
  dir=$(make_case ceiling-new-delivery)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 CI_FAILURE 2026-09-04T10:00:00Z
  set +e
  FM_PR_ENQUEUE_ATTEMPT_CEILING=1 run_enqueue "$dir" CI_FAILURE > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the first delivery should requeue: $(cat "$dir/stdout")"

  write_ready_meta "$dir" https://github.com/o/r/pull/2 CI_FAILURE 2026-09-04T11:00:00Z
  set +e
  FM_PR_ENQUEUE_ATTEMPT_CEILING=1 run_enqueue "$dir" CI_FAILURE > "$dir/stdout2" 2> "$dir/stderr2"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a different pull request should get its own attempts: $(cat "$dir/stdout2")"
  [ "$(cat "$dir/stdout2")" = 'queued: https://github.com/o/r/pull/2' ] \
    || fail "a new delivery inherited the previous ceiling: $(cat "$dir/stdout2")"
  count=$(grep -c enqueuePullRequest "$dir/gh.log")
  [ "$count" -eq 2 ] || fail "the new delivery did not requeue: $count"
  pass "the attempt ceiling is spent per pull request, not carried to the next one"
}

test_closed_pull_request_is_named_before_any_unknown_wait() {
  local dir rc reads
  dir=$(make_case closed-with-unknown)
  write_ready_meta "$dir"
  set +e
  FM_PR_ENQUEUE_UNKNOWN_SLEEP_SECS=0 \
    FM_TEST_GH_PR_READ=$'PR_kwDOabc\tCLOSED\tfalse\tfalse\tUNKNOWN\t\tSUCCESS\t0\tfalse' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a closed pull request should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks pull request is not open' ] \
    || fail "a closed pull request was reported as unmergeable: $(cat "$dir/stdout")"
  reads=$(grep -c reviewThreads "$dir/gh.log")
  [ "$reads" -eq 1 ] || fail "a closed pull request was waited on for mergeability: $reads"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "a closed pull request called enqueuePullRequest"
  pass "a settled pull request is named on the first read instead of waiting on UNKNOWN"
}

test_queued_pull_request_is_reported_before_any_unknown_wait() {
  local dir rc reads
  dir=$(make_case queued-with-unknown)
  write_ready_meta "$dir"
  set +e
  FM_PR_ENQUEUE_UNKNOWN_SLEEP_SECS=0 \
    FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\ttrue\tUNKNOWN\t\tSUCCESS\t0\tfalse' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a pull request back in the queue should succeed: $(cat "$dir/stdout")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "a queued pull request with UNKNOWN mergeability escalated: $(cat "$dir/stdout")"
  reads=$(grep -c reviewThreads "$dir/gh.log")
  [ "$reads" -eq 1 ] || fail "a queued pull request was waited on for mergeability: $reads"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "a queued pull request still mutated"
  pass "a pull request already back in the queue is reported queued whatever mergeability says"
}

test_unknown_reason_is_refused_by_name() {
  local dir rc
  dir=$(make_case unknown-reason)
  write_ready_meta "$dir" https://github.com/o/r/pull/1 flurbed_by_kraken
  set +e
  run_enqueue "$dir" flurbed_by_kraken > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an unknown reason should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: flurbed_by_kraken is not a known merge-queue ejection reason' ] \
    || fail "an unknown reason was not refused by name: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "an unknown reason called enqueuePullRequest"
  pass "a reason outside every known vocabulary is refused explicitly"
}

test_unlabelled_ejection_escalates() {
  local dir rc reason
  for reason in unreported unreadable; do
    dir=$(make_case "unlabelled-$reason")
    write_ready_meta "$dir" https://github.com/o/r/pull/1 "$reason"
    set +e
    run_enqueue "$dir" "$reason" > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "an unlabelled ejection should escalate"
    [ "$(cat "$dir/stdout")" = "escalate: $reason the forge reported no usable ejection reason" ] \
      || fail "an unlabelled ejection did not say so: $(cat "$dir/stdout")"
    ! grep -q enqueuePullRequest "$dir/gh.log" \
      || fail "an unlabelled ejection called enqueuePullRequest"
  done
  pass "an ejection the forge did not label usably escalates instead of requeueing"
}

test_unrecorded_requeue_is_reported_as_queued() {
  local dir rc
  dir=$(make_case unrecorded-requeue)
  write_ready_meta "$dir"
  mkdir "$dir/home/state/task-a.pr-poll-enqueued"
  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an unrecorded requeue should still escalate"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "the requeue mutation did not run"
  grep -Fqx 'queued: https://github.com/o/r/pull/1' "$dir/stdout" \
    || fail "an unrecorded requeue hid the landed requeue: $(cat "$dir/stdout")"
  grep -Fqx 'escalate: failed_checks pull request was requeued but the attempt could not be recorded' \
    "$dir/stdout" || fail "an unrecorded requeue did not name the lost bound: $(cat "$dir/stdout")"
  pass "a requeue whose attempt could not be recorded is still reported as queued"
}

test_unreadable_state_escalates() {
  local dir rc
  dir=$(make_case unreadable)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_READ_FAIL=1 run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unreadable forge state should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks forge state could not be read' ] \
    || fail "unreadable state did not stay closed: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "unreadable state called enqueuePullRequest"
  pass "an unreadable forge read escalates instead of enqueueing"
}

test_unknown_then_mergeable_requeues() {
  local dir rc reads
  dir=$(make_case unknown-then-mergeable)
  write_ready_meta "$dir"
  printf '%s\n%s\n' \
    $'PR_kwDOabc\tOPEN\tfalse\tfalse\tUNKNOWN\t\tSUCCESS\t0\tfalse' \
    $'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\tSUCCESS\t0\tfalse' \
    > "$dir/pr-reads"
  set +e
  FM_PR_ENQUEUE_UNKNOWN_SLEEP_SECS=0 FM_TEST_GH_PR_READ_FILE="$dir/pr-reads" \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "UNKNOWN then MERGEABLE should requeue: $(cat "$dir/stdout") $(cat "$dir/stderr")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/o/r/pull/1' ] \
    || fail "UNKNOWN then MERGEABLE did not requeue: $(cat "$dir/stdout")"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "UNKNOWN then MERGEABLE did not call enqueuePullRequest"
  reads=$(grep -c reviewThreads "$dir/gh.log")
  [ "$reads" -eq 2 ] || fail "UNKNOWN then MERGEABLE did not re-read: $reads"
  pass "transient UNKNOWN mergeability is re-read until MERGEABLE"
}

test_persistent_unknown_mergeability_is_refused() {
  local dir rc
  dir=$(make_case persistent-unknown)
  write_ready_meta "$dir"
  set +e
  FM_PR_ENQUEUE_UNKNOWN_SLEEP_SECS=0 FM_PR_ENQUEUE_UNKNOWN_BUDGET_SECS=60 \
    FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tUNKNOWN\t\tSUCCESS\t0\tfalse' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "persistent UNKNOWN should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks mergeable is UNKNOWN after 8 reads, short of the 60s budget' ] \
    || fail "persistent UNKNOWN did not name the read ceiling: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "persistent UNKNOWN called enqueuePullRequest"
  pass "UNKNOWN mergeability that never recomputes is refused, naming what ended the wait"
}

test_ejection_marker_mismatch_is_refused() {
  local dir rc
  dir=$(make_case marker-mismatch)
  write_ready_meta "$dir"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/o/r/pull/2"
  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a marker/metadata mismatch should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks ejection identity does not match task metadata' ] \
    || fail "mismatch did not refuse: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "mismatch called enqueuePullRequest"
  pass "enqueue refuses when the ejection marker and task metadata name different pull requests"
}

test_absent_rollup_is_named_not_called_red() {
  local dir rc
  dir=$(make_case absent-rollup)
  write_ready_meta "$dir"
  set +e
  FM_TEST_GH_PR_READ=$'PR_kwDOabc\tOPEN\tfalse\tfalse\tMERGEABLE\t\t\t0\tfalse' \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an absent rollup should escalate"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks no checks on the head commit' ] \
    || fail "an absent rollup was labelled as red checks: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" || fail "an absent rollup called enqueuePullRequest"
  pass "an absent check rollup is refused as missing checks, not as red checks"
}

test_graphql_string_fields_are_sent_raw() {
  local dir rc
  dir=$(make_case graphql-string-vars)
  write_ready_meta "$dir" https://github.com/true/true/pull/1
  set +e
  run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a JSON-looking repo name should still requeue: $(cat "$dir/stdout") $(cat "$dir/stderr")"
  [ "$(cat "$dir/stdout")" = 'queued: https://github.com/true/true/pull/1' ] \
    || fail "JSON-looking repo name did not requeue: $(cat "$dir/stdout")"
  grep -q enqueuePullRequest "$dir/gh.log" || fail "JSON-looking repo name did not call enqueuePullRequest"
  pass "GraphQL owner and name are sent as strings even when they look like JSON literals"
}

write_thread_payload() {
  local path=$1 more=$2 count=$3
  jq -n --argjson more "$more" --argjson count "$count" \
    '{data:{repository:{pullRequest:{
      id:"PR_kwDOabc", state:"OPEN", isDraft:false, isInMergeQueue:false,
      mergeable:"MERGEABLE", reviewDecision:null,
      commits:{nodes:[{commit:{statusCheckRollup:{state:"SUCCESS"}}}]},
      reviewThreads:{
        pageInfo:{hasNextPage:$more},
        nodes:[range($count) | {isResolved:true, isOutdated:false}]}}}}}' \
    > "$path" || fail "could not write the review-thread payload"
}

test_review_threads_beyond_one_page_escalate() {
  local dir rc
  dir=$(make_case threads-beyond-page)
  write_ready_meta "$dir"
  write_thread_payload "$dir/pr.json" true 100
  set +e
  FM_TEST_GH_PR_READ_JSON="$dir/pr.json" \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "review threads past the read page should escalate: $(cat "$dir/stdout")"
  [ "$(cat "$dir/stdout")" = 'escalate: failed_checks review threads do not fit one page and could not be counted' ] \
    || fail "an uncounted thread remainder was not named: $(cat "$dir/stdout")"
  ! grep -q enqueuePullRequest "$dir/gh.log" \
    || fail "an uncounted thread remainder called enqueuePullRequest"

  dir=$(make_case threads-fill-one-page)
  write_ready_meta "$dir"
  write_thread_payload "$dir/pr.json" false 100
  set +e
  FM_TEST_GH_PR_READ_JSON="$dir/pr.json" \
    run_enqueue "$dir" failed_checks > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "a full page of resolved threads should requeue: $(cat "$dir/stdout") $(cat "$dir/stderr")"
  grep -q enqueuePullRequest "$dir/gh.log" \
    || fail "a full page of resolved threads did not requeue"
  pass "review threads past the read page escalate instead of counting as zero unresolved"
}

test_green_failed_checks_requeues_once
test_merge_conflict_escalates_without_enqueue
test_red_checks_escalate
test_unresolved_threads_escalate
test_review_threads_beyond_one_page_escalate
test_already_queued_is_idempotent
test_unreadable_state_escalates
test_forge_spelled_reason_requeues
test_unknown_reason_is_refused_by_name
test_unlabelled_ejection_escalates
test_unrecorded_requeue_is_reported_as_queued
test_unknown_then_mergeable_requeues
test_persistent_unknown_mergeability_is_refused
test_ejection_marker_mismatch_is_refused
test_absent_rollup_is_named_not_called_red
test_graphql_string_fields_are_sent_raw
test_reason_disagreeing_with_the_marker_is_refused
test_each_ejection_gets_its_own_automatic_attempt
test_closed_pull_request_is_named_before_any_unknown_wait
test_queued_pull_request_is_reported_before_any_unknown_wait
test_automatic_attempts_stop_at_the_ceiling
test_ceiling_does_not_mask_the_forge_reason
test_unreadable_marker_is_replaced_and_counted
test_attempt_ceiling_is_overridable
test_a_new_delivery_starts_its_own_attempts
