#!/usr/bin/env bash
# Local task-code identity, display, lookup, and child allocation behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CODE="$ROOT/bin/fm-task-code.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-code)

out=$($CODE display A2-reviewer.1.2 2>&1) || fail "display failed: $out"
[ "$out" = 'A2….1.2' ] || fail "nested display lost its deepest counter: $out"
ascii=${out//…/}
cells=$(( ${#ascii} + 1 ))
[ "$cells" -le 8 ] || fail "display exceeded eight rendered cells: $out"
pass "task code display middle-elides to eight cells and preserves the deepest counter"

home="$TMP_ROOT/home"
mkdir -p "$home/state" "$home/data" "$TMP_ROOT/artemis" "$TMP_ROOT/firstmate"
printf '%s\n' '- artemis [direct-PR] - fixture' > "$home/data/projects.md"

mint() {
  bash -c '. "$1/bin/fm-task-code-lib.sh"; shift; fm_task_code_mint "$@"' _ "$ROOT" "$@"
}

out=$(mint "$home" "$TMP_ROOT/artemis" secondmate artemis-engineer '' '') \
  || fail "secondmate root mint failed"
[ "$out" = A2-engineer ] || fail "secondmate root code was wrong: $out"
out=$(mint "$home" "$TMP_ROOT/firstmate" ship fix-herdr-sidebar-labels-glanceable '' '') \
  || fail "firstmate task root mint failed"
[ "$out" = FMC-fix-herdr-sidebar-labels-glanceable ] || fail "task root code was wrong: $out"
printf 'code=A2-engineer\n' > "$home/state/parent.meta"
out=$(mint "$home" "$TMP_ROOT/artemis" ship child parent 1) || fail "child mint failed"
[ "$out" = A2-engineer.1 ] || fail "child code was wrong: $out"
printf 'code=A2-engineer.1\n' > "$home/state/child.meta"
out=$(mint "$home" "$TMP_ROOT/artemis" ship grandchild child 2) || fail "nested child mint failed"
[ "$out" = A2-engineer.1.2 ] || fail "nested child code was wrong: $out"
pass "task code mint uses project roots and stored parent identity at arbitrary depth"

next_seq() {
  FM_TASK_CODE_TODAY=$1 bash -c '. "$1/bin/fm-task-code-lib.sh"; fm_task_code_child_seq_next "$2" "$3"' \
    _ "$ROOT" "$home" "$2"
}
printf 'code=A2-sequence\n' > "$home/state/sequence-parent.meta"
[ "$(next_seq 2026-09-12 sequence-parent)" = 1 ] || fail "first child sequence was not one"
[ "$(next_seq 2026-09-12 sequence-parent)" = 2 ] || fail "same-day child sequence was reused"
rm -f "$home/state/child.meta"
[ "$(next_seq 2026-09-12 sequence-parent)" = 3 ] || fail "retired same-day child sequence was reused"
[ "$(next_seq 2026-09-13 sequence-parent)" = 1 ] || fail "next-day sequence did not reset"
assert_grep 'parent_child_seq_day=2026-09-13' "$home/state/sequence-parent.meta" \
  "parent sequence day was not persisted"
assert_grep 'parent_child_seq=1' "$home/state/sequence-parent.meta" \
  "parent sequence value was not persisted"
pass "parent-local counters persist same-day retirement and reset on the next UTC day"

printf 'code=A2-race\n' > "$home/state/race-parent.meta"
race_lock=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_meta_lock_path "$2"' _ "$ROOT" "$home/state/race-parent.meta")
bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2"
  cp "$3/state/race-parent.meta" "$3/state/race-parent.staged"
  printf "concurrent=preserved\\n" >> "$3/state/race-parent.staged"
  : > "$4/race-owner-ready"
  while [ ! -e "$4/race-sequence-started" ]; do sleep 0.01; done
  sleep 1
  mv -f "$3/state/race-parent.staged" "$3/state/race-parent.meta"
  fm_lock_release "$2"
' _ "$ROOT" "$race_lock" "$home" "$TMP_ROOT" &
race_owner=$!
while [ ! -e "$TMP_ROOT/race-owner-ready" ]; do sleep 0.01; done
bash -c '
  . "$1/bin/fm-task-code-lib.sh"
  : > "$3/race-sequence-started"
  FM_TASK_CODE_TODAY=2026-09-14 fm_task_code_child_seq_next "$2" race-parent > "$3/race-first-seq"
' _ "$ROOT" "$home" "$TMP_ROOT" &
race_sequence=$!
wait "$race_owner" || fail "staged metadata owner failed"
wait "$race_sequence" || fail "locked child sequence allocation failed"
grep -Fx -- 'concurrent=preserved' "$home/state/race-parent.meta" >/dev/null \
  || fail "child sequence allocation lost a concurrent metadata field"
[ "$(cat "$TMP_ROOT/race-first-seq")" = 1 ] || fail "first locked child sequence was not one"
[ "$(next_seq 2026-09-14 race-parent)" = 2 ] \
  || fail "concurrent metadata publication allowed same-day sequence reuse"
pass "child sequence allocation shares the metadata publication lock"

printf 'code=A2-overnight\n' > "$home/state/overnight-parent.meta"
[ "$(next_seq 2026-09-14 overnight-parent)" = 1 ] \
  || fail "overnight fixture did not allocate its first child"
printf 'code=A2-overnight.1\n' > "$home/state/overnight-child.meta"
overnight_seq=$(next_seq 2026-09-15 overnight-parent) \
  || fail "next-day allocation failed while the prior child remained recorded"
[ "$overnight_seq" = 2 ] \
  || fail "next-day allocation reused occupied child sequence one: $overnight_seq"
[ "$(mint "$home" "$TMP_ROOT/artemis" ship overnight-new overnight-parent "$overnight_seq")" = A2-overnight.2 ] \
  || fail "next-day child code did not skip the occupied sequence"
printf 'code=A2-overnight.3\n' > "$home/state/overnight-third.meta"
[ "$(next_seq 2026-09-15 overnight-parent)" = 4 ] \
  || fail "same-day allocation did not skip an occupied sequence after a gap"
pass "every child allocation skips still-recorded codes"

printf 'code=A2-eng.1\n' > "$home/state/lookup-one.meta"
printf 'code=A2-eng.10\n' > "$home/state/lookup-ten.meta"
out=$(FM_STATE_OVERRIDE="$home/state" "$CODE" resolve '[A2-eng.1]') \
  || fail "bracketed exact code did not resolve"
[ "$out" = lookup-one ] || fail "bracketed exact code resolved to $out"
out=$(FM_STATE_OVERRIDE="$home/state" "$CODE" resolve A2-eng.10) \
  || fail "plain exact code did not resolve"
[ "$out" = lookup-ten ] || fail "plain exact code resolved to $out"
if FM_STATE_OVERRIDE="$home/state" "$CODE" resolve A2-eng. >/dev/null 2>&1; then
  fail "ambiguous full-code prefix resolved"
fi
if FM_STATE_OVERRIDE="$home/state" "$CODE" resolve 'A2…g.1' >/dev/null 2>&1; then
  fail "clipped display code resolved"
fi
if FM_STATE_OVERRIDE="$home/state" "$CODE" resolve A2-missing >/dev/null 2>&1; then
  fail "unknown code resolved"
fi
pass "stored-code lookup accepts exact bodies and brackets but refuses ambiguous or clipped selectors"

resolve_backend_id() {
  bash -c '. "$1/bin/fm-backend.sh"; fm_backend_task_id_for_selector "$2" "$3"' \
    _ "$ROOT" "$1" "$home/state"
}
[ "$(resolve_backend_id '[A2-eng.1]')" = lookup-one ] \
  || fail "backend selector did not consume stored bracketed code"
if resolve_backend_id A2-eng. >/dev/null 2>&1; then
  fail "backend selector accepted an ambiguous stored-code prefix"
fi
pass "shared backend selectors route crew-state and send through stored codes"
