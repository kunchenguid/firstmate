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
#
# Plus the cross-machine hole found on 2026-08-06, where a direct-PR task
# dispatched with `fm-spawn --host` reached its PR record with both recorded
# paths pointing at the other machine, so nothing here could arm a watch and the
# merge poll still reported `armed`:
#   (l) a task whose recorded paths are on another machine arms from this home's
#       own clone of the same project name
#   (m) firstmate's own repo counts as that clone by name, because it is this
#       home's code root and not a directory under projects/
#   (n) when nothing resolves, fm-pr-check.sh states the lost CI monitoring in
#       its own right instead of leaving it to a line in the middle of a
#       successful-looking run
#   (o) a task whose recorded worktree is readable resolves exactly as before,
#       with no new candidate consulted
#
# Plus the masked-diagnostics incident of 2026-08-10, where every arm against
# lavish-axi MR 5 reported "A new build of no-mistakes is available: 8a4127c ->
# 2fcbae7" - no-mistakes writes that self-update banner to stderr on every CLI
# call, and the reason was read off the first line of a 2>&1 capture, so the real
# refusal one line below it never reached anyone:
#   (p) a banner-polluted refusal reports the refusal, not the banner
#   (q) a banner-polluted success still yields the run id, which is the half of
#       the parsing that was already immune - asserted rather than assumed,
#       because "the banner cannot reach this path" is exactly what was believed
#       about the failure path too
#   (r) unpolluted output is unchanged by the filter, in both directions
#   (s) the raw output survives the filter as stderr evidence
#   (t) the refusal that actually happened - an uninitialized repo - names its
#       own remedy, so nobody has to go read where that rule lives
#   (u) fm-pr-check.sh still finds the verdict line now that stderr also carries
#       the raw evidence dump
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

# A task that RAN ON ANOTHER MACHINE: the recorded worktree and project are that
# machine's absolute paths, so neither exists here. Everything else - the mode,
# the PR, the meta shape - is an ordinary direct-PR ship task, because that is
# exactly what it is on the machine that ran it.
make_remote_case() {  # <name> <project-name>
  local name=$1 proj=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/fakebin" "$case_dir/projects"
  fm_write_meta "$case_dir/state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=/host/pool/7/$proj" \
    "project=/host/fmhome/projects/$proj" \
    "kind=ship" \
    "mode=direct-PR" \
    "host=box151"
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

# The self-update banner exactly as the installed no-mistakes emits it: two
# stderr lines ahead of everything the command itself says, still carrying their
# ANSI colouring when captured to a pipe. Recorded 2026-08-10 from
# `no-mistakes watch --pr ... 2>&1 | cat -A` on box151 with build 8a4127c.
NM_BANNER_1=$'\033[33mA new build of no-mistakes is available: 8a4127c -> 2fcbae7'
NM_BANNER_2=$'Run "no-mistakes update" to update\033[0m'

# A no-mistakes stub that prints the self-update banner on stderr before doing
# anything else, then refuses the watch the way the real one refused on
# lavish-axi MR 5: an uninitialized repo. <refusal> overrides that message.
add_nm_stub_banner_refusal() {  # <case_dir> [refusal]
  local case_dir=$1 refusal=${2:-"repo not initialized (run 'no-mistakes init' first)"}
  cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/nm.log"
printf '%s\n%s\n' '$NM_BANNER_1' '$NM_BANNER_2' >&2
printf '%s\n' "$refusal" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

# The same banner in front of a SUCCESSFUL arm, which is the case the run-id
# parse has to survive: `watch` prints its Watching line on stdout while the
# banner goes to stderr, and fm-nm-watch.sh reads both as one merged capture.
add_nm_stub_banner_success() {  # <case_dir> <run-id>
  local case_dir=$1 run=$2
  cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/nm.log"
pwd -P >> "$case_dir/nm.cwd"
printf '%s\n%s\n' '$NM_BANNER_1' '$NM_BANNER_2' >&2
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
printf '  x Watching %s %s\n' "$PR_URL" "$run"
printf '    branch fm/task-a at abc1234\n'
exit 0
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

# --- a task that ran on another machine ---------------------------------------

test_cross_machine_task_arms_from_the_local_clone() {
  local dir out clone
  dir=$(make_remote_case xmachine alpha)
  fm_git_init_commit "$dir/projects/alpha" >/dev/null 2>&1
  clone=$(cd "$dir/projects/alpha" && pwd -P)
  add_nm_stub_needs_dir "$dir" 01KTESTRUN0014 "$dir/projects/alpha"

  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_PROJECTS_OVERRIDE="$dir/projects" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || fail "xmachine: fm-nm-watch.sh exited non-zero: $out"

  assert_contains "$out" "watch armed: run 01KTESTRUN0014" \
    "xmachine: a task whose recorded paths are on another machine was left unmonitored"
  assert_grep "$clone" "$dir/nm.cwd" "xmachine: this home's own clone of the project was never tried"
  assert_grep "nm_watch_run=01KTESTRUN0014" "$dir/state/task-a.meta" \
    "xmachine: the run armed from the local clone was not recorded"
  pass "a task that ran on another machine arms from this home's clone of the same project"
}

# firstmate's own repo is the case that would otherwise still fail: it is this
# home's code root, not a clone under projects/, so a name lookup that only
# searched projects/ would miss exactly the repo most cross-machine firstmate
# work runs in.
test_cross_machine_firstmate_task_arms_from_the_code_root() {
  local dir out root
  dir=$(make_remote_case xmachine-fm firstmate)
  fm_git_init_commit "$dir/firstmate" >/dev/null 2>&1
  root=$(cd "$dir/firstmate" && pwd -P)
  add_nm_stub_needs_dir "$dir" 01KTESTRUN0015 "$dir/firstmate"

  out=$(FM_ROOT_OVERRIDE="$dir/firstmate" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_PROJECTS_OVERRIDE="$dir/projects" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || fail "xmachine-fm: fm-nm-watch.sh exited non-zero: $out"

  assert_contains "$out" "watch armed: run 01KTESTRUN0015" \
    "xmachine-fm: a cross-machine firstmate task was left unmonitored"
  assert_grep "$root" "$dir/nm.cwd" "xmachine-fm: this home's own code root was never tried"
  pass "a cross-machine firstmate task arms from this home's code root, not a projects/ clone"
}

# The one that is easiest to regress, because the regression is silence: when no
# checkout resolves at all, the PR record still succeeds and the poll is still
# armed, so the lost CI monitoring has to be stated as its own result.
test_unresolvable_checkout_is_stated_by_pr_check() {
  local dir out err rc=0
  dir=$(make_remote_case xmachine-none beta)
  add_nm_stub "$dir" 01KTESTRUN0016
  add_gh_stub "$dir"
  err="$dir/pr-check.err"

  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" FM_PROJECTS_OVERRIDE="$dir/projects" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$PR_CHECK" task-a "$PR_URL" 2>"$err") || rc=$?

  expect_code 0 "$rc" "xmachine-none: an unarmable watch must still not fail the PR record"
  assert_present "$dir/state/task-a.check.sh" "xmachine-none: the merge poll was not armed"
  assert_contains "$out" "no CI monitoring" "xmachine-none: the arm's own line went missing"
  assert_contains "$(cat "$err")" "NM_UNWATCHED: task-a: $PR_URL has no CI monitoring" \
    "xmachine-none: the lost CI monitoring was left buried in a run that otherwise reads as success"
  assert_contains "$(cat "$err")" "re-arm with bin/fm-nm-watch.sh task-a" \
    "xmachine-none: the report did not name the remedy"
  assert_grep "another machine records THAT machine's paths" "$dir/state/task-a.meta" \
    "xmachine-none: the recorded reason did not explain why no checkout resolved"
  pass "an unresolvable checkout is reported as lost CI monitoring in its own right"
}

# The compatibility half: a task whose recorded worktree is readable must resolve
# exactly where it always did, and must not reach a name-derived candidate at all.
test_local_task_resolution_is_unchanged() {
  local dir out err rc=0 checkout decoy
  dir=$(make_case unchanged)
  mkdir -p "$dir/projects"
  fm_git_init_commit "$dir/projects/wt" >/dev/null 2>&1
  checkout=$(cd "$dir/wt" && pwd -P)
  decoy=$(cd "$dir/projects/wt" && pwd -P)
  add_nm_stub "$dir" 01KTESTRUN0017
  add_gh_stub "$dir"
  err="$dir/pr-check.err"

  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" FM_PROJECTS_OVERRIDE="$dir/projects" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$PR_CHECK" task-a "$PR_URL" 2>"$err") || rc=$?

  expect_code 0 "$rc" "unchanged: a healthy local direct-PR task must still record and arm"
  assert_contains "$out" "watch armed: run 01KTESTRUN0017" "unchanged: the local arm regressed"
  assert_grep "$checkout" "$dir/nm.cwd" "unchanged: the arm left the task's own checkout"
  assert_no_grep "$decoy" "$dir/nm.cwd" \
    "unchanged: a name-derived candidate was consulted for a task that resolved locally"
  assert_not_contains "$(cat "$err")" "NM_UNWATCHED" \
    "unchanged: a healthy arm reported lost CI monitoring"
  pass "a task whose recorded worktree is readable resolves exactly as before"
}

# --- the self-update banner must not stand in for the reason -----------------

test_banner_does_not_mask_the_refusal() {
  local dir out err rc=0
  dir=$(make_case banner-mask)
  add_nm_stub_banner_refusal "$dir" 'start watch run: some refusal the fleet has never seen'
  err="$dir/watch.err"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>"$err") || rc=$?

  expect_code 1 "$rc" "banner-mask: a refused arm must not report success"
  assert_contains "$out" "some refusal the fleet has never seen" \
    "banner-mask: the reason did not carry the refusal no-mistakes actually gave"
  assert_not_contains "$out" "A new build of no-mistakes" \
    "banner-mask: the self-update banner was reported as the reason again"
  assert_not_contains "$out" "no-mistakes update" \
    "banner-mask: the banner's second line leaked into the reason"
  # The durable half matters more than the printed one: bin/fm-bootstrap.sh
  # re-surfaces this field at every later session start, so a banner recorded
  # here would mislead every future session, not just this run.
  assert_grep "some refusal the fleet has never seen" "$dir/state/task-a.meta" \
    "banner-mask: the durable record kept the masked reason"
  assert_no_grep "A new build of no-mistakes" "$dir/state/task-a.meta" \
    "banner-mask: the banner was recorded durably as this PR's reason"
  pass "the self-update banner does not stand in for a refusal's real reason"
}

test_banner_polluted_success_still_yields_the_run_id() {
  local dir out
  dir=$(make_case banner-ok)
  add_nm_stub_banner_success "$dir" 01KTESTRUN0018

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>/dev/null) || fail "banner-ok: fm-nm-watch.sh exited non-zero: $out"

  assert_contains "$out" "watch armed: run 01KTESTRUN0018" \
    "banner-ok: the banner displaced the run id the Watching line carries"
  assert_grep "nm_watch_run=01KTESTRUN0018" "$dir/state/task-a.meta" \
    "banner-ok: the run id was not recorded under banner noise"
  assert_not_contains "$out" "not verified" \
    "banner-ok: the banner broke the read-back that confirms the run is watching"
  pass "a banner-polluted successful arm still yields the run id"
}

test_clean_output_is_unchanged_by_the_filter() {
  local dir out rc=0
  dir=$(make_case banner-none)
  add_nm_stub_banner_refusal "$dir" 'plain refusal with no banner'
  # Strip the banner back out of the stub: the filter must be a no-op on output
  # that never carried it, in both the reason and the run-id direction.
  grep -v 'A new build of no-mistakes' "$dir/fakebin/no-mistakes" > "$dir/fakebin/no-mistakes.clean"
  mv "$dir/fakebin/no-mistakes.clean" "$dir/fakebin/no-mistakes"
  chmod +x "$dir/fakebin/no-mistakes"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>/dev/null) || rc=$?

  expect_code 1 "$rc" "banner-none: a refused arm must not report success"
  assert_contains "$out" "plain refusal with no banner" \
    "banner-none: the filter altered a reason that had no banner to remove"
  pass "output that never carried the banner is unchanged by the filter"
}

test_raw_arm_output_is_kept_as_evidence() {
  local dir err rc=0 raw
  dir=$(make_case banner-raw)
  add_nm_stub_banner_refusal "$dir"
  err="$dir/watch.err"

  FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" >/dev/null 2>"$err" || rc=$?

  expect_code 1 "$rc" "banner-raw: a refused arm must not report success"
  raw=$(cat "$err")
  assert_contains "$raw" "repo not initialized" \
    "banner-raw: the raw refusal was not kept anywhere for debugging"
  assert_contains "$raw" "A new build of no-mistakes" \
    "banner-raw: filtering the reason also discarded the raw output it came from"
  assert_contains "$raw" "$(cd "$dir/wt" && pwd -P)" \
    "banner-raw: the evidence does not say which checkout produced it"
  pass "the raw arm output is kept as stderr evidence, not discarded by the filter"
}

test_uninitialized_repo_names_its_own_remedy() {
  local dir out rc=0
  dir=$(make_case uninit)
  add_nm_stub_banner_refusal "$dir"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>/dev/null) || rc=$?

  expect_code 1 "$rc" "uninit: an uninitialized repo must not report success"
  assert_contains "$out" "no CI monitoring" "uninit: the lost CI monitoring was not named"
  assert_contains "$out" "init" "uninit: the reason did not name the command that fixes it"
  assert_contains "$out" "direct-PR project needs that too" \
    "uninit: the reason did not say why a project that skips the pipeline still needs this"
  pass "an uninitialized repo's refusal names the initialization that fixes it"
}

test_pr_check_relays_the_real_reason() {
  local dir out err rc=0
  dir=$(make_case prcheck-evidence)
  add_nm_stub_banner_refusal "$dir" 'start watch run: a refusal fm-pr-check must relay'
  add_gh_stub "$dir"
  err="$dir/pr-check.err"

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$PR_CHECK" task-a "$PR_URL" 2>"$err") || rc=$?

  expect_code 0 "$rc" "prcheck-evidence: a failed arm must still not fail the PR record"
  assert_present "$dir/state/task-a.check.sh" "prcheck-evidence: the merge poll was not armed"
  assert_contains "$(cat "$err")" "a refusal fm-pr-check must relay" \
    "prcheck-evidence: the diagnostic did not carry the refusal no-mistakes gave"
  assert_not_contains "$(cat "$err")" "NM_UNWATCHED: task-a: $PR_URL has no CI monitoring - A new build" \
    "prcheck-evidence: the banner reached the diagnostic firstmate reads at every session start"
  pass "fm-pr-check.sh relays the arm's real reason into its NM_UNWATCHED diagnostic"
}

# fm-pr-check.sh captures the arm with 2>&1, so the raw evidence dump lands in
# the same buffer as the verdict and its fallback can no longer take the last
# line. That fallback only fires when the durable record is missing, which is
# hard to force from the outside - so assert the invariant it now depends on
# instead: exactly one line of the merged capture starts with "watch not armed".
test_verdict_line_is_selectable_under_the_evidence_dump() {
  local dir merged verdicts
  dir=$(make_case verdict-prefix)
  add_nm_stub_banner_refusal "$dir" 'start watch run: the refusal a caller must find'

  merged=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$NM_WATCH" task-a "$PR_URL" 2>&1 || true)

  verdicts=$(printf '%s\n' "$merged" | grep -c '^watch not armed' || true)
  [ "$verdicts" -eq 1 ] || fail "verdict-prefix: expected exactly one verdict line, found $verdicts"
  assert_contains "$(printf '%s\n' "$merged" | grep '^watch not armed')" \
    "the refusal a caller must find" \
    "verdict-prefix: the verdict line does not carry the reason a caller relays"
  pass "the merged capture holds exactly one verdict line, selectable by prefix"
}

test_banner_does_not_mask_the_refusal
test_banner_polluted_success_still_yields_the_run_id
test_clean_output_is_unchanged_by_the_filter
test_raw_arm_output_is_kept_as_evidence
test_uninitialized_repo_names_its_own_remedy
test_pr_check_relays_the_real_reason
test_verdict_line_is_selectable_under_the_evidence_dump
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
test_cross_machine_task_arms_from_the_local_clone
test_cross_machine_firstmate_task_arms_from_the_code_root
test_unresolvable_checkout_is_stated_by_pr_check
test_local_task_resolution_is_unchanged
