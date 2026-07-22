#!/usr/bin/env bash
# Tests for the direct-PR watch wiring: bin/fm-nm-watch.sh (arming an
# escalate-only no-mistakes watch run on a PR the pipeline did not open), its
# invocation from bin/fm-pr-check.sh, and bin/fm-nm-park-wake.sh (turning a
# no-mistakes park/unpark into a firstmate wake).
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
#   (h) a watch park opens a keyed needs-decision on the mapped task's status
#   (i) the recorded run id maps the park even when another task owns the branch
#   (j) a crew-driven gate park stays silent until the reminders show nobody answered
#   (k) a re-notified park is rate-limited, and the unpark closes the keyed decision
#   (l) a park that maps to no task still wakes the home through nm-park.status
#   (m) a park for a secondmate's task wakes that secondmate's home
#   (n) multi-line findings collapse into one status line, so the status fold survives
#   (o) a hook call with no run id fails loudly instead of silently dropping the wake
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# Every park-hook case supplies its own NM_* wait explicitly. When this suite
# itself runs inside a no-mistakes run, that run exports its own NM_* (NM_HOME,
# NM_RUN_ID, ...) into the test process, so an inherited NM_RUN_ID would satisfy
# the very input the missing-run-id case removes. Scrub the ambient set once.
while IFS= read -r _nm_var; do
  unset "$_nm_var"
done <<EOF
$(env | sed -n 's/^\(NM_[A-Za-z0-9_]*\)=.*/\1/p')
EOF
unset _nm_var

NM_WATCH="$ROOT/bin/fm-nm-watch.sh"
PARK_WAKE="$ROOT/bin/fm-nm-park-wake.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-watch-tests)

PR_URL="https://github.com/example/repo/pull/7"

# One sandbox: a state dir, a real git worktree for the task branch, and a fake
# no-mistakes that records how it was called and from where.
make_case() {  # <name> [mode] [branch]
  local name=$1 mode=${2:-direct-PR} branch=${3:-fm/task-a} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  fm_git_init_commit "$case_dir/wt" >/dev/null 2>&1
  git -C "$case_dir/wt" checkout -q -b "$branch"
  fm_write_meta "$case_dir/state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/wt" \
    "kind=ship" \
    "mode=$mode"
  printf '%s\n' "$case_dir"
}

# A no-mistakes stub that logs argv and cwd, then answers like the real
# `watch --pr` does ("  <mark> Watching <url> <run-id>").
add_nm_stub() {  # <case_dir> <run-id>
  local case_dir=$1 run=$2
  cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/nm.log"
pwd -P >> "$case_dir/nm.cwd"
printf '  x Watching %s %s\n' "$PR_URL" "$run"
printf '    branch fm/task-a at abc1234\n'
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

run_park_hook() {  # <case_dir> <home> <env assignments...>
  local case_dir=$1 home=$2
  shift 2
  env FM_HOME="$home" "$@" "$PARK_WAKE"
}

# --- fm-nm-watch.sh ---------------------------------------------------------

test_arms_direct_pr_task() {
  local dir out checkout
  dir=$(make_case arms)
  add_nm_stub "$dir" 01KTESTRUN0001
  # The temp root reaches the stub through /private on macOS, so compare against
  # the resolved path rather than the one the meta records.
  checkout=$(cd "$dir/wt" && pwd -P)

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_NM_BIN="$dir/fakebin/no-mistakes" \
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

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_NM_BIN="$dir/fakebin/no-mistakes" \
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

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_NM_BIN="$dir/fakebin/no-mistakes" \
    "$NM_WATCH" task-a "$PR_URL" 2>&1) || rc=$?

  expect_code 1 "$rc" "refuse: a no-mistakes-mode task must be refused"
  assert_contains "$out" "watch not armed" "refuse: the refusal was not reported"
  assert_contains "$out" "not direct-PR" "refuse: the refusal did not name the mode mismatch"
  assert_absent "$dir/nm.log" "refuse: no-mistakes was called for a pipeline-owned task"
  assert_no_grep "nm_watch_run=" "$dir/state/task-a.meta" "refuse: a refused arm still wrote a run id"
  pass "a no-mistakes-mode task is refused so its pipeline watcher is never replaced"
}

test_reports_missing_watch_command() {
  local dir out rc=0
  dir=$(make_case oldbin)
  add_nm_stub_no_watch_cmd "$dir"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_NM_BIN="$dir/fakebin/no-mistakes" \
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

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
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

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
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

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
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

  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
    FM_NM_BIN="$dir/fakebin/no-mistakes" "$PR_CHECK" task-a "$PR_URL" --no-watch 2>&1) \
    || fail "prcheck-nowatch: fm-pr-check.sh exited non-zero: $out"

  assert_present "$dir/state/task-a.check.sh" "prcheck-nowatch: the poll was not armed"
  assert_grep "pr=$PR_URL" "$dir/state/task-a.meta" "prcheck-nowatch: the PR was not recorded"
  assert_absent "$dir/nm.log" "prcheck-nowatch: --no-watch still armed a monitor on an about-to-merge PR"
  pass "--no-watch records and polls without arming a monitor"
}

# --- fm-nm-park-wake.sh -----------------------------------------------------

make_home() {  # <name> -> home dir with one direct-PR task meta
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data"
  fm_write_meta "$home/state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=$home/wt" \
    "project=$home/wt" \
    "kind=ship" \
    "mode=direct-PR"
  printf '%s\n' "$home"
}

test_watch_park_opens_keyed_decision() {
  local home line
  home=$(make_home park-watch)

  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0001 NM_STEP=watch NM_GATE=awaiting_approval \
    NM_BRANCH=fm/task-a NM_REPO="$home/wt" NM_REMINDER=0 \
    NM_FINDINGS='watch-1 [blocking] (ask-user) 2 unresolved review thread(s)' \
    || fail "park-watch: the hook exited non-zero"

  assert_present "$home/state/task-a.status" "park-watch: no wake was written for the task"
  line=$(last_status_line "$home/state/task-a.status")
  assert_contains "$line" "needs-decision [key=nm-park-01KPARK0001]" \
    "park-watch: the park did not open a keyed decision"
  assert_contains "$line" "unresolved review thread" "park-watch: the wake dropped the finding detail"
  assert_contains "$line" "no-mistakes parked" "park-watch: the wake did not point at the durable record"
  status_is_captain_relevant "$line" || fail "park-watch: the wake line is not captain-relevant, so no watcher would surface it"
  pass "a watch park opens a keyed needs-decision on the mapped task's status"
}

test_recorded_run_id_beats_branch() {
  local home
  home=$(make_home park-runid)
  # A second task owns the fm/<id> branch shape the park names, while the first
  # task is the one that actually armed this run.
  printf 'nm_watch_run=01KPARK0002\n' >> "$home/state/task-a.meta"
  fm_write_meta "$home/state/task-b.meta" \
    "window=fm-task-b" "worktree=$home/wt2" "project=$home/wt2" "kind=ship" "mode=direct-PR"

  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0002 NM_STEP=watch NM_GATE=awaiting_approval \
    NM_BRANCH=fm/task-b NM_REPO="$home/wt" NM_REMINDER=0 NM_FINDINGS='watch-1 CI failing' \
    || fail "park-runid: the hook exited non-zero"

  assert_present "$home/state/task-a.status" "park-runid: the recorded run id did not map the park"
  assert_absent "$home/state/task-b.status" "park-runid: the branch guess beat the recorded run id"
  pass "the recorded run id maps the park even when another task owns the branch"
}

test_crew_gate_park_waits_for_reminders() {
  local home line
  home=$(make_home park-crew)

  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0003 NM_STEP=review NM_GATE=awaiting_approval \
    NM_BRANCH=fm/task-a NM_REPO="$home/wt" NM_REMINDER=0 NM_FINDINGS='review-1 blocking' \
    || fail "park-crew: the hook exited non-zero on the edge"
  assert_absent "$home/state/task-a.status" \
    "park-crew: a crew-driven gate park woke firstmate on the edge, where the crew is still answering"

  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0003 NM_STEP=review NM_GATE=awaiting_approval \
    NM_BRANCH=fm/task-a NM_REPO="$home/wt" NM_REMINDER=2 NM_FINDINGS='review-1 blocking' \
    || fail "park-crew: the hook exited non-zero on the reminder"

  line=$(last_status_line "$home/state/task-a.status")
  assert_contains "$line" "blocked [key=nm-park-01KPARK0003]" \
    "park-crew: an unanswered gate park did not open a blocked thread"
  assert_contains "$line" "unanswered after 2 reminders" "park-crew: the wake did not say nobody answered"
  pass "a crew-driven gate park stays silent until the reminders show nobody answered"
}

test_rate_limit_then_unpark_closes() {
  local home open count
  home=$(make_home park-repeat)

  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0004 NM_STEP=watch NM_GATE=awaiting_approval \
    NM_BRANCH=fm/task-a NM_REPO="$home/wt" NM_REMINDER=0 NM_FINDINGS='watch-1 awaiting approval' \
    || fail "park-repeat: the hook exited non-zero"
  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0004 NM_STEP=watch NM_GATE=awaiting_approval \
    NM_BRANCH=fm/task-a NM_REPO="$home/wt" NM_REMINDER=1 NM_FINDINGS='watch-1 awaiting approval' \
    || fail "park-repeat: the reminder exited non-zero"

  count=$(grep -c 'nm-park-01KPARK0004' "$home/state/task-a.status")
  [ "$count" -eq 1 ] || fail "park-repeat: a re-notified park woke firstmate again ($count lines)"

  open=$(status_open_decisions "$home/state/task-a.status")
  assert_contains "$open" "nm-park-01KPARK0004" "park-repeat: the park left no open decision"

  run_park_hook "$home" "$home" \
    NM_EVENT=unpark NM_RUN_ID=01KPARK0004 NM_STEP=watch NM_BRANCH=fm/task-a \
    || fail "park-repeat: the unpark exited non-zero"

  open=$(status_open_decisions "$home/state/task-a.status")
  assert_not_contains "$open" "nm-park-01KPARK0004" "park-repeat: the unpark did not close the keyed decision"
  assert_absent "$home/state/.nm-park/01KPARK0004" "park-repeat: the unpark left the dedup marker behind"
  pass "a re-notified park is rate-limited and the unpark closes the keyed decision"
}

test_unmapped_park_still_wakes_home() {
  local home line
  home=$(make_home park-orphan)

  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0005 NM_STEP=watch NM_GATE=awaiting_approval \
    NM_BRANCH=someone/else NM_REPO=/somewhere/other-repo NM_REMINDER=0 \
    NM_FINDINGS='watch-1 CI failing' \
    || fail "park-orphan: the hook exited non-zero"

  assert_present "$home/state/nm-park.status" "park-orphan: an unattributable park woke nobody"
  line=$(last_status_line "$home/state/nm-park.status")
  assert_contains "$line" "/somewhere/other-repo" "park-orphan: the wake did not name the repo it came from"
  pass "a park that maps to no task still wakes the home through nm-park.status"
}

test_secondmate_park_wakes_its_own_home() {
  local home sub
  home=$(make_home park-main)
  sub="$TMP_ROOT/park-sub"
  mkdir -p "$sub/state"
  fm_write_secondmate_meta "$home/state/mate-1.meta" "$sub"
  fm_write_meta "$sub/state/task-s.meta" \
    "window=fm-task-s" "worktree=$sub/wt" "project=$sub/wt" "kind=ship" "mode=direct-PR"

  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0006 NM_STEP=watch NM_GATE=awaiting_approval \
    NM_BRANCH=fm/task-s NM_REPO="$sub/wt" NM_REMINDER=0 NM_FINDINGS='watch-1 CI failing' \
    || fail "park-sub: the hook exited non-zero"

  assert_present "$sub/state/task-s.status" "park-sub: the secondmate's own home was not woken"
  assert_absent "$home/state/nm-park.status" "park-sub: the park fell back to the main home instead of routing"
  pass "a park for a secondmate's task wakes that secondmate's home"
}

test_multiline_findings_collapse_to_one_line() {
  local home lines
  home=$(make_home park-multiline)

  run_park_hook "$home" "$home" \
    NM_EVENT=park NM_RUN_ID=01KPARK0007 NM_STEP=watch NM_GATE=awaiting_approval \
    NM_BRANCH=fm/task-a NM_REPO="$home/wt" NM_REMINDER=0 \
    NM_FINDINGS=$'watch-1 [blocking] first thread\nwatch-2 [blocking] second thread\nwatch-3 third' \
    || fail "park-multiline: the hook exited non-zero"

  lines=$(wc -l < "$home/state/task-a.status")
  [ "$lines" -eq 1 ] || fail "park-multiline: multi-line findings wrote $lines status lines, breaking the status fold"
  pass "multi-line findings collapse into one status line"
}

test_missing_run_id_fails_loudly() {
  local home rc=0 out
  home=$(make_home park-norun)

  out=$(env FM_HOME="$home" NM_EVENT=park NM_STEP=watch NM_BRANCH=fm/task-a "$PARK_WAKE" 2>&1) || rc=$?
  expect_code 2 "$rc" "park-norun: a hook call with no run id must fail loudly"
  assert_contains "$out" "NM_RUN_ID" "park-norun: the failure did not name the missing input"
  pass "a hook call with no run id fails loudly instead of silently dropping the wake"
}

test_arms_direct_pr_task
test_explicit_branch_wins
test_refuses_no_mistakes_mode
test_reports_missing_watch_command
test_pr_check_arms_watch_for_direct_pr
test_pr_check_skips_watch_for_pipeline_mode
test_failed_arm_does_not_fail_pr_record
test_no_watch_flag_records_without_arming
test_watch_park_opens_keyed_decision
test_recorded_run_id_beats_branch
test_crew_gate_park_waits_for_reminders
test_rate_limit_then_unpark_closes
test_unmapped_park_still_wakes_home
test_secondmate_park_wakes_its_own_home
test_multiline_findings_collapse_to_one_line
test_missing_run_id_fails_loudly
