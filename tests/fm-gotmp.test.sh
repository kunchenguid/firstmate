#!/usr/bin/env bash
# Behavior tests for the per-task temp root (bin/fm-task-tmp-lib.sh).
#
# fm-spawn gives each task a temp root with Go's build temp nested at gotmp/,
# exports GOTMPDIR into the crewmate pane, pins the agent's TMPDIR to the root so
# its harness scratch lands there, and records tasktmp= in the task's meta.
# fm-teardown reads tasktmp= and removes that one root on cleanup.
#
# The removal is task-scoped on purpose: the worktree pool reuses slot numbers, so
# one slot's scratch path accumulates sessions from many tasks, live ones included.
# The root is also home-scoped, because /tmp is shared by every firstmate home on
# the machine and task ids are per-home slugs. These tests pin that teardown
# removes only the path this task's own record names, that it refuses anything
# else - including the older undiscriminated <base>/fm-<id> shape, which is
# ambiguous between homes and so is deliberately left to leak - and that a refusal
# or failure never fails an otherwise-complete teardown.
#
# Creation is guarded too. The root's name is deterministic and its real parent
# /tmp is world-writable, so the cases below also pin that fm_task_tmp_create
# refuses a path this user does not own instead of letting the pinned TMPDIR
# write the agent's whole scratch tree through it.
#
# These tests exercise fm-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts, and call the
# creation guard through the library the same way fm-spawn does.
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
# Derive every canonical per-task temp root inside the sandbox instead of /tmp, so
# these tests create and remove nothing outside it. Creation (fm-spawn) and removal
# (fm-teardown) read the same override, exactly as they read the same default.
export FM_TASK_TMP_BASE="$TMP_ROOT"

# The canonical temp root for a task under a given fake home. Home-scoped via
# bin/fm-backend-hometag-lib.sh, so it is derived here exactly the way the
# teardown subprocess derives it - same FM_HOME/FM_ROOT, same library - instead of
# being spelled out, which would only pin a copy of the shape.
canonical_task_tmp() {  # <fake-home> <task-id>
  local fake=$1 id=$2
  mkdir -p "$fake"
  (
    FM_HOME=$fake
    FM_ROOT=$fake
    # shellcheck source=bin/fm-task-tmp-lib.sh
    . "$ROOT/bin/fm-task-tmp-lib.sh"
    fm_task_tmp_root "$id"
  )
}

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
  # fm-backend.sh + its tmux adapter: symlink the REAL files (teardown sources
  # fm-backend.sh unconditionally, and dispatches the kill call through the
  # tmux adapter; both are unchanged by this suite's fixture, just newly
  # required siblings since the P1 backend extraction).
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  # fm-task-tmp-lib.sh: the per-task temp root shape and its guarded removal,
  # plus the home-tag library it sources for the per-home discriminator.
  ln -s "$ROOT/bin/fm-task-tmp-lib.sh" "$fake/bin/fm-task-tmp-lib.sh"
  ln -s "$ROOT/bin/fm-backend-hometag-lib.sh" "$fake/bin/fm-backend-hometag-lib.sh"
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
  local id=td-rm-z2
  local task_tmp
  task_tmp=$(canonical_task_tmp "$TMP_ROOT/$id" "$id")
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

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-task-tmp-lib.sh" "$fake/bin/fm-task-tmp-lib.sh"
  ln -s "$ROOT/bin/fm-backend-hometag-lib.sh" "$fake/bin/fm-backend-hometag-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/fm-lease-lib.sh" "$fake/bin/fm-lease-lib.sh"
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
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
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
  local task_tmp
  task_tmp=$(canonical_task_tmp "$TMP_ROOT/$id" "$id")
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}


# Build one task's temp root holding agent scratch shaped the way a harness lays
# it out: <root>/claude-<uid>/<worktree-slot>/<session>/scratchpad/<file>. The slot
# component is deliberately the SAME string for every task here, because the
# worktree pool reuses slot numbers - that shared slot is what makes any
# slot-scoped or pattern-scoped sweep unsafe.
seed_task_scratch() {  # <root> <session> <payload>
  local root=$1 session=$2 payload=$3
  local dir="$root/claude-1000/-home-cap--treehouse-proj-1/$session/scratchpad"
  mkdir -p "$root/gotmp" "$dir" || fail "could not seed task scratch under $root"
  printf '%s\n' "$payload" > "$dir/index.db" \
    || fail "could not seed scratch payload under $root"
}

# The seeded scratch file for one task root, so a test can hold the same literal
# path across a teardown instead of rebuilding it on either side.
task_scratch_file() {  # <root> <session>
  printf '%s\n' "$1/claude-1000/-home-cap--treehouse-proj-1/$2/scratchpad/index.db"
}

test_teardown_leaves_live_sibling_session_untouched() {
  # The acceptance case: another task is live in the same reused worktree slot,
  # with its own scratch. Tearing this task down must remove this task's root and
  # nothing of the sibling's.
  local id=td-sibling-z5
  local mine sibling
  mine=$(canonical_task_tmp "$TMP_ROOT/$id" "$id")
  # The live sibling belongs to the SAME home - a second task of this
  # installation reusing the worktree slot - so only the task component of the
  # root distinguishes the two.
  sibling=$(canonical_task_tmp "$TMP_ROOT/$id" td-sibling-live-z5)
  seed_task_scratch "$mine" 11111111-1111-1111-1111-111111111111 mine
  seed_task_scratch "$sibling" 22222222-2222-2222-2222-222222222222 live-sibling
  local mine_file sibling_file
  mine_file=$(task_scratch_file "$mine" 11111111-1111-1111-1111-111111111111)
  sibling_file=$(task_scratch_file "$sibling" 22222222-2222-2222-2222-222222222222)
  # Both halves must be able to fail: assert the state teardown is supposed to
  # change, and the state it is supposed to leave alone, BEFORE it runs.
  [ -f "$mine_file" ] || fail "this task's scratch was not seeded before teardown"
  [ -f "$sibling_file" ] || fail "the live sibling's scratch was not seeded before teardown"
  local fake
  fake=$(make_fake_root "$id" "$mine")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a live sibling task present"
  [ ! -e "$mine" ] || fail "teardown did not remove its own task's temp root"
  [ -f "$sibling_file" ] \
    || fail "teardown destroyed a live sibling task's scratch in the same worktree slot"
  pass "fm-teardown removes its own task's scratch and leaves a live sibling session's intact"
}

test_teardown_refuses_a_foreign_tasktmp() {
  # A recorded path that is not this task's own canonical root is never removed,
  # however plausible it looks - this is what stops a hand-edited or stale record
  # from turning cleanup into someone else's data loss.
  local id=td-foreign-z6
  local foreign="$TMP_ROOT/fm-td-foreign-other-z6"
  seed_task_scratch "$foreign" 33333333-3333-3333-3333-333333333333 someone-else
  local fake
  fake=$(make_fake_root "$id" "$foreign")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err" \
    || fail "teardown exited non-zero when the recorded temp root was not its own"
  [ -d "$foreign" ] || fail "teardown removed a temp root belonging to another task"
  grep -q "is not $id's own" "$TMP_ROOT/$id.err" \
    || fail "teardown did not report the refused temp-root removal"
  grep -q "teardown $id complete" "$TMP_ROOT/$id.out" \
    || fail "teardown did not complete after refusing the temp-root removal"
  pass "fm-teardown refuses a recorded temp root that is not this task's own, and still completes"
}

test_teardown_refuses_a_legacy_undiscriminated_tasktmp() {
  # A task in flight when the home scoping landed recorded the old
  # <base>/fm-<id> shape: the right task id, but no home tag. Two homes with
  # colliding ids both recorded exactly that, and nothing at teardown time says
  # which one this is, so it is refused rather than guessed at - a bounded leak
  # (those roots hold only Go build temp) instead of one chance of deleting a
  # live sibling home's directory.
  local id=td-legacy-z9
  local legacy="$TMP_ROOT/fm-$id"
  seed_task_scratch "$legacy" 44444444-4444-4444-4444-444444444444 legacy-shape
  local fake
  fake=$(make_fake_root "$id" "$legacy")
  [ "$legacy" != "$(canonical_task_tmp "$TMP_ROOT/$id" "$id")" ] \
    || fail "precondition: the legacy shape must differ from the home-scoped root"
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err" \
    || fail "teardown exited non-zero on a legacy undiscriminated temp root"
  [ -d "$legacy" ] || fail "teardown removed a legacy undiscriminated temp root"
  grep -q "is not $id's own" "$TMP_ROOT/$id.err" \
    || fail "teardown did not report the refused legacy temp root"
  grep -q "teardown $id complete" "$TMP_ROOT/$id.out" \
    || fail "teardown did not complete after refusing the legacy temp root"
  pass "fm-teardown refuses a legacy undiscriminated temp root, reports it, and still completes"
}

test_teardown_refuses_a_symlinked_tasktmp() {
  # The canonical path exists but is a symlink: removing it would delete the link
  # and, for a careless implementation, could reach its target. Refuse instead.
  local id=td-symlink-z7
  local target="$TMP_ROOT/symlink-target-z7"
  local task_tmp
  task_tmp=$(canonical_task_tmp "$TMP_ROOT/$id" "$id")
  mkdir -p "$target"
  printf 'keep\n' > "$target/keep"
  ln -s "$target" "$task_tmp"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err" \
    || fail "teardown exited non-zero when the recorded temp root was a symlink"
  [ -f "$target/keep" ] || fail "teardown followed a symlinked temp root and removed its target"
  [ -L "$task_tmp" ] || fail "teardown removed the symlink itself"
  grep -q "is a symlink" "$TMP_ROOT/$id.err" || fail "teardown did not report the symlinked temp root"
  grep -q "teardown $id complete" "$TMP_ROOT/$id.out" \
    || fail "teardown did not complete after refusing a symlinked temp root"
  pass "fm-teardown refuses a symlinked temp root, and still completes"
}

test_teardown_survives_an_unremovable_tasktmp() {
  # Losing worktree cleanup over a leftover temp directory would be worse than the
  # leak: an unremovable root is reported and teardown still succeeds.
  if [ "$(id -u)" = 0 ]; then
    pass "skipped unremovable-temp-root case (running as root bypasses directory permissions)"
    return 0
  fi
  local id=td-stuck-z8
  local base="$TMP_ROOT/readonly-base-z8"
  local task_tmp
  mkdir -p "$base"
  task_tmp=$(FM_TASK_TMP_BASE="$base" canonical_task_tmp "$TMP_ROOT/$id" "$id")
  mkdir -p "$task_tmp"
  printf 'stuck\n' > "$task_tmp/leftover"
  chmod 555 "$base"
  local fake rc
  fake=$(make_fake_root "$id" "$task_tmp")
  set +e
  FM_TASK_TMP_BASE="$base" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" \
    > "$TMP_ROOT/$id.out" 2> "$TMP_ROOT/$id.err"
  rc=$?
  set -e
  chmod 755 "$base"
  [ "$rc" = 0 ] || fail "teardown failed ($rc) because the temp root could not be removed"
  grep -q "could not be removed" "$TMP_ROOT/$id.err" \
    || fail "teardown did not report the temp root it could not remove"
  grep -q "teardown $id complete" "$TMP_ROOT/$id.out" \
    || fail "teardown did not complete after failing to remove the temp root"
  pass "fm-teardown reports an unremovable temp root and still completes"
}

# --- creation guard (bin/fm-task-tmp-lib.sh, as fm-spawn calls it) ---

# Create a canonical root the way fm-spawn does: same library, same
# FM_HOME/FM_ROOT, same sandbox base, in a subshell so the fake home does not
# leak into the rest of the suite.
create_task_tmp() {  # <fake-home> <root>
  local fake=$1 root=$2
  (
    FM_HOME=$fake
    FM_ROOT=$fake
    # shellcheck source=bin/fm-task-tmp-lib.sh
    . "$ROOT/bin/fm-task-tmp-lib.sh"
    fm_task_tmp_create "$root"
  )
}

# Portable directory mode, GNU and BSD stat disagreeing on the flag.
task_tmp_mode() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_create_makes_a_private_root_and_accepts_its_own() {
  local id=create-z9 fake task_tmp mode
  fake="$TMP_ROOT/$id"
  task_tmp=$(canonical_task_tmp "$fake" "$id")
  create_task_tmp "$fake" "$task_tmp" || fail "creating a fresh temp root failed"
  [ -d "$task_tmp/gotmp" ] || fail "creation did not make the Go temp directory"
  mode=$(task_tmp_mode "$task_tmp")
  [ "$mode" = 700 ] || fail "temp root is not private to its owner (mode $mode)"
  # A relaunch reuses its task's own root, so an already-owned root is accepted
  # with everything already in it.
  printf 'scratch\n' > "$task_tmp/scratch"
  create_task_tmp "$fake" "$task_tmp" || fail "re-creating this task's own temp root failed"
  [ -f "$task_tmp/scratch" ] || fail "re-creating the temp root discarded its contents"
  pass "fm-task-tmp-lib creates a private per-task root and accepts its own on reuse"
}

test_create_refuses_a_planted_symlink() {
  # The attack the guard exists for: another local user plants a symlink at the
  # predictable root name, and the launch would then pin TMPDIR through it and
  # hand the agent's whole scratch tree to a directory this user does not own.
  local id=create-symlink-z10 fake task_tmp target err
  fake="$TMP_ROOT/$id"
  target="$TMP_ROOT/planted-target-z10"
  err="$TMP_ROOT/$id.err"
  task_tmp=$(canonical_task_tmp "$fake" "$id")
  mkdir -p "$target"
  ln -s "$target" "$task_tmp"
  create_task_tmp "$fake" "$task_tmp" 2> "$err" \
    && fail "creation wrote through a symlink planted at the temp root"
  [ -z "$(ls -A "$target")" ] || fail "creation created directories through the planted symlink"
  [ -L "$task_tmp" ] || fail "creation removed the planted symlink instead of refusing"
  grep -q "refusing to use it" "$err" || fail "creation did not report the refused temp root"
  pass "fm-task-tmp-lib refuses a symlink planted at the temp root instead of writing through it"
}

test_create_refuses_a_non_directory() {
  local id=create-file-z11 fake task_tmp err
  fake="$TMP_ROOT/$id"
  err="$TMP_ROOT/$id.err"
  task_tmp=$(canonical_task_tmp "$fake" "$id")
  printf 'not a directory\n' > "$task_tmp"
  create_task_tmp "$fake" "$task_tmp" 2> "$err" \
    && fail "creation accepted a non-directory at the temp root"
  grep -q "refusing to use it" "$err" || fail "creation did not report the refused temp root"
  pass "fm-task-tmp-lib refuses a non-directory at the temp root"
}

test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_teardown_leaves_live_sibling_session_untouched
test_teardown_refuses_a_foreign_tasktmp
test_teardown_refuses_a_legacy_undiscriminated_tasktmp
test_teardown_refuses_a_symlinked_tasktmp
test_teardown_survives_an_unremovable_tasktmp
test_create_makes_a_private_root_and_accepts_its_own
test_create_refuses_a_planted_symlink
test_create_refuses_a_non_directory
