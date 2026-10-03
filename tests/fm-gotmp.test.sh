#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>+uid<uid>/ with Go's build temp nested
# at gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the
# task's meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise fm-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts.
# The isolated fm-spawn subprocess in fm-kimi-harness.test.sh covers temp-root creation,
# metadata publication, and the pane environment export.
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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh is real, while its adapter is stubbed so this temp-cleanup
  # test cannot depend on or mutate a host tmux server. Teardown still refuses
  # unless every sibling the real tmux adapter sources is present.
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
fm_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-agent-process-lib.sh" "$fake/bin/fm-agent-process-lib.sh"
  ln -s "$ROOT/bin/fm-gemini-lib.sh" "$fake/bin/fm-gemini-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  # fm-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/fm-lease-lib.sh" "$fake/bin/fm-lease-lib.sh"
  # Lifecycle serialization, status presentation retirement, and shared adapter
  # ownership are sourced by teardown.
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$fake/bin/fm-timeout-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-path-lib.sh" "$fake/bin/fm-path-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh and fm-env-lib.sh it
  # sources): teardown sources it for the relay-activation gate on the
  # promised-public-reply check. None does anything in this fixture, which has
  # no .env, but all three are real siblings teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-env-lib.sh" "$fake/bin/fm-env-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  # Receiver-wake retirement sources the pending-reply library, which in turn
  # requires the marker helper even for this ordinary-task teardown fixture.
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
  # Ordinary teardown reports any final ledger outcome before removing records.
  ln -s "$ROOT/bin/fm-inactive-reconcile.sh" "$fake/bin/fm-inactive-reconcile.sh"
  ln -s "$ROOT/bin/fm-parent-channel-lib.sh" "$fake/bin/fm-parent-channel-lib.sh"
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
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so the
  # fused backlog close is skipped and the follow-up echo takes the plain-message
  # path; there is no tasks-axi and no backlog in this fixture.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
FM_TASKS_AXI_MIN=0.2.6
fm_tasks_axi_backend() { printf 'markdown\n'; }
fm_tasks_axi_backend_available() { return 1; }
fm_tasks_axi_compatible() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  ln -s "$ROOT/bin/fm-backlog-transition-lib.sh" "$fake/bin/fm-backlog-transition-lib.sh"
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

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2 task_tmp
  task_tmp="$TMP_ROOT/fm-$id+uid$(id -u)"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_leaves_a_legacy_named_tasktmp_alone() {
  # A legacy /tmp/fm-<id> root has no uid namespace, so another account or home
  # can hold the same path; even an owned real directory there is not this
  # task's to reap or remove.
  local id=td-legacy-z5 task_tmp fake
  task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  printf 'keep\n' > "$task_tmp/gotmp/precious"
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a legacy-named tasktmp"
  [ -f "$task_tmp/gotmp/precious" ] \
    || fail "teardown removed a legacy-named tasktmp ($task_tmp)"
  pass "fm-teardown leaves a legacy-named tasktmp= root alone"
}

# The home identity fm-spawn writes into a superseded root's owner marker: the
# sha256 of the home's physical path, then the task id.
owner_marker_for() {  # <home> <id>
  local root hash
  root=$(cd "$1" && pwd -P)
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  else
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  fi
  printf '%s %s\n' "$hash" "$2"
}

# Teardown of a task whose meta records a superseded root as tasktmp_prior=.
# <marker> is none, home (this home and task), other-home, or other-task;
# prints the prior root.
run_prior_teardown() {  # <id> <marker>
  local id=$1 marker=$2 task_tmp prior_tmp fake
  task_tmp="$TMP_ROOT/fm-$id+uid$(id -u)"
  prior_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp" "$prior_tmp/gotmp"
  printf 'leftover\n' > "$prior_tmp/gotmp/build-artifact"
  fake=$(make_fake_root "$id" "$task_tmp")
  printf 'tasktmp_prior=%s\n' "$prior_tmp" >> "$fake/state/$id.meta"
  case "$marker" in
    none) ;;
    home) owner_marker_for "$fake" "$id" > "$prior_tmp/.fm-task-owner" ;;
    other-home) printf '%064d %s\n' 0 "$id" > "$prior_tmp/.fm-task-owner" ;;
    other-task) owner_marker_for "$fake" "$id-other" > "$prior_tmp/.fm-task-owner" ;;
  esac
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>"$TMP_ROOT/$id.err" \
    || fail "teardown exited non-zero with a tasktmp_prior"
  [ ! -e "$task_tmp" ] || fail "teardown did not remove the current tasktmp ($task_tmp)"
  printf '%s' "$prior_tmp"
}

test_teardown_removes_a_marked_superseded_tasktmp_prior() {
  # A relaunch across a temp-root formula change records the older root as
  # tasktmp_prior= and marks it as this home's and task's; teardown removes it.
  local id=td-prior-z5 prior_tmp
  prior_tmp=$(run_prior_teardown "$id" home)
  [ ! -e "$prior_tmp" ] \
    || fail "teardown did not remove the marked tasktmp_prior ($prior_tmp still exists)"
  pass "fm-teardown removes a tasktmp_prior= root that carries this home's and task's marker"
}

test_teardown_leaves_an_unmarked_tasktmp_prior_alone() {
  # A pre-existing legacy /tmp/fm-<id> with no marker may belong to another home
  # of this account, so ownership alone does not make it this task's.
  local id=td-prior-z7 prior_tmp
  prior_tmp=$(run_prior_teardown "$id" none)
  [ -f "$prior_tmp/gotmp/build-artifact" ] \
    || fail "teardown removed an unmarked tasktmp_prior ($prior_tmp)"
  grep -q "owner marker" "$TMP_ROOT/$id.err" \
    || fail "teardown must warn when it leaves an unmarked tasktmp_prior alone"
  pass "fm-teardown leaves an unmarked tasktmp_prior= root alone and warns"
}

test_teardown_leaves_a_tasktmp_prior_marked_for_another_owner_alone() {
  local id=td-prior-z8 marker prior_tmp
  for marker in other-home other-task; do
    prior_tmp=$(run_prior_teardown "$id-$marker" "$marker")
    [ -f "$prior_tmp/gotmp/build-artifact" ] \
      || fail "teardown removed a tasktmp_prior with a $marker marker ($prior_tmp)"
  done
  pass "fm-teardown leaves a tasktmp_prior= root marked for another home or task alone"
}

test_teardown_does_not_reap_processes_in_an_unmarked_tasktmp_prior() {
  # The reap selects processes by working directory alone, so it must not see an
  # unmarked root: a live process there belongs to whoever else shares it.
  local id=td-prior-z10 task_tmp prior_tmp fake pid
  command -v lsof >/dev/null 2>&1 || { pass "fm-teardown reap check skipped (no lsof)"; return; }
  task_tmp="$TMP_ROOT/fm-$id+uid$(id -u)"
  prior_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp" "$prior_tmp"
  fake=$(make_fake_root "$id" "$task_tmp")
  printf 'tasktmp_prior=%s\n' "$prior_tmp" >> "$fake/state/$id.meta"
  (cd "$prior_tmp" && exec sleep 60) &
  pid=$!
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || { kill "$pid" 2>/dev/null; fail "teardown exited non-zero with an unmarked tasktmp_prior"; }
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
  else
    fail "teardown killed a process whose cwd is in an unmarked tasktmp_prior"
  fi
  pass "fm-teardown does not reap processes rooted in an unmarked tasktmp_prior= root"
}

test_teardown_ignores_symlinked_tasktmp() {
  # A recorded root that is a symlink (as another local account could plant at
  # the predictable path) must be neither followed nor removed.
  local id=td-link-z6 target task_tmp fake
  target="$TMP_ROOT/$id-target"
  task_tmp="$TMP_ROOT/fm-$id+uid$(id -u)"
  mkdir -p "$target/gotmp"
  printf 'keep\n' > "$target/gotmp/precious"
  ln -s "$target" "$task_tmp"
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a symlinked tasktmp"
  [ -f "$target/gotmp/precious" ] \
    || fail "teardown followed a symlinked tasktmp and removed its target"
  [ -L "$task_tmp" ] || fail "teardown removed the symlinked tasktmp ($task_tmp)"
  pass "fm-teardown leaves a symlinked tasktmp= root alone"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
fm_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-agent-process-lib.sh" "$fake/bin/fm-agent-process-lib.sh"
  ln -s "$ROOT/bin/fm-gemini-lib.sh" "$fake/bin/fm-gemini-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/fm-lease-lib.sh" "$fake/bin/fm-lease-lib.sh"
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$fake/bin/fm-timeout-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-path-lib.sh" "$fake/bin/fm-path-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh and fm-env-lib.sh it
  # sources): teardown sources it for the relay-activation gate on the
  # promised-public-reply check. None does anything in this fixture, which has
  # no .env, but all three are real siblings teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-env-lib.sh" "$fake/bin/fm-env-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
  ln -s "$ROOT/bin/fm-inactive-reconcile.sh" "$fake/bin/fm-inactive-reconcile.sh"
  ln -s "$ROOT/bin/fm-parent-channel-lib.sh" "$fake/bin/fm-parent-channel-lib.sh"
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
FM_TASKS_AXI_MIN=0.2.6
fm_tasks_axi_backend() { printf 'markdown\n'; }
fm_tasks_axi_backend_available() { return 1; }
fm_tasks_axi_compatible() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  ln -s "$ROOT/bin/fm-backlog-transition-lib.sh" "$fake/bin/fm-backlog-transition-lib.sh"
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
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-fm-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_removes_tasktmp_dir
test_teardown_leaves_a_legacy_named_tasktmp_alone
test_teardown_removes_a_marked_superseded_tasktmp_prior
test_teardown_leaves_an_unmarked_tasktmp_prior_alone
test_teardown_leaves_a_tasktmp_prior_marked_for_another_owner_alone
test_teardown_does_not_reap_processes_in_an_unmarked_tasktmp_prior
test_teardown_ignores_symlinked_tasktmp
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
