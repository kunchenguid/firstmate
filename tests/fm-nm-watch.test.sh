#!/usr/bin/env bash
# Tests for the direct-PR watch wiring: bin/fm-nm-watch.sh (arming an
# escalate-only no-mistakes watch run on a PR the pipeline did not open) and its
# invocation from bin/fm-pr-check.sh.
#
# Matrix:
#   (a) a direct-PR task arms the watch with an explicit branch and records the run id
#   (b) an explicit --branch overrides the worktree's current branch
#   (c) a no-mistakes-mode task is refused, so its pipeline watcher is never replaced
#   (d) an installed no-mistakes without the watch command reports the upgrade, not a raw error
#   (e) fm-pr-check.sh arms the watch for a direct-PR task and still writes the poll
#   (f) fm-pr-check.sh arms no watch for a no-mistakes-mode task
#   (g) a watch that cannot be armed never fails the PR record or the poll
#   (g2) --no-watch records and polls without arming a monitor on an about-to-merge PR
#   (h) arming records the run id in the durable data/nm-armed-runs ledger, deduped on re-arm
#
# Plus the three "armed is not watching" properties, from the 2026-07-28 incident
# where a red MR reached the captain because firstmate believed an armed watch:
#   (i) a watch that cannot be armed at all is reported as NO CI MONITORING and
#       recorded in the task meta, so bin/fm-bootstrap.sh re-surfaces it
#   (j) a watch that arms and instantly skips its watch step is reported as not
#       armed, and never recorded as this task's run
#   (k) a watch that fails in the task worktree falls back to the project clone
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

NM_WATCH="$ROOT/bin/fm-nm-watch.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-watch-tests)

PR_URL="https://github.com/example/repo/pull/7"

# One sandbox: a state dir, a data dir for the ledger, a real git worktree for
# the task branch, and a fake no-mistakes that records how it was called and
# from where.
make_case() {  # <name> [mode] [branch] [project-dir]
  local name=$1 mode=${2:-direct-PR} branch=${3:-fm/task-a} project=${4:-} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/fakebin"
  fm_git_init_commit "$case_dir/wt" >/dev/null 2>&1
  git -C "$case_dir/wt" checkout -q -b "$branch"
  [ -n "$project" ] || project="$case_dir/wt"
  fm_write_meta "$case_dir/state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=$case_dir/wt" \
    "project=$project" \
    "kind=ship" \
    "mode=$mode"
  printf '%s\n' "$case_dir"
}

# A no-mistakes stub that logs argv and cwd, then answers like the real CLI:
# `watch --pr` prints "  <mark> Watching <url> <run-id>", and `axi status --run`
# prints the run object as TOON. The status answer is what fm-nm-watch.sh reads
# back to decide whether the arm produced a run that is genuinely watching, so a
# stub that only answers `watch` would test half the contract.
#
# <watch-step> selects which run the status answer describes: "running" is a
# healthy watch, "skipped" reproduces run 01KYJY370CPPE9DRV9NPEPFKAD from
# 2026-07-28 - armed, then finished in 2ms having polled nothing, reporting
# outcome: passed.
add_nm_stub() {  # <case_dir> <run-id> [watch-step]
  local case_dir=$1 run=$2 step=${3:-running} run_status=running outcome=
  if [ "$step" = skipped ]; then
    run_status=completed
    outcome='outcome: passed'
  fi
  cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/nm.log"
pwd -P >> "$case_dir/nm.cwd"
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ]; then
  cat <<'TOON'
run:
  id: "$run"
  branch: fm/task-a
  status: $run_status
  head: "abc1234"
  pr: "$PR_URL"
  findings: none
  steps[1]{step,status,findings,duration_ms}:
    watch,$step,0,2
$outcome
TOON
  exit 0
fi
printf '  x Watching %s %s\n' "$PR_URL" "$run"
printf '    branch fm/task-a at abc1234\n'
exit 0
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

# A no-mistakes stub whose `watch` refuses everywhere except <good-dir>, exactly
# as an uninitialized repo does. It is how the fallback from the disposable task
# worktree to the project clone is observable.
add_nm_stub_needs_dir() {  # <case_dir> <run-id> <good-dir>
  local case_dir=$1 run=$2 good=$3
  cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/nm.log"
pwd -P >> "$case_dir/nm.cwd"
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ]; then
  cat <<'TOON'
run:
  id: "$run"
  branch: fm/task-a
  status: running
  head: "abc1234"
  pr: "$PR_URL"
  findings: none
  steps[1]{step,status,findings,duration_ms}:
    watch,running,0,0
TOON
  exit 0
fi
if [ "\$(pwd -P)" != "\$(cd '$good' && pwd -P)" ]; then
  echo "repo not initialized (run 'no-mistakes init' first)" >&2
  exit 1
fi
printf '  x Watching %s %s\n' "$PR_URL" "$run"
exit 0
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

# A no-mistakes stub from before the external watch entry landed.
add_nm_stub_no_watch_cmd() {  # <case_dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo 'unknown command "watch" for "no-mistakes"' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

# gh stub for fm-pr-check.sh's pr_head lookup: a failed lookup is tolerated by
# design, and it keeps the test off the network.
add_gh_stub() {  # <case_dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
}

# --- fm-nm-watch.sh ---------------------------------------------------------

test_arms_direct_pr_task() {
  local dir out checkout
  dir=$(make_case arms)
  add_nm_stub "$dir" 01KTESTRUN0001
  # The temp root reaches the stub through /private on macOS, so compare against
  # the resolved path rather than the one the meta records.
  checkout=$(cd "$dir/wt" && pwd -P)

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || fail "arms: fm-nm-watch.sh exited non-zero: $out"

  assert_contains "$out" "watch armed: run 01KTESTRUN0001" "arms: the armed line did not report the run"
  assert_contains "$out" "escalate-only" "arms: the armed line did not name the escalate-only posture"
  assert_grep "watch --pr $PR_URL --branch fm/task-a" "$dir/nm.log" \
    "arms: no-mistakes was not asked to watch the PR on the task branch"
  assert_grep "nm_watch_run=01KTESTRUN0001" "$dir/state/task-a.meta" \
    "arms: the run id was not recorded in the task meta"
  assert_grep "$checkout" "$dir/nm.cwd" "arms: the watch was not armed from the task checkout"
  pass "a direct-PR task arms an escalate-only watch and records its run id"
}

test_explicit_branch_wins() {
  local dir out
  dir=$(make_case branch)
  add_nm_stub "$dir" 01KTESTRUN0002

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" --branch feature/other 2>&1) \
    || fail "branch: fm-nm-watch.sh exited non-zero: $out"

  assert_grep "--branch feature/other" "$dir/nm.log" "branch: the explicit branch was not passed through"
  assert_no_grep "--branch fm/task-a" "$dir/nm.log" "branch: the worktree branch overrode the explicit one"
  pass "an explicit --branch overrides the worktree's current branch"
}

test_refuses_no_mistakes_mode() {
  local dir out rc=0
  dir=$(make_case refuse no-mistakes)
  add_nm_stub "$dir" 01KTESTRUN0003

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || rc=$?

  expect_code 1 "$rc" "refuse: a no-mistakes-mode task must be refused"
  assert_contains "$out" "watch not armed" "refuse: the refusal was not reported"
  assert_contains "$out" "not direct-PR" "refuse: the refusal did not name the mode mismatch"
  assert_absent "$dir/nm.log" "refuse: no-mistakes was called for a pipeline-owned task"
  assert_no_grep "nm_watch_run=" "$dir/state/task-a.meta" "refuse: a refused arm still wrote a run id"
  assert_absent "$dir/data/nm-armed-runs" "refuse: a refused arm still recorded a run in the ledger"
  pass "a no-mistakes-mode task is refused so its pipeline watcher is never replaced"
}

test_reports_missing_watch_command() {
  local dir out rc=0
  dir=$(make_case oldbin)
  add_nm_stub_no_watch_cmd "$dir"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || rc=$?

  expect_code 1 "$rc" "oldbin: a binary without the watch command must not report success"
  assert_contains "$out" "has no 'watch' command" "oldbin: the reason did not name the missing command"
  assert_contains "$out" "update it" "oldbin: the reason did not point at the fix"
  pass "an installed no-mistakes without the watch command reports the upgrade it needs"
}

# --- fm-pr-check.sh integration ---------------------------------------------

test_pr_check_arms_watch_for_direct_pr() {
  local dir out
  dir=$(make_case prcheck)
  add_nm_stub "$dir" 01KTESTRUN0004
  add_gh_stub "$dir"

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$PR_CHECK" task-a "$PR_URL" 2>&1) \
    || fail "prcheck: fm-pr-check.sh exited non-zero: $out"

  assert_present "$dir/state/task-a.check.sh" "prcheck: the merge/CI poll was not armed"
  assert_contains "$out" "watch armed: run 01KTESTRUN0004" "prcheck: the watch was not armed for a direct-PR task"
  assert_grep "pr=$PR_URL" "$dir/state/task-a.meta" "prcheck: the PR was not recorded"
  pass "fm-pr-check.sh arms the watch for a direct-PR task and still writes the poll"
}

test_pr_check_skips_watch_for_pipeline_mode() {
  local dir out
  dir=$(make_case prcheck-nm no-mistakes)
  add_nm_stub "$dir" 01KTESTRUN0005
  add_gh_stub "$dir"

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$PR_CHECK" task-a "$PR_URL" 2>&1) \
    || fail "prcheck-nm: fm-pr-check.sh exited non-zero: $out"

  assert_present "$dir/state/task-a.check.sh" "prcheck-nm: the merge/CI poll was not armed"
  assert_not_contains "$out" "watch armed" "prcheck-nm: a pipeline-owned task armed an external watch"
  assert_not_contains "$out" "watch not armed" "prcheck-nm: a pipeline-owned task tried to arm an external watch"
  assert_absent "$dir/nm.log" "prcheck-nm: no-mistakes was called for a pipeline-owned task"
  pass "fm-pr-check.sh arms no watch for a no-mistakes-mode task"
}

test_failed_arm_does_not_fail_pr_record() {
  local dir out rc=0
  dir=$(make_case prcheck-fail)
  add_nm_stub_no_watch_cmd "$dir"
  add_gh_stub "$dir"

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$PR_CHECK" task-a "$PR_URL" 2>&1) || rc=$?

  expect_code 0 "$rc" "prcheck-fail: a failed watch arm must not fail the PR record"
  assert_present "$dir/state/task-a.check.sh" "prcheck-fail: the poll was not armed"
  assert_contains "$out" "watch not armed" "prcheck-fail: the failed arm was not reported"
  pass "a watch that cannot be armed never fails the PR record or the poll"
}

test_no_watch_flag_records_without_arming() {
  local dir out
  dir=$(make_case prcheck-nowatch)
  add_nm_stub "$dir" 01KTESTRUN0006
  add_gh_stub "$dir"

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$PR_CHECK" task-a "$PR_URL" --no-watch 2>&1) \
    || fail "prcheck-nowatch: fm-pr-check.sh exited non-zero: $out"

  assert_present "$dir/state/task-a.check.sh" "prcheck-nowatch: the poll was not armed"
  assert_grep "pr=$PR_URL" "$dir/state/task-a.meta" "prcheck-nowatch: the PR was not recorded"
  assert_absent "$dir/nm.log" "prcheck-nowatch: --no-watch still armed a monitor on an about-to-merge PR"
  pass "--no-watch records and polls without arming a monitor"
}

# --- data/nm-armed-runs ledger ----------------------------------------------

test_arming_records_and_dedupes_ledger() {
  local dir line count
  dir=$(make_case ledger)
  add_nm_stub "$dir" 01KTESTRUN0007

  FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" >/dev/null 2>&1 || fail "ledger: fm-nm-watch.sh exited non-zero"

  assert_present "$dir/data/nm-armed-runs" "ledger: arming wrote no durable ledger for the orphan scan"
  line=$(grep ' 01KTESTRUN0007 ' "$dir/data/nm-armed-runs" || true)
  assert_contains "$line" "01KTESTRUN0007 task-a fm/task-a" \
    "ledger: the entry did not record run id, task id, and branch"

  # Re-arming the same run (answering a park then re-arming) must not duplicate.
  FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" >/dev/null 2>&1 || fail "ledger: the re-arm exited non-zero"

  count=$(grep -c ' 01KTESTRUN0007 ' "$dir/data/nm-armed-runs")
  [ "$count" -eq 1 ] || fail "ledger: re-arming the same run duplicated the ledger entry ($count lines)"
  pass "arming records the run id in the durable ledger, deduped on re-arm"
}

# --- armed is not watching --------------------------------------------------

test_unarmable_watch_reports_no_ci_monitoring() {
  local dir out rc=0
  dir=$(make_case unarmable)
  add_nm_stub_no_watch_cmd "$dir"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || rc=$?

  expect_code 1 "$rc" "unarmable: a watch that could not be armed must not report success"
  assert_contains "$out" "no CI monitoring" \
    "unarmable: the line reads like a note instead of naming the lost CI monitoring"
  assert_grep "nm_watch_unarmed=" "$dir/state/task-a.meta" \
    "unarmable: the lost monitoring was not recorded durably, so nothing re-surfaces it"
  assert_no_grep "nm_watch_run=" "$dir/state/task-a.meta" \
    "unarmable: a failed arm still recorded a run id"
  pass "a watch that cannot be armed is reported and recorded as no CI monitoring"
}

test_mode_refusal_is_not_reported_as_lost_monitoring() {
  local dir out rc=0
  dir=$(make_case mode-refusal no-mistakes)
  add_nm_stub "$dir" 01KTESTRUN0010

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || rc=$?

  expect_code 1 "$rc" "mode-refusal: a pipeline-owned task must still be refused"
  assert_not_contains "$out" "no CI monitoring" \
    "mode-refusal: a task whose own pipeline watches it was reported as unmonitored"
  assert_no_grep "nm_watch_unarmed=" "$dir/state/task-a.meta" \
    "mode-refusal: a by-design refusal was recorded as a coverage hole"
  pass "a by-design refusal is not reported or recorded as lost CI monitoring"
}

test_instantly_skipped_watch_is_not_armed() {
  local dir out rc=0
  dir=$(make_case skipped)
  add_nm_stub "$dir" 01KTESTRUN0011 skipped

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || rc=$?

  expect_code 1 "$rc" "skipped: a run that skipped its watch step must not be reported as armed"
  assert_not_contains "$out" "watch armed" "skipped: a run that polled nothing was reported as armed"
  assert_contains "$out" "no CI monitoring" "skipped: the line did not name the lost CI monitoring"
  assert_contains "$out" "skipped its watch step" "skipped: the reason did not name what the run did"
  assert_no_grep "nm_watch_run=" "$dir/state/task-a.meta" \
    "skipped: a run that never watched was recorded as this task's watch run"
  assert_grep "nm_watch_unarmed=" "$dir/state/task-a.meta" \
    "skipped: the unmonitored PR was not recorded durably"
  assert_absent "$dir/data/nm-armed-runs" "skipped: a run that never watched was recorded in the ledger"
  pass "a watch that arms and instantly skips its watch step is reported as not armed"
}

test_healthy_arm_is_verified() {
  local dir out
  dir=$(make_case verified)
  add_nm_stub "$dir" 01KTESTRUN0012

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || fail "verified: fm-nm-watch.sh exited non-zero: $out"

  assert_contains "$out" "watch armed: run 01KTESTRUN0012" "verified: a healthy watch was not reported as armed"
  assert_not_contains "$out" "not verified" "verified: a run that reported itself running was still called unverified"
  assert_grep "axi status --run 01KTESTRUN0012" "$dir/nm.log" \
    "verified: the arm was never checked against the run's own record"
  pass "a healthy arm is confirmed against the run's own record before it is reported"
}

test_falls_back_to_project_clone() {
  local dir out clone
  dir="$TMP_ROOT/fallback"
  mkdir -p "$dir"
  fm_git_init_commit "$dir/clone" >/dev/null 2>&1
  clone=$(cd "$dir/clone" && pwd -P)
  dir=$(make_case fallback direct-PR fm/task-a "$dir/clone")
  add_nm_stub_needs_dir "$dir" 01KTESTRUN0013 "$TMP_ROOT/fallback/clone"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || fail "fallback: fm-nm-watch.sh exited non-zero: $out"

  assert_contains "$out" "watch armed: run 01KTESTRUN0013" \
    "fallback: the arm stopped at the task worktree instead of retrying in the project clone"
  assert_grep "$clone" "$dir/nm.cwd" "fallback: the project clone was never tried"
  assert_grep "nm_watch_run=01KTESTRUN0013" "$dir/state/task-a.meta" \
    "fallback: the run armed from the project clone was not recorded"
  pass "a watch that fails in the task worktree falls back to the project clone"
}

test_arms_direct_pr_task
test_explicit_branch_wins
test_refuses_no_mistakes_mode
test_reports_missing_watch_command
test_pr_check_arms_watch_for_direct_pr
test_pr_check_skips_watch_for_pipeline_mode
test_failed_arm_does_not_fail_pr_record
test_no_watch_flag_records_without_arming
test_arming_records_and_dedupes_ledger
test_unarmable_watch_reports_no_ci_monitoring
test_mode_refusal_is_not_reported_as_lost_monitoring
test_instantly_skipped_watch_is_not_armed
test_healthy_arm_is_verified
test_falls_back_to_project_clone
