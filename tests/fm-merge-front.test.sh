#!/usr/bin/env bash
# Behavioral coverage for the structural merge-front queue, its PR-registration
# and confirmed-merge integrations, and the front-only Greptile gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

MERGE_FRONT="$ROOT/bin/fm-merge-front.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
MERGE_OUTCOME="$ROOT/bin/fm-merge-outcome-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-front)
BASE_PATH=$PATH
HEAD_SHA=0123456789abcdef0123456789abcdef01234567

make_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/project-alpha" "$dir/fakebin" "$dir/fake-root/bin"
  cat > "$dir/fake-root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fake-root/bin/fm-guard.sh"
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *" state "*) printf '%s\n' "\${FM_TEST_GH_STATE:-MERGED}" ;;
      *) printf '%s\n' '$HEAD_SHA' ;;
    esac
    ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  printf '%s\n' "$dir"
}

run_front() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    PATH="$dir/fakebin:$BASE_PATH" "$MERGE_FRONT" "$@"
}

write_meta() {  # <dir> <task>
  local dir=$1 task=$2
  fm_write_meta "$dir/home/state/$task.meta" \
    "window=fm-$task" \
    "worktree=$dir/worktree-$task" \
    "project=$dir/project-alpha" \
    "kind=ship" \
    "mode=no-mistakes"
}

test_queue_order_and_promotion() {
  local dir status duplicate rc
  dir=$(make_home queue)
  status=$(run_front "$dir" status project-alpha) || fail "empty queue status failed"
  assert_contains "$status" 'front=none' "empty queue did not report no front"

  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "first enqueue failed"
  run_front "$dir" enqueue project-alpha task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "second enqueue failed"
  duplicate=$(run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1) \
    || fail "exact duplicate enqueue was not idempotent"
  assert_contains "$duplicate" 'front=task-a' "duplicate front enqueue lost its role"

  status=$(run_front "$dir" status project-alpha) || fail "populated queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/1' "first PR was not the front"
  assert_contains "$status" $'parked=task-b\thttps://github.com/o/r/pull/2' "second PR was not parked"
  [ "$(grep -c '^task=' "$dir/home/state/merge-front/project-alpha.queue")" -eq 2 ] \
    || fail "duplicate enqueue changed queue cardinality"
  [ "$(fm_pr_file_mode "$dir/home/state/merge-front")" = 700 ] \
    || fail "merge-front directory was not private"
  [ "$(fm_pr_file_mode "$dir/home/state/merge-front/project-alpha.queue")" = 600 ] \
    || fail "merge-front queue was not private"

  set +e
  FM_TEST_GH_STATE=OPEN run_front "$dir" promote project-alpha >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unmerged front was promoted"
  status=$(run_front "$dir" status project-alpha) || fail "refused promotion status failed"
  assert_contains "$status" 'front=task-a' "refused promotion changed the front"
  run_front "$dir" promote project-alpha >/dev/null || fail "confirmed front promotion failed"
  status=$(run_front "$dir" status project-alpha) || fail "promoted queue status failed"
  assert_contains "$status" $'front=task-b\thttps://github.com/o/r/pull/2' "promotion did not expose the next PR"
  assert_no_grep 'task-a' "$dir/home/state/merge-front/project-alpha.queue" \
    "promotion retained the merged front"
  pass "enqueue, status, and promote preserve one ordered front"
}

test_queue_conflicts_and_paths_fail_closed() {
  local dir outside before rc
  dir=$(make_home conflicts)
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "conflict fixture enqueue failed"
  set +e
  run_front "$dir" enqueue project-alpha task-b https://github.com/o/r/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "one PR was rebound to a different task"
  [ "$(grep -c '^task=' "$dir/home/state/merge-front/project-alpha.queue")" -eq 1 ] \
    || fail "conflicting enqueue changed the queue"

  before=$(find "$dir/home/state" -mindepth 1 -maxdepth 2 -print | sort)
  set +e
  run_front "$dir" enqueue ../escape task-z https://github.com/o/r/pull/9 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "traversing project key was accepted"
  [ "$(find "$dir/home/state" -mindepth 1 -maxdepth 2 -print | sort)" = "$before" ] \
    || fail "invalid project key changed state"

  outside="$dir/outside"
  printf 'sentinel\n' > "$outside"
  rm "$dir/home/state/merge-front/project-alpha.queue"
  ln -s "$outside" "$dir/home/state/merge-front/project-alpha.queue"
  set +e
  run_front "$dir" status project-alpha >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "status accepted a queue symlink"
  [ "$(cat "$outside")" = sentinel ] || fail "queue symlink target was changed"
  pass "queue conflicts, traversal, and symlink destinations fail closed"
}

test_same_task_replacement_and_removal_recovery() {
  local dir status rebound removed rc
  dir=$(make_home recovery)
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "recovery fixture front enqueue failed"
  run_front "$dir" enqueue project-alpha task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "recovery fixture parked enqueue failed"

  rebound=$(run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/3) \
    || fail "same task could not register a replacement PR"
  assert_contains "$rebound" $'front=task-a\thttps://github.com/o/r/pull/3' \
    "replacement PR did not keep the task's queue position"
  status=$(run_front "$dir" status project-alpha) || fail "rebound queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/3' \
    "replacement PR did not become the recorded front"
  assert_contains "$status" $'parked=task-b\thttps://github.com/o/r/pull/2' \
    "replacement PR disturbed the parked entry"
  [ "$(grep -c '^task=' "$dir/home/state/merge-front/project-alpha.queue")" -eq 2 ] \
    || fail "replacement PR changed queue cardinality"

  removed=$(run_front "$dir" remove project-alpha task-a https://github.com/o/r/pull/3) \
    || fail "stuck front could not be retired"
  assert_contains "$removed" $'removed=task-a\thttps://github.com/o/r/pull/3' \
    "removal did not report the retired identity"
  assert_contains "$removed" $'front=task-b\thttps://github.com/o/r/pull/2' \
    "retiring the front did not expose the next PR"
  status=$(run_front "$dir" status project-alpha) || fail "post-removal status failed"
  assert_contains "$status" 'front=task-b' "retired front was not durably removed"
  assert_no_grep 'task-a' "$dir/home/state/merge-front/project-alpha.queue" \
    "removal retained the retired entry"

  removed=$(run_front "$dir" remove project-alpha task-a https://github.com/o/r/pull/3) \
    || fail "repeated removal was not idempotent"
  assert_contains "$removed" 'removed=none' "absent identity reported a removal"

  set +e
  run_front "$dir" remove project-alpha task-b >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "removal without a PR identity was accepted"
  pass "same-task replacement rebinds in place and removal retires a stuck front"
}

test_pr_check_enqueues_project_front() {
  local dir status
  dir=$(make_home pr-check)
  write_meta "$dir" task-a
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view") printf '%s\n' '$HEAD_SHA' ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a https://github.com/o/r/pull/7 >/dev/null \
    || fail "fm-pr-check could not register the queue entry"
  status=$(run_front "$dir" status project-alpha) || fail "registered queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/7' \
    "fm-pr-check did not enqueue by task project"
  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a https://github.com/o/r/pull/8 >/dev/null \
    || fail "fm-pr-check could not register a replacement PR for the same task"
  status=$(run_front "$dir" status project-alpha) || fail "replacement queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/8' \
    "replacement registration did not rebind the queued PR"
  [ "$(grep -c '^task=' "$dir/home/state/merge-front/project-alpha.queue")" -eq 1 ] \
    || fail "replacement registration duplicated the task"
  pass "PR registration structurally enrolls the task in its project queue"
}

run_outcome() {  # <dir> <task> <url>
  local dir=$1 task=$2 url=$3
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1"; fm_merge_outcome_report "$2" "$3" "$4" "$5" poll' \
      _ "$MERGE_OUTCOME" "$dir/home" "$dir/home/state" "$task" "$url"
}

test_confirmed_merge_reconciles_exact_identity() {
  local dir status
  dir=$(make_home merge-outcome)
  write_meta "$dir" task-a
  write_meta "$dir" task-b
  write_meta "$dir" task-c
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "first merge-outcome enqueue failed"
  run_front "$dir" enqueue project-alpha task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "second merge-outcome enqueue failed"

  run_outcome "$dir" task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "out-of-order merged PR could not publish its outcome"
  status=$(run_front "$dir" status project-alpha) || fail "out-of-order queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/1' \
    "out-of-order merge displaced the front"
  assert_no_grep 'task-b' "$dir/home/state/merge-front/project-alpha.queue" \
    "out-of-order merge retained its own queued entry"

  run_outcome "$dir" task-c https://github.com/o/r/pull/9 >/dev/null \
    || fail "unqueued merged PR could not publish its outcome"
  status=$(run_front "$dir" status project-alpha) || fail "unqueued outcome status failed"
  assert_contains "$status" 'front=task-a' "unqueued merged PR changed the queue"

  run_outcome "$dir" task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "confirmed front merge did not advance the queue"
  status=$(run_front "$dir" status project-alpha) || fail "advanced queue status failed"
  assert_contains "$status" 'front=none' "confirmed front merge did not empty the queue"
  pass "a confirmed merge always publishes and retires only its own queued entry"
}

install_github_gate_fake() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
{
  printf '['
  printf '<%s>' "$@"
  printf ']\n'
} >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    printf 'OPEN\t%s\t%s\n' "${FM_TEST_BASE:-main}" "${FM_TEST_HEAD:?}"
    ;;
  "api repos"*)
    printf '%s\n' "${FM_TEST_BEHIND:-0}"
    ;;
  "pr checks")
    case " $* " in
      *" --required "*) printf '%s\n' "${FM_TEST_REQUIRED_JSON:-[]}" ;;
      *) printf '%s\n' "${FM_TEST_ALL_JSON:-[]}" ;;
    esac
    ;;
  "pr comment")
    ;;
  *)
    exit 2
    ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
}

run_kick() {  # <dir>
  local dir=$1
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_HEAD="$HEAD_SHA" \
    FM_TEST_BASE="${FM_TEST_BASE:-main}" FM_TEST_BEHIND="${FM_TEST_BEHIND:-0}" \
    FM_TEST_REQUIRED_JSON="${FM_TEST_REQUIRED_JSON:-[]}" \
    FM_TEST_ALL_JSON="${FM_TEST_ALL_JSON:-[]}" \
    PATH="$dir/fakebin:$BASE_PATH" run_front "$dir" greptile-kick project-alpha
}

test_greptile_gate_refusals_and_single_action() {
  local dir rc comment_count
  dir=$(make_home greptile)
  install_github_gate_fake "$dir"
  : > "$dir/gh.log"
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "Greptile front enqueue failed"
  run_front "$dir" enqueue project-alpha task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "Greptile parked enqueue failed"

  set +e
  FM_TEST_BEHIND=1 run_kick "$dir" >/dev/null 2> "$dir/behind.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "behind front received Greptile authority"
  assert_no_grep '<pr><comment>' "$dir/gh.log" "behind front posted a Greptile comment"

  : > "$dir/gh.log"
  set +e
  FM_TEST_REQUIRED_JSON='[{"name":"CI","state":"PENDING"}]' run_kick "$dir" \
    >/dev/null 2> "$dir/required.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "front with a non-green required check received Greptile authority"
  assert_no_grep '<pr><comment>' "$dir/gh.log" "non-green required check posted a Greptile comment"

  : > "$dir/gh.log"
  set +e
  FM_TEST_REQUIRED_JSON='[{"name":"CI","state":"SUCCESS"}]' \
    FM_TEST_ALL_JSON='[{"name":"Greptile Review","state":"IN_PROGRESS"}]' \
    run_kick "$dir" >/dev/null 2> "$dir/pending.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "already-pending Greptile review received another kick"
  assert_no_grep '<pr><comment>' "$dir/gh.log" "pending Greptile review received a comment"

  : > "$dir/gh.log"
  FM_TEST_REQUIRED_JSON='[{"name":"CI","state":"SUCCESS"}]' \
    FM_TEST_ALL_JSON='[{"name":"CI","state":"SUCCESS"},{"name":"Greptile Review","state":"ERROR"}]' \
    run_kick "$dir" >/dev/null || fail "errored Greptile check could not be retriggered"
  comment_count=$(grep -c '^\[<pr><comment>' "$dir/gh.log")
  [ "$comment_count" -eq 1 ] || fail "errored Greptile check did not get exactly one kick"

  : > "$dir/gh.log"
  FM_TEST_REQUIRED_JSON='[{"name":"CI","state":"SUCCESS"},{"name":"Greptile Review","state":"PENDING"}]' \
    FM_TEST_ALL_JSON='[{"name":"CI","state":"SUCCESS"},{"name":"Greptile Review","state":"FAILURE"}]' \
    run_kick "$dir" >/dev/null || fail "fully eligible front was not kicked"
  comment_count=$(grep -c '^\[<pr><comment>' "$dir/gh.log")
  [ "$comment_count" -eq 1 ] || fail "eligible kick did not post exactly one comment"
  assert_grep '[<pr><comment><1><--repo><o/r><--body><@greptile review>]' "$dir/gh.log" \
    "eligible kick did not use the explicit Greptile review comment"
  assert_no_grep '<2>' "$dir/gh.log" "parked PR received GitHub authority"
  assert_no_grep '<update-branch>' "$dir/gh.log" "Greptile gate updated a branch"
  pass "Greptile kick fails closed at every gate and comments once for the front"
}

test_queue_order_and_promotion
test_queue_conflicts_and_paths_fail_closed
test_same_task_replacement_and_removal_recovery
test_pr_check_enqueues_project_front
test_confirmed_merge_reconciles_exact_identity
test_greptile_gate_refusals_and_single_action
