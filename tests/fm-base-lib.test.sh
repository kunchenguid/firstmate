#!/usr/bin/env bash
# Behavior tests for bin/fm-base-lib.sh, the one owner of what a task's declared base means.
#
# Every consumer - fm-spawn.sh, fm-brief.sh, fm-pr-check.sh, fm-review-diff.sh - used to
# hand-roll its own partial version of this question, and each got a different piece of it
# wrong. The decision lives here now, so the matrix is pinned HERE, once, against the
# functions themselves. The consumers' own suites then only have to show that they honour
# the verdict they are handed, not re-derive it.
#
# THE DECIDING QUESTION IS NEVER WHETHER THE BASE BRANCH EXISTS. It is two questions, asked
# together: has the base's work LANDED in the default branch, and is the head ROOTED in the
# base's own commits? Branch existence only chooses which tip to reason from.
#
# fm_base_resolve_state (no head needed):
#   (a) base on origin carrying unmerged work                     -> LIVE
#   (b) base on origin, ancestor-merged into the default branch   -> LANDED
#   (c) base on origin, SQUASH-merged (firstmate's own default,
#       so its commits are NOT in the default branch by id)       -> LANDED
#   (d) base gone from origin, its recorded tip merged            -> LANDED
#   (e) base gone from origin, its recorded tip never merged      -> ABANDONED
#   (f) base gone from origin, no recorded tip to decide with     -> UNKNOWN
#   (g) origin cannot be asked at all (auth, network, no remote)  -> UNKNOWN, and NOT
#       mistaken for a base that is gone: an infrastructure failure is never a merge
#
# fm_base_verdict (the state, plus where the head is rooted):
#   (h) LIVE   + head stacked on the base   -> STACKED_LIVE    (allow, target the base)
#   (i) LIVE   + head rebased onto default  -> UNSTACKED       (the 2026-07-07 incident)
#   (j) LANDED + head rebased onto default  -> ORDINARY        (no hazard left)
#   (k) LANDED + head STILL stacked on it   -> STACKED_LANDED  (a squash left the base's
#       commits out of the default branch by id, and this head still carries them)
#   (l) ABANDONED, however the head is rooted -> ABANDONED_BASE
#   (m) UNKNOWN state, or a head sharing no history with the base -> INDETERMINATE
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-base-lib.sh
. "$ROOT/bin/fm-base-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-base-lib)

# Exact match, not substring: STACKED_LIVE and STACKED_LANDED are opposite verdicts whose
# names share a prefix, so a contains-style assertion would happily accept the wrong one.
assert_verdict() {  # <expected> <actual> <msg>
  [ "$1" = "$2" ] || fail "$3"$'\n'"  expected: $1"$'\n'"  got:      $2"
}

commit() {  # <dir> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$4"
}

# A clone with a real origin: main, plus a feature/base branch carrying a commit of its
# OWN, so "has this base's work landed" is a real question rather than trivially true.
make_repo() {  # <name>; echoes the work dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/wt" 2>/dev/null
  commit "$dir/wt" seed.txt seed "seed"
  git -C "$dir/wt" push -q origin main

  git -C "$dir/wt" checkout -q -b feature/base
  commit "$dir/wt" base-only.txt base-work "feature base work"
  git -C "$dir/wt" push -q origin feature/base
  git -C "$dir/wt" checkout -q main
  git -C "$dir/wt" fetch -q origin
  printf '%s\n' "$dir"
}

# Resolve the base's state and report it as a word, so a test reads as the question it is
# asking rather than as a return code.
state_of() {  # <work-dir> [<recorded-tip>]
  local wt="$1/wt" recorded=${2:-} rc=0
  fm_base_resolve_state "$wt" feature/base "$recorded" main || rc=$?
  case "$rc" in
    "$FM_BASE_STATE_LIVE") printf 'LIVE' ;;
    "$FM_BASE_STATE_LANDED") printf 'LANDED' ;;
    "$FM_BASE_STATE_ABANDONED") printf 'ABANDONED' ;;
    "$FM_BASE_STATE_UNKNOWN") printf 'UNKNOWN' ;;
    *) printf 'BOGUS(%s)' "$rc" ;;
  esac
}

# The full verdict: resolve the base, root the head against it, and combine - the exact
# three-step ritual fm-pr-check.sh and fm-review-diff.sh both perform.
verdict_of() {  # <work-dir> <head-rev> [<recorded-tip>]
  local wt="$1/wt" head=$2 recorded=${3:-} state_rc=0 rooted_rc=0 rc=0 head_sha
  head_sha=$(git -C "$wt" rev-parse --verify "$head^{commit}")
  fm_base_resolve_state "$wt" feature/base "$recorded" main || state_rc=$?
  if [ "$state_rc" -ne "$FM_BASE_STATE_UNKNOWN" ]; then
    fm_base_head_rooted "$wt" "$FM_BASE_STATE_TIP" "$head_sha" \
      "$FM_BASE_STATE_DEFAULT_SHA" || rooted_rc=$?
  fi
  fm_base_verdict "$state_rc" "$rooted_rc" || rc=$?
  case "$rc" in
    "$FM_BASE_VERDICT_ORDINARY") printf 'ORDINARY' ;;
    "$FM_BASE_VERDICT_STACKED_LIVE") printf 'STACKED_LIVE' ;;
    "$FM_BASE_VERDICT_STACKED_LANDED") printf 'STACKED_LANDED' ;;
    "$FM_BASE_VERDICT_UNSTACKED") printf 'UNSTACKED' ;;
    "$FM_BASE_VERDICT_ABANDONED_BASE") printf 'ABANDONED_BASE' ;;
    "$FM_BASE_VERDICT_INDETERMINATE") printf 'INDETERMINATE' ;;
    *) printf 'BOGUS(%s)' "$rc" ;;
  esac
}

base_tip() {  # <work-dir>
  git -C "$1/origin.git" rev-parse refs/heads/feature/base
}

# Stack the crewmate's branch ON the base: the head the guard is built to allow.
stack_head_on_base() {  # <work-dir>; echoes the head sha
  local wt="$1/wt"
  git -C "$wt" checkout -q -B fm/task origin/feature/base
  commit "$wt" fix.txt crew-fix "the crewmate's fix"
  git -C "$wt" rev-parse HEAD
}

# What the no-mistakes pipeline leaves behind: the fix rebased onto the default branch,
# carrying none of the base's commits by id.
rebase_head_onto_default() {  # <work-dir>; echoes the head sha
  local wt="$1/wt"
  git -C "$wt" checkout -q -B fm/task origin/main
  commit "$wt" fix.txt crew-fix "the crewmate's fix"
  git -C "$wt" rev-parse HEAD
}

merge_base_into_main() {  # <work-dir> [--squash]
  local dir=$1 squash=${2:-} wt="$1/wt"
  git -C "$wt" checkout -q -B main origin/main
  if [ "$squash" = --squash ]; then
    git -C "$wt" merge -q --squash origin/feature/base >/dev/null
    git -C "$wt" -c user.name=t -c user.email=t@t commit -qm "squash feature/base"
  else
    git -C "$wt" -c user.name=t -c user.email=t@t \
      merge -q --no-ff -m "merge feature/base" origin/feature/base
  fi
  git -C "$wt" push -q origin main
  git -C "$wt" fetch -q origin
}

delete_base_on_origin() {  # <work-dir>
  git -C "$1/origin.git" update-ref -d refs/heads/feature/base
}

test_state_live_base() {
  local dir
  dir=$(make_repo state-live)
  assert_verdict LIVE "$(state_of "$dir")" \
    "state-live: a base on origin carrying unmerged work is LIVE"
  pass "fm_base_resolve_state: a base carrying unmerged work is LIVE"
}

test_state_landed_however_it_merged() {
  local dir
  dir=$(make_repo state-landed-ancestor)
  merge_base_into_main "$dir"
  assert_verdict LANDED "$(state_of "$dir")" \
    "state-landed-ancestor: an ancestor-merged base has landed"

  dir=$(make_repo state-landed-squash)
  merge_base_into_main "$dir" --squash
  assert_verdict LANDED "$(state_of "$dir")" \
    "state-landed-squash: a SQUASH-merged base has landed too - its content is in the default branch even though its commits are not, and an ancestor-only test would call it unmerged forever"
  pass "fm_base_resolve_state: a merged base is LANDED whether it merged by ancestor or by squash, branch kept"
}

# The branch is gone in BOTH of the next two cases and they mean opposite things, which is
# exactly why existence cannot be the question. The recorded spawn-time tip is what tells
# them apart.
test_state_of_a_gone_base_is_decided_by_its_recorded_tip() {
  local dir tip
  dir=$(make_repo state-gone-merged)
  tip=$(base_tip "$dir")
  merge_base_into_main "$dir" --squash
  delete_base_on_origin "$dir"
  assert_verdict LANDED "$(state_of "$dir" "$tip")" \
    "state-gone-merged: a base that merged and was auto-deleted has landed; refusing it would deadlock the normal end-state of a stacked PR"

  dir=$(make_repo state-gone-abandoned)
  tip=$(base_tip "$dir")
  delete_base_on_origin "$dir"
  assert_verdict ABANDONED "$(state_of "$dir" "$tip")" \
    "state-gone-abandoned: a base deleted WITHOUT merging is ABANDONED, not merged - waving it through is the incident"
  pass "fm_base_resolve_state: a gone base is decided by its recorded tip, not by being gone"
}

test_state_unknown_without_a_tip_to_decide_with() {
  local dir
  dir=$(make_repo state-gone-no-tip)
  delete_base_on_origin "$dir"
  assert_verdict UNKNOWN "$(state_of "$dir")" \
    "state-gone-no-tip: with the branch gone and no recorded tip, merged and abandoned cannot be told apart, so the answer is UNKNOWN - never LANDED"
  pass "fm_base_resolve_state: a gone base with no recorded tip is UNKNOWN, never assumed merged"
}

# An origin that cannot be ASKED is not a base that is gone, and it is certainly not a base
# that merged. Reading a failed probe as either one is a fail-open on infrastructure.
test_state_unknown_when_origin_cannot_be_asked() {
  local dir tip rc=0
  dir=$(make_repo state-probe-fails)
  tip=$(git -C "$dir/wt" rev-parse origin/feature/base)
  git -C "$dir/wt" remote set-url origin "$dir/no-such-origin.git"
  # Called directly rather than through state_of: FM_BASE_STATE_WHY is an out-param, and a
  # command substitution would resolve it inside a subshell where the test cannot read it.
  fm_base_resolve_state "$dir/wt" feature/base "$tip" main || rc=$?
  assert_verdict "$FM_BASE_STATE_UNKNOWN" "$rc" \
    "state-probe-fails: an unreachable origin must be UNKNOWN, never read as a gone or merged base"
  assert_verdict probe-failed "$FM_BASE_STATE_WHY" \
    "state-probe-fails: the reason must name the probe, so a caller can report an infrastructure failure as one"
  [ -n "$FM_BASE_STATE_ERR" ] \
    || fail "state-probe-fails: git's own error was not captured, so a caller's refusal cannot name the infrastructure failure"
  pass "fm_base_resolve_state: an origin that cannot be asked is UNKNOWN and says so"
}

test_verdict_stacked_on_a_live_base() {
  local dir head
  dir=$(make_repo verdict-stacked-live)
  head=$(stack_head_on_base "$dir")
  assert_verdict STACKED_LIVE "$(verdict_of "$dir" "$head")" \
    "verdict-stacked-live: a head stacked on a live base is what a based task is FOR"
  pass "fm_base_verdict: a head stacked on a live base is STACKED_LIVE"
}

# The launch incident: the pipeline rebased the head onto the default branch while the base
# was still unmerged, replaying the base's own commits onto the head as it did.
test_verdict_head_rebased_off_a_live_base() {
  local dir head
  dir=$(make_repo verdict-unstacked)
  head=$(rebase_head_onto_default "$dir")
  assert_verdict UNSTACKED "$(verdict_of "$dir" "$head")" \
    "verdict-unstacked: a head rebased onto the default branch while its base is still unmerged is the 2026-07-07 incident"
  pass "fm_base_verdict: a head rebased off a still-unmerged base is UNSTACKED"
}

test_verdict_ordinary_once_the_base_has_merged() {
  local dir head
  dir=$(make_repo verdict-ordinary)
  merge_base_into_main "$dir" --squash
  head=$(rebase_head_onto_default "$dir")
  assert_verdict ORDINARY "$(verdict_of "$dir" "$head")" \
    "verdict-ordinary: once the base has merged and the head sits on the default branch, no unmerged history can be dragged anywhere - guarding it would deadlock a safe merge forever"
  pass "fm_base_verdict: a head on the default branch whose base has merged is ORDINARY"
}

# The case landedness ALONE cannot see, and the one that makes rootedness the first
# question. A squash puts the base's CONTENT in the default branch but not its COMMITS, so
# a head still stacked on it carries every one of them - and merging would land them again.
test_verdict_head_still_stacked_on_a_squash_merged_base() {
  local dir head
  dir=$(make_repo verdict-stacked-landed)
  head=$(stack_head_on_base "$dir")
  merge_base_into_main "$dir" --squash
  assert_verdict STACKED_LANDED "$(verdict_of "$dir" "$head")" \
    "verdict-stacked-landed: a head still rooted in a squash-merged base carries the base's pre-squash commits, which the default branch does not have by id"

  # Gone from origin changes only which tip the question is asked of, never the verdict.
  dir=$(make_repo verdict-stacked-landed-gone)
  head=$(stack_head_on_base "$dir")
  local tip
  tip=$(base_tip "$dir")
  merge_base_into_main "$dir" --squash
  delete_base_on_origin "$dir"
  assert_verdict STACKED_LANDED "$(verdict_of "$dir" "$head" "$tip")" \
    "verdict-stacked-landed-gone: deleting the branch does not move the head, so the verdict is the same"
  pass "fm_base_verdict: a head still rooted in a merged base is STACKED_LANDED, branch kept or deleted"
}

test_verdict_abandoned_base_however_the_head_is_rooted() {
  local dir head tip
  dir=$(make_repo verdict-abandoned-stacked)
  head=$(stack_head_on_base "$dir")
  tip=$(base_tip "$dir")
  delete_base_on_origin "$dir"
  assert_verdict ABANDONED_BASE "$(verdict_of "$dir" "$head" "$tip")" \
    "verdict-abandoned-stacked: a head stacked on an abandoned base carries its never-merged commits"

  dir=$(make_repo verdict-abandoned-rebased)
  tip=$(base_tip "$dir")
  head=$(rebase_head_onto_default "$dir")
  delete_base_on_origin "$dir"
  assert_verdict ABANDONED_BASE "$(verdict_of "$dir" "$head" "$tip")" \
    "verdict-abandoned-rebased: the pipeline replayed the abandoned base's commits onto this head, so it is no safer than the stacked one"
  pass "fm_base_verdict: an abandoned base is ABANDONED_BASE however the head is rooted"
}

test_verdict_indeterminate_is_never_a_relaxation() {
  local dir head
  dir=$(make_repo verdict-indeterminate)
  head=$(rebase_head_onto_default "$dir")
  delete_base_on_origin "$dir"
  assert_verdict INDETERMINATE "$(verdict_of "$dir" "$head")" \
    "verdict-indeterminate: with no recorded tip and the branch gone, the verdict is INDETERMINATE - and a caller must refuse, never stand down"

  # A head sharing no history with the base at all is equally unanswerable.
  dir=$(make_repo verdict-unrelated)
  git -C "$dir/wt" checkout -q --orphan orphan
  git -C "$dir/wt" rm -q -rf . >/dev/null 2>&1 || true
  commit "$dir/wt" orphan.txt orphan "unrelated history"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  assert_verdict INDETERMINATE "$(verdict_of "$dir" "$head")" \
    "verdict-unrelated: a head sharing no history with its declared base cannot be judged against it"
  pass "fm_base_verdict: an unanswerable question is INDETERMINATE, never a stand-down"
}

# The enums travel as return codes through the same call chain. Two of them sharing a value
# would let "we could not tell" arrive as "stand the guard down" in a merge gate, which is a
# fail-open on exactly the path the guard exists to close.
test_enum_values_cannot_alias_across_enums() {
  local dupes
  dupes=$(printf '%s\n' \
    "$FM_BASE_PRESENT" "$FM_BASE_PROBE_FAILED" "$FM_BASE_ABSENT" \
    "$FM_BASE_WORK_LANDED" "$FM_BASE_WORK_UNLANDED" "$FM_BASE_WORK_UNKNOWN" \
    "$FM_BASE_HEAD_ROOTED" "$FM_BASE_HEAD_UNROOTED" "$FM_BASE_HEAD_UNRELATED" \
    "$FM_BASE_STATE_LIVE" "$FM_BASE_STATE_LANDED" "$FM_BASE_STATE_ABANDONED" \
    "$FM_BASE_STATE_UNKNOWN" \
    "$FM_BASE_VERDICT_ORDINARY" "$FM_BASE_VERDICT_STACKED_LIVE" \
    "$FM_BASE_VERDICT_STACKED_LANDED" "$FM_BASE_VERDICT_UNSTACKED" \
    "$FM_BASE_VERDICT_ABANDONED_BASE" "$FM_BASE_VERDICT_INDETERMINATE" \
    | sort | uniq -d)
  [ -z "$dupes" ] \
    || fail "enum: FM_BASE_* outcomes share the value(s) [$dupes] across enums; a value of one could be read as a value of another in the same scope"
  pass "fm-base-lib: no two FM_BASE_* outcomes share a numeric value"
}

test_state_live_base
test_state_landed_however_it_merged
test_state_of_a_gone_base_is_decided_by_its_recorded_tip
test_state_unknown_without_a_tip_to_decide_with
test_state_unknown_when_origin_cannot_be_asked
test_verdict_stacked_on_a_live_base
test_verdict_head_rebased_off_a_live_base
test_verdict_ordinary_once_the_base_has_merged
test_verdict_head_still_stacked_on_a_squash_merged_base
test_verdict_abandoned_base_however_the_head_is_rooted
test_verdict_indeterminate_is_never_a_relaxation
test_enum_values_cannot_alias_across_enums
