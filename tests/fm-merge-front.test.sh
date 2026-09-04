#!/usr/bin/env bash
# Behavioral coverage for the structural merge-front queue, its PR-registration
# and confirmed-merge integrations, and the front-only Greptile gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-front-lib.sh
. "$ROOT/bin/fm-merge-front-lib.sh"

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
if [ -n "\${FM_TEST_GH_HOOK:-}" ]; then
  "\$FM_TEST_GH_HOOK" >/dev/null 2>&1
fi
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

write_meta() {  # <dir> <task> [project-path]
  local dir=$1 task=$2 project=${3:-$1/project-alpha}
  fm_write_meta "$dir/home/state/$task.meta" \
    "window=fm-$task" \
    "worktree=$dir/worktree-$task" \
    "project=$project" \
    "kind=ship" \
    "mode=no-mistakes"
}

# The durable queue key a registration derives from a project checkout path.
# Callers that reach the queue through the CLI need the same mapping the
# registration path used.
project_key() {  # <project-path>
  fm_merge_front_project_key_from_path "$1"
}

run_pr_check() {  # <dir> <task> <url>
  local dir=$1 task=$2 url=$3
  FM_ROOT_OVERRIDE="$dir/fake-root" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" "$task" "$url"
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

# Removal is keyed on the exact task and canonical URL pair. A stale or
# mismatched identity must retire nothing rather than dropping the row that
# happens to share one half of it.
test_removal_requires_the_exact_task_and_url_pair() {
  local dir removed status
  dir=$(make_home exact-identity)
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/3 >/dev/null \
    || fail "exact-identity front enqueue failed"
  run_front "$dir" enqueue project-alpha task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "exact-identity parked enqueue failed"

  removed=$(run_front "$dir" remove project-alpha task-a https://github.com/o/r/pull/2) \
    || fail "mismatched removal was not reported"
  assert_contains "$removed" 'removed=none' "a mismatched identity reported a removal"
  status=$(run_front "$dir" status project-alpha) || fail "mismatched removal status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/3' \
    "a mismatched removal disturbed the front"
  assert_contains "$status" $'parked=task-b\thttps://github.com/o/r/pull/2' \
    "a mismatched removal silently retired another task's live entry"

  removed=$(run_front "$dir" remove project-alpha task-a https://github.com/o/r/pull/3) \
    || fail "exact removal failed"
  assert_contains "$removed" $'removed=task-a\thttps://github.com/o/r/pull/3' \
    "exact removal did not report its own identity"
  status=$(run_front "$dir" status project-alpha) || fail "exact removal status failed"
  assert_contains "$status" $'front=task-b\thttps://github.com/o/r/pull/2' \
    "exact removal did not leave the other entry queued"
  pass "removal retires only the exact task and URL pair it was given"
}

# promote runs the same live merge poll the watcher does; holding the queue lock
# across it would starve enqueue and confirmed-merge retirement behind a slow
# forge exactly as the Greptile gate would.
test_promote_leaves_the_queue_usable_during_its_merge_poll() {
  local dir status
  dir=$(make_home promote-lock)
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "promote-lock fixture enqueue failed"
  cat > "$dir/hook.sh" <<SH
#!/usr/bin/env bash
FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
  FM_MERGE_FRONT_LOCK_TIMEOUT=2 "$MERGE_FRONT" \
  enqueue project-alpha task-b https://github.com/o/r/pull/2 >/dev/null 2>&1 \
  && printf 'concurrent-enqueue=ok\n' > "$dir/hook.out" \
  || printf 'concurrent-enqueue=blocked\n' > "$dir/hook.out"
SH
  chmod +x "$dir/hook.sh"
  FM_TEST_GH_HOOK="$dir/hook.sh" run_front "$dir" promote project-alpha >/dev/null \
    || fail "confirmed front promotion failed"
  assert_grep 'concurrent-enqueue=ok' "$dir/hook.out" \
    "the queue lock was held across promote's live merge poll"
  status=$(run_front "$dir" status project-alpha) || fail "post-promote status failed"
  assert_contains "$status" $'front=task-b\thttps://github.com/o/r/pull/2' \
    "promotion did not expose the PR enqueued during its poll"
  pass "promote never holds the queue lock across its live merge poll"
}

# `none` is the empty-queue label promote prints, and it is also a valid task ID.
# The promoted output must name the real next front rather than claim the queue
# drained because the next task happens to be called none.
test_promote_reports_a_next_front_named_none() {
  local dir promoted status
  dir=$(make_home promote-none)
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "promote-none fixture front enqueue failed"
  run_front "$dir" enqueue project-alpha none https://github.com/o/r/pull/2 >/dev/null \
    || fail "promote-none fixture parked enqueue failed"

  promoted=$(run_front "$dir" promote project-alpha) || fail "promotion failed"
  assert_contains "$promoted" $'front=none\thttps://github.com/o/r/pull/2' \
    "promotion reported a drained queue while a task named none held the front"
  status=$(run_front "$dir" status project-alpha) || fail "promote-none status failed"
  assert_contains "$status" $'front=none\thttps://github.com/o/r/pull/2' \
    "promotion did not leave the task named none as the front"
  pass "promotion names a next front whose task ID is exactly none"
}

# The common retirement path - a task whose metadata still resolves its project
# and whose row is already gone - is answered from that one project queue. An
# unrelated project's unreadable queue must not turn it into a reported failure.
test_retirement_of_an_absent_row_ignores_unrelated_queues() {
  local dir key err
  dir=$(make_home retire-absent)
  write_meta "$dir" task-a
  write_meta "$dir" task-b
  key=$(project_key "$dir/project-alpha") || fail "project key could not be derived"
  run_front "$dir" enqueue "$key" task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "retire-absent own-project enqueue failed"
  run_front "$dir" enqueue zzz task-x https://github.com/o/r/pull/5 >/dev/null \
    || fail "retire-absent sibling enqueue failed"
  printf 'not-a-merge-front-queue\n' > "$dir/home/state/merge-front/zzz.queue"
  chmod 0600 "$dir/home/state/merge-front/zzz.queue"

  err=$(run_outcome "$dir" task-a https://github.com/o/r/pull/1 2>&1 >/dev/null) \
    || fail "a merge outcome for an unqueued task could not be published"
  case "$err" in
    *"could not retire"*)
      fail "retiring an already-absent row reported a failure from an unrelated queue" ;;
  esac
  pass "retirement of an absent row never consults unrelated project queues"
}

test_pr_check_enqueues_project_front() {
  local dir status key
  dir=$(make_home pr-check)
  write_meta "$dir" task-a
  key=$(project_key "$dir/project-alpha") || fail "project key could not be derived"
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view") printf '%s\n' '$HEAD_SHA' ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  run_pr_check "$dir" task-a https://github.com/o/r/pull/7 >/dev/null \
    || fail "fm-pr-check could not register the queue entry"
  status=$(run_front "$dir" status "$key") || fail "registered queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/7' \
    "fm-pr-check did not enqueue by task project"
  run_pr_check "$dir" task-a https://github.com/o/r/pull/8 >/dev/null \
    || fail "fm-pr-check could not register a replacement PR for the same task"
  status=$(run_front "$dir" status "$key") || fail "replacement queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/8' \
    "replacement registration did not rebind the queued PR"
  [ "$(grep -c '^task=' "$dir/home/state/merge-front/$key.queue")" -eq 1 ] \
    || fail "replacement registration duplicated the task"
  pass "PR registration structurally enrolls the task in its project queue"
}

# An ordinary checkout basename is a naming convention, not a registration
# precondition: a project directory that is not slug-shaped must still register.
test_pr_check_registers_any_checkout_basename() {
  local dir status key
  dir=$(make_home odd-basename)
  mkdir -p "$dir/my repo (v2)"
  write_meta "$dir" task-a "$dir/my repo (v2)"
  key=$(project_key "$dir/my repo (v2)") || fail "odd basename yielded no queue key"
  run_pr_check "$dir" task-a https://github.com/o/r/pull/7 >/dev/null \
    || fail "a non-slug checkout basename blocked PR registration"
  status=$(run_front "$dir" status "$key") || fail "odd-basename queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/7' \
    "the odd-basename project did not get its own front"
  pass "PR registration accepts any checkout basename and isolates its queue"
}

# The one enqueue refusal no retry can clear must land before any mutation:
# neither the task meta nor the poll may be touched when the URL is taken.
test_pr_check_refuses_bound_url_before_mutating() {
  local dir key rc
  dir=$(make_home bound-url)
  write_meta "$dir" task-a
  write_meta "$dir" task-b
  key=$(project_key "$dir/project-alpha") || fail "project key could not be derived"
  run_pr_check "$dir" task-a https://github.com/o/r/pull/7 >/dev/null \
    || fail "bound-url fixture registration failed"

  set +e
  run_pr_check "$dir" task-b https://github.com/o/r/pull/7 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a PR bound to another task was re-registered"
  assert_no_grep '^pr=' "$dir/home/state/task-b.meta" \
    "refused registration still rewrote the task metadata"
  [ ! -e "$dir/home/state/task-b.check.sh" ] \
    || fail "refused registration still armed a merge poll"
  [ ! -e "$dir/home/state/task-b.pr-poll" ] \
    || fail "refused registration still published a poll"
  [ "$(grep -c '^task=' "$dir/home/state/merge-front/$key.queue")" -eq 1 ] \
    || fail "refused registration changed the queue"
  pass "registration refuses an already-bound PR URL over untouched state"
}

run_outcome() {  # <dir> <task> <url>
  local dir=$1 task=$2 url=$3
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1"; fm_merge_outcome_report "$2" "$3" "$4" "$5" poll' \
      _ "$MERGE_OUTCOME" "$dir/home" "$dir/home/state" "$task" "$url"
}

test_confirmed_merge_reconciles_exact_identity() {
  local dir status key
  dir=$(make_home merge-outcome)
  write_meta "$dir" task-a
  write_meta "$dir" task-b
  write_meta "$dir" task-c
  key=$(project_key "$dir/project-alpha") || fail "project key could not be derived"
  run_front "$dir" enqueue "$key" task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "first merge-outcome enqueue failed"
  run_front "$dir" enqueue "$key" task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "second merge-outcome enqueue failed"

  run_outcome "$dir" task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "out-of-order merged PR could not publish its outcome"
  status=$(run_front "$dir" status "$key") || fail "out-of-order queue status failed"
  assert_contains "$status" $'front=task-a\thttps://github.com/o/r/pull/1' \
    "out-of-order merge displaced the front"
  assert_no_grep 'task-b' "$dir/home/state/merge-front/$key.queue" \
    "out-of-order merge retained its own queued entry"

  run_outcome "$dir" task-c https://github.com/o/r/pull/9 >/dev/null \
    || fail "unqueued merged PR could not publish its outcome"
  status=$(run_front "$dir" status "$key") || fail "unqueued outcome status failed"
  assert_contains "$status" 'front=task-a' "unqueued merged PR changed the queue"

  run_outcome "$dir" task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "confirmed front merge did not advance the queue"
  status=$(run_front "$dir" status "$key") || fail "advanced queue status failed"
  assert_contains "$status" 'front=none' "confirmed front merge did not empty the queue"
  pass "a confirmed merge always publishes and retires only its own queued entry"
}

# A front whose task record is already gone (teardown, or a merge observed after
# the record was removed) must still be retired, or it parks every PR behind it.
test_confirmed_merge_retires_front_without_task_metadata() {
  local dir status key
  dir=$(make_home merge-outcome-no-meta)
  write_meta "$dir" task-a
  write_meta "$dir" task-b
  key=$(project_key "$dir/project-alpha") || fail "project key could not be derived"
  run_front "$dir" enqueue "$key" task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "no-meta fixture front enqueue failed"
  run_front "$dir" enqueue "$key" task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "no-meta fixture parked enqueue failed"
  rm -f "$dir/home/state/task-a.meta"

  run_outcome "$dir" task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "merged front without task metadata could not publish its outcome"
  status=$(run_front "$dir" status "$key") || fail "no-meta queue status failed"
  assert_contains "$status" $'front=task-b\thttps://github.com/o/r/pull/2' \
    "a front with no task metadata stayed queued in front of the next PR"
  assert_no_grep 'task-a' "$dir/home/state/merge-front/$key.queue" \
    "the metadata-less front was not retired"
  pass "a merged front is retired even when its task record is already gone"
}

# One unreadable project queue must not abandon the scan: the target entry lives
# in another project and can still be safely retired.
test_retirement_scan_survives_an_unreadable_project_queue() {
  local dir status
  dir=$(make_home scan-resilience)
  write_meta "$dir" task-a
  run_front "$dir" enqueue aaa task-x https://github.com/o/r/pull/5 >/dev/null \
    || fail "scan fixture first-project enqueue failed"
  run_front "$dir" enqueue zzz task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "scan fixture target enqueue failed"
  printf 'not-a-merge-front-queue\n' > "$dir/home/state/merge-front/aaa.queue"
  chmod 0600 "$dir/home/state/merge-front/aaa.queue"
  rm -f "$dir/home/state/task-a.meta"

  run_outcome "$dir" task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "merged PR could not publish its outcome past an unreadable queue"
  status=$(run_front "$dir" status zzz) || fail "scan-resilience status failed"
  assert_contains "$status" 'front=none' \
    "an unreadable sibling queue aborted the scan before the target was retired"
  pass "retirement scans every project queue past an unreadable one"
}

# A replacement registration that commits the task metadata but fails its
# enqueue leaves the queue holding a stale URL for that very task. Retirement
# must still clear the row, or it stays the project's front forever with nothing
# reported to name it.
test_retirement_clears_a_row_whose_recorded_url_diverged() {
  local dir status key
  dir=$(make_home diverged-url)
  write_meta "$dir" task-a
  write_meta "$dir" task-b
  key=$(project_key "$dir/project-alpha") || fail "project key could not be derived"
  run_front "$dir" enqueue "$key" task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "diverged-url fixture front enqueue failed"
  run_front "$dir" enqueue "$key" task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "diverged-url fixture parked enqueue failed"

  run_outcome "$dir" task-a https://github.com/o/r/pull/9 >/dev/null \
    || fail "a diverged merge outcome could not be published"
  status=$(run_front "$dir" status "$key") || fail "diverged-url status failed"
  assert_contains "$status" $'front=task-b\thttps://github.com/o/r/pull/2' \
    "the stale row for the retiring task stayed the project's front"
  assert_no_grep 'task-a' "$dir/home/state/merge-front/$key.queue" \
    "the diverged row was not retired"
  pass "retirement clears a task's row whose recorded URL diverged"
}

run_drop_anywhere() {  # <dir> <task> <url>
  local dir=$1 task=$2 url=$3
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1"; fm_merge_front_drop_anywhere "$2" "$3" "$4" \
      && printf "dropped=%s\t%s\n" "$FM_MERGE_FRONT_DROPPED_TASK" "$FM_MERGE_FRONT_DROPPED_URL"' \
      _ "$ROOT/bin/fm-merge-front-lib.sh" "$dir/home/state" "$task" "$url"
}

# The scan reports the identity it retired; a later unrelated queue must not
# clear it, and must not be locked and parsed once the row is already gone.
test_retirement_scan_reports_the_identity_it_retired() {
  local dir dropped
  dir=$(make_home scan-identity)
  run_front "$dir" enqueue aaa task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "scan-identity target enqueue failed"
  run_front "$dir" enqueue zzz task-z https://github.com/o/r/pull/9 >/dev/null \
    || fail "scan-identity sibling enqueue failed"

  dropped=$(run_drop_anywhere "$dir" task-a https://github.com/o/r/pull/1) \
    || fail "the retirement scan did not retire the queued row"
  assert_contains "$dropped" $'dropped=task-a\thttps://github.com/o/r/pull/1' \
    "the retirement scan lost the identity it retired"
  pass "the retirement scan reports the exact identity it retired"
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
    if [ -n "${FM_TEST_GH_HOOK:-}" ]; then
      "$FM_TEST_GH_HOOK" >> "$FM_TEST_GH_LOG" 2>&1
    fi
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
    FM_TEST_GH_HOOK="${FM_TEST_GH_HOOK:-}" \
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

# GitHub's own merge gate accepts a required check that was skipped or neutral,
# so treating either as blocking would refuse the initial Greptile trigger
# forever and stall the whole project queue behind that front.
test_greptile_gate_accepts_skipped_and_neutral_required_checks() {
  local dir rc comment_count
  dir=$(make_home greptile-skipped)
  install_github_gate_fake "$dir"
  : > "$dir/gh.log"
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "skipped-check fixture enqueue failed"

  FM_TEST_REQUIRED_JSON='[{"name":"CI / e2e","state":"SKIPPED"},{"name":"CI / lint","state":"NEUTRAL"},{"name":"CI","state":"SUCCESS"}]' \
    FM_TEST_ALL_JSON='[{"name":"CI","state":"SUCCESS"}]' \
    run_kick "$dir" >/dev/null || fail "a skipped required check blocked the Greptile kick"
  comment_count=$(grep -c '^\[<pr><comment>' "$dir/gh.log")
  [ "$comment_count" -eq 1 ] \
    || fail "satisfied required checks did not yield exactly one kick"

  : > "$dir/gh.log"
  set +e
  FM_TEST_REQUIRED_JSON='[{"name":"CI","state":"CANCELLED"}]' \
    FM_TEST_ALL_JSON='[{"name":"CI","state":"CANCELLED"}]' \
    run_kick "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a cancelled required check received Greptile authority"
  assert_no_grep '<pr><comment>' "$dir/gh.log" \
    "a cancelled required check posted a Greptile comment"
  pass "skipped and neutral required checks satisfy the gate; other states block"
}

# The gate's GitHub reads must not hold the per-project queue lock: a slow forge
# would otherwise starve ordinary enqueue and confirmed-merge retirement, whose
# waits are bounded far below the gate's total GitHub budget.
test_greptile_kick_leaves_the_queue_usable_during_github_reads() {
  local dir
  dir=$(make_home greptile-lock)
  install_github_gate_fake "$dir"
  : > "$dir/gh.log"
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "lock-hold fixture enqueue failed"
  cat > "$dir/hook.sh" <<SH
#!/usr/bin/env bash
FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
  FM_MERGE_FRONT_LOCK_TIMEOUT=2 "$MERGE_FRONT" \
  enqueue project-alpha task-b https://github.com/o/r/pull/2 >/dev/null 2>&1 \
  && printf 'concurrent-enqueue=ok\n' > "$dir/hook.out" \
  || printf 'concurrent-enqueue=blocked\n' > "$dir/hook.out"
SH
  chmod +x "$dir/hook.sh"
  FM_TEST_GH_HOOK="$dir/hook.sh" \
    FM_TEST_REQUIRED_JSON='[{"name":"CI","state":"SUCCESS"}]' \
    FM_TEST_ALL_JSON='[{"name":"CI","state":"SUCCESS"}]' \
    run_kick "$dir" >/dev/null || fail "eligible front was not kicked"
  assert_grep 'concurrent-enqueue=ok' "$dir/hook.out" \
    "the queue lock was held across the gate's GitHub reads"
  pass "the Greptile gate never holds the queue lock across GitHub calls"
}

# Releasing the lock means the front can change mid-gate, so the structural gate
# is re-read before the single side effect.
test_greptile_kick_refuses_when_the_front_changes_mid_gate() {
  local dir rc
  dir=$(make_home greptile-revalidate)
  install_github_gate_fake "$dir"
  : > "$dir/gh.log"
  run_front "$dir" enqueue project-alpha task-a https://github.com/o/r/pull/1 >/dev/null \
    || fail "revalidate fixture front enqueue failed"
  run_front "$dir" enqueue project-alpha task-b https://github.com/o/r/pull/2 >/dev/null \
    || fail "revalidate fixture parked enqueue failed"
  cat > "$dir/hook.sh" <<SH
#!/usr/bin/env bash
FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$MERGE_FRONT" \
  remove project-alpha task-a https://github.com/o/r/pull/1 >/dev/null 2>&1
SH
  chmod +x "$dir/hook.sh"
  set +e
  FM_TEST_GH_HOOK="$dir/hook.sh" \
    FM_TEST_REQUIRED_JSON='[{"name":"CI","state":"SUCCESS"}]' \
    FM_TEST_ALL_JSON='[{"name":"CI","state":"SUCCESS"}]' \
    run_kick "$dir" >/dev/null 2> "$dir/revalidate.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a PR retired mid-gate was still kicked"
  assert_no_grep '<pr><comment>' "$dir/gh.log" \
    "a PR that stopped being the front still received a Greptile comment"
  pass "the Greptile gate revalidates the front before its single side effect"
}

test_queue_order_and_promotion
test_queue_conflicts_and_paths_fail_closed
test_same_task_replacement_and_removal_recovery
test_removal_requires_the_exact_task_and_url_pair
test_promote_leaves_the_queue_usable_during_its_merge_poll
test_promote_reports_a_next_front_named_none
test_pr_check_enqueues_project_front
test_pr_check_registers_any_checkout_basename
test_pr_check_refuses_bound_url_before_mutating
test_confirmed_merge_reconciles_exact_identity
test_confirmed_merge_retires_front_without_task_metadata
test_retirement_scan_survives_an_unreadable_project_queue
test_retirement_clears_a_row_whose_recorded_url_diverged
test_retirement_scan_reports_the_identity_it_retired
test_retirement_of_an_absent_row_ignores_unrelated_queues
test_greptile_gate_refusals_and_single_action
test_greptile_gate_accepts_skipped_and_neutral_required_checks
test_greptile_kick_leaves_the_queue_usable_during_github_reads
test_greptile_kick_refuses_when_the_front_changes_mid_gate
