#!/usr/bin/env bash
# tests/fm-run-bind.test.sh - bin/fm-run-bind.sh, which records `nm_run=<run-id>`
# in a task's record so bin/fm-crew-state.sh can tell concurrent crews on ONE
# branch apart. The run id is the only unambiguous identifier no-mistakes
# exposes, and only the crew that started a run knows which id is its own.
# A lost or STALE binding degrades to the branch guess this command exists to
# improve on, rather than to a confident wrong answer: bin/fm-crew-state.sh
# declines a bound run that has reached a terminal outcome while the repo is
# currently running a different id on the same branch, and falls through to the
# unbound path (its header owns that rule). So a missed re-bind is self-healing,
# and re-binding on every run start - which case (b) pins - is what keeps the
# crew on the sharper answer.
#
#   (a) a first bind records the key and leaves every other key intact
#   (b) re-binding REPLACES the value rather than accumulating, so a restarted
#       run leaves exactly one binding behind
#   (c) re-binding the same id is a no-op that still reports success
#   (d) an unknown task is refused and nothing is created
#   (e) a malformed run id is refused and an existing binding is left untouched
#   (f) a malformed task id is refused
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIND="$ROOT/bin/fm-run-bind.sh"
TMP_ROOT=$(fm_test_tmproot fm-run-bind)

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

run_bind() {  # <case-dir> <args...>
  local d=$1
  shift
  FM_STATE_OVERRIDE="$d/state" "$BIND" "$@"
}

meta_bindings() {  # <meta> -> every nm_run= line, so accumulation is visible
  grep -c '^nm_run=' "$1" 2>/dev/null || true
}

meta_binding() {  # <meta> -> the effective value readers see (last wins)
  grep '^nm_run=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

test_first_bind_records_the_run() {
  local d meta out
  d=$(new_case first)
  meta="$d/state/feat.meta"
  fm_write_meta "$meta" "window=fm:fm-feat" "worktree=$d/wt" "kind=ship" "mode=no-mistakes"
  out=$(run_bind "$d" feat 01RUNAAAAAAAAAAAAAAAAAAAAA)
  assert_contains "$out" "bound feat to run 01RUNAAAAAAAAAAAAAAAAAAAAA" "the bind is reported"
  [ "$(meta_binding "$meta")" = 01RUNAAAAAAAAAAAAAAAAAAAAA ] || fail "the run id was not recorded"
  assert_grep "kind=ship" "$meta" "binding must not disturb the existing record"
  assert_grep "worktree=$d/wt" "$meta" "binding must not disturb the worktree"
  assert_grep "mode=no-mistakes" "$meta" "binding must not disturb the delivery mode"
  pass "a first bind records the run id and leaves the rest of the record intact"
}

test_rebind_replaces_the_previous_value() {
  local d meta out
  d=$(new_case rebind)
  meta="$d/state/feat.meta"
  fm_write_meta "$meta" "window=fm:fm-feat" "worktree=$d/wt" "kind=ship"
  run_bind "$d" feat 01RUNAAAAAAAAAAAAAAAAAAAAA >/dev/null
  out=$(run_bind "$d" feat 01RUNBBBBBBBBBBBBBBBBBBBBB)
  assert_contains "$out" "replaced 01RUNAAAAAAAAAAAAAAAAAAAAA" "the replacement is reported"
  [ "$(meta_binding "$meta")" = 01RUNBBBBBBBBBBBBBBBBBBBBB ] || fail "the new run id is not effective"
  [ "$(meta_bindings "$meta")" = 1 ] \
    || fail "re-binding must leave exactly one binding, not accumulate them"
  pass "re-binding replaces the previous value rather than accumulating"
}

test_rebinding_the_same_id_is_a_noop() {
  local d meta out
  d=$(new_case same)
  meta="$d/state/feat.meta"
  fm_write_meta "$meta" "window=fm:fm-feat" "worktree=$d/wt" "kind=ship"
  run_bind "$d" feat 01RUNAAAAAAAAAAAAAAAAAAAAA >/dev/null
  out=$(run_bind "$d" feat 01RUNAAAAAAAAAAAAAAAAAAAAA)
  assert_contains "$out" "unchanged" "an identical re-bind reports that nothing changed"
  [ "$(meta_bindings "$meta")" = 1 ] || fail "an identical re-bind must not duplicate the key"
  pass "re-binding the same run id is a no-op that still succeeds"
}

test_unknown_task_is_refused() {
  local d rc=0
  d=$(new_case unknown)
  run_bind "$d" ghost 01RUNAAAAAAAAAAAAAAAAAAAAA >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "binding an unknown task must fail"
  assert_absent "$d/state/ghost.meta" "a refused bind must not create a task record"
  pass "an unknown task is refused and no record is created"
}

test_malformed_run_id_is_refused() {
  local d meta rc
  d=$(new_case malformed)
  meta="$d/state/feat.meta"
  fm_write_meta "$meta" "window=fm:fm-feat" "worktree=$d/wt" "kind=ship"
  run_bind "$d" feat 01RUNAAAAAAAAAAAAAAAAAAAAA >/dev/null
  local bad
  # A path separator, shell syntax, a newline, and a too-short token: the value
  # is written verbatim into a record every supervisor parses.
  for bad in '../escape' 'run id' 'run;id' 'short' '' '-leading'; do
    rc=0
    run_bind "$d" feat "$bad" >/dev/null 2>&1 || rc=$?
    [ "$rc" != 0 ] || fail "a malformed run id ('$bad') must be refused"
  done
  [ "$(meta_binding "$meta")" = 01RUNAAAAAAAAAAAAAAAAAAAAA ] \
    || fail "a refused bind must leave the existing binding untouched"
  [ "$(meta_bindings "$meta")" = 1 ] || fail "a refused bind must not add a key"
  pass "a malformed run id is refused and the existing binding survives"
}

test_malformed_task_id_is_refused() {
  local d rc=0
  d=$(new_case badtask)
  run_bind "$d" '../escape' 01RUNAAAAAAAAAAAAAAAAAAAAA >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "a task id that escapes the state dir must be refused"
  pass "a malformed task id is refused"
}

test_first_bind_records_the_run
test_rebind_replaces_the_previous_value
test_rebinding_the_same_id_is_a_noop
test_unknown_task_is_refused
test_malformed_run_id_is_refused
test_malformed_task_id_is_refused

echo "all fm-run-bind tests passed"
