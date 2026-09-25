#!/usr/bin/env bash
# Behavior tests for fm-claim.sh: cross-home work claims.
#
# These drive the real CLI against two simulated homes sharing one machine-wide
# claim root, and assert on exit codes, stdout, and the refusal messages - never
# on the implementation source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CLAIM="$ROOT/bin/fm-claim.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claim)
export FM_CLAIM_ROOT="$TMP_ROOT/claims"

OUT=
ERR=
RC=0
run() {
  local errfile="$TMP_ROOT/.err"
  OUT=$("$@" 2>"$errfile")
  RC=$?
  ERR=$(cat "$errfile" 2>/dev/null)
}

assert_rc() {
  [ "$RC" -eq "$1" ] || fail "expected exit $1, got $RC"$'\n'"--- stdout ---"$'\n'"$OUT"$'\n'"--- stderr ---"$'\n'"$ERR"
}

assert_eq() {
  [ "$OUT" = "$1" ] || fail "expected stdout '$1', got '$OUT'"
}

assert_err_contains() {
  case "$ERR" in
  *"$1"*) ;;
  *) fail "expected stderr to contain '$1', got '$ERR'" ;;
  esac
}

make_home() {
  local name=$1
  mkdir -p "$TMP_ROOT/$name/state"
  printf '%s\n' "$TMP_ROOT/$name"
}

HOME_A=$(make_home home-a)
HOME_B=$(make_home home-b)

# --- canonical keys ---------------------------------------------------------

run "$CLAIM" key "https://github.com/KunChenGuid/firstmate/pull/42"
assert_rc 0
assert_eq "pr:github.com/kunchenguid/firstmate#42"

run "$CLAIM" key "kunchenguid/firstmate#42"
assert_rc 0
assert_eq "pr:github.com/kunchenguid/firstmate#42"

run "$CLAIM" key "https://github.com/o/r/issues/7"
assert_rc 0
assert_eq "issue:github.com/o/r#7"

run "$CLAIM" key --kind issue "o/r#7"
assert_rc 0
assert_eq "issue:github.com/o/r#7"

run "$CLAIM" key "lin-123"
assert_rc 0
assert_eq "issue:LIN-123"

run "$CLAIM" key "area:v10:src//claims-grid/"
assert_rc 0
assert_eq "area:v10:src/claims-grid"

run "$CLAIM" key "area:v10:./src/claims-grid"
assert_rc 0
assert_eq "area:v10:src/claims-grid"

# A trailing slash, an extra path segment, and a query string all canonicalize
# to the same key.
run "$CLAIM" key "https://github.com/o/r/pull/42/"
assert_rc 0
assert_eq "pr:github.com/o/r#42"
run "$CLAIM" key "https://github.com/o/r/pull/42/files"
assert_rc 0
assert_eq "pr:github.com/o/r#42"
run "$CLAIM" key "https://github.com/o/r/issues/7?tab=activity"
assert_rc 0
assert_eq "issue:github.com/o/r#7"

# An unsupported forge path shape fails closed rather than guessing a key.
run "$CLAIM" key "https://gitlab.com/o/r/-/merge_requests/9"
assert_rc 1

# An unclassifiable target is an error, not a guess.
run "$CLAIM" key "not a target"
assert_rc 1

# --- cross-home conflict ----------------------------------------------------

PR="https://github.com/kunchenguid/firstmate/pull/42"

run "$CLAIM" acquire "$PR" --task t1 --home "$HOME_A"
assert_rc 0

run "$CLAIM" acquire "kunchenguid/firstmate#42" --task t2 --home "$HOME_B"
assert_rc 3
assert_err_contains "claim refused"
assert_err_contains "$HOME_A"
assert_err_contains "t1"

# Same home and task re-acquiring is idempotent, not a conflict.
run "$CLAIM" acquire "$PR" --task t1 --home "$HOME_A"
assert_rc 0
case "$OUT" in
*already\ held*) ;;
*) fail "expected an idempotent already-held message, got '$OUT'" ;;
esac

# A non-owner may not release.
run "$CLAIM" release "$PR" --task t2 --home "$HOME_B"
assert_rc 3
assert_err_contains "release refused"

# The owner releases, and the target is then free.
run "$CLAIM" release "$PR" --task t1 --home "$HOME_A"
assert_rc 0
run "$CLAIM" status "$PR"
assert_rc 0
case "$OUT" in
free:*) ;;
*) fail "expected free status after release, got '$OUT'" ;;
esac

run "$CLAIM" acquire "$PR" --task t2 --home "$HOME_B"
assert_rc 0

# --- release-task frees every claim a task holds ----------------------------

run "$CLAIM" acquire "area:v10:src/claims-grid" --task t2 --home "$HOME_B"
assert_rc 0
run "$CLAIM" release-task t2 --home "$HOME_B"
assert_rc 0
case "$OUT" in
"released 2 claim(s)"*) ;;
*) fail "expected release of 2 claims, got '$OUT'" ;;
esac
run "$CLAIM" list
assert_rc 0
assert_eq ""

# --- pending grace versus provable staleness --------------------------------

run "$CLAIM" acquire "o/r#7" --kind issue --task t3 --home "$HOME_A"
assert_rc 0
# home-a has no state/t3.meta: a fresh claim is NOT stolen inside the grace.
run "$CLAIM" acquire "o/r#7" --kind issue --task t4 --home "$HOME_B"
assert_rc 3
assert_err_contains "claim refused"

# Past the grace window the same claim is provably stale and auto-reclaimed.
run env FM_CLAIM_PENDING_GRACE=0 "$CLAIM" acquire "o/r#7" --kind issue --task t4 --home "$HOME_B"
assert_rc 0
case "$OUT" in
reclaimed:*) ;;
*) fail "expected a stale reclaim, got '$OUT'" ;;
esac

# --- reclaim refuses a live claim, accepts a provably gone holder -----------

PE="repos/example"
run "$CLAIM" acquire "$PE#9" --task t5 --home "$HOME_A"
assert_rc 0
: >"$HOME_A/state/t5.meta"
run "$CLAIM" reclaim "$PE#9" --task t6 --home "$HOME_B"
assert_rc 4
assert_err_contains "reclaim refused"

rm -rf "$HOME_A"
run "$CLAIM" reclaim "$PE#9" --task t6 --home "$HOME_B"
assert_rc 0
case "$OUT" in
reclaimed:*) ;;
*) fail "expected reclaim after the holder home vanished, got '$OUT'" ;;
esac

# --- status and list report held versus stale -------------------------------

HOME_A=$(make_home home-a)
run "$CLAIM" acquire "owner/repo#11" --task t7 --home "$HOME_A"
assert_rc 0
run "$CLAIM" status "owner/repo#11"
assert_rc 0
case "$OUT" in
held$'\t'"pr:github.com/owner/repo#11"$'\t'"$HOME_A"$'\t't7$'\t'*) ;;
*) fail "unexpected held status line: '$OUT'" ;;
esac

: >"$HOME_A/state/t7.meta"
run "$CLAIM" status "owner/repo#11"
assert_rc 0
case "$OUT" in
held$'\t'*) ;;
*) fail "a present task record must read held, got '$OUT'" ;;
esac

rm -f "$HOME_A/state/t7.meta"
run env FM_CLAIM_PENDING_GRACE=0 "$CLAIM" status "owner/repo#11"
assert_rc 0
case "$OUT" in
stale$'\t'*) ;;
*) fail "a gone task record past the grace must read stale, got '$OUT'" ;;
esac

run "$CLAIM" list
assert_rc 0
case "$OUT" in
*"pr:github.com/owner/repo#11"*) ;;
*) fail "list did not include the recorded claim: '$OUT'" ;;
esac

# A corrupt record fails closed rather than being trusted.
CORRUPT=$(find "$FM_CLAIM_ROOT" -name '*.claim' | head -n 1)
[ -n "$CORRUPT" ] || fail "no claim file was created to corrupt"
printf 'garbage\n' >"$CORRUPT"
run "$CLAIM" status "owner/repo#11"
assert_rc 5

# --- the claim root must be private -----------------------------------------

INSECURE="$TMP_ROOT/insecure/claims"
mkdir -p "$INSECURE"
chmod 0755 "$INSECURE"
FM_CLAIM_ROOT="$INSECURE" run "$CLAIM" acquire "owner/repo#12" --task t8 --home "$HOME_A"
assert_rc 1
assert_err_contains "0700"

# --- usage and validation ---------------------------------------------------

run "$CLAIM" acquire "$PR" --home "$HOME_A"
assert_rc 2
run "$CLAIM" bogus-command
assert_rc 2
run "$CLAIM" acquire "$PR" --kind bogus --task t9 --home "$HOME_A"
assert_rc 1
run "$CLAIM" acquire "$PR" --task 'bad id!' --home "$HOME_A"
assert_rc 1

# --- fm-spawn refuses --claim on a secondmate and on a relaunch -------------

run "$SPAWN" some-id --claim "$PR" --secondmate
assert_rc 1
assert_err_contains "--claim"

run "$SPAWN" some-id --claim "$PR" --relaunch
assert_rc 1
assert_err_contains "--claim"

run "$SPAWN" "some-id=projects/x" --claim "$PR" --scout
assert_rc 1
assert_err_contains "batch dispatch does not support --claim"

# --- a fresh dispatch records its claim on the task record ------------------

SPAWN_CASE="$TMP_ROOT/spawn"
SPAWN_HOME="$SPAWN_CASE/home"
SPAWN_PROJ="$SPAWN_CASE/project"
SPAWN_WT="$SPAWN_CASE/wt"
SPAWN_FAKE=$(fm_test_make_spawn_fakebin "$SPAWN_CASE/fake")
fm_test_spawn_home "$SPAWN_HOME" claude
fm_git_worktree "$SPAWN_PROJ" "$SPAWN_WT" wt-claim
fm_test_spawn_brief "$SPAWN_HOME" claim-task
fm_test_spawn_brief "$SPAWN_HOME" claim-task-2

TARGET="owner/repo#777"
spawn_out=$(fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_WT" "$SPAWN_FAKE" \
  claim-task "$SPAWN_PROJ" --mode no-mistakes --yolo off --claim "$TARGET")
spawn_rc=$?
[ "$spawn_rc" -eq 0 ] || fail "spawn with --claim failed ($spawn_rc): $spawn_out"

META="$SPAWN_HOME/state/claim-task.meta"
grep -q '^claims=pr:github.com/owner/repo#777$' "$META" ||
  fail "the task record did not record the canonical claim key:"$'\n'"$(cat "$META" 2>/dev/null)"

run "$CLAIM" status "$TARGET"
assert_rc 0
case "$OUT" in
held$'\t'"pr:github.com/owner/repo#777"$'\t'"$SPAWN_HOME"$'\t'claim-task$'\t'*) ;;
*) fail "the dispatched task did not own the claim: '$OUT'" ;;
esac

# A second home dispatching the same target is refused before it builds anything.
spawn2_out=$(fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_WT" "$SPAWN_FAKE" \
  claim-task-2 "$SPAWN_PROJ" --mode no-mistakes --yolo off --claim "$TARGET")
spawn2_rc=$?
[ "$spawn2_rc" -ne 0 ] || fail "a second dispatch of a claimed target was not refused: $spawn2_out"
case "$spawn2_out" in
*"claim refused"*) ;;
*) fail "expected the second dispatch to report the claim refusal, got: $spawn2_out" ;;
esac

# Cleaning up the first task frees its claim.
run "$CLAIM" release-task claim-task --home "$SPAWN_HOME"
assert_rc 0
run "$CLAIM" status "$TARGET"
assert_rc 0
case "$OUT" in
free:*) ;;
*) fail "expected the target to be free after release-task, got '$OUT'" ;;
esac

pass "fm-claim"
