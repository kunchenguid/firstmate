#!/usr/bin/env bash
# Behavior tests for per-task chrome-devtools-axi browser session cleanup on teardown.
#
# fm-spawn exports CHROME_DEVTOOLS_AXI_SESSION=<task-id> into each task's pane so
# concurrent crewmates never share one Chrome instance. fm-teardown stops that same
# named session on cleanup so the browser never outlives its task. Scoped strictly to
# the torn-down task's own session name - never a process-name kill, which would also
# catch a sibling task's in-flight browser.
#
# These tests exercise fm-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts and a stub
# chrome-devtools-axi binary (tests/fm-gotmp.test.sh established this fixture pattern).
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-chrome-session-teardown-tests.XXXXXX")

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  # bin/backends/tmux.sh sources this unconditionally.
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  # fm-nm-run-lib.sh: teardown sources it for the pre-teardown parked-run abort.
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  ln -s "$ROOT/bin/fm-worktree-ownership-lib.sh" "$fake/bin/fm-worktree-ownership-lib.sh"
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  # fm-secondmate-parent-lib.sh: teardown sources it for the durable parent record.
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  printf '%s' "$fake"
}

# Installs a stub chrome-devtools-axi that appends one line per invocation to
# $log (session=<CHROME_DEVTOOLS_AXI_SESSION> args=<args>) and exits with
# $exit_code. Returns the stub directory to prepend onto PATH.
install_chrome_stub() {
  local fake=$1 log=$2 exit_code=$3
  local stubbin="$fake/stubbin"
  mkdir -p "$stubbin"
  cat > "$stubbin/chrome-devtools-axi" <<STUB
#!/usr/bin/env bash
printf 'session=%s args=%s\n' "\${CHROME_DEVTOOLS_AXI_SESSION:-<unset>}" "\$*" >> "$log"
exit $exit_code
STUB
  chmod +x "$stubbin/chrome-devtools-axi"
  printf '%s' "$stubbin"
}

test_teardown_stops_the_task_own_chrome_session() {
  local id=td-chrome-z1
  local fake log stubbin
  fake=$(make_fake_root "$id")
  log="$TMP_ROOT/$id.stub.log"
  stubbin=$(install_chrome_stub "$fake" "$log" 0)
  PATH="$stubbin:$PATH" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero on a normal chrome-session stop"
  [ -f "$log" ] || fail "chrome-devtools-axi stub was never invoked"
  grep -qx "session=$id args=stop" "$log" \
    || fail "chrome-devtools-axi was not stopped with this task's own session id ($(cat "$log" 2>/dev/null))"
  pass "fm-teardown stops chrome-devtools-axi with CHROME_DEVTOOLS_AXI_SESSION=<task-id> stop"
}

test_teardown_succeeds_when_chrome_stop_fails() {
  local id=td-chrome-z2
  local fake log stubbin
  fake=$(make_fake_root "$id")
  log="$TMP_ROOT/$id.stub.log"
  stubbin=$(install_chrome_stub "$fake" "$log" 1)
  PATH="$stubbin:$PATH" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when chrome-devtools-axi stop failed; cleanup failure must never fail teardown"
  grep -qx "session=$id args=stop" "$log" \
    || fail "chrome-devtools-axi stub was not invoked before teardown continued"
  pass "fm-teardown still completes when the chrome-devtools-axi stop call fails"
}

test_teardown_skips_silently_without_chrome_binary() {
  # Simulate a host with no chrome-devtools-axi installed (or a task that never
  # started a browser session): restrict PATH to exclude any chrome-devtools-axi
  # binary. Teardown must still succeed, with no attempt and no warning.
  local id=td-chrome-z3
  local fake err
  fake=$(make_fake_root "$id")
  err="$TMP_ROOT/$id.stderr"
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" \
    >/dev/null 2>"$err" \
    || fail "teardown exited non-zero with no chrome-devtools-axi binary on PATH"
  if grep -qi chrome-devtools-axi "$err"; then
    fail "teardown printed something about chrome-devtools-axi when the binary was absent: $(cat "$err")"
  fi
  pass "fm-teardown silently skips chrome-session cleanup when chrome-devtools-axi is not installed"
}

test_teardown_stops_the_task_own_chrome_session
test_teardown_succeeds_when_chrome_stop_fails
test_teardown_skips_silently_without_chrome_binary
