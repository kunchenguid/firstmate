#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the fail-closed browser-session guard
# (docs/browser-session-isolation.md).
#
# bin/fm-browser-session-guard.sh is the single owner of the refuse/allow
# decision, and bin/shims/chrome-devtools-axi is the symlink that puts that
# decision in front of every spawned agent's browser command. This suite proves
# the refusal matrix through both entry shapes, the scope rules that keep
# legitimate shared use working, the shim's transparent pass-through and
# anti-recursion behavior, and the spawn wiring that binds a task's own session
# inside the launch command rather than only beside it. No agent is spawned and
# no real browser is launched; a stub stands in for chrome-devtools-axi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-browser-session-guard)

GUARD="$ROOT/bin/fm-browser-session-guard.sh"
SHIM="$ROOT/bin/shims/chrome-devtools-axi"
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$(dirname "$PYTHON_BIN"):/usr/bin:/bin:/usr/sbin:/sbin}

# A stub chrome-devtools-axi that records that it ran and with which session, so
# "refused" and "ran shared" are distinguishable observables rather than exit
# codes alone.
STUB_BIN="$TMP_ROOT/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/chrome-devtools-axi" <<'EOF'
#!/bin/sh
printf 'RAN session=%s args=%s\n' "${CHROME_DEVTOOLS_AXI_SESSION-unset}" "$*"
EOF
chmod +x "$STUB_BIN/chrome-devtools-axi"

# Any directory that is not a firstmate primary home stands in for a task
# worktree: that is exactly the guard's enforcing scope.
TASK_CWD="$TMP_ROOT/task-worktree"
mkdir -p "$TASK_CWD"

# Run a guard entry point from <cwd>. <session> is the literal
# CHROME_DEVTOOLS_AXI_SESSION value, or "unset" to remove it entirely; <extra>
# is an additional VAR=VALUE to set, or "-" for none. Returns the invocation's
# own exit code and leaves its combined output in RUN_OUT, so a caller can
# assert on both without losing the status to a command substitution's subshell.
RUN_OUT=""
run_guard() {
  local cwd=$1 session=$2 extra=$3 entry=$4 rc=0
  shift 4
  # env requires every -u option before the first VAR=VALUE assignment.
  local -a envargs=(env)
  [ "$session" != unset ] || envargs+=(-u CHROME_DEVTOOLS_AXI_SESSION)
  envargs+=("PATH=$STUB_BIN:$PATH")
  [ "$session" = unset ] || envargs+=("CHROME_DEVTOOLS_AXI_SESSION=$session")
  [ "$extra" = - ] || envargs+=("$extra")
  RUN_OUT=$(cd "$cwd" && "${envargs[@]}" "$entry" "$@" 2>&1) || rc=$?
  return "$rc"
}

# --- the refusal matrix -----------------------------------------------------

test_refuses_unset_session() {
  local code=0
  run_guard "$TASK_CWD" unset - "$SHIM" open https://example.invalid || code=$?
  expect_code 1 "$code" "an unset session must refuse"
  assert_not_contains "$RUN_OUT" "RAN session=" \
    "the real tool must not run without a per-task session"
  assert_contains "$RUN_OUT" "REFUSED" "the refusal must be loud"
  assert_contains "$RUN_OUT" "CHROME_DEVTOOLS_AXI_SESSION" \
    "the refusal must name the missing isolation"
  pass "an unset session refuses instead of sharing the default browser"
}

test_refuses_explicit_default_session() {
  local code=0
  run_guard "$TASK_CWD" default - "$SHIM" screenshot shot.png || code=$?
  expect_code 1 "$code" "the shared default session must refuse"
  assert_not_contains "$RUN_OUT" "RAN session=" "the real tool must not run on default"
  pass "the shared \"default\" session name refuses"
}

test_refuses_blank_session() {
  local code=0
  run_guard "$TASK_CWD" "   " - "$SHIM" snapshot || code=$?
  expect_code 1 "$code" "a blank session must refuse"
  assert_not_contains "$RUN_OUT" "RAN session=" "the real tool must not run blank"
  pass "a blank session name refuses"
}

test_allows_isolated_session() {
  local code=0
  run_guard "$TASK_CWD" my-task-id - "$SHIM" open https://example.invalid || code=$?
  expect_code 0 "$code" "an isolated session must be allowed"
  assert_contains "$RUN_OUT" "RAN session=my-task-id" \
    "a task with its own session must be unaffected"
  assert_contains "$RUN_OUT" "args=open https://example.invalid" \
    "arguments must reach the real tool untouched"
  pass "a task with its own session runs unaffected"
}

test_allows_sessionless_subcommands() {
  local sub code
  for sub in --help -v --version setup; do
    code=0
    run_guard "$TASK_CWD" unset - "$SHIM" "$sub" || code=$?
    expect_code 0 "$code" "$sub must not need isolation"
    assert_contains "$RUN_OUT" "RAN session=unset" "$sub must reach the real tool"
  done
  pass "help, version, and setup do not require a per-task session"
}

# --- scope: legitimate shared use keeps working -----------------------------

test_inert_in_primary_home() {
  local home=$TMP_ROOT/primary code=0 home_shim
  mkdir -p "$home/bin/shims" "$home/state"
  git init -q "$home"
  : > "$home/AGENTS.md"
  cp "$GUARD" "$ROOT/bin/fm-primary-scope-lib.sh" "$home/bin/"
  chmod +x "$home/bin/fm-browser-session-guard.sh"
  ln -sfn ../fm-browser-session-guard.sh "$home/bin/shims/chrome-devtools-axi"
  home_shim="$home/bin/shims/chrome-devtools-axi"

  run_guard "$home" unset - "$home_shim" open https://example.invalid || code=$?
  expect_code 0 "$code" "a firstmate primary home must stay usable"
  assert_contains "$RUN_OUT" "RAN session=unset" \
    "firstmate's own session may use the shared browser"
  pass "the guard is inert in a firstmate primary home"

  # The same home's linked task worktree is a task-scoped context and must
  # still be enforced.
  git -C "$home" add -A >/dev/null 2>&1
  git -C "$home" commit -qm init >/dev/null 2>&1
  git -C "$home" worktree add -q "$TMP_ROOT/linked" -b linked >/dev/null 2>&1
  code=0
  run_guard "$TMP_ROOT/linked" unset - "$home_shim" open https://example.invalid || code=$?
  expect_code 1 "$code" "a linked task worktree must be enforced"
  assert_not_contains "$RUN_OUT" "RAN session=" \
    "a task worktree must not reach the shared browser"
  pass "the guard still enforces in that home's linked task worktree"
}

test_declared_shared_use_is_allowed() {
  local code=0
  run_guard "$TASK_CWD" unset FM_BROWSER_SHARED_SESSION_OK=1 \
    "$SHIM" open https://example.invalid || code=$?
  expect_code 0 "$code" "declared shared use must be allowed"
  assert_contains "$RUN_OUT" "RAN session=unset" \
    "an explicit shared-session declaration must still work"
  pass "deliberate shared use is allowed when it says so"
}

# The guard fails closed, deliberately opposite to the sibling primary-session
# guards: when the scope predicate cannot be read the inert question is
# unanswerable, so an unisolated command is refused rather than allowed.
# The fixture is test_inert_in_primary_home's home with exactly one delta -
# fm-primary-scope-lib.sh is absent - so that test is this one's control: same
# cwd shape allows with the lib, refuses without it.
test_fails_closed_when_scope_is_unreadable() {
  local home=$TMP_ROOT/primary-no-scope-lib code=0 home_shim
  mkdir -p "$home/bin/shims" "$home/state"
  git init -q "$home"
  : > "$home/AGENTS.md"
  cp "$GUARD" "$home/bin/"
  chmod +x "$home/bin/fm-browser-session-guard.sh"
  ln -sfn ../fm-browser-session-guard.sh "$home/bin/shims/chrome-devtools-axi"
  home_shim="$home/bin/shims/chrome-devtools-axi"
  [ -e "$home/bin/fm-primary-scope-lib.sh" ] \
    && fail "the fixture must leave the scope predicate absent"

  run_guard "$home" unset - "$home_shim" open https://example.invalid || code=$?
  expect_code 1 "$code" "an unreadable scope predicate must refuse, not allow"
  assert_not_contains "$RUN_OUT" "RAN session=" \
    "an undecidable scope must not reach the shared browser"
  assert_contains "$RUN_OUT" "REFUSED" "the fail-closed refusal must be loud"
  pass "an unreadable scope predicate refuses instead of failing open"

  # The declared-shared escape is checked before the predicate is read, so it
  # still works on the fail-closed path.
  code=0
  run_guard "$home" unset FM_BROWSER_SHARED_SESSION_OK=1 \
    "$home_shim" open https://example.invalid || code=$?
  expect_code 0 "$code" "declared shared use must survive an unreadable scope"
  assert_contains "$RUN_OUT" "RAN session=unset" \
    "the explicit escape must not depend on the scope predicate"
  pass "the declared-shared escape still works when the scope is unreadable"
}

# --- the check CLI ----------------------------------------------------------

test_check_cli_decides_without_running() {
  local code=0
  run_guard "$TASK_CWD" unset - "$GUARD" check open https://example.invalid || code=$?
  expect_code 1 "$code" "check must refuse an unisolated command"
  assert_not_contains "$RUN_OUT" "RAN session=" "check must never run the tool"

  code=0
  run_guard "$TASK_CWD" t1 - "$GUARD" check open https://example.invalid || code=$?
  expect_code 0 "$code" "check must allow an isolated command"
  assert_not_contains "$RUN_OUT" "RAN session=" "check must never run the tool"
  pass "the check CLI decides without running the browser tool"
}

test_usage_is_a_usage_error() {
  local code=0
  run_guard "$TASK_CWD" unset - "$GUARD" bogus || code=$?
  expect_code 2 "$code" "an unknown subcommand must be a usage error"
  code=0
  run_guard "$TASK_CWD" unset - "$GUARD" --help || code=$?
  expect_code 0 "$code" "--help must exit 0"
  pass "the guard CLI reports usage errors distinctly from refusals"
}

# --- shim mechanics ---------------------------------------------------------

test_shim_does_not_recurse_into_itself() {
  local code=0 out
  out=$(cd "$TASK_CWD" && env CHROME_DEVTOOLS_AXI_SESSION=t2 \
    PATH="$ROOT/bin/shims:$STUB_BIN:$BASE_PATH" chrome-devtools-axi pages 2>&1) || code=$?
  expect_code 0 "$code" "the shim on PATH must resolve past itself"
  assert_contains "$out" "RAN session=t2" \
    "the shim must exec the real tool, not itself"
  pass "the shim skips its own directory when resolving the real tool"
}

test_shim_reports_a_missing_real_tool() {
  local code=0 out toolless
  # Everything the shim itself needs to run, with no chrome-devtools-axi on it.
  toolless="$ROOT/bin/shims:/usr/bin:/bin"
  if PATH="/usr/bin:/bin" command -v chrome-devtools-axi >/dev/null 2>&1; then
    pass "a real chrome-devtools-axi is installed in the base path, skipping"
    return
  fi
  out=$(cd "$TASK_CWD" && env CHROME_DEVTOOLS_AXI_SESSION=t3 \
    PATH="$toolless" "$SHIM" pages 2>&1) || code=$?
  expect_code 2 "$code" "a missing real tool must be a usage-class error"
  assert_contains "$out" "no real chrome-devtools-axi" \
    "a missing real tool must be reported, not silently succeed"
  pass "the shim reports a missing real chrome-devtools-axi"
}

test_shim_is_a_symlink_to_the_guard() {
  [ -L "$SHIM" ] || fail "bin/shims/chrome-devtools-axi must be a symlink"
  [ -x "$SHIM" ] || fail "bin/shims/chrome-devtools-axi must be executable"
  pass "the shim is an executable symlink onto the single decision owner"
}

# --- spawn wiring -----------------------------------------------------------

# A fake tmux that records the exact text fm-spawn.sh sends into the pane, so
# the launch command and the pane exports are observable without a real
# terminal, backend, or agent.
make_spawn_fakebin() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_SENT_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
  capture-pane) printf 'shell starting\n$ \n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh claude
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

# The 2026-08-03 near-miss was a hand-built relaunch that copied fm-spawn.sh's
# launch command and dropped a separate export line, silently reverting to the
# shared session. So the binding must ride the launch command itself; this
# asserts it on the command fm-spawn actually sends into the pane.
test_spawn_binds_isolation_inside_the_launch_command() {
  local case_dir home proj wt fakebin id sent launch out
  id="browser-isolation-demo"
  case_dir="$TMP_ROOT/spawn-case"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-browser-isolation"
  touch "$home/state/.last-watcher-beat"
  sent="$case_dir/sent.log"
  : > "$sent"
  : > "$case_dir/tmux-calls.log"

  out=$(HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_SENT_LOG="$sent" FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --harness claude \
    --mode no-mistakes --yolo off 2>&1) \
    || fail "fm-spawn.sh should spawn the fixture task"$'\n'"$out"

  launch=$(grep -F 'claude' "$sent" | tail -1)
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_SESSION='$id'" \
    "the launch command itself must carry this task's own browser session"
  assert_contains "$launch" "/bin/shims" \
    "the launch command itself must put the guard shim ahead of the real tool"
  # The launch command is sent as literal bytes; the pane exports are ordinary
  # submitted lines, so they land in the full call log rather than the literal
  # log.
  assert_grep "export CHROME_DEVTOOLS_AXI_SESSION='$id'" "$case_dir/tmux-calls.log" \
    "the pane shell must also be bound to this task's browser session"
  pass "spawn binds the task's browser session inside the launch command"
}

test_briefs_state_the_enforced_contract() {
  local data="$TMP_ROOT/brief-data"
  mkdir -p "$data"
  FM_DATA_OVERRIDE="$data" "$ROOT/bin/fm-brief.sh" ship-demo somerepo \
    --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh must produce a ship brief"
  assert_grep "is refused rather than run" "$data/ship-demo/brief.md" \
    "the ship brief must state that an unisolated browser command is refused"
  FM_DATA_OVERRIDE="$data" "$ROOT/bin/fm-brief.sh" scout-demo somerepo \
    --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh must produce a scout brief"
  assert_grep "is refused rather than run" "$data/scout-demo/brief.md" \
    "the scout brief must state that an unisolated browser command is refused"
  pass "generated briefs state the enforced browser-isolation contract"
}

test_refuses_unset_session
test_refuses_explicit_default_session
test_refuses_blank_session
test_allows_isolated_session
test_allows_sessionless_subcommands
test_inert_in_primary_home
test_declared_shared_use_is_allowed
test_fails_closed_when_scope_is_unreadable
test_check_cli_decides_without_running
test_usage_is_a_usage_error
test_shim_does_not_recurse_into_itself
test_shim_reports_a_missing_real_tool
test_shim_is_a_symlink_to_the_guard
test_spawn_binds_isolation_inside_the_launch_command
test_briefs_state_the_enforced_contract
