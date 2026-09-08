#!/usr/bin/env bash
# Behavior tests for Firstmate's argv-level no-mistakes ownership boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CASE_DIR=$(fm_test_tmproot fm-no-mistakes-dispatch)
UPSTREAM="$CASE_DIR/upstream"
mkdir -p "$UPSTREAM"
cat > "$UPSTREAM/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'upstream:'
printf ' <%s>' "$@"
printf '\n'
SH
chmod +x "$UPSTREAM/no-mistakes"

run_dispatch() {
  PATH="$ROOT/bin:$UPSTREAM:/usr/bin:/bin" no-mistakes "$@"
}

out=$(run_dispatch axi respond --action fix 2>"$CASE_DIR/respond.err")
rc=$?
[ "$rc" -eq 2 ] || fail "primary axi respond must refuse at dispatch, got $rc"
[ -z "$out" ] || fail "primary refusal must not invoke upstream: $out"
assert_grep 'REFUSED: no-mistakes axi respond is worker-owned' "$CASE_DIR/respond.err" \
  "primary respond refusal omitted ownership guidance"
pass "primary axi respond is refused before upstream dispatch"

out=$(run_dispatch axi run --intent test 2>"$CASE_DIR/run.err")
rc=$?
[ "$rc" -eq 2 ] || fail "primary axi run must refuse at dispatch, got $rc"
[ -z "$out" ] || fail "primary run refusal must not invoke upstream: $out"
pass "primary axi run is refused before upstream dispatch"

out=$(FM_TASK_ID=task-1 run_dispatch axi respond --action fix)
[ "$out" = 'upstream: <axi> <respond> <--action> <fix>' ] \
  || fail "task worker respond did not reach upstream unchanged: $out"
pass "task worker retains axi respond ownership"

out=$(run_dispatch axi status)
[ "$out" = 'upstream: <axi> <status>' ] \
  || fail "primary status did not reach upstream unchanged: $out"
pass "primary retains read-only axi status"

out=$(run_dispatch axi abort --run run-1)
[ "$out" = 'upstream: <axi> <abort> <--run> <run-1>' ] \
  || fail "primary recovery command did not reach upstream unchanged: $out"
pass "primary retains explicit recovery commands"

printf '\nAll no-mistakes dispatch tests passed.\n'
