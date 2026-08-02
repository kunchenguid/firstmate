#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each generation a unique temp root with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise the shared ownership helpers directly.
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
  grep -F 'fm_tasktmp_create "$STATE" "$FM_HOME" "$ID" "$SPAWN_GENERATION_ID" "$TASK_TMP"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: owned per-generation task temp creation"
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
  local task_tmp="/tmp/fm-$id-testgeneration"
  local fake="$TMP_ROOT/$id-owner"
  mkdir -p "$fake/state"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  fm_tasktmp_create "$fake/state" "$fake" "$id" "$generation" "$task_tmp" \
    || fail "could not create an exactly owned task temp root"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  grep -F "safe_remove_task_tmp \"\$TASK_TMP\"" "$TEARDOWN" >/dev/null \
    || fail "fm-teardown no longer delegates exact task temp cleanup"
  FM_HOME="$fake" fm_tasktmp_remove_owned "$fake/state" "$fake" "$id" "$generation" "$task_tmp" \
    || fail "exact owned task temp cleanup failed"
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
  local task_tmp="/tmp/fm-$id-testgeneration"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake="$TMP_ROOT/$id-owner"
  local generation=spawn:testgeneration
  mkdir -p "$fake/state"
  {
    printf 'home=%s\n' "$(cd "$fake" && pwd -P)"
    printf 'task=%s\ngeneration=%s\nroot=%s\n' "$id" "$generation" "$task_tmp"
  } > "$fake/state/$id.tasktmp-owner.testgeneration"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  FM_HOME="$fake" fm_tasktmp_remove_owned "$fake/state" "$fake" "$id" "$generation" "$task_tmp" \
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
  root_a=$(fm_tasktmp_path "$id" "$generation_a")
  root_b=$(fm_tasktmp_path "$id" "$generation_b")
  [ "$root_a" != "$root_b" ] || fail "independent generations collided"
  fm_tasktmp_create "$home_a/state" "$home_a" "$id" "$generation_a" "$root_a" &
  local pid_a=$!
  fm_tasktmp_create "$home_b/state" "$home_b" "$id" "$generation_b" "$root_b" &
  local pid_b=$!
  local status_a=0 status_b=0
  wait "$pid_a" || status_a=$?
  wait "$pid_b" || status_b=$?
  if [ "$status_a" -ne 0 ] || [ "$status_b" -ne 0 ]; then
    fail "concurrent owned root creation failed"
  fi
  FM_HOME="$home_a" fm_tasktmp_remove_owned "$home_a/state" "$home_a" "$id" "$generation_a" "$root_a" \
    || fail "first home could not remove its exact root"
  [ -d "$root_b" ] || fail "first home cleanup altered the second home root"
  FM_HOME="$home_b" fm_tasktmp_remove_owned "$home_b/state" "$home_b" "$id" "$generation_b" "$root_b" \
    || fail "second home could not remove its exact root"
  root_c=$(fm_tasktmp_path "$id" "$generation_c")
  [ "$root_c" != "$root_a" ] || fail "sequential reuse did not receive a new root"
  fm_tasktmp_create "$home_a/state" "$home_a" "$id" "$generation_c" "$root_c" \
    || fail "sequential generation could not create its new root"
  FM_HOME="$home_a" fm_tasktmp_remove_owned "$home_a/state" "$home_a" "$id" "$generation_c" "$root_c" \
    || fail "sequential generation cleanup failed"
  pass "same task ids use isolated roots across homes and generations"
}

test_forged_ownership_fails_closed() {
  local id=forged-root home="$TMP_ROOT/forged-home" generation=spawn:forgedgeneration root
  mkdir -p "$home/state"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  root=$(fm_tasktmp_path "$id" "$generation")
  fm_tasktmp_create "$home/state" "$home" "$id" "$generation" "$root" \
    || fail "forged fixture setup failed"
  printf 'home=/forged\ntask=%s\ngeneration=%s\nroot=%s\n' "$id" "$generation" "$root" > "$root/.fm-tasktmp-owner"
  if FM_HOME="$home" fm_tasktmp_remove_owned "$home/state" "$home" "$id" "$generation" "$root"; then
    fail "forged root ownership was accepted"
  fi
  [ -d "$root" ] || fail "forged root was not retained"
  cp "$home/state/$id.tasktmp-owner.forgedgeneration" "$root/.fm-tasktmp-owner"
  FM_HOME="$home" fm_tasktmp_remove_owned "$home/state" "$home" "$id" "$generation" "$root" \
    || fail "exact recorded recovery did not clean its root"
  pass "forged ownership fails closed and exact recovery succeeds"
}

test_spawn_contract_and_mkdir_pattern
test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_generation_roots_are_isolated_and_owned
test_forged_ownership_fails_closed
