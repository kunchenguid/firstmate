#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-run-lib.sh's shared run-attribution rule,
# fm_nm_head_matches_worktree - the ONE owner of the code-identity question
# "does this no-mistakes run belong to this worktree?", consumed by
# bin/fm-crew-state.sh (read-only reporting) and bin/fm-teardown.sh (pre-teardown
# run abort).
#
# The rule is THREE-valued, and these cases pin all three over real throwaway
# git repos:
#   0 MATCH        run head is the worktree HEAD, or a descendant of it
#   1 NO MATCH     no head reported, or a head that is a strict ancestor of
#                  local HEAD, or one on a diverged line of history
#   2 UNRESOLVABLE a head was reported that this worktree cannot resolve at all
#
# The third value is the reason this file exists. While a run validates,
# no-mistakes commits its fix rounds in its own gate-repo clone and does not
# push until the push step, so the live run's tip is an object the crew's
# worktree has never seen. The `gate-clone descendant` case below reproduces
# exactly that shape - a real descendant commit created in a SEPARATE clone, so
# it is genuinely absent from the worktree's object store - and it is the case
# that a two-valued rule answered "not mine".
#
# Every git command here goes through wt_git, which refuses any repo path
# outside this file's own temp root. These fixtures build and rewrite history
# with `reset --hard` and `checkout --orphan`; a path that silently resolved
# empty would run those against the firstmate checkout the tests live in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-run-lib)
fm_git_identity fmtest fmtest@example.invalid

MATCH=0
NO_MATCH=1
UNRESOLVABLE=2

# git in <repo-dir>, refusing anything that is not inside this run's temp root.
wt_git() {  # <repo-dir> <git-args...>
  case "${1:-}" in
    "$TMP_ROOT"/*) ;;
    *) fail "fixture refused: git repo path '${1:-}' is outside $TMP_ROOT" ;;
  esac
  git -C "$@"
}

# A worktree-shaped repo on a task branch, plus the bare origin it was cloned
# from so a separate clone can later stand in for no-mistakes' own gate repo.
# Sets CASE_DIR and WT rather than echoing them: a fixture failure must abort
# the whole test file, and `fail` inside a command substitution would only kill
# the subshell and hand the caller an empty path.
CASE_DIR=""
WT=""
make_worktree() {  # <name>
  CASE_DIR="$TMP_ROOT/$1"
  WT="$CASE_DIR/wt"
  mkdir -p "$CASE_DIR"
  git init -q --bare "$CASE_DIR/origin.git"
  git -C "$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$CASE_DIR/origin.git" "$WT" 2>/dev/null
  wt_git "$WT" commit -q --allow-empty -m baseline
  wt_git "$WT" push -q origin HEAD:main
  wt_git "$WT" checkout -q -b fm/task
  wt_git "$WT" commit -q --allow-empty -m 'crew implementation commit'
}

# A commit made in a SEPARATE clone of the same origin: a real commit, on a real
# line of history, whose object this worktree has never fetched. That is the
# shape of a no-mistakes pipeline fix commit before the push step. Sets
# GATE_SHA rather than echoing it, for the same reason make_worktree sets its
# globals: a fixture failure must abort the whole test file.
GATE_SHA=""
gate_clone_commit() {  # sets GATE_SHA to a full sha absent from $WT
  local gate
  gate="$CASE_DIR/gate-clone"
  git clone -q "$CASE_DIR/origin.git" "$gate" 2>/dev/null
  wt_git "$gate" commit -q --allow-empty -m 'pipeline fix commit'
  GATE_SHA=$(wt_git "$gate" rev-parse HEAD)
  printf '%s' "$GATE_SHA" | grep -qxE '[0-9a-f]{40}' \
    || fail "gate clone produced no full sha: '$GATE_SHA'"
  wt_git "$WT" cat-file -e "${GATE_SHA}^{commit}" 2>/dev/null \
    && fail "fixture is not honest: $GATE_SHA is already reachable from the worktree"
  return 0
}

# Assert the rule's exit status for the current $WT against <head>.
expect_verdict() {  # <expected> <head> <what>
  local expected=$1 head=$2 what=$3 rc=0
  case "$WT" in "$TMP_ROOT"/*) ;; *) fail "$what: fixture worktree is unset" ;; esac
  fm_nm_head_matches_worktree "$WT" "$head" || rc=$?
  [ "$rc" = "$expected" ] || fail "$what: expected verdict $expected, got $rc"
}

test_equal_head_matches() {
  make_worktree equal-head
  expect_verdict "$MATCH" "$(wt_git "$WT" rev-parse HEAD)" \
    "run head equal to worktree HEAD"
  expect_verdict "$MATCH" "$(wt_git "$WT" rev-parse --short=7 HEAD)" \
    "short-sha form of the same commit"
  pass "a run head equal to the worktree HEAD matches"
}

test_locally_visible_descendant_matches() {
  local base fix
  make_worktree visible-descendant
  base=$(wt_git "$WT" rev-parse HEAD)
  wt_git "$WT" commit -q --allow-empty -m 'fix commit already fetched here'
  fix=$(wt_git "$WT" rev-parse HEAD)
  wt_git "$WT" reset -q --hard "$base"
  expect_verdict "$MATCH" "$fix" "descendant run head this worktree can see"
  pass "a descendant run head the worktree can resolve matches"
}

test_ancestor_head_does_not_match() {
  local old
  make_worktree ancestor-head
  old=$(wt_git "$WT" rev-parse HEAD)
  wt_git "$WT" commit -q --allow-empty -m 'local stage-2 work after that run'
  expect_verdict "$NO_MATCH" "$old" "run head left behind by local work"
  pass "a run head the local branch has advanced past does not match"
}

test_diverged_head_does_not_match() {
  local other
  make_worktree diverged-head
  wt_git "$WT" checkout -q --orphan rewritten
  wt_git "$WT" commit -q --allow-empty -m 'rewritten history'
  other=$(wt_git "$WT" rev-parse HEAD)
  wt_git "$WT" checkout -q fm/task
  expect_verdict "$NO_MATCH" "$other" "run head on a diverged line of history"
  pass "a run head on diverged history does not match"
}

test_absent_head_field_does_not_match() {
  make_worktree no-head-field
  expect_verdict "$NO_MATCH" "" "run that reported no head at all"
  pass "a run that reported no head makes no claim and does not match"
}

# THE regression: a live pipeline fix commit, made in no-mistakes' own clone and
# not pushed yet, is a real descendant this worktree cannot resolve. The honest
# answer is UNRESOLVABLE. Answering NO MATCH here is what let a stale terminal
# run at the worktree's own head win attribution instead.
test_gate_clone_descendant_is_unresolvable() {
  make_worktree gate-clone-tip
  gate_clone_commit
  expect_verdict "$UNRESOLVABLE" "$GATE_SHA" \
    "live run tip committed in the gate-repo clone, not pushed yet"
  pass "an unpushed pipeline tip is unresolvable, not a mismatch"
}

test_unknown_sha_is_unresolvable() {
  make_worktree unknown-sha
  expect_verdict "$UNRESOLVABLE" "5152b3ab" \
    "short sha naming no object this worktree holds"
  expect_verdict "$UNRESOLVABLE" "0123456789abcdef0123456789abcdef01234567" \
    "full sha naming no object this worktree holds"
  pass "a head naming no reachable object is unresolvable, not a mismatch"
}

test_unreadable_worktree_head_is_unresolvable() {
  local sha
  make_worktree unreadable-local-head
  sha=$(wt_git "$WT" rev-parse HEAD)
  wt_git "$WT" checkout -q --orphan unborn
  expect_verdict "$UNRESOLVABLE" "$sha" \
    "worktree with no readable HEAD to compare against"
  pass "an unreadable local HEAD is unresolvable, not a mismatch"
}

test_equal_head_matches
test_locally_visible_descendant_matches
test_ancestor_head_does_not_match
test_diverged_head_does_not_match
test_absent_head_field_does_not_match
test_gate_clone_descendant_is_unresolvable
test_unknown_sha_is_unresolvable
test_unreadable_worktree_head_is_unresolvable

echo "all fm-nm-run-lib tests passed"
