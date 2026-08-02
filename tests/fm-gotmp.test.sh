#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each generation a unique temp root with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise the shared generation-path and descriptor-pinned cleanup helpers directly.
# The fm-spawn side is verified both structurally (the source has the contract lines)
# and behaviorally (the mkdir + meta-write pattern it uses).
# They also verify teardown wiring structurally.
# Teardown cleanup is covered by tests/fm-teardown-suite.sh's full lifecycle fixture.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
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
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# --- fm-spawn side ---

test_spawn_contract_and_mkdir_pattern() {
  # Structural: fm-spawn must create the gotmp dir, record tasktmp in meta, and export
  # GOTMPDIR into the pane. Assert the contract lines are present in the source.
  # shellcheck disable=SC2016  # single quotes are deliberate: these are literal source strings
  grep -F 'SPAWN_TASK_TMP=$(fm_account_task_tmp_path "$ID" "$SPAWN_GENERATION_ID")' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: generation-scoped task temp derivation"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'mkdir -p "$TASK_TMP/gotmp"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: generation-scoped task temp creation"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'echo "tasktmp=$TASK_TMP"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: tasktmp= line in meta write"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source pattern
  grep -E 'spawn_send_text_line .*GOTMPDIR=\$TASK_TMP/gotmp' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: GOTMPDIR export into pane"
  # Behavioral: the mkdir + meta-write pattern spawn uses must produce a gotmp dir and
  # a meta line whose value the teardown grep (tasktmp=, cut -d= -f2-) reads back whole.
  local id=spawn-sim-z1
  local sim_root="$TMP_ROOT/$id-root"
  local task_tmp="$sim_root/tmp/fm-$id"
  mkdir -p "$sim_root/state"
  # Replicate spawn's exact mkdir + meta-write lines.
  TASK_TMP="$task_tmp"
  mkdir -p "$TASK_TMP/gotmp"
  {
    echo "tasktmp=$TASK_TMP"
  } > "$sim_root/state/$id.meta"
  [ -d "$task_tmp/gotmp" ] || fail "simulated spawn did not create gotmp dir"
  # Teardown reads tasktmp= with `grep '^tasktmp=' | cut -d= -f2-`; round-trip it.
  local read_back
  read_back=$(grep '^tasktmp=' "$sim_root/state/$id.meta" | cut -d= -f2-)
  [ "$read_back" = "$task_tmp" ] \
    || fail "tasktmp value not round-tripped by teardown's grep|cut (got '$read_back')"
  pass "fm-spawn creates gotmp dir and records tasktmp in meta"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local generation=spawn:testgeneration
  local fake="$TMP_ROOT/$id-owner"
  mkdir -p "$fake/state"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  local task_tmp
  task_tmp=$(STATE="$fake/state" fm_account_task_tmp_path "$id" "$generation") \
    || fail "could not derive a generation-scoped task temp root"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  grep -F "safe_remove_task_tmp \"\$TASK_TMP\"" "$TEARDOWN" >/dev/null \
    || fail "fm-teardown no longer delegates exact task temp cleanup"
  STATE="$fake/state" FM_HOME="$fake" fm_account_safe_remove_task_tmp "$id" "$task_tmp" "$generation" \
    || fail "exact generation-scoped task temp cleanup failed"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  grep -F "[ -z \"\$TASK_TMP\" ] || safe_remove_task_tmp \"\$TASK_TMP\"" "$TEARDOWN" >/dev/null \
    || fail "teardown does not preserve the absent-tasktmp compatibility guard"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local fake="$TMP_ROOT/$id-owner"
  local generation=spawn:testgeneration
  mkdir -p "$fake/state"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  local task_tmp
  task_tmp=$(STATE="$fake/state" fm_account_task_tmp_path "$id" "$generation") \
    || fail "could not derive the absent generation-scoped task temp root"
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  STATE="$fake/state" FM_HOME="$fake" fm_account_safe_remove_task_tmp "$id" "$task_tmp" "$generation" \
    || fail "exact absent task temp cleanup failed"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_generation_roots_are_isolated_and_owned() {
  local id=same-task home_a="$TMP_ROOT/home-a" home_b="$TMP_ROOT/home-b"
  local generation_a=spawn:generationa generation_b=spawn:generationb generation_c=spawn:generationc
  local root_a root_b root_c
  mkdir -p "$home_a/state" "$home_b/state"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  root_a=$(STATE="$home_a/state" fm_account_task_tmp_path "$id" "$generation_a")
  root_b=$(STATE="$home_b/state" fm_account_task_tmp_path "$id" "$generation_b")
  [ "$root_a" != "$root_b" ] || fail "independent generations collided"
  mkdir -p "$root_a/gotmp" &
  local pid_a=$!
  mkdir -p "$root_b/gotmp" &
  local pid_b=$!
  local status_a=0 status_b=0
  wait "$pid_a" || status_a=$?
  wait "$pid_b" || status_b=$?
  if [ "$status_a" -ne 0 ] || [ "$status_b" -ne 0 ]; then
    fail "concurrent owned root creation failed"
  fi
  STATE="$home_a/state" FM_HOME="$home_a" fm_account_safe_remove_task_tmp "$id" "$root_a" "$generation_a" \
    || fail "first home could not remove its exact root"
  [ -d "$root_b" ] || fail "first home cleanup altered the second home root"
  STATE="$home_b/state" FM_HOME="$home_b" fm_account_safe_remove_task_tmp "$id" "$root_b" "$generation_b" \
    || fail "second home could not remove its exact root"
  root_c=$(STATE="$home_a/state" fm_account_task_tmp_path "$id" "$generation_c")
  [ "$root_c" != "$root_a" ] || fail "sequential reuse did not receive a new root"
  mkdir -p "$root_c/gotmp" || fail "sequential generation could not create its new root"
  STATE="$home_a/state" FM_HOME="$home_a" fm_account_safe_remove_task_tmp "$id" "$root_c" "$generation_c" \
    || fail "sequential generation cleanup failed"
  pass "same task ids use isolated roots across homes and generations"
}

test_forged_ownership_fails_closed() {
  local id=forged-root home="$TMP_ROOT/forged-home" generation=spawn:forgedgeneration root outside
  mkdir -p "$home/state"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  root=$(STATE="$home/state" fm_account_task_tmp_path "$id" "$generation")
  outside="$home/must-survive"
  mkdir -p "$outside"
  printf 'preserve\n' > "$outside/marker"
  mkdir -p "$(dirname "$root")"
  ln -s "$outside" "$root"
  if STATE="$home/state" FM_HOME="$home" fm_account_safe_remove_task_tmp "$id" "$root" "$generation"; then
    fail "redirected task temp root was accepted"
  fi
  [ -f "$outside/marker" ] || fail "redirected task temp cleanup altered outside data"
  rm "$root"
  mkdir -p "$root/gotmp"
  STATE="$home/state" FM_HOME="$home" fm_account_safe_remove_task_tmp "$id" "$root" "$generation" \
    || fail "exact descriptor-pinned recovery did not clean its root"
  pass "redirected ownership fails closed and exact recovery succeeds"
}

test_spawn_contract_and_mkdir_pattern
test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_generation_roots_are_isolated_and_owned
test_forged_ownership_fails_closed
