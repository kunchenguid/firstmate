#!/usr/bin/env bash
# Tests for bin/fm-hooks-lib.sh (the shared best-effort lifecycle hook runner)
# and its post-spawn / pr-ready / post-merge call sites (docs/extension-points.md).
#
# The contract under test: an absent or non-executable hook is a silent no-op,
# a present hook runs with the documented positional args and FM_HOOK_* env, a
# failing or timed-out hook is warned to stderr and never breaks the calling
# flow, the hook is always time-bounded (under 'timeout -k 5 <budget>' when a
# timeout binary exists, and under the shell-native watchdog when none does),
# and no hook - not even one that leaves a background descendant behind - can
# stall a caller reading the calling script's output, because a hook never
# inherits the caller's stdout or stderr.
#
# Matrix:
#   unit (fm_hook_run sourced directly):
#     (a) absent hook                      -> silent no-op, returns 0
#     (b) non-executable hook file         -> silent no-op, returns 0
#     (c) present hook                     -> runs with positional args + env pairs
#     (d) failing hook                     -> stderr warning, returns 0
#     (e) timeout invocation shape         -> 'timeout -k 5 <budget> <hook> <args>'
#     (f) hook timed out (exit 124)        -> "timed out" warning, returns 0
#     (k) no timeout binary, hanging hook  -> shell watchdog kills it, returns 0
#     (l) no timeout binary, fast hook     -> completes normally, not killed
#     (m) no timeout binary, hook blocked in a descendant -> the whole process
#         group is killed, so no orphan survives holding the caller's stdout
#     (n) hook exits clean but leaves a background child -> unreachable by any
#         kill, yet the caller's command substitution still returns at once, on
#         the timeout-binary and watchdog paths and on the unbounded
#         FM_HOOK_TIMEOUT=0 path with and without a timeout binary on PATH
#     (o) hook stderr -> relayed to firstmate's stderr, and its temp file is
#         already unlinked, so nothing is left behind in TMPDIR
#     (p) no mktemp, planted symlink at the fallback errfile name -> skipped
#         rather than written through
#     (q) chatty hook -> stderr relayed only up to FM_HOOK_STDERR_MAX_BYTES,
#         with the truncation warned rather than dumped whole into the caller,
#         and that cap counts bytes even when the hook's stderr is multibyte
#     (t) the same cap bounds what reaches DISK, so a looping hook - or a
#         descendant still writing after it - cannot fill TMPDIR
#   integration:
#     (j) fm-spawn fires post-spawn once per spawned task (batch included) with
#         the task's kind and meta path; a failing hook does not fail the spawn
#     (g) fm-pr-check fires pr-ready on first pr= record only; a failing hook
#         does not break fm-pr-check (exit 0, merge poll still armed)
#     (u) with no pr-ready hook installed - every home by default, since firstmate
#         ships none - fm-pr-check records no pr_ready_hook= marker at all
#     (r) fm-pr-merge, whose nested fm-pr-check does the first pr= record, fires
#         pr-ready exactly once and only after the merge, so a slow hook cannot
#         delay the merge; a re-merge of a recorded PR does not re-fire it
#     (s) a merge that FAILS after that record still fires pr-ready exactly once
#         (never post-merge), still propagates the failure, and the retried merge
#         does not re-fire pr-ready
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

# A PATH that holds neither 'timeout' nor 'gtimeout', so fm_hook_run must fall
# back to its shell-native watchdog - the stock macOS shape. Only the binaries
# the runner and the test hooks actually need are linked in. Echoes the dir.
make_no_timeout_path() {
  local case_dir=$1 minbin bin src
  minbin="$case_dir/minbin"
  mkdir -p "$minbin"
  for bin in bash env sleep mktemp mkfifo rmdir head cat rm; do
    src=$(command -v "$bin") || fail "watchdog: '$bin' not found on PATH"
    ln -sf "$src" "$minbin/$bin"
  done
  printf '%s\n' "$minbin"
}

test_watchdog_kills_a_hanging_hook_without_timeout_binary() {
  local case_dir minbin rc started
  case_dir=$(make_case watchdog-hang)
  minbin=$(make_no_timeout_path "$case_dir")
  cat > "$case_dir/config/hooks/post-spawn" <<SH
#!/usr/bin/env bash
printf 'started\n' > '$case_dir/hook.log'
sleep 60
printf 'finished\n' >> '$case_dir/hook.log'
SH
  chmod +x "$case_dir/config/hooks/post-spawn"

  started=$SECONDS
  set +e
  FM_HOOK_TIMEOUT=1 PATH="$minbin" \
    fm_hook_run "$case_dir/config" post-spawn -- task-x1 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "watchdog: fm_hook_run should swallow the watchdog timeout"
  [ $((SECONDS - started)) -lt 30 ] \
    || fail "watchdog: the hanging hook was not bounded (took $((SECONDS - started))s)"
  assert_grep 'started' "$case_dir/hook.log" "watchdog: the hook never ran"
  grep -q 'finished' "$case_dir/hook.log" \
    && fail "watchdog: the hanging hook ran to completion instead of being killed"
  assert_grep 'post-spawn hook timed out after 1s for task-x1; continuing' "$case_dir/stderr" \
    "watchdog: expected a timed-out stderr warning"
  pass "with no timeout binary, the shell watchdog kills a hanging hook and the caller continues"
}

test_watchdog_lets_a_fast_hook_finish_without_timeout_binary() {
  local case_dir minbin rc
  case_dir=$(make_case watchdog-fast)
  minbin=$(make_no_timeout_path "$case_dir")
  write_logging_hook "$case_dir" post-spawn 0 FM_HOOK_TASK_ID
  set +e
  FM_HOOK_TIMEOUT=30 PATH="$minbin" \
    fm_hook_run "$case_dir/config" post-spawn "FM_HOOK_TASK_ID=task-x1" -- task-x1 \
    2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "watchdog-fast: fm_hook_run should return 0"
  assert_grep 'args:task-x1' "$case_dir/hook.log" "watchdog-fast: hook did not receive its args"
  assert_grep 'FM_HOOK_TASK_ID=task-x1' "$case_dir/hook.log" "watchdog-fast: FM_HOOK_TASK_ID missing"
  [ ! -s "$case_dir/stderr" ] \
    || fail "watchdog-fast: a hook well inside its budget must not warn: $(cat "$case_dir/stderr")"
  pass "with no timeout binary, a hook inside its budget completes normally"
}

test_watchdog_kills_descendants_and_never_stalls_the_caller() {
  local case_dir minbin rc out started gc_pid waited=0
  case_dir=$(make_case watchdog-descendant)
  minbin=$(make_no_timeout_path "$case_dir")
  # A hook blocked in a descendant: killing only the hook itself would orphan the
  # 'sleep', which keeps the caller's stdout pipe open and stalls the command
  # substitution below forever.
  cat > "$case_dir/config/hooks/post-spawn" <<SH
#!/usr/bin/env bash
sleep 60 &
printf '%s\n' "\$!" > '$case_dir/descendant.pid'
wait
SH
  chmod +x "$case_dir/config/hooks/post-spawn"

  started=$SECONDS
  set +e
  out=$(FM_HOOK_TIMEOUT=1 PATH="$minbin" \
    fm_hook_run "$case_dir/config" post-spawn -- task-x1 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "descendant: fm_hook_run must still return 0"
  [ $((SECONDS - started)) -lt 30 ] \
    || fail "descendant: the caller was stalled by an orphaned descendant ($((SECONDS - started))s)"
  case "$out" in
    *"post-spawn hook timed out after 1s for task-x1; continuing"*) ;;
    *) fail "descendant: expected a timed-out warning, got: $out" ;;
  esac
  gc_pid=$(cat "$case_dir/descendant.pid")
  while kill -0 "$gc_pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "$gc_pid" 2>/dev/null \
    && fail "descendant: the hook's descendant ($gc_pid) survived the watchdog"
  pass "the watchdog kills the hook's whole process group and never stalls the caller"
}

# A hook that exits cleanly but leaves a background child behind: no timeout and
# no process-group kill can reach that orphan, so the only thing keeping it from
# stalling the caller's command substitution is that the hook never inherited the
# caller's stdout or stderr. Asserted on every path, since each runs the hook.
test_orphaned_descendant_never_stalls_the_caller() {
  local case_dir minbin rc out started elapsed path budget label
  case_dir=$(make_case orphan)
  minbin=$(make_no_timeout_path "$case_dir")
  cat > "$case_dir/config/hooks/post-spawn" <<SH
#!/usr/bin/env bash
# Survives the hook: nothing firstmate can signal, and it would hold any
# inherited pipe open for its whole life.
sleep 30 &
printf '%s\n' "\$!" >> '$case_dir/orphan.pid'
exit 0
SH
  chmod +x "$case_dir/config/hooks/post-spawn"

  # timeout-binary path, shell-watchdog path, and the unbounded FM_HOOK_TIMEOUT=0
  # path (which has no bound at all, so only detached stdio protects the caller).
  # Unbounded is asserted both with and without a timeout binary on PATH, because
  # "no time limit" is firstmate's own branch, not a timeout binary's semantics.
  for label in timeout-binary watchdog unbounded unbounded-with-timeout-binary; do
    case $label in
      timeout-binary) path="$case_dir/fakebin:$PATH"; budget=60 ;;
      watchdog) path="$minbin"; budget=60 ;;
      unbounded) path="$minbin"; budget=0 ;;
      unbounded-with-timeout-binary) path="$case_dir/fakebin:$PATH"; budget=0 ;;
    esac
    started=$SECONDS
    set +e
    out=$(FM_HOOK_TIMEOUT=$budget PATH="$path" \
      fm_hook_run "$case_dir/config" post-spawn -- task-x1 2>&1)
    rc=$?
    elapsed=$((SECONDS - started))
    set -e
    expect_code 0 "$rc" "orphan/$label: fm_hook_run should return 0"
    [ "$elapsed" -lt 10 ] \
      || fail "orphan/$label: an orphaned descendant stalled the caller (${elapsed}s)"
    [ -z "$out" ] \
      || fail "orphan/$label: a clean hook must produce no output, got: $out"
  done

  local orphan
  while read -r orphan; do
    kill "$orphan" 2>/dev/null || true
  done < "$case_dir/orphan.pid"
  pass "a hook that leaves a background descendant behind never stalls the caller"
}

# The captured stderr reaches the operator, and neither the file it was captured
# in nor the FIFO it was carried through is still there by the time the hook is
# done - firstmate unlinks both as soon as it and the cap writer hold their
# descriptors, so an interrupt mid-hook can leave nothing behind in TMPDIR.
test_hook_stderr_is_relayed_and_leaves_no_tempfile() {
  local case_dir rc tmp leftovers
  case_dir=$(make_case errfile)
  tmp="$case_dir/tmp"
  mkdir -p "$tmp"
  printf '#!/usr/bin/env bash\nprintf %%s\\\\n "hook diag" >&2\nexit 0\n' \
    > "$case_dir/config/hooks/post-spawn"
  chmod +x "$case_dir/config/hooks/post-spawn"
  set +e
  TMPDIR="$tmp" PATH="$case_dir/fakebin:$PATH" \
    fm_hook_run "$case_dir/config" post-spawn -- task-x1 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "errfile: fm_hook_run should return 0"
  assert_grep 'hook diag' "$case_dir/stderr" \
    "errfile: the hook's captured stderr was not relayed to firstmate's stderr"
  leftovers=$(find "$tmp" -name 'fm-hook-err.*' | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] \
    || fail "errfile: a hook stderr temp file was left behind in TMPDIR"
  leftovers=$(find "$tmp" -name 'fm-hook-cap.*' | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] \
    || fail "errfile: a hook stderr FIFO was left behind in TMPDIR"
  pass "hook stderr is relayed and its temp file never outlives the hook"
}

# Without mktemp the runner falls back to a pid-keyed name in TMPDIR, which on a
# shared /tmp an attacker can pre-plant as a symlink. The fallback creates under
# 'set -C', so it skips the planted name rather than truncating what it points at.
test_errfile_fallback_refuses_a_planted_symlink() {
  local case_dir minbin tmp victim rc
  case_dir=$(make_case errfile-symlink)
  minbin=$(make_no_timeout_path "$case_dir")
  rm -f "$minbin/mktemp"
  tmp="$case_dir/tmp"
  mkdir -p "$tmp"
  victim="$case_dir/victim"
  printf 'precious\n' > "$victim"
  ln -s "$victim" "$tmp/fm-hook-err.$$.0"
  printf '#!/usr/bin/env bash\nprintf %%s\\\\n "hook diag" >&2\nexit 0\n' \
    > "$case_dir/config/hooks/post-spawn"
  chmod +x "$case_dir/config/hooks/post-spawn"
  set +e
  TMPDIR="$tmp" PATH="$minbin" \
    fm_hook_run "$case_dir/config" post-spawn -- task-x1 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "errfile-symlink: fm_hook_run should return 0"
  assert_grep 'precious' "$victim" \
    "errfile-symlink: the planted symlink's target was clobbered"
  assert_grep 'hook diag' "$case_dir/stderr" \
    "errfile-symlink: the hook's stderr was not relayed via the next candidate"
  pass "the no-mktemp errfile fallback never writes through a planted symlink"
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

# fm-pr-merge records pr= through fm-pr-check before merging, so a pr-ready hook
# fired there would sit between the recording and the merge and could hold the
# merge for the whole hook budget. It is deferred to after the merge instead, and
# still fires exactly once per (task, PR URL) - never twice, never zero times.
test_pr_merge_defers_pr_ready_until_after_the_merge() {
  local case_dir order
  case_dir=$(make_case pr-merge-pr-ready)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "kind=ship" "mode=no-mistakes"
  fm_fake_exit0 "$case_dir/fakebin" gh
  # A merge fake and a pr-ready hook that append to one log, so the log's order
  # is the real order: a hook firing before the merge would show up first.
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf 'merged:%s\n' "\$*" >> '$case_dir/hook.log'
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  cat > "$case_dir/config/hooks/pr-ready" <<SH
#!/usr/bin/env bash
sleep 2
printf 'pr-ready:%s|%s\n' "\$1" "\$2" >> '$case_dir/hook.log'
exit 0
SH
  chmod +x "$case_dir/config/hooks/pr-ready"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "pr-merge/pr-ready: merge failed: $(cat "$case_dir/stderr")"

  assert_grep 'pr-ready:task-x1|https://github.com/example/repo/pull/9' "$case_dir/hook.log" \
    "pr-merge/pr-ready: the deferred pr-ready hook never fired"
  expect_code 1 "$(grep -c '^pr-ready:' "$case_dir/hook.log")" \
    "pr-merge/pr-ready: pr-ready must fire exactly once per (task, PR URL)"
  order=$(grep -n -e '^merged:' -e '^pr-ready:' "$case_dir/hook.log" | cut -d: -f2 | tr '\n' ' ')
  case "$order" in
    'merged pr-ready '*) ;;
    *) fail "pr-merge/pr-ready: the slow hook delayed the merge (order: $order)" ;;
  esac

  # A second merge of an already-recorded PR must not re-fire it.
  rm -f "$case_dir/hook.log"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "pr-merge/pr-ready: re-merge failed: $(cat "$case_dir/stderr")"
  grep -q '^pr-ready:' "$case_dir/hook.log" \
    && fail "pr-merge/pr-ready: an already-recorded PR re-fired the pr-ready hook"
  pass "fm-pr-merge fires pr-ready once, after the merge, and never re-fires it"
}

# A chatty or looping hook must not dump an unbounded volume into a caller that
# captures firstmate's output (bin/fm-bootstrap.sh reads fm-spawn.sh that way).
test_hook_stderr_relay_is_bounded() {
  local case_dir rc bytes
  case_dir=$(make_case errfile-cap)
  cat > "$case_dir/config/hooks/post-spawn" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ]; do
  printf 'noise-%s-%s\n' "$i" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >&2
  i=$((i + 1))
done
exit 0
SH
  chmod +x "$case_dir/config/hooks/post-spawn"
  set +e
  FM_HOOK_STDERR_MAX_BYTES=512 PATH="$case_dir/fakebin:$PATH" \
    fm_hook_run "$case_dir/config" post-spawn -- task-x1 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "errfile-cap: fm_hook_run should return 0"
  assert_grep 'noise-0-' "$case_dir/stderr" "errfile-cap: the relayed prefix is missing"
  assert_grep 'post-spawn hook stderr truncated after 512 bytes for task-x1' "$case_dir/stderr" \
    "errfile-cap: the truncation was not warned"
  bytes=$(wc -c < "$case_dir/stderr" | tr -d ' ')
  [ "$bytes" -lt 1024 ] \
    || fail "errfile-cap: relayed $bytes bytes despite a 512-byte cap"
  pass "a chatty hook's stderr is relayed as a bounded prefix and the truncation is warned"
}

# The cap is a BYTE cap: bash's 'read -N' and ${#var} count characters, so a
# multibyte hook would relay several times the cap in a UTF-8 locale.
test_hook_stderr_relay_cap_counts_bytes() {
  local case_dir rc bytes
  case_dir=$(make_case errfile-cap-multibyte)
  cat > "$case_dir/config/hooks/post-spawn" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ]; do
  printf '🚢🚢🚢🚢🚢🚢🚢🚢🚢🚢\n' >&2
  i=$((i + 1))
done
exit 0
SH
  chmod +x "$case_dir/config/hooks/post-spawn"
  set +e
  LC_ALL=en_US.UTF-8 FM_HOOK_STDERR_MAX_BYTES=512 PATH="$case_dir/fakebin:$PATH" \
    fm_hook_run "$case_dir/config" post-spawn -- task-x1 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "errfile-cap-multibyte: fm_hook_run should return 0"
  assert_grep 'post-spawn hook stderr truncated after 512 bytes for task-x1' "$case_dir/stderr" \
    "errfile-cap-multibyte: the truncation was not warned"
  bytes=$(wc -c < "$case_dir/stderr" | tr -d ' ')
  [ "$bytes" -lt 1024 ] \
    || fail "errfile-cap-multibyte: relayed $bytes bytes despite a 512-byte cap"
  pass "the hook stderr cap counts bytes, not characters, on multibyte output"
}

# The relay cap bounds what the operator sees; this bounds what reaches DISK. The
# capture file is unlinked while the hook runs, so the bound is asserted on the
# writer that owns it: a hook that loops, or a descendant that keeps writing after
# the hook is gone, feeds this and must never grow the file past the cap.
test_hook_stderr_on_disk_capture_is_bounded() {
  local case_dir sink bytes
  case_dir=$(make_case errfile-disk-cap)
  sink="$case_dir/captured"
  # 64 KiB of hook stderr into a 512-byte cap. The extra byte the writer keeps is
  # what tells the relay the stream was truncated rather than exactly cap-sized.
  {
    yes 'noise-noise-noise-noise-noise-noise-noise' 2>/dev/null | head -c 65536 |
      fm_hook_cap_writer 512
  } 8> "$sink"
  bytes=$(wc -c < "$sink" | tr -d ' ')
  [ "$bytes" -le 513 ] \
    || fail "errfile-disk-cap: $bytes bytes reached disk despite a 512-byte cap"
  [ "$bytes" -ge 512 ] \
    || fail "errfile-disk-cap: only $bytes bytes reached disk; the prefix was lost"
  pass "a runaway hook's stderr is capped on disk, not just in the relay"
}

# firstmate ships no hooks, so the common case is a home with none. Such a home's
# task meta must be exactly what it was before hook points existed - the marker
# records a fire, and with no hook installed there is no fire to record.
test_pr_check_records_no_marker_without_a_pr_ready_hook() {
  local case_dir before after
  case_dir=$(make_case pr-check-no-hook)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "kind=ship" "mode=no-mistakes"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "pr-check/no-hook: run failed"
  grep -q '^pr_ready_hook=' "$case_dir/state/task-x1.meta" \
    && fail "pr-check/no-hook: a hook fire was recorded though no pr-ready hook is installed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "pr-check/no-hook: the PR was not recorded"

  # And a re-run leaves that meta byte-identical, as it did before hook points.
  before=$(cat "$case_dir/state/task-x1.meta")
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "pr-check/no-hook: re-run failed"
  after=$(cat "$case_dir/state/task-x1.meta")
  [ "$before" = "$after" ] \
    || fail "pr-check/no-hook: the re-run changed the meta of a hookless home"

  # Installing the hook then makes the marker appear and gate the re-fire.
  write_logging_hook "$case_dir" pr-ready 0 FM_HOOK_TASK_ID FM_HOOK_PR_URL
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "pr-check/no-hook: hooked run failed"
  assert_present "$case_dir/hook.log" "pr-check/no-hook: an installed pr-ready hook did not fire"
  assert_grep 'pr_ready_hook=https://github.com/example/repo/pull/9' \
    "$case_dir/state/task-x1.meta" "pr-check/no-hook: the fire was not recorded"
  rm -f "$case_dir/hook.log"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "pr-check/no-hook: hooked re-run failed"
  assert_absent "$case_dir/hook.log" "pr-check/no-hook: the recorded fire did not gate the re-run"
  pass "a home with no pr-ready hook records no hook marker in a task's meta"
}

# The merge can fail after fm-pr-check has durably recorded pr=. pr-ready belongs
# to that recording, so it must still fire - exactly once - and the merge failure
# must still propagate.
test_pr_merge_fires_pr_ready_when_the_merge_fails() {
  local case_dir rc
  case_dir=$(make_case pr-merge-failed)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "kind=ship" "mode=no-mistakes"
  fm_fake_exit0 "$case_dir/fakebin" gh
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "merge failed: protected branch" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  local hook
  for hook in pr-ready post-merge; do
    cat > "$case_dir/config/hooks/$hook" <<SH
#!/usr/bin/env bash
printf '%s:%s|%s\n' "$hook" "\$1" "\$2" >> '$case_dir/hook.log'
exit 0
SH
    chmod +x "$case_dir/config/hooks/$hook"
  done

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pr-merge/failed: the merge failure must still propagate"
  assert_grep 'pr-ready:task-x1|https://github.com/example/repo/pull/9' "$case_dir/hook.log" \
    "pr-merge/failed: pr-ready did not fire after a failed merge"
  grep -q '^post-merge:' "$case_dir/hook.log" \
    && fail "pr-merge/failed: post-merge fired despite the merge failing"

  # The retried merge must not re-fire pr-ready, and must fire post-merge once.
  rm -f "$case_dir/hook.log"
  fm_fake_exit0 "$case_dir/fakebin" gh-axi
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "pr-merge/failed: the retried merge failed: $(cat "$case_dir/stderr")"
  grep -q '^pr-ready:' "$case_dir/hook.log" \
    && fail "pr-merge/failed: the retried merge re-fired pr-ready"
  assert_grep 'post-merge:task-x1|https://github.com/example/repo/pull/9' "$case_dir/hook.log" \
    "pr-merge/failed: the retried merge did not fire post-merge"
  pass "fm-pr-merge fires pr-ready exactly once even when the merge fails"
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
test_watchdog_kills_a_hanging_hook_without_timeout_binary
test_watchdog_lets_a_fast_hook_finish_without_timeout_binary
test_watchdog_kills_descendants_and_never_stalls_the_caller
test_orphaned_descendant_never_stalls_the_caller
test_hook_stderr_is_relayed_and_leaves_no_tempfile
test_hook_stderr_relay_is_bounded
test_hook_stderr_relay_cap_counts_bytes
test_hook_stderr_on_disk_capture_is_bounded
test_errfile_fallback_refuses_a_planted_symlink
test_spawn_fires_post_spawn_per_task_and_survives_failure
test_pr_check_fires_pr_ready_on_first_record_only
test_pr_check_records_no_marker_without_a_pr_ready_hook
test_pr_merge_defers_pr_ready_until_after_the_merge
test_pr_merge_fires_pr_ready_when_the_merge_fails
test_pr_merge_fires_post_merge_after_merge
test_merge_local_fires_post_merge_with_branch_ref
