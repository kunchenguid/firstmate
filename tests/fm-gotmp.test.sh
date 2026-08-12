#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a private temp root with Go's build temp nested at gotmp/,
# exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's meta.
# fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise behavior directly: fm-teardown is run as a subprocess against a
# fake FM_ROOT (built so the real script resolves into it), with stub helper scripts.
# Nothing is sourced. The teardown side is exercised as a real subprocess.
set -u

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
TASK_TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
  if [ -n "${TASK_TMP_ROOT:-}" ]; then
    rm -rf -- "$TASK_TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")

install_fake_tmux() {
  local fake=$1
  cat > "$fake/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/tmux"
}

# Build a fake FM_ROOT so the real fm-teardown.sh (symlinked in) resolves FM_ROOT to
# it via its BASH_SOURCE computation. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data" "$fake/config" "$fake/projects"
  printf '%s\n' '# fixture' > "$fake/AGENTS.md"
  git -C "$fake" init -q
  install_fake_tmux "$fake"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # The teardown now routes endpoint cleanup through the backend dispatcher.
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-tool-path-lib.sh" "$fake/bin/fm-tool-path-lib.sh"
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  : > "$fake/bin/fm-pending-reply-lib.sh"
  cat > "$fake/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_refuse_if_gate_agent() { return 0; }
SH
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-config-inherit-lib.sh" "$fake/bin/fm-config-inherit-lib.sh"
  ln -s "$ROOT/bin/fm-slot-owner-lib.sh" "$fake/bin/fm-slot-owner-lib.sh"
  ln -s "$ROOT/bin/fm-agent-cwd-lib.sh" "$fake/bin/fm-agent-cwd-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-worker-isolation-lib.sh" "$fake/bin/fm-worker-isolation-lib.sh"
  # fm-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  # fm-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so
  # backlog_refresh_reminder takes the plain-message path; no tasks-axi here.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  cat > "$fake/bin/fm-task-identity-lib.sh" <<'SH'
fm_assert_task_branch_matches_meta() { return 0; }
SH
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- fm-spawn side ---

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp
  task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-$id.XXXXXX") || fail "could not create task temp fixture"
  TASK_TMP_ROOT="$task_tmp"
  rm -rf -- "$task_tmp"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  printf 'task=%s\npath=%s\n' "$id" "$task_tmp" > "$task_tmp/.fm-tasktmp-owner"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  (cd "$fake" && PATH="$fake/bin:$PATH" FM_HOME="$fake" FM_ROOT_OVERRIDE="$fake" FM_STATE_OVERRIDE="$fake/state" \
    bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
  ) \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data" "$fake/config" "$fake/projects"
  printf '%s\n' '# fixture' > "$fake/AGENTS.md"
  git -C "$fake" init -q
  install_fake_tmux "$fake"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-tool-path-lib.sh" "$fake/bin/fm-tool-path-lib.sh"
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  : > "$fake/bin/fm-pending-reply-lib.sh"
  cat > "$fake/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_refuse_if_gate_agent() { return 0; }
SH
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-config-inherit-lib.sh" "$fake/bin/fm-config-inherit-lib.sh"
  ln -s "$ROOT/bin/fm-slot-owner-lib.sh" "$fake/bin/fm-slot-owner-lib.sh"
  ln -s "$ROOT/bin/fm-agent-cwd-lib.sh" "$fake/bin/fm-agent-cwd-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-worker-isolation-lib.sh" "$fake/bin/fm-worker-isolation-lib.sh"
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
  cat > "$fake/bin/fm-task-identity-lib.sh" <<'SH'
fm_assert_task_branch_matches_meta() { return 0; }
SH
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  (cd "$fake" && PATH="$fake/bin:$PATH" FM_HOME="$fake" FM_ROOT_OVERRIDE="$fake" FM_STATE_OVERRIDE="$fake/state" \
    bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
  ) \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/fm-$id.ABC123"
  TASK_TMP_ROOT="$task_tmp"
  rm -rf -- "$task_tmp"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  (cd "$fake" && PATH="$fake/bin:$PATH" FM_HOME="$fake" FM_ROOT_OVERRIDE="$fake" FM_STATE_OVERRIDE="$fake/state" \
    bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
  ) \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
