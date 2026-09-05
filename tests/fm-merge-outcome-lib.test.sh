#!/usr/bin/env bash
# Tests for bin/fm-merge-outcome-lib.sh's ready-frontier attachment: a merging
# PR is how a `blocked-by` dependency clears, so fm_merge_outcome_report - the
# single convergence point for both a self-performed merge and a polled one -
# carries the actual ready frontier with the outcome, not just a landed-PR
# notice. tests/fm-pr-merge.test.sh already pins where the outcome record goes
# (parent status line vs. local wake) through the real merge entrypoint; this
# file unit-tests the frontier attachment directly against both legal `origin`
# values, since only bin/fm-watch.sh drives the `poll` origin end to end and
# standing up its full merge-poll fixture here would test machinery this
# change never touches.
#
# Matrix:
#   (a) origin=self on a main home: the local wake carries the ready item ids
#       and the standing no-cap sentence
#   (b) origin=poll on a main home: same attachment, so a merge the captain
#       performs directly on GitHub is covered identically to one firstmate
#       performs itself
#   (c) a ready-probe failure (manual backlog backend) degrades to the outcome
#       report's existing behavior with no ready-frontier addendum, and the
#       report still succeeds
#   (d) a secondmate's upward status line stays exact-line dedupable across an
#       at-least-once retry even though the ready frontier is time-varying: the
#       frontier attaches only to the local wake, never to the upward line
#   (e) the deploy handoff this function now makes is completely inert for a
#       task whose project has no deploy policy: same wake, nothing else
#   (f) a deploy that cannot even be assessed never turns a recorded merge into
#       an unrecorded one. bin/fm-pr-merge.sh reads a non-zero return here as
#       "the merge landed and the record did not", so the deploy's own trouble
#       must not borrow that meaning
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || fail "these tests need the real tasks-axi to seed a backlog"
TMP_ROOT=$(fm_test_tmproot fm-merge-outcome-lib-tests)

FM_READY_FRONTIER_SENTENCE_FOR_TEST='Live tasks are bounded by the concurrency cap and by serial integration onto an unstable seam; preparation is never seam-bounded, and every undispatched ready item carries a recorded rule, owner, and recheck event.'

# make_main_home_case <name>: a plain main home (no .fm-secondmate-home marker)
# with a real data/backlog.md carrying one already-ready, unblocked item.
# Echoes the case dir; the home is "$case_dir/home", the state dir
# "$case_dir/state".
make_main_home_case() {
  local name=$1 case_dir home state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  state="$case_dir/state"
  mkdir -p "$home/data" "$state"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  tasks-axi add task-r1 "an independent ready item" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  printf '%s\n' "$case_dir"
}

call_merge_outcome_report() {  # <home> <state> <id> <url> <origin>
  (
    FM_ROOT_OVERRIDE="$ROOT"
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$1" "$2" "$3" "$4" "$5"
  )
}

test_self_origin_attaches_the_ready_frontier() {
  local case_dir home state url rc=0
  case_dir=$(make_main_home_case self-origin-frontier)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/91

  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "self-origin-frontier: fm_merge_outcome_report failed: rc=$rc"

  assert_present "$state/.wake-queue" \
    "self-origin-frontier: a main-home self-merge left no local wake"
  assert_grep 'task-r1' "$state/.wake-queue" \
    "self-origin-frontier: the merge outcome wake omitted the ready item it should have shown"
  assert_grep "$FM_READY_FRONTIER_SENTENCE_FOR_TEST" "$state/.wake-queue" \
    "self-origin-frontier: the merge outcome wake dropped the standing no-cap sentence"
  pass "a self-performed merge's outcome wake carries the ready frontier"
}

test_poll_origin_attaches_the_ready_frontier() {
  local case_dir home state url rc=0
  case_dir=$(make_main_home_case poll-origin-frontier)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/92

  call_merge_outcome_report "$home" "$state" task-x1 "$url" poll || rc=$?
  [ "$rc" -eq 0 ] || fail "poll-origin-frontier: fm_merge_outcome_report failed: rc=$rc"

  assert_present "$state/.wake-queue" \
    "poll-origin-frontier: a merge detected by the watcher's poll left no local wake"
  assert_grep 'task-r1' "$state/.wake-queue" \
    "poll-origin-frontier: the merge outcome wake omitted the ready item it should have shown"
  assert_grep "$FM_READY_FRONTIER_SENTENCE_FOR_TEST" "$state/.wake-queue" \
    "poll-origin-frontier: the merge outcome wake dropped the standing no-cap sentence"
  pass "a merge the captain performs directly, detected by the poll, carries the ready frontier identically"
}

test_ready_probe_failure_still_reports_the_merge() {
  local case_dir home state url rc=0
  case_dir=$(make_main_home_case ready-probe-fails)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/93
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"

  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "ready-probe-fails: fm_merge_outcome_report should still succeed when the ready probe is unavailable: rc=$rc"

  assert_present "$state/.wake-queue" \
    "ready-probe-fails: a landed merge produced no outcome wake at all"
  assert_grep "merge landed: task-x1 $url" "$state/.wake-queue" \
    "ready-probe-fails: the landed-merge notice itself was dropped"
  assert_no_grep "$FM_READY_FRONTIER_SENTENCE_FOR_TEST" "$state/.wake-queue" \
    "ready-probe-fails: a failed ready probe should never fabricate a frontier report"
  pass "a ready-probe failure degrades gracefully: the merge is still reported, with no frontier addendum"
}

test_upward_line_stays_dedupable_across_a_changing_frontier() {
  local case_dir home state url marker rc=0 lines
  case_dir="$TMP_ROOT/secondmate-frontier-retry"
  home="$case_dir/home"
  state="$case_dir/state"
  mkdir -p "$home/data" "$state"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  tasks-axi add task-r1 "first ready item" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  printf '%s\n' mate-x > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$home/.fm-secondmate-parent"
  url=https://github.com/example/repo/pull/94
  marker="$state/task-x1.pr-poll-merge-notified"

  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "frontier-retry: first report failed: rc=$rc"
  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    "$state/parent-replies.status" \
    "frontier-retry: the first report never reached the parent channel"

  # Simulate the header's documented at-least-once window: the outcome
  # published but the notified marker's commit never landed, so a retry
  # replays the whole publish path. Change the ready frontier in between, the
  # way real elapsed time between a publish and its retry would.
  rm -f "$marker"
  tasks-axi add task-r2 "second ready item, added between attempts" --kind ship \
    --file "$home/data/backlog.md" >/dev/null

  rc=0
  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "frontier-retry: retried report failed: rc=$rc"

  lines=$(grep -c -F "merged task-x1 $url" "$state/parent-replies.status" 2>/dev/null || true)
  [ "$lines" -eq 1 ] \
    || fail "frontier-retry: a changing ready frontier broke the upward line's at-most-once dedup: got $lines line(s)"
  pass "the upward status line stays exact-line dedupable across a retry even while the ready frontier changes"
}

test_the_deploy_handoff_is_inert_without_a_policy() {
  local case_dir home state url rc=0 rows
  case_dir=$(make_main_home_case deploy-handoff-inert)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/93
  mkdir -p "$home/projects/demo"
  fm_write_meta "$state/task-x1.meta" "project=$home/projects/demo"

  call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] || fail "deploy-handoff-inert: fm_merge_outcome_report failed: rc=$rc"

  assert_absent "$state/deploy-ledger" \
    "deploy-handoff-inert: a project with no deploy policy reached the deploy path"
  rows=$(wc -l < "$state/.wake-queue" | tr -d ' ')
  [ "$rows" -eq 1 ] \
    || fail "deploy-handoff-inert: expected only the merge wake, got $rows rows: $(cat "$state/.wake-queue")"
  assert_grep "merge landed: task-x1 $url" "$state/.wake-queue" \
    "deploy-handoff-inert: the merge outcome itself changed"
  pass "the deploy handoff is inert for a project with no deploy policy"
}

test_a_deploy_that_cannot_be_assessed_still_records_the_merge() {
  local case_dir home state url rc=0
  case_dir=$(make_main_home_case deploy-handoff-failure)
  home="$case_dir/home"
  state="$case_dir/state"
  url=https://github.com/example/repo/pull/94
  mkdir -p "$home/projects/demo" "$home/config/deploy-policy"
  # A policy with no matching deploy target: the deploy path is reachable and
  # cannot complete, which is exactly the shape that must not be mistaken for a
  # failure to record the merge.
  printf 'dashboard/**\n' > "$home/config/deploy-policy/demo"
  fm_write_meta "$state/task-x1.meta" "project=$home/projects/demo"

  FM_DEPLOY_SYNC_TIMEOUT=5 FM_DEPLOY_STATUS_TIMEOUT=5 \
    call_merge_outcome_report "$home" "$state" task-x1 "$url" self || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "deploy-handoff-failure: a deploy that could not be assessed was reported as a failure to record the merge (rc=$rc)"
  assert_grep "merge landed: task-x1 $url" "$state/.wake-queue" \
    "deploy-handoff-failure: the merge outcome was lost"
  # Proves the case is not vacuous: the deploy path really was entered and
  # really did fail, rather than being skipped before it could.
  assert_grep "could not check whether demo" "$state/.wake-queue" \
    "deploy-handoff-failure: the deploy path was never reached, so this case proves nothing"
  pass "a deploy that cannot be assessed never turns a recorded merge into an unrecorded one"
}

test_self_origin_attaches_the_ready_frontier
test_poll_origin_attaches_the_ready_frontier
test_ready_probe_failure_still_reports_the_merge
test_upward_line_stays_dedupable_across_a_changing_frontier
test_the_deploy_handoff_is_inert_without_a_policy
test_a_deploy_that_cannot_be_assessed_still_records_the_merge
