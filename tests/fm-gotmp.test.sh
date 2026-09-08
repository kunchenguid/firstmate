#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
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
# make_fake_root <id> [<tasktmp>]: with one argument the meta carries no
# tasktmp= line at all (a pre-fix task); with two it records the given path.
make_fake_root() {
  local id=$1 tasktmp_line=
  [ $# -lt 2 ] || tasktmp_line="tasktmp=$2"
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh is real, while its adapter is stubbed so this temp-cleanup
  # test cannot depend on or mutate a host tmux server.
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
fm_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
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
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
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
  # fm-remote-job-reap-orphans.sh: stub (teardown calls it with `|| true`). The
  # real sweep signals orphaned remote job workers on this machine, so it must
  # never be symlinked into a fixture.
  cat > "$fake/bin/fm-remote-job-reap-orphans.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-remote-job-reap-orphans.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so the
  # fused backlog close is skipped and the follow-up echo takes the plain-message
  # path; there is no tasks-axi and no backlog in this fixture.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
FM_TASKS_AXI_MIN=0.2.4
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
META
  [ -z "$tasktmp_line" ] || printf '%s\n' "$tasktmp_line" >> "$fake/state/$id.meta"
  printf '%s' "$fake"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/fm-$id"
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

test_teardown_preserves_replacement_record() {
  local id=td-replacement-z8 fake task_tmp rc=0
  task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  fake=$(make_fake_root "$id" "$task_tmp")
  cp "$fake/state/$id.meta" "$fake/replacement.meta"
  printf 'spawn_gen=replacement\n' >> "$fake/replacement.meta"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$FM_HOME/bin/fm-wake-lib.sh"
meta="$FM_HOME/state/$TEST_REPLACEMENT_ID.meta"
lock=$(fm_meta_lock_path "$meta")
fm_lock_try_acquire "$lock"
trap 'fm_lock_release "$lock"' EXIT
[ ! -e "$meta" ] && [ ! -L "$meta" ]
[ ! -e "$TEST_ORIGINAL_TASKTMP" ]
cp "$FM_HOME/replacement.meta" "$meta"
SH
  FM_HOME="$fake" TEST_REPLACEMENT_ID="$id" TEST_ORIGINAL_TASKTMP="$task_tmp" \
    bash "$fake/bin/fm-teardown.sh" "$id" >"$fake/teardown.stdout" 2>"$fake/teardown.stderr" || rc=$?
  cmp -s "$fake/replacement.meta" "$fake/state/$id.meta" \
    || fail "post-cleanup replacement metadata was not published or preserved"
  [ ! -e "$task_tmp" ] || fail "original task scratch survived cleanup"
  [ "$rc" -eq 0 ] || {
    cat "$fake/teardown.stderr" >&2
    fail "teardown rejected replacement metadata after successful cleanup"
  }
  grep -q "teardown $id complete" "$fake/teardown.stdout" \
    || fail "original teardown did not report completion"
  if grep -q 'aborted before its task record was removed' "$fake/teardown.stderr"; then
    fail "completed teardown reported a false abort"
  fi
  pass "fm-teardown succeeds and preserves replacement metadata published after cleanup"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake
  fake=$(make_fake_root "$id")
  ! grep -q '^tasktmp=' "$fake/state/$id.meta" \
    || fail "precondition: meta must carry no tasktmp= line"
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

test_teardown_fails_loudly_when_a_sourced_sibling_is_missing() {
  # POSIX mode makes a missing sourced file fatal on modern Bash too. Default
  # modern Bash can continue after that error inside a best-effort function;
  # assuming it always aborts was the old Linux CI failure. The adapter stays
  # stubbed so this regression never contacts a host tmux server.
  local id=td-nosib-z5
  local task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  local fake err
  fake=$(make_fake_root "$id" "$task_tmp")
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
: > "$FM_HOME/sibling-source-reached"
set -o posix
# shellcheck source=/dev/null
. "$FM_BACKEND_LIB_DIR/missing-sibling.sh"
fm_backend_tmux_kill() { return 0; }
SH
  err="$TMP_ROOT/$id.stderr"
  if FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>"$err"; then
    fail "teardown exited 0 with a sourced sibling missing"
  fi
  [ -e "$fake/state/$id.meta" ] \
    || fail "teardown removed the task record after a fatal source failure"
  [ -e "$task_tmp" ] \
    || fail "teardown removed the tasktmp dir after a fatal source failure"
  [ -e "$fake/sibling-source-reached" ] || fail "teardown did not reach the missing sibling"
  pass "fm-teardown exits non-zero and retains every record when a sourced sibling is missing"
}

test_teardown_rejects_zero_status_abort() {
  # Pin the EXIT contract independently of the shell version's source-error
  # status: an adapter that exits 0 before cleanup is still an aborted teardown.
  local id=td-zero-z6 fake err task_tmp
  task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  fake=$(make_fake_root "$id" "$task_tmp")
  printf 'exit 0\n' > "$fake/bin/backends/tmux.sh"
  err="$TMP_ROOT/$id.stderr"
  if FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>"$err"; then
    fail "teardown accepted an exit 0 before cleanup"
  fi
  [ -e "$fake/state/$id.meta" ] || fail "zero-status abort removed the task record"
  [ -d "$task_tmp/gotmp" ] || fail "zero-status abort removed task scratch"
  grep -q "aborted before its task record was removed" "$err" \
    || fail "zero-status abort did not reach the original stderr"
  pass "fm-teardown rejects a zero-status abort and reports it on original stderr"
}

test_missing_adapter_returns_to_caller() {
  local id=td-noadapter-z7 fake out
  fake=$(make_fake_root "$id")
  rm "$fake/bin/backends/tmux.sh"
  out=$(FM_HOME="$fake" bash --posix -c '
    . "$1/bin/fm-backend.sh"
    if fm_backend_source tmux; then exit 1; fi
    printf "adapter refused\n"
  ' _ "$fake" 2>&1) || fail "missing adapter aborted instead of returning failure"
  [ "$out" = 'adapter refused' ] || fail "missing adapter did not reach caller refusal"
  [ -e "$fake/state/$id.meta" ] || fail "adapter probe removed task metadata"
  pass "a missing adapter returns failure so the caller can refuse safely"
}

test_forced_parent_preflights_child_adapters() {
  local mode id fake home task_tmp child_wt child_tmp err log path
  for mode in missing-sibling missing-adapter zero-exit kill-failure success; do
    id="td-child-$mode"
    task_tmp="$TMP_ROOT/fm-$id"
    home="$TMP_ROOT/home-$id"
    child_wt="$TMP_ROOT/work-$id"
    child_tmp="$home/tasktmp"
    mkdir -p "$task_tmp/gotmp" "$home/state" "$child_tmp/gotmp" "$child_wt"
    fake=$(make_fake_root "$id" "$task_tmp")
    printf '%s\n' "$id" > "$home/.fm-secondmate-home"
    printf 'parent work\n' > "$home/work-note"
    printf 'parent scratch\n' > "$task_tmp/gotmp/artifact"
    printf 'child scratch\n' > "$child_tmp/gotmp/artifact"
    git -C "$child_wt" init -q || fail "child fixture git init failed"
    git -C "$child_wt" -c user.name=Test -c user.email=test@example.invalid \
      -c commit.gpgsign=false commit -q --allow-empty -m fixture \
      || fail "child fixture commit failed"
    printf 'child work\n' > "$child_wt/work-note"
    cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$home
home=$home
project=$TMP_ROOT/nonexistent-project-$id
kind=secondmate
tasktmp=$task_tmp
META
    cat > "$home/state/child-z.meta" <<META
backend=zellij
window=fakeses:1
zellij_session=fakeses
zellij_tab_id=1
zellij_pane_id=1
endpoint_task_id=child-z
worktree=$child_wt
project=$child_wt
kind=ship
mode=local-only
tasktmp=$child_tmp
META
    cp "$fake/state/$id.meta" "$fake/parent.meta.before"
    cp "$home/state/child-z.meta" "$fake/child.meta.before"
    : > "$fake/bin/backends/zellij.sh"
    if [ "$mode" = missing-sibling ]; then
      printf 'set -o posix\n' >> "$fake/bin/backends/zellij.sh"
    fi
    cat >> "$fake/bin/backends/zellij.sh" <<'SH'
. "$FM_BACKEND_LIB_DIR/fm-backend-hometag-lib.sh"
fm_backend_zellij_kill() {
  printf '%s\n' "$FM_HOME" "$FM_ROOT" "$@" >> "$TEST_CHILD_KILL_LOG"
  return "$TEST_CHILD_KILL_RC"
}
SH
    case "$mode" in
      missing-sibling) ;;
      missing-adapter) rm "$fake/bin/backends/zellij.sh" ;;
      zero-exit) printf 'exit 0\n' > "$fake/bin/fm-backend-hometag-lib.sh" ;;
      *) : > "$fake/bin/fm-backend-hometag-lib.sh" ;;
    esac
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fake/bin/treehouse"
    chmod +x "$fake/bin/treehouse"
    err="$fake/teardown.stderr"
    log="$fake/child-kill.log"
    local kill_rc=0 rc=0
    [ "$mode" != kill-failure ] || kill_rc=1
    FM_HOME="$fake" PATH="$fake/bin:$PATH" TEST_CHILD_KILL_LOG="$log" TEST_CHILD_KILL_RC="$kill_rc" \
      bash "$fake/bin/fm-teardown.sh" "$id" --force > "$fake/teardown.stdout" 2>"$err" || rc=$?
    case "$mode" in
      missing-sibling|missing-adapter|zero-exit)
        [ "$rc" -ne 0 ] || fail "$mode: forced parent teardown accepted child adapter failure"
        cmp -s "$fake/state/$id.meta" "$fake/parent.meta.before" || fail "$mode: parent record changed"
        cmp -s "$home/state/child-z.meta" "$fake/child.meta.before" || fail "$mode: child record changed"
        [ "$(cat "$home/work-note")" = 'parent work' ] || fail "$mode: parent work changed"
        [ "$(cat "$child_wt/work-note")" = 'child work' ] || fail "$mode: child work changed"
        [ "$(cat "$task_tmp/gotmp/artifact")" = 'parent scratch' ] || fail "$mode: parent scratch changed"
        [ "$(cat "$child_tmp/gotmp/artifact")" = 'child scratch' ] || fail "$mode: child scratch changed"
        [ ! -e "$log" ] || fail "$mode: child kill ran before preflight completed"
        case "$mode" in
          missing-sibling) grep -q 'fm-backend-hometag-lib.sh' "$err" || fail "missing sibling diagnostic absent: $(cat "$err")" ;;
          missing-adapter) grep -q 'REFUSED: zellij adapter is unavailable for child child-z' "$err" || fail "missing adapter refusal absent: $(cat "$err")" ;;
          zero-exit) grep -q 'aborted before its task record was removed' "$err" || fail "zero-status abort diagnostic absent: $(cat "$err")" ;;
        esac
        ;;
      *)
        [ "$rc" -eq 0 ] || { cat "$err" >&2; fail "$mode: forced parent teardown failed"; }
        for path in "$fake/state/$id.meta" "$home" "$child_wt" "$task_tmp"; do
          [ ! -e "$path" ] || fail "$mode: cleanup retained $path"
        done
        printf '%s\n' "$home" "$home" fakeses:1 1 fm-child-z > "$fake/expected-kill.log"
        cmp -s "$log" "$fake/expected-kill.log" || fail "$mode: child kill lost its owning home or endpoint"
        ;;
    esac
    pass "forced parent child-adapter preflight: $mode"
  done
}

test_teardown_removes_tasktmp_dir
test_teardown_preserves_replacement_record
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_teardown_fails_loudly_when_a_sourced_sibling_is_missing
test_teardown_rejects_zero_status_abort
test_missing_adapter_returns_to_caller
test_forced_parent_preflights_child_adapters
