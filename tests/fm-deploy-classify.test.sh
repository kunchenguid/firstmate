#!/usr/bin/env bash
# Tests for bin/fm-deploy-lib.sh's classification: which merged work may go live
# on its own, and which the captain reserved.
#
# The decision this file guards is a safety decision. Getting it wrong in the
# permissive direction ships a design change to the captain's own live site
# without him seeing it, so every case here is written to catch that direction.
#
# Matrix:
#   (a) a policy pattern ending `/**` claims files nested any depth below it
#   (b) a prefix pattern claims files inside every directory it names, which is
#       the shape `openspec/changes/dashboard-v21-*` relies on
#   (c) a path a policy does not name stays auto-deployable
#   (d) a MERGE COMMIT carrying a reserved change is caught. `git diff-tree`
#       prints nothing for a merge, so a per-commit walk would call this range
#       auto-deployable; the classifier reads the range's own diff instead
#   (e) an absent policy claims nothing but still counts the pending work, so
#       absence never silently means "auto-deployable"
#   (f) a range whose deployed end is not an ancestor of the target is refused
#       rather than described
#   (g) only a full 40-hex commit counts as a deployed version
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deploy-classify-tests)

# shellcheck source=bin/fm-deploy-lib.sh
. "$ROOT/bin/fm-deploy-lib.sh"

git_c() { git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

commit_file() {  # <path> <content> <message>
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  git_c add -A
  git_c commit -qm "$3"
}

# One repository shared by the cases below, with a deliberate merge commit.
setup_repo() {
  REPO="$TMP_ROOT/repo"
  mkdir -p "$REPO"
  git_c init -q -b main
  commit_file README.md base "base"
  BASE=$(git_c rev-parse HEAD)

  commit_file src/engine.py "engine" "a plain code change"
  PLAIN=$(git_c rev-parse HEAD)

  # A design change that arrives through a merge commit, which is how a real
  # pull request lands.
  git_c checkout -q -b design "$PLAIN"
  commit_file dashboard/v2/src/pages/home.tsx "home page" "redesign the home page"
  commit_file openspec/changes/dashboard-v21-cockpit/tasks.md "tasks" "cockpit plan"
  git_c checkout -q main
  git_c merge -q --no-ff design -m "Merge pull request #1 from design"
  MERGED=$(git_c rev-parse HEAD)

  POLICY="$TMP_ROOT/policy"
  cat > "$POLICY" <<'POL'
# design surfaces the captain approves himself
dashboard/v2/src/**
dashboard/v2/index.html
dashboard/index.html
openspec/changes/dashboard-v21-*
POL
}

captain_paths() { printf '%s' "$FM_DEPLOY_CAPTAIN" | sed -n 's/.*\t//p' | sort; }

test_nested_subtree_pattern_claims_deep_files() {
  fm_deploy_classify "$REPO" "$BASE" "$MERGED" "$POLICY" \
    || fail "nested-subtree: classify failed"
  captain_paths | grep -qx 'dashboard/v2/src/pages/home.tsx' \
    || fail "nested-subtree: a file two levels under dashboard/v2/src was not claimed by dashboard/v2/src/**: got $(captain_paths | tr '\n' ' ')"
  pass "a /** policy pattern claims files nested below it"
}

test_prefix_pattern_claims_files_inside_matching_directories() {
  fm_deploy_classify "$REPO" "$BASE" "$MERGED" "$POLICY" \
    || fail "prefix-pattern: classify failed"
  captain_paths | grep -qx 'openspec/changes/dashboard-v21-cockpit/tasks.md' \
    || fail "prefix-pattern: a file inside a dashboard-v21-* directory was not claimed: got $(captain_paths | tr '\n' ' ')"
  pass "a prefix policy pattern claims files inside every directory it names"
}

test_unnamed_paths_stay_auto_deployable() {
  fm_deploy_classify "$REPO" "$BASE" "$PLAIN" "$POLICY" \
    || fail "unnamed-paths: classify failed"
  [ "$FM_DEPLOY_CAPTAIN_COUNT" -eq 0 ] \
    || fail "unnamed-paths: a plain code change was reserved for the captain: $(captain_paths | tr '\n' ' ')"
  [ "$FM_DEPLOY_PENDING_COUNT" -eq 1 ] \
    || fail "unnamed-paths: expected one pending change, got $FM_DEPLOY_PENDING_COUNT"
  pass "a path no policy names stays auto-deployable"
}

test_a_reserved_change_inside_a_merge_commit_is_caught() {
  # The counterfactual this case exists for: prove the per-commit view really is
  # blind here, so the assertion below cannot go quietly vacuous if the
  # classifier is ever rewritten onto it.
  local per_commit
  per_commit=$(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$MERGED")
  [ -z "$per_commit" ] \
    || fail "merge-commit: this fixture's merge commit is not actually diff-tree-empty, so the case proves nothing"

  fm_deploy_classify "$REPO" "$PLAIN" "$MERGED" "$POLICY" \
    || fail "merge-commit: classify failed"
  [ "$FM_DEPLOY_CAPTAIN_COUNT" -gt 0 ] \
    || fail "merge-commit: a design change that landed through a merge commit was reported as auto-deployable"
  pass "a reserved change that lands through a merge commit is still caught"
}

test_absent_policy_claims_nothing_but_still_counts_pending() {
  fm_deploy_classify "$REPO" "$BASE" "$MERGED" "$TMP_ROOT/no-such-policy" \
    || fail "absent-policy: classify failed"
  [ "$FM_DEPLOY_CAPTAIN_COUNT" -eq 0 ] \
    || fail "absent-policy: an absent policy claimed paths"
  [ "$FM_DEPLOY_PENDING_COUNT" -gt 0 ] \
    || fail "absent-policy: pending work was not counted"
  pass "an absent policy claims nothing and still counts the pending work"
}

test_a_diverged_deployed_version_is_refused() {
  local rc=0 sideline
  git_c checkout -q -b sideline "$BASE"
  commit_file src/other.py other "a commit that never reached main"
  sideline=$(git_c rev-parse HEAD)
  git_c checkout -q main

  fm_deploy_classify "$REPO" "$sideline" "$MERGED" "$POLICY" || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "diverged: a deployed version that is not an ancestor of the target was described instead of refused (rc=$rc)"
  pass "a deployed version that is not on the way to the target is refused"
}

test_only_a_full_commit_id_counts_as_a_deployed_version() {
  fm_deploy_sha_valid c0835941c3eb5539e3fff4ccbeefae3cc274fc73 \
    || fail "sha-valid: a real commit id was rejected"
  fm_deploy_sha_valid c0835941c && fail "sha-valid: a short commit id was accepted"
  fm_deploy_sha_valid main && fail "sha-valid: a branch name was accepted"
  fm_deploy_sha_valid '' && fail "sha-valid: an empty value was accepted"
  fm_deploy_sha_valid 'fatal: detected dubious ownership' && fail "sha-valid: an error message was accepted"
  pass "only a full 40-character commit id counts as a deployed version"
}

setup_repo
test_nested_subtree_pattern_claims_deep_files
test_prefix_pattern_claims_files_inside_matching_directories
test_unnamed_paths_stay_auto_deployable
test_a_reserved_change_inside_a_merge_commit_is_caught
test_absent_policy_claims_nothing_but_still_counts_pending
test_a_diverged_deployed_version_is_refused
test_only_a_full_commit_id_counts_as_a_deployed_version
