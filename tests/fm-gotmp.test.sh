#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# The fm-spawn side is verified both structurally (the source has the contract lines)
# and behaviorally (the mkdir + meta-write pattern it uses).
# Teardown cleanup is covered by tests/fm-teardown.test.sh's full lifecycle fixture.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"

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

# --- fm-spawn side ---

test_spawn_contract_and_mkdir_pattern() {
  # Structural: fm-spawn must create the gotmp dir, record tasktmp in meta, and export
  # GOTMPDIR into the pane. Assert the contract lines are present in the source.
  # shellcheck disable=SC2016  # single quotes are deliberate: these are literal source strings
  grep -F 'mkdir -p "$TASK_TMP/gotmp"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: mkdir of gotmp under TASK_TMP"
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

test_spawn_contract_and_mkdir_pattern
