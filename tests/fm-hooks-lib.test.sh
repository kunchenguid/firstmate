#!/usr/bin/env bash
# Tests for bin/fm-hooks-lib.sh (the shared best-effort lifecycle hook runner)
# and its post-spawn / pr-ready / post-merge call sites (docs/extension-points.md).
#
# The contract under test: an absent or non-executable hook is a silent no-op,
# a present hook runs with the documented positional args and FM_HOOK_* env, a
# failing or timed-out hook is warned to stderr and never breaks the calling
# flow, and the runner invokes the hook under 'timeout -k 5 <budget>'.
#
# Matrix:
#   unit (fm_hook_run sourced directly):
#     (a) absent hook                      -> silent no-op, returns 0
#     (b) non-executable hook file         -> silent no-op, returns 0
#     (c) present hook                     -> runs with positional args + env pairs
#     (d) failing hook                     -> stderr warning, returns 0
#     (e) timeout invocation shape         -> 'timeout -k 5 <budget> <hook> <args>'
#     (f) hook timed out (exit 124)        -> "timed out" warning, returns 0
#   integration:
#     (j) fm-spawn fires post-spawn once per spawned task (batch included) with
#         the task's kind and meta path; a failing hook does not fail the spawn
#     (g) fm-pr-check fires pr-ready on first pr= record only; a failing hook
#         does not break fm-pr-check (exit 0, merge poll still armed)
#     (h) fm-pr-merge fires post-merge with the PR URL after a successful
#         merge; a failing hook does not fail the merge
#     (i) fm-merge-local fires post-merge with the merged branch as ref
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-hooks-lib.sh
. "$ROOT/bin/fm-hooks-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-hooks-lib-tests)

# Build a case dir with a config/hooks/ dir and a fakebin whose 'timeout' strips
# '-k 5 <budget>' and execs the hook directly, so unit runs behave identically
# whether or not the host has a real timeout/gtimeout. Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/config/hooks" "$case_dir/fakebin" "$case_dir/state"
  cat > "$case_dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
# fake timeout: drop '-k 5 <budget>' and exec the command directly.
shift 3
exec "$@"
SH
  chmod +x "$case_dir/fakebin/timeout"
  printf '%s\n' "$case_dir"
}

# Write an executable hook that logs its positional args and the given env var
# names to <case>/hook.log, then exits with the given status.
write_logging_hook() {
  local case_dir=$1 hook_name=$2 exit_status=$3
  shift 3
  local var lines=""
  for var in "$@"; do
    lines="$lines$var=\${$var:-unset}\n"
  done
  cat > "$case_dir/config/hooks/$hook_name" <<SH
#!/usr/bin/env bash
{
  printf 'args:%s\n' "\$*"
  printf "$lines"
} > '$case_dir/hook.log'
exit $exit_status
SH
  chmod +x "$case_dir/config/hooks/$hook_name"
}

test_absent_hook_is_silent_noop() {
  local case_dir rc out
  case_dir=$(make_case absent)
  set +e
  out=$(PATH="$case_dir/fakebin:$PATH" fm_hook_run "$case_dir/config" post-spawn -- task-x1 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "absent: fm_hook_run should return 0"
  [ -z "$out" ] || fail "absent: expected no output, got: $out"
  pass "an absent hook is a silent no-op"
}

test_non_executable_hook_is_silent_noop() {
  local case_dir rc out
  case_dir=$(make_case non-exec)
  printf '#!/bin/sh\nexit 1\n' > "$case_dir/config/hooks/post-spawn"
  set +e
  out=$(PATH="$case_dir/fakebin:$PATH" fm_hook_run "$case_dir/config" post-spawn -- task-x1 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "non-exec: fm_hook_run should return 0"
  [ -z "$out" ] || fail "non-exec: expected no output, got: $out"
  pass "a non-executable hook file is skipped silently"
}

test_present_hook_gets_args_and_env() {
  local case_dir rc
  case_dir=$(make_case args-env)
  write_logging_hook "$case_dir" post-spawn 0 FM_HOOK_TASK_ID FM_HOOK_META FM_HOOK_KIND
  set +e
  PATH="$case_dir/fakebin:$PATH" fm_hook_run "$case_dir/config" post-spawn \
    "FM_HOOK_TASK_ID=task-x1" "FM_HOOK_META=/some/meta" "FM_HOOK_KIND=ship" \
    -- task-x1 /some/meta 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "args-env: fm_hook_run should return 0"
  assert_grep 'args:task-x1 /some/meta' "$case_dir/hook.log" \
    "args-env: hook did not receive positional args"
  assert_grep 'FM_HOOK_TASK_ID=task-x1' "$case_dir/hook.log" "args-env: FM_HOOK_TASK_ID missing"
  assert_grep 'FM_HOOK_META=/some/meta' "$case_dir/hook.log" "args-env: FM_HOOK_META missing"
  assert_grep 'FM_HOOK_KIND=ship' "$case_dir/hook.log" "args-env: FM_HOOK_KIND missing"
  [ ! -s "$case_dir/stderr" ] || fail "args-env: unexpected stderr: $(cat "$case_dir/stderr")"
  pass "a present hook runs with positional args and FM_HOOK_* env"
}

test_failing_hook_warns_and_returns_zero() {
  local case_dir rc
  case_dir=$(make_case failing)
  write_logging_hook "$case_dir" post-spawn 3
  set +e
  PATH="$case_dir/fakebin:$PATH" fm_hook_run "$case_dir/config" post-spawn -- task-x1 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "failing: fm_hook_run should swallow the hook failure"
  assert_grep 'post-spawn hook failed (exit 3) for task-x1; continuing' "$case_dir/stderr" \
    "failing: expected a warn-and-continue stderr line"
  assert_present "$case_dir/hook.log" "failing: hook did not run at all"
  pass "a failing hook is warned to stderr and swallowed"
}

test_timeout_invocation_shape() {
  local case_dir rc
  case_dir=$(make_case timeout-shape)
  write_logging_hook "$case_dir" post-spawn 0
  # Recording fake: log how timeout was invoked without running the hook.
  cat > "$case_dir/fakebin/timeout" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$case_dir/timeout.log'
exit 0
SH
  chmod +x "$case_dir/fakebin/timeout"
  set +e
  PATH="$case_dir/fakebin:$PATH" fm_hook_run "$case_dir/config" post-spawn -- task-x1 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "timeout-shape: fm_hook_run should return 0"
  assert_grep "-k 5 120 $case_dir/config/hooks/post-spawn task-x1" "$case_dir/timeout.log" \
    "timeout-shape: hook was not run under 'timeout -k 5 120'"
  pass "the hook runs under 'timeout -k 5 <default budget>'"
}

test_timed_out_hook_warns_and_returns_zero() {
  local case_dir rc
  case_dir=$(make_case timed-out)
  write_logging_hook "$case_dir" post-spawn 0
  # Fake timeout reporting the hook exceeded its budget (GNU timeout exit 124).
  cat > "$case_dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
exit 124
SH
  chmod +x "$case_dir/fakebin/timeout"
  set +e
  FM_HOOK_TIMEOUT=7 PATH="$case_dir/fakebin:$PATH" \
    fm_hook_run "$case_dir/config" post-spawn -- task-x1 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "timed-out: fm_hook_run should swallow the timeout"
  assert_grep 'post-spawn hook timed out after 7s for task-x1; continuing' "$case_dir/stderr" \
    "timed-out: expected a timed-out stderr warning"
  pass "a timed-out hook is warned to stderr and swallowed"
}

test_pr_check_fires_pr_ready_on_first_record_only() {
  local case_dir rc
  case_dir=$(make_case pr-check)
  # Meta without worktree= so fm-pr-check skips the gh pr_head lookup.
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "kind=ship" "mode=no-mistakes"
  write_logging_hook "$case_dir" pr-ready 0 FM_HOOK_TASK_ID FM_HOOK_PR_URL

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "pr-check: first run failed"
  assert_grep 'args:task-x1 https://github.com/example/repo/pull/9' "$case_dir/hook.log" \
    "pr-check: pr-ready hook did not receive task id and PR URL"

  rm -f "$case_dir/hook.log"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "pr-check: re-run failed"
  assert_absent "$case_dir/hook.log" "pr-check: re-run re-fired the pr-ready hook"

  # A failing hook must not break fm-pr-check: fresh task, hook exits 1.
  fm_write_meta "$case_dir/state/task-y2.meta" \
    "window=fm-task-y2" "kind=ship" "mode=no-mistakes"
  write_logging_hook "$case_dir" pr-ready 1
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-y2 https://github.com/example/repo/pull/10 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "pr-check: a failing pr-ready hook must not fail fm-pr-check"
  assert_grep 'pr-ready hook failed' "$case_dir/stderr" \
    "pr-check: failing hook was not warned to stderr"
  assert_present "$case_dir/state/task-y2.check.sh" \
    "pr-check: merge poll was not armed despite the failing hook"
  pass "fm-pr-check fires pr-ready once per recorded PR and survives a failing hook"
}

test_pr_merge_fires_post_merge_after_merge() {
  local case_dir rc
  case_dir=$(make_case pr-merge)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "kind=ship" "mode=no-mistakes"
  fm_fake_exit0 "$case_dir/fakebin" gh-axi gh
  write_logging_hook "$case_dir" post-merge 1 FM_HOOK_TASK_ID FM_HOOK_REF

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "pr-merge: a failing post-merge hook must not fail the merge"
  assert_grep 'args:task-x1 https://github.com/example/repo/pull/9' "$case_dir/hook.log" \
    "pr-merge: post-merge hook did not receive task id and PR URL"
  assert_grep 'post-merge hook failed' "$case_dir/stderr" \
    "pr-merge: failing hook was not warned to stderr"
  pass "fm-pr-merge fires post-merge with the PR URL and survives a failing hook"
}

# Build a firstmate home that fm-spawn can launch into: a fake tmux pane whose
# reported path is the task worktree, a stubbed treehouse, a real isolated git
# worktree, a crew harness, and a brief per task id. Echoes the home dir.
make_spawn_home() {
  local case_dir=$1 home proj wt id
  shift
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state"
  # The hooks live in the case dir's config/, which the spawn runs point at.
  printf 'claude\n' > "$case_dir/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  fm_fake_exit0 "$case_dir/fakebin" treehouse
  fm_git_worktree "$proj" "$wt" wt-spawn
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$home"
}

run_spawn() {
  local case_dir=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$case_dir/wt" PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@"
}

# A hook that appends one line per invocation, so a batch's per-task firing is
# countable; write_logging_hook truncates and cannot show repeat calls.
write_appending_hook() {
  local case_dir=$1 hook_name=$2 exit_status=$3
  cat > "$case_dir/config/hooks/$hook_name" <<SH
#!/usr/bin/env bash
printf 'fired:%s|%s|%s\n' "\$1" "\${FM_HOOK_KIND:-unset}" "\${FM_HOOK_META:-unset}" \
  >> '$case_dir/hook.log'
exit $exit_status
SH
  chmod +x "$case_dir/config/hooks/$hook_name"
}

test_spawn_fires_post_spawn_per_task_and_survives_failure() {
  local case_dir home rc
  case_dir=$(make_case spawn)
  home=$(make_spawn_home "$case_dir" spawn-hook-a-z1 spawn-hook-b-z2)
  # The hook fails, so this also pins that a failing post-spawn hook never fails
  # the spawn: both pairs must still be reported as spawned and the batch exit 0.
  write_appending_hook "$case_dir" post-spawn 1

  set +e
  run_spawn "$case_dir" "$home" \
    "spawn-hook-a-z1=$case_dir/project" "spawn-hook-b-z2=$case_dir/project" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn: a failing post-spawn hook must not fail the spawn: $(cat "$case_dir/stderr")"
  assert_grep "fired:spawn-hook-a-z1|ship|$home/state/spawn-hook-a-z1.meta" "$case_dir/hook.log" \
    "spawn: post-spawn did not fire for the first task with its kind and meta path"
  assert_grep "fired:spawn-hook-b-z2|ship|$home/state/spawn-hook-b-z2.meta" "$case_dir/hook.log" \
    "spawn: post-spawn did not fire for the second task of the batch"
  expect_code 2 "$(grep -c '^fired:' "$case_dir/hook.log")" \
    "spawn: post-spawn should fire exactly once per spawned task"
  assert_grep 'post-spawn hook failed' "$case_dir/stderr" \
    "spawn: failing hook was not warned to stderr"
  assert_grep 'spawned spawn-hook-b-z2' "$case_dir/stdout" \
    "spawn: the spawn did not complete despite the failing hook"
  pass "fm-spawn fires post-spawn once per spawned task and survives a failing hook"
}

test_merge_local_fires_post_merge_with_branch_ref() {
  local case_dir
  case_dir=$(make_case merge-local)
  # Project repo on its default branch, with fm/task-x1 one commit ahead via a
  # linked worktree, so the local-only fast-forward succeeds.
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  printf 'work\n' > "$case_dir/wt/work.txt"
  git -C "$case_dir/wt" add work.txt
  git -C "$case_dir/wt" commit -qm "task work"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=local-only"
  write_logging_hook "$case_dir" post-merge 0 FM_HOOK_TASK_ID FM_HOOK_REF

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$MERGE_LOCAL" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "merge-local: fm-merge-local failed: $(cat "$case_dir/stderr")"
  assert_grep 'args:task-x1 fm/task-x1' "$case_dir/hook.log" \
    "merge-local: post-merge hook did not receive task id and merged branch"
  pass "fm-merge-local fires post-merge with the merged branch as ref"
}

test_absent_hook_is_silent_noop
test_non_executable_hook_is_silent_noop
test_present_hook_gets_args_and_env
test_failing_hook_warns_and_returns_zero
test_timeout_invocation_shape
test_timed_out_hook_warns_and_returns_zero
test_spawn_fires_post_spawn_per_task_and_survives_failure
test_pr_check_fires_pr_ready_on_first_record_only
test_pr_merge_fires_post_merge_after_merge
test_merge_local_fires_post_merge_with_branch_ref
