#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's unpushed-work safety check.
#
# Covers the local-only fork-remote fix: a local-only-registered project whose
# task pushes its work to a fork (upstream-contribution PRs) must be teardown-
# eligible because a fork IS a remote. The pre-fix code short-circuited to a
# strict local-main check and false-refused legitimate fork-pushed work.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (the fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes  + HEAD on origin remote-tracking branch   -> ALLOW  (no regression)
#   (e) no-mistakes  + truly unpushed work                     -> REFUSE (no regression)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

# A close that could not happen must leave the map behind. The warning names a
# pane; the meta is the only durable thing tying that pane to the task, and
# deleting it in the same run told the operator to go hunting and burned the map.
fail_the_close() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# The window is there and will not close: the one case teardown must not swallow.
case "${1:-}" in
  kill-window)  exit 1 ;;
  list-windows) printf 'fm-task-x1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

test_a_failed_close_keeps_the_task_record() {
  local case_dir rc record
  case_dir=$(make_case close-fails)
  write_meta "$case_dir" local-only ship
  fail_the_close "$case_dir"
  record="$case_dir/state/task-x1.orphan-pane"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "close-fails: teardown should still complete its own cleanup"
  [ -f "$record" ] || fail "close-fails: the task record was not kept; the leftover pane is unfindable"
  grep -qF 'window=fm-task-x1' "$record" \
    || fail "close-fails: the kept record does not name the pane"
  grep -qF 'orphan-pane=fm-task-x1' "$record" \
    || fail "close-fails: the kept record does not say which pane was orphaned"
  grep -qF 'orphan-since=' "$record" \
    || fail "close-fails: the kept record does not say when it was orphaned"
  [ ! -f "$case_dir/state/task-x1.meta" ] \
    || fail "close-fails: the meta was left in the in-flight glob; the task would read as live forever"
  grep -qF "$record" "$case_dir/stderr" \
    || fail "close-fails: the warning does not say the record was kept, or where"
  grep -qF 'was NOT closed' "$case_dir/stdout" \
    || fail "close-fails: teardown reported a plain completion over a pane it could not close"
  pass "a close that failed keeps the task record, outside the in-flight glob, and says so"
}

test_a_successful_close_leaves_no_orphan_record() {
  local case_dir rc
  case_dir=$(make_case close-succeeds)
  write_meta "$case_dir" local-only ship

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "close-succeeds: teardown should succeed"
  [ ! -f "$case_dir/state/task-x1.orphan-pane" ] \
    || fail "close-succeeds: a clean teardown left an orphan record; the signal would mean nothing"
  [ ! -f "$case_dir/state/task-x1.meta" ] || fail "close-succeeds: the meta was not cleared"
  grep -qF 'teardown task-x1 complete (window fm-task-x1' "$case_dir/stdout" \
    || fail "close-succeeds: the ordinary completion line changed"
  pass "a clean close leaves no orphan record (the warning keeps its meaning)"
}

# The retry: run 1 could not close the pane and kept the record, run 2 closed
# it. A record that survives the close names a pane that is no longer there,
# which sends an operator hunting exactly as the missing record once did.
test_a_later_successful_close_clears_a_stale_record() {
  local case_dir rc record
  case_dir=$(make_case close-retry)
  write_meta "$case_dir" local-only ship
  fail_the_close "$case_dir"
  record="$case_dir/state/task-x1.orphan-pane"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout1" 2> "$case_dir/stderr1"
  set -e
  [ -f "$record" ] || fail "close-retry: the first run did not keep a record to go stale"

  # Run 2: the meta the first run cleared is back (a reconcile restores it from
  # the kept record), and the pane closes this time.
  write_meta "$case_dir" local-only ship
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e

  expect_code 0 "$rc" "close-retry: the second teardown should succeed"
  [ ! -f "$record" ] \
    || fail "close-retry: a closed pane still has an orphan record; the operator is sent hunting"
  grep -qF 'teardown task-x1 complete (window fm-task-x1' "$case_dir/stdout2" \
    || fail "close-retry: the second run did not report an ordinary completion"
  pass "a later successful close clears the record an earlier failed close kept"
}

# The record write is a second, independent failure: the close still failed, so
# the summary line must still say so. Keying that line on the record file let a
# failed write print the ordinary completion over a leaked pane - the exact
# plain-success-over-a-leaked-tab report the kept record was added to remove.
test_a_failed_close_reports_even_when_the_record_cannot_be_written() {
  local case_dir rc
  case_dir=$(make_case close-fails-record-unwritable)
  write_meta "$case_dir" local-only ship
  fail_the_close "$case_dir"
  # A directory where the record goes: the redirect cannot write it.
  mkdir -p "$case_dir/state/task-x1.orphan-pane"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "record-unwritable: teardown should still complete its own cleanup"
  grep -qF 'was NOT closed' "$case_dir/stdout" \
    || fail "record-unwritable: teardown reported a plain completion over a pane it could not close"
  grep -qF 'no record could be written' "$case_dir/stdout" \
    || fail "record-unwritable: the summary does not say the record is missing"
  grep -qF 'could not write the task record' "$case_dir/stderr" \
    || fail "record-unwritable: the failed record write is not its own warning"
  pass "a failed close still reports as unclosed when the record cannot be written"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with truly unpushed work is refused (no regression)"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_a_failed_close_keeps_the_task_record
test_a_successful_close_leaves_no_orphan_record
test_a_later_successful_close_clears_a_stale_record
test_a_failed_close_reports_even_when_the_record_cannot_be_written
