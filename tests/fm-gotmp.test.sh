#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a claimed unpredictable private root with Go's build
# temp nested at gotmp/, exports that exact path as GOTMPDIR, and records it in
# metadata.
# fm-teardown validates the recorded root and child again before scanning or
# removing either one.
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
PYTHON_BIN=$(command -v python3) || { echo 'not ok - test needs python3' >&2; exit 1; }
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasktmp-lib.sh
. "$ROOT/bin/fm-tasktmp-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

tasktmp_lstat_identity() {  # <path>
  "$PYTHON_BIN" -c 'import os, sys; s = os.lstat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$1"
}

tasktmp_lstat_mode() {  # <path>
  "$PYTHON_BIN" -c 'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' "$1"
}

# Fixture roots under the shared temporary parent carry a per-process nonce, and
# every fixture whose spelling must be the predictable legacy form carries it in
# the task id instead, so concurrent runs never collide on one /tmp name.
GOTMP_TMP_NONCE="gt$$gotmpfixture"

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
  ln -s "$ROOT/bin/fm-tasktmp-lib.sh" "$fake/bin/fm-tasktmp-lib.sh"
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
  local id="td-rm-z2-$$"
  local task_tmp="/tmp/fm-$id.$GOTMP_TMP_NONCE"
  rm -rf "$task_tmp"
  mkdir -p "$task_tmp/gotmp"
  chmod 700 "$task_tmp" "$task_tmp/gotmp"
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
  ln -s "$ROOT/bin/fm-tasktmp-lib.sh" "$fake/bin/fm-tasktmp-lib.sh"
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
  local id="td-missing-z4-$$"
  local task_tmp="/tmp/fm-$id.$GOTMP_TMP_NONCE"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_two_allocations_differ_and_abort_cleanup_is_complete() {
  local state="$TMP_ROOT/alloc-state" id="alloc-diff-z5-$$" first second
  mkdir -p "$state"
  first=$(fm_tasktmp_claim_create "$state" "$id") \
    || fail "first claimed allocation failed"
  assert_private_root "$id" "$first"
  fm_tasktmp_claim_reconcile_one "$state" "$id" \
    || fail "pre-publication failure cleanup did not reconcile the first root"
  [ ! -e "$first" ] && [ ! -L "$first" ] \
    || fail "pre-publication failure cleanup leaked the first root"
  [ ! -e "$state/$id.tasktmp-claim" ] \
    || fail "pre-publication failure cleanup leaked the claim"
  second=$(fm_tasktmp_claim_create "$state" "$id") \
    || fail "second claimed allocation failed"
  [ "$first" != "$second" ] || fail "two complete allocations reused one root"
  fm_tasktmp_claim_reconcile_one "$state" "$id" \
    || fail "second claimed root did not reconcile"
  pass "tasktmp allocator: complete allocations differ and pre-publication cleanup removes root plus claim"
}

assert_private_root() {  # <id> <path>
  local id=$1 path=$2
  fm_tasktmp_validate "$id" "$path" \
    || fail "claimed root failed shared validation: $FM_TASKTMP_ERROR"
  fm_tasktmp_lstat "$path" || fail "claimed root cannot be inspected"
  [ "$FM_TASKTMP_STAT_UID:$FM_TASKTMP_STAT_MODE" = "$(id -u):700" ] \
    || fail "claimed root is not private and current-user-owned"
  case "$FM_TASKTMP_STAT_TYPE" in directory|Directory) ;; *) fail "claimed root is not a real directory" ;; esac
  fm_tasktmp_lstat "$path/gotmp" || fail "claimed gotmp cannot be inspected"
  [ "$FM_TASKTMP_STAT_UID:$FM_TASKTMP_STAT_MODE" = "$(id -u):700" ] \
    || fail "claimed gotmp is not private and current-user-owned"
  case "$FM_TASKTMP_STAT_TYPE" in directory|Directory) ;; *) fail "claimed gotmp is not a real directory" ;; esac
}

test_startup_reconciles_only_when_locked() {
  local home="$TMP_ROOT/startup-home" state id="startup-crash-z6-$$" root out
  state=$home/state
  mkdir -p "$state" "$home/data" "$home/config" "$home/projects"
  root=$(fm_tasktmp_claim_create "$state" "$id") || fail "startup fixture allocation failed"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  case "$out" in *"read-only startup left it untouched"*) ;; *) fail "read-only startup did not report the pending claim" ;; esac
  [ -d "$root" ] && [ -f "$state/$id.tasktmp-claim" ] \
    || fail "read-only startup mutated the pending root or claim"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 \
    || fail "locked startup did not complete claim reconciliation"
  [ ! -e "$root" ] && [ ! -e "$state/$id.tasktmp-claim" ] \
    || fail "locked startup did not remove the abandoned root and claim"
  pass "tasktmp startup: real read-only bootstrap reports without mutation and real locked bootstrap cleans a crash remnant"
}

test_startup_reports_unsafe_recorded_root_without_mutating_task() {
  local home="$TMP_ROOT/startup-unsafe-home" state id="startup-unsafe-z10-$$"
  local root target meta out inode mode
  state=$home/state
  root=/tmp/fm-$id
  target=$home/hostile-target
  meta=$state/$id.meta
  rm -rf -- "$root" "$target"
  mkdir -p "$state" "$home/data" "$home/config" "$home/projects" "$target/gotmp"
  chmod 0777 "$target" "$target/gotmp"
  printf 'startup sentinel\n' > "$target/gotmp/sentinel"
  ln -s "$target" "$root"
  printf 'window=fake\nkind=ship\ntasktmp=%s\n' "$root" > "$meta"
  inode=$(tasktmp_lstat_identity "$root")
  mode=$(tasktmp_lstat_mode "$target")
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  case "$out" in *"TASKTMP_RECONCILE: $id: unsafe recorded"*) ;; *) fail "startup did not report the unsafe live recorded root" ;; esac
  [ -f "$meta" ] && [ -L "$root" ] \
    || fail "startup audit changed the unsafe task or symlink"
  [ "$(tasktmp_lstat_identity "$root")" = "$inode" ] && [ "$(tasktmp_lstat_mode "$target")" = "$mode" ] \
    || fail "startup audit changed unsafe path identity or permissions"
  grep -qx 'startup sentinel' "$target/gotmp/sentinel" \
    || fail "startup audit changed the unsafe sentinel"
  rm -f -- "$root"
  pass "tasktmp startup: an unsafe recorded live root is reported and quarantined without mutation"
}

test_claim_transfers_to_metadata_without_removing_root() {
  local state="$TMP_ROOT/transfer-state" id="transfer-z7-$$" root
  mkdir -p "$state"
  root=$(fm_tasktmp_claim_create "$state" "$id") || fail "transfer fixture allocation failed"
  printf 'window=fake\ntasktmp=%s\n' "$root" > "$state/$id.meta"
  fm_tasktmp_claim_mark_committed "$state" "$id" \
    || fail "transfer fixture could not record its commit point"
  fm_tasktmp_startup "$state" locked >/dev/null \
    || fail "locked startup did not transfer a matching claim"
  [ -d "$root/gotmp" ] || fail "claim transfer deleted the metadata-owned live root"
  [ ! -e "$state/$id.tasktmp-claim" ] || fail "claim transfer did not retire the claim"
  fm_tasktmp_remove "$id" "$root" || fail "transferred root cleanup failed"
  pass "tasktmp claim: matching published metadata takes ownership without deleting the live root"
}

test_entropy_failure_never_falls_back_to_predictable_root() {
  local state="$TMP_ROOT/entropy-state" fakebin="$TMP_ROOT/entropy-bin" out rc
  local id="entropy-z11-$$"
  local predictable="/tmp/fm-$id"
  mkdir -p "$state" "$fakebin"
  rm -rf -- "$predictable"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/mktemp"
  out=$(PATH="$fakebin:$PATH" fm_tasktmp_claim_create "$state" "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "entropy failure unexpectedly allocated a root"
  case "$out" in *"failed safely"*) ;; *"could not create a private random"*) ;; *) fail "entropy failure was not loud" ;; esac
  [ ! -e "$predictable" ] && [ ! -L "$predictable" ] \
    || fail "entropy failure fell back to the predictable legacy root"
  [ ! -e "$state/$id.tasktmp-claim" ] \
    || fail "entropy failure published a claim without a random candidate"
  pass "tasktmp allocator: entropy failure refuses and never falls back to the predictable path"
}

test_collision_is_refused_without_entering_or_deleting_candidate() {
  local state="$TMP_ROOT/collision-state" id="collision-z8-$$"
  local parent candidate inode mode out rc
  mkdir -p "$state"
  parent=$(fm_tasktmp_parent) || fail "trusted temp parent unavailable"
  candidate="$parent/fm-$id.$GOTMP_TMP_NONCE"
  rm -rf -- "$candidate"
  mkdir -p "$candidate/gotmp"
  chmod 0777 "$candidate" "$candidate/gotmp"
  printf 'collision sentinel\n' > "$candidate/gotmp/sentinel"
  inode=$(tasktmp_lstat_identity "$candidate")
  mode=$(tasktmp_lstat_mode "$candidate")
  # Pin the draw inside the substitution subshell so the allocator lands on the
  # pre-existing hostile candidate; everything downstream of the nonce is the
  # real allocator, and the override never escapes this call.
  out=$(
    # shellcheck disable=SC2329 # Invoked indirectly: it pins the nonce draw.
    fm_tasktmp_nonce() { printf '%s\n' "$GOTMP_TMP_NONCE"; }
    FM_TASKTMP_CLAIM_ATTEMPTS=1 fm_tasktmp_claim_create "$state" "$id" 2>&1
  ); rc=$?
  [ "$rc" -ne 0 ] || fail "collision candidate was adopted"
  case "$out" in *"collision-free"*) ;; *) fail "collision refusal was not loud" ;; esac
  [ "$(tasktmp_lstat_identity "$candidate")" = "$inode" ] \
    || fail "collision refusal replaced the candidate"
  [ "$(tasktmp_lstat_mode "$candidate")" = "$mode" ] \
    || fail "collision refusal changed candidate permissions"
  grep -qx 'collision sentinel' "$candidate/gotmp/sentinel" \
    || fail "collision refusal entered or changed the candidate"
  [ ! -e "$state/$id.tasktmp-claim" ] \
    || fail "collision refusal left a claim for a root it never created"
  rm -rf -- "$candidate"
  pass "tasktmp allocator: a collided candidate is never entered, changed, adopted, or deleted"
}

test_teardown_refuses_unsafe_tasktmp_without_touching_it() {
  local id="td-unsafe-z9-$$" task_tmp target fake out rc inode mode
  task_tmp="/tmp/fm-$id"
  target="$TMP_ROOT/unsafe-target"
  rm -rf -- "$task_tmp" "$target"
  mkdir -p "$target/gotmp"
  chmod 0777 "$target" "$target/gotmp"
  printf 'unsafe sentinel\n' > "$target/gotmp/sentinel"
  ln -s "$target" "$task_tmp"
  inode=$(tasktmp_lstat_identity "$target")
  mode=$(tasktmp_lstat_mode "$target")
  fake=$(make_fake_root "$id" "$task_tmp")
  out=$(FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "one unsafe task root stranded the whole teardown: $out"
  case "$out" in *"Nothing under that path is scanned, changed, or removed"*) ;; *) fail "unsafe teardown refusal did not state its no-touch result" ;; esac
  case "$out" in *"was preserved untouched for an operator"*) ;; *) fail "the completion line did not name the preserved untrusted root" ;; esac
  [ -L "$task_tmp" ] && [ "$(readlink "$task_tmp")" = "$target" ] \
    || fail "unsafe teardown refusal changed the symlink"
  [ "$(tasktmp_lstat_identity "$target")" = "$inode" ] && [ "$(tasktmp_lstat_mode "$target")" = "$mode" ] \
    || fail "unsafe teardown refusal changed the target"
  grep -qx 'unsafe sentinel' "$target/gotmp/sentinel" \
    || fail "unsafe teardown refusal changed the sentinel"
  [ ! -e "$fake/state/$id.meta" ] \
    || fail "the refusal was not scoped to the temporary root: the task record survived teardown"
  rm -f -- "$task_tmp"
  pass "fm-teardown preserves an unsafe root untouched and still completes the rest of the teardown"
}

test_teardown_refusal_is_durably_re_reported_after_the_task_record_is_gone() {
  local id="td-durable-z20-$$" task_tmp target fake state record out rc inode mode
  task_tmp="/tmp/fm-$id"
  target="$TMP_ROOT/durable-target"
  rm -rf -- "$task_tmp" "$target"
  mkdir -p "$target/gotmp"
  chmod 0777 "$target" "$target/gotmp"
  printf 'durable sentinel\n' > "$target/gotmp/sentinel"
  ln -s "$target" "$task_tmp"
  inode=$(tasktmp_lstat_identity "$target")
  mode=$(tasktmp_lstat_mode "$target")
  fake=$(make_fake_root "$id" "$task_tmp")
  state=$fake/state
  mkdir -p "$fake/config" "$fake/projects"
  record=$state/$id.tasktmp-refused
  out=$(FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "the refusing teardown did not complete the rest of its work: $out"
  [ ! -e "$state/$id.meta" ] \
    || fail "the fixture no longer exercises the case where the only tasktmp= carrier is removed"
  [ -f "$record" ] || fail "teardown left no durable record of the refused root"
  [ "$(tasktmp_lstat_mode "$record")" = 600 ] \
    || fail "the durable refusal record is not private"
  # A later session has no task record left to scan, so the refused path can only
  # be named again from the durable record teardown wrote.
  out=$(FM_HOME="$fake" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  case "$out" in
    *"TASKTMP_RECONCILE: $id: refused task temporary root $task_tmp is still present"*) ;;
    *) fail "read-only startup did not re-report the refused root: $out" ;;
  esac
  [ -f "$record" ] || fail "read-only startup retired the refusal record"
  out=$(FM_HOME="$fake" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  case "$out" in
    *"TASKTMP_RECONCILE: $id: refused task temporary root $task_tmp is still present"*) ;;
    *) fail "locked startup did not re-report the still-present refused root: $out" ;;
  esac
  [ -f "$record" ] \
    || fail "locked startup retired a record whose refused path is still on disk"
  [ -L "$task_tmp" ] && [ "$(readlink "$task_tmp")" = "$target" ] \
    || fail "re-reporting changed the refused symlink"
  [ "$(tasktmp_lstat_identity "$target")" = "$inode" ] && [ "$(tasktmp_lstat_mode "$target")" = "$mode" ] \
    || fail "re-reporting changed the refused path's identity or permissions"
  grep -qx 'durable sentinel' "$target/gotmp/sentinel" \
    || fail "re-reporting changed the refused path's contents"
  # An operator resolving the path is what ends the report.
  rm -f -- "$task_tmp"
  out=$(FM_HOME="$fake" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  case "$out" in
    *"BOOTSTRAP_INFO: $id: previously refused task temporary root $task_tmp is gone"*) ;;
    *) fail "locked startup did not retire the record once the refused path was gone: $out" ;;
  esac
  [ ! -e "$record" ] || fail "the resolved refusal record was not retired"
  rm -f -- "$task_tmp"
  pass "fm-teardown records a refused root durably and every later startup re-reports it until it is gone"
}

test_teardown_reports_a_refusal_record_it_could_not_write() {
  local id="td-norecord-z21-$$" task_tmp target fake state fakebin real_mv out rc inode
  task_tmp="/tmp/fm-$id"
  target="$TMP_ROOT/norecord-target"
  rm -rf -- "$task_tmp" "$target"
  mkdir -p "$target/gotmp"
  chmod 0777 "$target" "$target/gotmp"
  printf 'norecord sentinel\n' > "$target/gotmp/sentinel"
  ln -s "$target" "$task_tmp"
  inode=$(tasktmp_lstat_identity "$target")
  fake=$(make_fake_root "$id" "$task_tmp")
  state=$fake/state
  # A full or read-only state directory fails the record's publication rename.
  fakebin="$TMP_ROOT/norecord-bin"
  mkdir -p "$fakebin"
  real_mv=$(command -v mv) || fail "the fixture needs a real mv"
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in *.tasktmp-refused) exit 1 ;; esac
done
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "an unrecordable refusal stranded the rest of the teardown: $out"
  [ ! -e "$state/$id.meta" ] \
    || fail "the rest of the teardown did not complete"
  [ ! -e "$state/$id.tasktmp-refused" ] \
    || fail "the fixture did not actually block the durable record"
  case "$out" in
    *"could NOT be recorded for re-reporting"*) ;;
    *) fail "teardown did not say the refusal is unrecorded: $out" ;;
  esac
  case "$out" in
    *"recorded at $state/$id.tasktmp-refused for re-reporting"*)
      fail "the completion line promised a record teardown never wrote" ;;
  esac
  [ -L "$task_tmp" ] && [ "$(tasktmp_lstat_identity "$target")" = "$inode" ] \
    || fail "the unrecorded refusal still changed the refused path"
  grep -qx 'norecord sentinel' "$target/gotmp/sentinel" \
    || fail "the unrecorded refusal changed the refused path's contents"
  rm -f -- "$task_tmp"
  pass "fm-teardown says the refusal is unrecorded rather than promising a record it could not write"
}

test_unresolvable_trusted_parent_refuses_instead_of_allocating() {
  local state="$TMP_ROOT/parent-state" id="parent-refuse-z12-$$" out rc
  mkdir -p "$state"
  # An overriding cd makes the trusted temporary parent unresolvable, which is
  # the one trust check that must never fall through to an empty parent.
  # A fresh process is the honest fixture: the parent resolves once per process,
  # so this proves the very first resolution failure refuses rather than
  # inheriting an answer this suite already cached.
  rc=0
  out=$(bash -c '
set -u
# shellcheck source=/dev/null
. "$1/bin/fm-tasktmp-lib.sh"
cd() { return 1; }
fm_tasktmp_claim_create "$2" "$3" 2>&1
' _ "$ROOT" "$state" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unresolvable trusted temporary parent still allocated a root"
  case "$out" in
    *"trusted temporary parent"*) ;;
    *) fail "an unresolvable trusted temporary parent did not refuse loudly: $out" ;;
  esac
  # A parent that fails OPEN would keep going with an empty parent, publish a
  # claim, and only give up after exhausting its collision attempts against
  # candidates rooted at the filesystem root.
  case "$out" in
    *"collision-free"*) fail "the allocator kept going after an unresolvable parent" ;;
  esac
  [ -z "$(find / -maxdepth 1 -name "fm-$id.*" -print -quit 2>/dev/null)" ] \
    || fail "an unresolvable parent was used as an empty prefix for a real candidate"
  [ ! -e "$state/$id.tasktmp-claim" ] \
    || fail "a refused allocation published a claim anyway"
  [ -z "$(find "$state" -maxdepth 1 -name "*.tasktmp-claim*" -print -quit 2>/dev/null)" ] \
    || fail "a refused allocation left a private claim candidate behind"
  pass "tasktmp allocator: an unresolvable trusted temporary parent refuses before any candidate exists"
}

test_startup_reaches_route_scoped_state_directories() {
  local home="$TMP_ROOT/route-home" state route id="route-remnant-z22-$$" root refused out
  state=$home/state
  route=$state/parent-route
  mkdir -p "$route" "$home/data" "$home/config" "$home/projects"
  # A remote-routed secondmate keeps its whole lifecycle one level down, so this
  # is where its crash remnant and its refused-root record really land.
  root=$(fm_tasktmp_claim_create "$route" "$id") \
    || fail "the route fixture could not allocate its claimed root"
  refused="$TMP_ROOT/route-refused-target"
  mkdir -p "$refused"
  fm_tasktmp_refusal_record "$route" "$id" "$refused" "route fixture refusal" \
    || fail "the route fixture could not record a refused root"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  case "$out" in
    *"TASKTMP_RECONCILE: $id: pending task temporary claim"*) ;;
    *) fail "read-only startup never saw the route-scoped pending claim: $out" ;;
  esac
  case "$out" in
    *"refused task temporary root $refused is still present"*) ;;
    *) fail "read-only startup never re-reported the route-scoped refusal: $out" ;;
  esac
  [ -d "$root/gotmp" ] && [ -f "$route/$id.tasktmp-claim" ] \
    || fail "read-only startup mutated the route-scoped root or claim"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  [ ! -e "$root" ] && [ ! -e "$route/$id.tasktmp-claim" ] \
    || fail "locked startup did not reconcile the route-scoped crash remnant"
  case "$out" in
    *"refused task temporary root $refused is still present"*) ;;
    *) fail "locked startup dropped the route-scoped refusal while its path is still on disk: $out" ;;
  esac
  [ -f "$route/$id.tasktmp-refused" ] \
    || fail "locked startup retired a route-scoped record whose path still exists"
  rmdir "$refused"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  case "$out" in
    *"BOOTSTRAP_INFO: $id: previously refused task temporary root $refused is gone"*) ;;
    *) fail "locked startup did not retire the resolved route-scoped record: $out" ;;
  esac
  [ ! -e "$route/$id.tasktmp-refused" ] \
    || fail "the resolved route-scoped refusal record was not retired"
  rm -rf -- "$root"
  pass "tasktmp startup: route-scoped state directories are reconciled and re-reported like the home's own"
}

test_crash_before_the_commit_point_transfers_an_identical_recorded_root() {
  local state="$TMP_ROOT/crashwindow-state" id="crash-window-z13-$$" root second
  mkdir -p "$state"
  root=$(fm_tasktmp_claim_create "$state" "$id") || fail "crash-window fixture allocation failed"
  printf 'window=fake\ntasktmp=%s\n' "$root" > "$state/$id.meta"
  # No mark-committed: this is the SIGKILL window between metadata publication
  # and the spawn's commit point.
  fm_tasktmp_startup "$state" locked >/dev/null \
    || fail "locked startup did not retire a claim its metadata already owns"
  [ -d "$root/gotmp" ] || fail "the completed transfer deleted the metadata-owned live root"
  [ ! -e "$state/$id.tasktmp-claim" ] \
    || fail "the crash window left the task id permanently unspawnable"
  second=$(fm_tasktmp_claim_create "$state" "$id") \
    || fail "the task id could not allocate again after the crash window"
  fm_tasktmp_claim_reconcile_one "$state" "$id" >/dev/null 2>&1 || true
  rm -rf -- "$second"
  fm_tasktmp_remove "$id" "$root" || fail "transferred crash-window root cleanup failed"
  pass "tasktmp claim: a crash before the commit point is retired as a completed transfer, not a permanent wedge"
}

test_crash_window_preserves_a_recorded_root_that_no_longer_validates() {
  local state="$TMP_ROOT/crashunsafe-state" id="crash-unsafe-z14-$$" root out rc
  mkdir -p "$state"
  root=$(fm_tasktmp_claim_create "$state" "$id") || fail "crash-window fixture allocation failed"
  printf 'window=fake\ntasktmp=%s\n' "$root" > "$state/$id.meta"
  chmod 0777 "$root"
  out=$(fm_tasktmp_startup "$state" locked); rc=$?
  [ "$rc" -ne 0 ] || fail "an unsafe claimed root was retired as a completed transfer"
  case "$out" in
    *"TASKTMP_RECONCILE: $id: pending task temporary claim was preserved"*) ;;
    *) fail "the preserved claim was not reported: $out" ;;
  esac
  [ -f "$state/$id.tasktmp-claim" ] || fail "an unsafe claimed root retired its claim"
  [ -d "$root/gotmp" ] || fail "an unsafe claimed root was removed"
  chmod 700 "$root"
  rm -rf -- "$root"
  pass "tasktmp claim: identical metadata never retires a claimed root that stopped validating"
}

# Hold the per-task spawn lock exactly the way fm-spawn does - through the real
# fm_lock_try_acquire producer in a separate live process - so this fixture
# cannot drift from the lock layout the read-only audit reads.
start_real_spawn_lock_holder() {  # <state> <task-id> <ready-file>
  local state=$1 id=$2 ready=$3 holder waited
  holder="$TMP_ROOT/hold-spawn-lock-$id.sh"
  cat > "$holder" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck source=/dev/null
. "$1/bin/fm-wake-lib.sh"
STATE=$2
fm_lock_try_acquire "$2/.spawn-$3.lock" || exit 1
: > "$4"
exec sleep 300
SH
  chmod +x "$holder"
  bash "$holder" "$ROOT" "$state" "$id" "$ready" &
  SPAWN_LOCK_HOLDER_PID=$!
  waited=0
  while [ ! -e "$ready" ]; do
    kill -0 "$SPAWN_LOCK_HOLDER_PID" 2>/dev/null \
      || fail "the real spawn-lock holder exited before it acquired the lock"
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || fail "the real spawn-lock holder never acquired the lock"
    sleep 0.05
  done
}

test_crash_window_retires_a_claim_whose_recorded_root_already_vanished() {
  local state="$TMP_ROOT/crashgone-state" id="crash-gone-z16-$$" root second
  mkdir -p "$state"
  root=$(fm_tasktmp_claim_create "$state" "$id") || fail "crash-window fixture allocation failed"
  printf 'window=fake\ntasktmp=%s\n' "$root" > "$state/$id.meta"
  # The claim never reached its commit point and a reaper then took the root.
  rm -rf -- "$root"
  fm_tasktmp_claim_reconcile_one "$state" "$id" \
    || fail "an already-absent claimed root was preserved as an error"
  [ ! -e "$state/$id.tasktmp-claim" ] \
    || fail "an already-absent claimed root left the task id permanently unspawnable"
  second=$(fm_tasktmp_claim_create "$state" "$id") \
    || fail "the task id could not allocate again after its root vanished"
  fm_tasktmp_claim_reconcile_one "$state" "$id" >/dev/null 2>&1 || true
  rm -rf -- "$second"
  pass "tasktmp claim: an identically recorded root that is already gone retires rather than wedging the id"
}

test_reuse_restores_a_vanished_gotmp_child_in_its_own_root() {
  local state="$TMP_ROOT/regotmp-state" id="regotmp-z17-$$" root reused
  mkdir -p "$state"
  root=$(fm_tasktmp_claim_create "$state" "$id") || fail "gotmp-restore fixture allocation failed"
  printf 'window=fake\ntasktmp=%s\n' "$root" > "$state/$id.meta"
  fm_tasktmp_claim_mark_committed "$state" "$id" >/dev/null \
    || fail "gotmp-restore fixture could not record its commit point"
  fm_tasktmp_claim_transfer "$state" "$id" "$state/$id.meta" \
    || fail "gotmp-restore fixture could not transfer ownership"
  # The task's own agent removed $GOTMPDIR; the root itself is still ours.
  rm -rf -- "$root/gotmp"
  fm_tasktmp_trust "$id" "$root"
  [ "$FM_TASKTMP_TRUST" = incomplete ] \
    || fail "a task-owned 0700 root missing only its gotmp child reported as $FM_TASKTMP_TRUST"
  reused=$(fm_tasktmp_recorded_prepare "$state" "$id" "$root") \
    || fail "reuse refused a root it still owns: $FM_TASKTMP_ERROR"
  [ "$reused" = "$root" ] || fail "reuse reallocated instead of restoring: $reused"
  fm_tasktmp_trust "$id" "$root"
  [ "$FM_TASKTMP_TRUST" = trusted ] \
    || fail "reuse returned a root whose gotmp child is still unusable"
  [ "$(tasktmp_lstat_mode "$root/gotmp")" = 700 ] \
    || fail "the restored gotmp child is not private"
  fm_tasktmp_remove "$id" "$root" || fail "restored root cleanup failed"
  pass "tasktmp reuse: a vanished gotmp child is restored inside the root the task already owns"
}

test_teardown_removes_a_root_whose_gotmp_child_vanished() {
  local id="td-nogotmp-z18-$$" task_tmp fake
  task_tmp="/tmp/fm-$id.$GOTMP_TMP_NONCE"
  rm -rf -- "$task_tmp"
  mkdir -p "$task_tmp"
  chmod 700 "$task_tmp"
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown refused a task-owned root whose gotmp child had vanished"
  [ ! -e "$task_tmp" ] \
    || fail "teardown leaked a task-owned root whose gotmp child had vanished"
  [ ! -e "$fake/state/$id.meta" ] || fail "teardown did not complete"
  pass "fm-teardown removes a task-owned root whose gotmp child vanished instead of leaking it"
}

test_ambiguous_metadata_preserves_the_claimed_root() {
  local state="$TMP_ROOT/ambiguous-state" id="ambiguous-z19-$$" root out rc
  mkdir -p "$state"
  root=$(fm_tasktmp_claim_create "$state" "$id") || fail "ambiguous-metadata fixture allocation failed"
  printf 'window=fake\ntasktmp=%s\ntasktmp=%s\n' "$root" "$root" > "$state/$id.meta"
  out=$(fm_tasktmp_claim_reconcile_one "$state" "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "reconciliation claimed success against unprovable ownership"
  case "$out" in *"duplicate or unreadable tasktmp fields"*) ;; *) fail "the ambiguous field was not named: $out" ;; esac
  [ -d "$root/gotmp" ] || fail "reconciliation deleted a root whose ownership it could not establish"
  [ -f "$state/$id.tasktmp-claim" ] || fail "reconciliation retired a claim it could not reconcile"
  rm -f -- "$state/$id.meta"
  fm_tasktmp_claim_reconcile_one "$state" "$id" >/dev/null 2>&1 || true
  rm -rf -- "$root"
  pass "tasktmp claim: metadata with duplicate tasktmp fields preserves and reports instead of deleting the root"
}

test_candidate_nonce_is_never_a_listable_state_filename() {
  local state="$TMP_ROOT/nonce-state" fakebin="$TMP_ROOT/nonce-bin" id="nonce-z20-$$"
  local listing real_chmod real_mkdir root nonce
  listing="$TMP_ROOT/nonce-state-listing"
  mkdir -p "$state" "$fakebin"
  : > "$listing"
  real_chmod=$(command -v chmod) || fail "test needs chmod"
  real_mkdir=$(command -v mkdir) || fail "test needs mkdir"
  # Snapshot the state directory across the whole window in which a claim names
  # a path that does not exist yet: chmod runs while the private claim is still
  # at its temporary name, mkdir runs when the candidate root is created.
  # Nothing listable there may carry the candidate's name.
  cat > "$fakebin/chmod" <<SH
#!/usr/bin/env bash
ls -a "$state" >> "$listing" 2>/dev/null || true
exec "$real_chmod" "\$@"
SH
  cat > "$fakebin/mkdir" <<SH
#!/usr/bin/env bash
ls -a "$state" >> "$listing" 2>/dev/null || true
exec "$real_mkdir" "\$@"
SH
  chmod +x "$fakebin/chmod" "$fakebin/mkdir"
  root=$(PATH="$fakebin:$PATH" fm_tasktmp_claim_create "$state" "$id") \
    || fail "nonce fixture allocation failed"
  nonce=${root##*.}
  [ -s "$listing" ] || fail "the fixture never observed the candidate-creation window"
  if grep -q -- "$nonce" "$listing"; then
    fail "the candidate nonce was a listable state filename before its root existed"
  fi
  fm_tasktmp_claim_reconcile_one "$state" "$id" >/dev/null 2>&1 || true
  rm -rf -- "$root"
  pass "tasktmp allocator: the candidate nonce never appears as a filename in the state directory"
}

test_read_only_startup_reports_a_live_spawn_as_an_ordinary_fact() {
  local state="$TMP_ROOT/readonly-live-state" id="readonly-live-z15-$$" root lock out rc
  mkdir -p "$state"
  root=$(fm_tasktmp_claim_create "$state" "$id") || fail "read-only fixture allocation failed"
  lock=$state/.spawn-$id.lock
  SPAWN_LOCK_HOLDER_PID=
  start_real_spawn_lock_holder "$state" "$id" "$TMP_ROOT/readonly-live-ready"
  [ -L "$lock" ] || fail "the real lock producer no longer publishes the spawn lock as a symlink"
  out=$(fm_tasktmp_startup "$state" read-only); rc=$?
  [ "$rc" -eq 0 ] || fail "an in-flight spawn made read-only startup report an unreconciled remnant"
  case "$out" in *"BOOTSTRAP_INFO: $id: pending task temporary claim"*) ;; *) fail "a live spawn's claim was not reported as an ordinary fact: $out" ;; esac
  case "$out" in *TASKTMP_RECONCILE*) fail "an ordinary in-flight spawn raised an actionable reconcile diagnostic" ;; esac
  [ -d "$root/gotmp" ] && [ -f "$state/$id.tasktmp-claim" ] \
    || fail "read-only startup mutated a live spawn's root or claim"
  # The same lock, now abandoned by a dead holder, is a remnant again.
  kill "$SPAWN_LOCK_HOLDER_PID" 2>/dev/null || true
  wait "$SPAWN_LOCK_HOLDER_PID" 2>/dev/null || true
  [ -L "$lock" ] || fail "killing the holder removed the lock this case still needs"
  out=$(fm_tasktmp_startup "$state" read-only); rc=$?
  [ "$rc" -ne 0 ] || fail "a claim whose spawn already died was not reported for locked reconciliation"
  case "$out" in *"TASKTMP_RECONCILE: $id: pending task temporary claim"*) ;; *) fail "an abandoned pending claim lost its actionable line: $out" ;; esac
  [ -d "$root/gotmp" ] && [ -f "$state/$id.tasktmp-claim" ] \
    || fail "read-only startup mutated an abandoned root or claim"
  fm_tasktmp_claim_reconcile_one "$state" "$id" >/dev/null 2>&1 || true
  rm -rf -- "$root"
  pass "tasktmp startup: a really-held spawn lock reports as an ordinary fact and an abandoned one stays actionable"
}

test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_two_allocations_differ_and_abort_cleanup_is_complete
test_startup_reconciles_only_when_locked
test_startup_reports_unsafe_recorded_root_without_mutating_task
test_claim_transfers_to_metadata_without_removing_root
test_entropy_failure_never_falls_back_to_predictable_root
test_collision_is_refused_without_entering_or_deleting_candidate
test_teardown_refuses_unsafe_tasktmp_without_touching_it
test_teardown_refusal_is_durably_re_reported_after_the_task_record_is_gone
test_teardown_reports_a_refusal_record_it_could_not_write
test_unresolvable_trusted_parent_refuses_instead_of_allocating
test_crash_before_the_commit_point_transfers_an_identical_recorded_root
test_startup_reaches_route_scoped_state_directories
test_crash_window_preserves_a_recorded_root_that_no_longer_validates
test_crash_window_retires_a_claim_whose_recorded_root_already_vanished
test_reuse_restores_a_vanished_gotmp_child_in_its_own_root
test_teardown_removes_a_root_whose_gotmp_child_vanished
test_ambiguous_metadata_preserves_the_claimed_root
test_candidate_nonce_is_never_a_listable_state_filename
test_read_only_startup_reports_a_live_spawn_as_an_ordinary_fact
