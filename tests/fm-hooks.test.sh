#!/usr/bin/env bash
# Behavior tests for bin/fm-hooks-lib.sh (the post-worktree-create seam).
#
# These call fm_run_post_worktree_create_hook directly against a temp
# config/hooks dir and a temp worktree, asserting: no-op when no hook is
# installed, runs and receives the right args/env when present, skips the
# primary checkout, is non-fatal (returns 0, warns) when the hook errors, and
# is non-fatal when the hook hangs past FM_HOOK_TIMEOUT - including a hook
# that traps SIGTERM, which the kill-after grace still stops.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-hooks-lib.sh
# shellcheck disable=SC2153  # ROOT is exported by lib.sh, not a misspelling of root
. "$ROOT/bin/fm-hooks-lib.sh"

# fixture <root> echoes "<config-dir> <primary> <worktree>": an empty config dir,
# a primary checkout, and a separate worktree, all under <root>.
fixture() {
  local root=$1
  mkdir -p "$root/config" "$root/primary" "$root/wt"
  printf '%s %s %s\n' "$root/config" "$root/primary" "$root/wt"
}

# install_hook <config-dir> <body>: write an executable post-worktree-create hook.
install_hook() {
  mkdir -p "$1/hooks"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/hooks/post-worktree-create"
  chmod +x "$1/hooks/post-worktree-create"
}

test_noop_when_absent() {
  local root config primary wt out status
  root=$(fm_test_tmproot fm-hooks-absent)
  read -r config primary wt < <(fixture "$root")
  out=$(fm_run_post_worktree_create_hook "$config" "$primary" "$wt" alpha task-a1 ship 2>&1)
  status=$?
  expect_code 0 "$status" "absent hook must return 0"
  [ -z "$out" ] || fail "absent hook must be silent, got: $out"
  pass "no-op and silent when no hook is installed"
}

test_runs_with_args_and_env() {
  local root config primary wt marker
  root=$(fm_test_tmproot fm-hooks-run)
  read -r config primary wt < <(fixture "$root")
  marker="$root/marker"
  install_hook "$config" "printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \"\$1\" \"\$2\" \"\$3\" \"\$4\" \"\$FM_HOOK_WORKTREE\" \"\$FM_HOOK_PROJECT\" \"\$FM_HOOK_TASK_ID\" \"\$FM_HOOK_KIND\" > '$marker'"

  fm_run_post_worktree_create_hook "$config" "$primary" "$wt" alpha task-a1 scout \
    || fail "hook run should return 0"
  assert_present "$marker" "hook should have executed and written its marker"
  assert_grep "$wt|alpha|task-a1|scout|$wt|alpha|task-a1|scout" "$marker" \
    "hook must receive worktree/project/task/kind as both args and env"
  pass "runs the installed hook with matching positional args and environment"
}

test_skips_primary_checkout() {
  local root config primary wt marker out
  root=$(fm_test_tmproot fm-hooks-primary)
  read -r config primary wt < <(fixture "$root")
  marker="$root/marker"
  install_hook "$config" "touch '$marker'"

  # Point the "worktree" at the primary root: the backstop must refuse to run.
  out=$(fm_run_post_worktree_create_hook "$config" "$primary" "$primary" alpha task-a1 ship 2>&1) \
    || fail "primary-checkout skip should still return 0"
  assert_absent "$marker" "hook must NOT run against the primary checkout"
  assert_contains "$out" "primary checkout" "should warn that it skipped the primary checkout"
  pass "refuses to run when the worktree is the primary checkout"
}

test_nonfatal_on_hook_error() {
  local root config primary wt out status
  root=$(fm_test_tmproot fm-hooks-error)
  read -r config primary wt < <(fixture "$root")
  install_hook "$config" "echo boom >&2; exit 3"

  out=$(fm_run_post_worktree_create_hook "$config" "$primary" "$wt" alpha task-a1 ship 2>&1)
  status=$?
  expect_code 0 "$status" "a failing hook must not fail the spawn"
  assert_contains "$out" "exit 3" "should warn with the hook's exit status"
  pass "non-fatal when the hook errors: warns and returns 0"
}

test_nonfatal_on_hung_hook() {
  local root config primary wt out status
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    pass "SKIP: no timeout/gtimeout on PATH; hung-hook bound not testable here"
    return 0
  fi
  root=$(fm_test_tmproot fm-hooks-hang)
  read -r config primary wt < <(fixture "$root")
  install_hook "$config" "sleep 30"

  out=$(FM_HOOK_TIMEOUT=1 fm_run_post_worktree_create_hook "$config" "$primary" "$wt" alpha task-a1 ship 2>&1)
  status=$?
  expect_code 0 "$status" "a hung hook must not fail the spawn"
  assert_contains "$out" "timed out after 1s" "should warn that the hook timed out"
  pass "non-fatal when the hook hangs: killed at FM_HOOK_TIMEOUT, warns and returns 0"
}

test_nonfatal_on_term_ignoring_hook() {
  local root config primary wt out status
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    pass "SKIP: no timeout/gtimeout on PATH; kill-after grace not testable here"
    return 0
  fi
  root=$(fm_test_tmproot fm-hooks-term-ignore)
  read -r config primary wt < <(fixture "$root")
  # A hook that ignores SIGTERM (sleep inherits the ignored disposition), so
  # only the kill-after grace's SIGKILL can stop it; the sleep bounds the test
  # at 30s if that SIGKILL never comes.
  install_hook "$config" "trap '' TERM; sleep 30"

  out=$(FM_HOOK_TIMEOUT=1 fm_run_post_worktree_create_hook "$config" "$primary" "$wt" alpha task-a1 ship 2>&1)
  status=$?
  expect_code 0 "$status" "a TERM-ignoring hung hook must not fail the spawn"
  assert_contains "$out" "timed out after 1s" "should warn that the TERM-ignoring hook timed out"
  pass "non-fatal when the hook ignores SIGTERM: kill-after grace stops it, warns and returns 0"
}

# Fake-timeout tests: assert the invocation contract without needing a real
# timeout binary, so the kill-after grace stays covered on hosts that SKIP the
# real-binary tests above.
test_timeout_invoked_with_kill_after_grace() {
  local root config primary wt fakebin argslog out status
  root=$(fm_test_tmproot fm-hooks-fake-timeout)
  read -r config primary wt < <(fixture "$root")
  fakebin=$(fm_fakebin "$root")
  argslog="$root/timeout-args"
  cat > "$fakebin/timeout" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$argslog'
exit 137
SH
  chmod +x "$fakebin/timeout"
  install_hook "$config" "exit 0"

  out=$(PATH="$fakebin:$PATH" FM_HOOK_TIMEOUT=7 fm_run_post_worktree_create_hook "$config" "$primary" "$wt" alpha task-a1 ship 2>&1)
  status=$?
  expect_code 0 "$status" "a timeout-killed hook must not fail the spawn"
  assert_grep "-k 5 7 " "$argslog" "timeout must be invoked with the kill-after grace before the budget"
  assert_contains "$out" "timed out after 7s" "a kill-after SIGKILL (exit 137) must be reported as a timeout"
  pass "invokes timeout with '-k 5 <budget>' and treats exit 137 as a timeout"
}

test_noop_when_absent
test_runs_with_args_and_env
test_skips_primary_checkout
test_nonfatal_on_hook_error
test_nonfatal_on_hung_hook
test_nonfatal_on_term_ignoring_hook
test_timeout_invoked_with_kill_after_grace
