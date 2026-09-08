#!/usr/bin/env bash
# Behavior tests for Firstmate's argv-level no-mistakes ownership boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CASE_DIR=$(fm_test_tmproot fm-no-mistakes-dispatch)
UPSTREAM="$CASE_DIR/upstream"
PRIMARY="$CASE_DIR/primary"
WORKER="$CASE_DIR/worker"
SECONDMATE="$CASE_DIR/secondmate"
mkdir -p "$UPSTREAM"
fm_git_init_commit "$PRIMARY"
git -C "$PRIMARY" worktree add --quiet -b worker "$WORKER"
git -C "$PRIMARY" worktree add --quiet -b secondmate "$SECONDMATE"
printf 'mate-1\n' > "$SECONDMATE/.fm-secondmate-home"
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

run_dispatch_in() {
  local dir=$1
  shift
  (cd "$dir" && PATH="$ROOT/bin:$UPSTREAM:/usr/bin:/bin" no-mistakes "$@")
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

out=$(FM_TASK_ID=spoofed run_dispatch_in "$PRIMARY" axi respond --action fix 2>"$CASE_DIR/spoof.err")
rc=$?
[ "$rc" -eq 2 ] || fail "a caller marker in the primary checkout must not authorize respond, got $rc"
[ -z "$out" ] || fail "spoofed primary marker invoked upstream: $out"
pass "a caller-controlled marker does not authorize the primary checkout"

out=$(FM_TASK_ID=spoofed run_dispatch_in "$SECONDMATE" axi run --intent test 2>"$CASE_DIR/secondmate.err")
rc=$?
[ "$rc" -eq 2 ] || fail "a caller marker in a linked secondmate home must not authorize run, got $rc"
[ -z "$out" ] || fail "spoofed secondmate marker invoked upstream: $out"
pass "a caller-controlled marker does not authorize a secondmate home"

out=$(FM_TASK_ID=task-1 run_dispatch_in "$WORKER" axi respond --action fix)
[ "$out" = 'upstream: <axi> <respond> <--action> <fix>' ] \
  || fail "task worker respond did not reach upstream unchanged: $out"
pass "marked linked task worker retains axi respond ownership"

out=$(run_dispatch axi status)
[ "$out" = 'upstream: <axi> <status>' ] \
  || fail "primary status did not reach upstream unchanged: $out"
pass "primary retains read-only axi status"

out=$(run_dispatch axi abort --run run-1)
[ "$out" = 'upstream: <axi> <abort> <--run> <run-1>' ] \
  || fail "primary recovery command did not reach upstream unchanged: $out"
pass "primary retains explicit recovery commands"

printf '\nAll no-mistakes dispatch tests passed.\n'
