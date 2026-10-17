#!/usr/bin/env bash
# Behavior tests for bin/fm-gate-ref-probe.sh: a read-only verdict on whether the
# gate repository will take a push of the copy's HEAD, built from real git
# repositories standing in for the gate (a bare repo behind the no-mistakes
# remote). The stale case is the daemon-crash shape: the gate ref holds the
# pre-rebase head while the copy's rebased head is not a descendant of it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gate-ref-probe)
fm_git_identity fmtest fmtest@example.invalid
PROBE="$ROOT/bin/fm-gate-ref-probe.sh"

# A copy on branch fm/lane with the no-mistakes remote pointing at a bare gate.
make_lane() {  # <name> -> sets WT and GATE
  local name=$1
  WT="$TMP_ROOT/$name/wt"
  GATE="$TMP_ROOT/$name/gate.git"
  mkdir -p "$TMP_ROOT/$name"
  git init -q --bare "$GATE"
  git init -q -b main "$WT"
  git -C "$WT" commit -q --allow-empty -m base
  git -C "$WT" checkout -q -b fm/lane
  git -C "$WT" remote add no-mistakes "$GATE"
}

commit_file() {  # <worktree> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$4"
}

gate_refs() {  # <gate>
  git --git-dir="$1" for-each-ref
}

probe() {  # <worktree> ; sets OUT and RC
  OUT=$("$PROBE" "$1" 2>&1)
  RC=$?
}

test_absent_ref_is_pushable() {
  make_lane absent
  commit_file "$WT" a.txt one 'feature'
  probe "$WT"
  [ "$RC" = 0 ] || fail "absent ref should be pushable, got $RC: $OUT"
  assert_contains "$OUT" 'gate_ref: absent' "absent ref not named"
  pass "a branch the gate has no ref for is pushable"
}

test_fast_forward_is_pushable() {
  make_lane ff
  commit_file "$WT" a.txt one 'feature'
  git -C "$WT" push -q no-mistakes fm/lane
  commit_file "$WT" b.txt two 'follow-up'
  probe "$WT"
  [ "$RC" = 0 ] || fail "fast-forward should be pushable, got $RC: $OUT"
  assert_contains "$OUT" 'gate_ref: in-sync' "fast-forward not named in-sync"
  pass "a head that descends from the gate ref is pushable"
}

test_rebased_head_is_stale_and_names_nothing_lost() {
  make_lane stale
  commit_file "$WT" a.txt one 'feature'
  git -C "$WT" push -q no-mistakes fm/lane
  # The base moves, then the lane rebases: same change, new commit id.
  git -C "$WT" checkout -q main
  commit_file "$WT" base2.txt moved 'staging moves'
  git -C "$WT" checkout -q fm/lane
  git -C "$WT" rebase -q main
  local before after
  before=$(gate_refs "$TMP_ROOT/stale/gate.git")
  probe "$WT"
  [ "$RC" = 10 ] || fail "rebased head should read stale (10), got $RC: $OUT"
  assert_contains "$OUT" 'gate_ref: stale' "stale verdict missing"
  assert_contains "$OUT" 'unique_commits: 0' "stale verdict must say nothing is unique to the gate"
  assert_contains "$OUT" 'gate_tip_subject: feature' "gate tip not named"
  after=$(gate_refs "$TMP_ROOT/stale/gate.git")
  [ "$before" = "$after" ] || fail "the probe changed a ref in the gate"
  pass "a rebased head reads stale, names the gate tip, and changes no ref"
}

test_gate_only_work_is_never_called_stale() {
  make_lane holds
  commit_file "$WT" a.txt one 'feature'
  git -C "$WT" push -q no-mistakes fm/lane
  # The gate gains a pipeline fix the copy never received, and the copy diverges.
  local fixer="$TMP_ROOT/holds/fixer"
  git clone -q "$TMP_ROOT/holds/gate.git" "$fixer"
  git -C "$fixer" checkout -q fm/lane
  commit_file "$fixer" fix.txt fix 'pipeline fix'
  git -C "$fixer" push -q origin fm/lane
  git -C "$WT" reset -q --hard HEAD~1
  commit_file "$WT" other.txt other 'different work'
  probe "$WT"
  [ "$RC" = 11 ] || fail "gate-only work should read holds-work (11), got $RC: $OUT"
  assert_contains "$OUT" 'gate_ref: holds-work' "holds-work verdict missing"
  pass "a gate ref carrying commits the copy lacks is never called stale"
}

test_gate_ahead_of_head_holds_work() {
  make_lane ahead
  commit_file "$WT" a.txt one 'feature'
  commit_file "$WT" b.txt two 'more'
  git -C "$WT" push -q no-mistakes fm/lane
  git -C "$WT" reset -q --hard HEAD~1
  probe "$WT"
  [ "$RC" = 11 ] || fail "a gate ref ahead of HEAD should read holds-work (11), got $RC: $OUT"
  assert_contains "$OUT" 'relation: gate-ahead' "gate-ahead relation missing"
  pass "a gate ref ahead of HEAD holds work and is refused"
}

test_unanswerable_questions_exit_two() {
  make_lane noremote
  git -C "$WT" remote remove no-mistakes
  probe "$WT"
  [ "$RC" = 2 ] || fail "missing remote should exit 2, got $RC: $OUT"
  git -C "$WT" remote add no-mistakes "$TMP_ROOT/noremote/gate.git"
  git -C "$WT" checkout -q --detach
  probe "$WT"
  [ "$RC" = 2 ] || fail "detached HEAD should exit 2, got $RC: $OUT"
  pass "a copy with no branch or no gate remote cannot be answered"
}

test_absent_ref_is_pushable
test_fast_forward_is_pushable
test_rebased_head_is_stale_and_names_nothing_lost
test_gate_only_work_is_never_called_stale
test_gate_ahead_of_head_holds_work
test_unanswerable_questions_exit_two

echo "all fm-gate-ref-probe tests passed"
