#!/usr/bin/env bash
# Behavior tests for bin/fm-delivery-proof-lib.sh - the mechanical delivery
# proof behind a reported-done ship task.
#
# The done-without-delivery family (four measured incidents, 2026-08-24/25):
# workers appended `done:` while their commits existed only in the task
# worktree - no branch on origin, no PR. This suite pins the proof verdicts
# over REAL throwaway git repos with a bare origin and a recording fake `gh`:
#   - refuted only when both remote probes DEFINITIVELY answer empty;
#   - a failed or tooling-less probe is unverified, never evidence of absence;
#   - an existing branch short-circuits the PR probe (the cheapness contract);
#   - open and merged PRs deliver, closed-unmerged does not;
#   - local-only counts commits against the merge base with the default branch,
#     so a landed-but-unpushed local branch never reads as empty;
#   - non-ship kinds, missing metadata, and unknown modes skip the probe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF_LIB="$ROOT/bin/fm-delivery-proof-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-proof)
fm_git_identity fmtest fmtest@example.invalid

# Run the public entry point against <state-dir> for task <id>. A subshell
# source keeps the library's globals out of this runner.
run_proof() {  # <case-dir> <id>
  FM_STATE_OVERRIDE="$1/state" bash -c '
    # shellcheck disable=SC1090
    . "$1"
    fm_delivery_proof "$2"
  ' _ "$PROOF_LIB" "$2"
}

# Real repo + bare origin + worktree already on branch fm/<id> at the base
# commit (an "empty" branch until something commits into it). The default
# branch is published to origin and fetched back, so the fixture carries the
# remote-tracking ref every real clone has and the proof's anchor resolves
# like it would on a live task.
make_ship_case() {  # <name> <mode> [kv...]
  local name=$1 mode=$2 d base
  d="$TMP_ROOT/$name"
  mkdir -p "$d/state"
  fm_git_worktree "$d/project" "$d/wt" "fm/t1"
  base=$(git -C "$d/project" symbolic-ref --quiet --short HEAD)
  git -C "$d/project" push -q origin "$base"
  git -C "$d/project" fetch -q origin
  shift 2
  fm_write_meta "$d/state/t1.meta" \
    "window=fake:fm-t1" \
    "worktree=$d/wt" \
    "project=$d/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=$mode" \
    "yolo=off" \
    "$@"
  printf '%s\n' "$d"
}

# Recording gh stub: logs every invocation to GH_STUB_LOG, serves GH_STUB_OUT,
# fails when GH_STUB_FAIL is set. The log doubles as the cheapness instrument.
make_gh_stub() {  # <dir>
  local d=$1
  local fb="$d/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?GH_STUB_LOG unset}"
if [ -n "${GH_STUB_FAIL:-}" ]; then exit 1; fi
printf '%s\n' "${GH_STUB_OUT:-[]}"
exit 0
SH
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

gh_calls() {  # <log>
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || printf '0'
}

test_missing_meta_skips() {
  local d out rc
  d="$TMP_ROOT/no-meta"
  mkdir -p "$d/state"
  out=$(run_proof "$d" t9)
  rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" $'skip\tno metadata' "missing meta -> skip"
  pass "a task without metadata skips the probe"
}

test_non_ship_kind_skips() {
  local d out rc
  d="$TMP_ROOT/scout-kind"
  mkdir -p "$d/state"
  fm_write_meta "$d/state/t1.meta" "worktree=/nowhere" "kind=scout"
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 0 "$rc" "scout kind exits 0"
  assert_contains "$out" $'skip\tkind=scout' "scout kind -> skip"
  pass "a scout task records no ship delivery and skips"
}

test_ship_without_mode_skips() {
  local d out rc
  d="$TMP_ROOT/no-mode"
  mkdir -p "$d/state"
  fm_write_meta "$d/state/t1.meta" "worktree=/nowhere" "kind=ship"
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 0 "$rc" "modeless ship exits 0"
  assert_contains "$out" $'skip\tno recorded delivery mode' "modeless ship -> skip"
  pass "a ship task without a recorded mode skips the probe"
}

test_unknown_mode_skips() {
  local d out rc
  d=$(make_ship_case unknown-mode secondmate)
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 0 "$rc" "unknown mode exits 0"
  assert_contains "$out" $'skip\tunknown delivery mode' "unknown mode -> skip"
  pass "an unrecognized mode value skips rather than guesses"
}

test_refuted_when_no_remote_branch_and_no_pr() {
  local d out rc log
  d=$(make_ship_case refute-remote no-mistakes)
  log="$d/gh.log"
  export GH_STUB_LOG="$log" GH_STUB_OUT='[]'
  PATH="$(make_gh_stub "$d"):$PATH"
  out=$(run_proof "$d" t1)
  rc=$?
  unset GH_STUB_LOG GH_STUB_OUT
  expect_code 1 "$rc" "refuted exits 1"
  assert_contains "$out" $'refuted\tls-remote leer, kein PR' "empty probes -> refuted with evidence"
  pass "done with no origin branch and no PR is refuted"
}

test_delivered_branch_short_circuits_pr_probe() {
  local d out rc log
  d=$(make_ship_case green-branch direct-PR)
  git -C "$d/wt" push -q origin fm/t1
  log="$d/gh.log"
  export GH_STUB_LOG="$log"
  PATH="$(make_gh_stub "$d"):$PATH"
  out=$(run_proof "$d" t1)
  rc=$?
  unset GH_STUB_LOG
  expect_code 0 "$rc" "delivered exits 0"
  assert_contains "$out" 'delivered' "pushed branch -> delivered"
  assert_contains "$out" 'exists at origin' "delivered evidence names the origin branch"
  [ "$(gh_calls "$log")" = "0" ] || fail "gh was invoked after ls-remote already answered"
  pass "an existing origin branch delivers without a PR probe"
}

test_delivered_open_pr_without_branch() {
  local d out rc
  d=$(make_ship_case green-pr no-mistakes)
  export GH_STUB_LOG="$d/gh.log" GH_STUB_OUT='[{"state":"OPEN","number":7}]'
  PATH="$(make_gh_stub "$d"):$PATH"
  out=$(run_proof "$d" t1)
  rc=$?
  unset GH_STUB_LOG GH_STUB_OUT
  expect_code 0 "$rc" "open PR exits 0"
  assert_contains "$out" 'open or merged' "open PR -> delivered"
  pass "an open PR delivers when no branch sits at origin"
}

test_delivered_merged_pr() {
  local d out rc
  d=$(make_ship_case merged-pr direct-PR)
  export GH_STUB_LOG="$d/gh.log" GH_STUB_OUT='[{"state":"MERGED","number":8}]'
  PATH="$(make_gh_stub "$d"):$PATH"
  out=$(run_proof "$d" t1)
  rc=$?
  unset GH_STUB_LOG GH_STUB_OUT
  expect_code 0 "$rc" "merged PR exits 0"
  assert_contains "$out" 'open or merged' "merged PR -> delivered"
  pass "a merged PR still counts as delivered"
}

test_closed_unmerged_pr_does_not_deliver() {
  local d out rc
  d=$(make_ship_case closed-pr no-mistakes)
  export GH_STUB_LOG="$d/gh.log" GH_STUB_OUT='[{"state":"CLOSED","number":9}]'
  PATH="$(make_gh_stub "$d"):$PATH"
  out=$(run_proof "$d" t1)
  rc=$?
  unset GH_STUB_LOG GH_STUB_OUT
  expect_code 1 "$rc" "closed-only PR exits 1"
  assert_contains "$out" $'refuted\tls-remote leer, kein PR' "closed-unmerged PR is not delivery"
  pass "a closed-unmerged PR does not rescue a done claim"
}

test_failed_probe_is_unverified_not_refuted() {
  local d out rc
  d=$(make_ship_case offline no-mistakes)
  git -C "$d/wt" remote set-url origin /nonexistent/broken-origin.git
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 0 "$rc" "unverified exits 0"
  assert_contains "$out" $'unverified\t' "failed ls-remote -> unverified"
  pass "a probe that cannot answer is never evidence of absence"
}

test_local_only_committed_branch_delivers() {
  local d out rc
  d=$(make_ship_case local-green local-only)
  git -C "$d/wt" commit -q --allow-empty -m "the fix"
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 0 "$rc" "local-only committed exits 0"
  assert_contains "$out" 'carries 1 commit(s)' "own commit counted against merge base"
  pass "local-only done with committed branch work delivers"
}

test_local_only_empty_branch_refuted() {
  local d out rc
  d=$(make_ship_case local-empty local-only)
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 1 "$rc" "empty local branch exits 1"
  assert_contains "$out" $'refuted\tleerer Zweig fm/t1 im Worktree' "branch with no own commits -> refuted"
  pass "local-only done on an empty branch is refuted"
}

test_local_only_detached_head_refuted() {
  local d out rc
  d=$(make_ship_case local-detached local-only)
  git -C "$d/wt" checkout -q --detach HEAD
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 1 "$rc" "detached local-only exits 1"
  assert_contains "$out" $'refuted\tkein lokaler Zweig im Worktree' "detached HEAD names the missing branch"
  pass "local-only done without any checked-out branch is refuted"
}

test_local_only_still_delivers_after_fast_forward_landing() {
  local d out rc
  d=$(make_ship_case local-landed local-only)
  git -C "$d/wt" commit -q --allow-empty -m "the fix"
  git -C "$d/project" merge -q --ff-only fm/t1
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 0 "$rc" "landed local branch exits 0"
  assert_contains "$out" 'carries 1 commit(s)' "merge-base counting survives the fast-forward"
  pass "a fast-forwarded local default never reads a landed branch as empty"
}

test_local_only_gone_worktree_unverified() {
  local d out rc
  d=$(make_ship_case local-gone local-only)
  rm -rf "$d/wt"
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 0 "$rc" "gone worktree exits 0"
  assert_contains "$out" $'unverified\tworktree missing' "gone worktree -> unverified"
  pass "a torn-down local-only worktree cannot refute anything"
}

test_local_only_without_origin_falls_back_to_local_default() {
  local d out rc base
  d=$(make_ship_case local-noorigin local-only)
  base=$(git -C "$d/project" symbolic-ref --quiet --short HEAD)
  git -C "$d/wt" commit -q --allow-empty -m "the fix"
  git -C "$d/project" update-ref -d "refs/remotes/origin/$base"
  git -C "$d/project" remote remove origin
  out=$(run_proof "$d" t1)
  rc=$?
  expect_code 0 "$rc" "no-origin fallback exits 0"
  assert_contains "$out" 'carries 1 commit(s)' "local default anchor still counts the branch's commits"
  pass "a clone without origin tracking counts against the local default"
}

test_main() {
  test_missing_meta_skips
  test_non_ship_kind_skips
  test_ship_without_mode_skips
  test_unknown_mode_skips
  test_refuted_when_no_remote_branch_and_no_pr
  test_delivered_branch_short_circuits_pr_probe
  test_delivered_open_pr_without_branch
  test_delivered_merged_pr
  test_closed_unmerged_pr_does_not_deliver
  test_failed_probe_is_unverified_not_refuted
  test_local_only_committed_branch_delivers
  test_local_only_empty_branch_refuted
  test_local_only_detached_head_refuted
  test_local_only_still_delivers_after_fast_forward_landing
  test_local_only_gone_worktree_unverified
  test_local_only_without_origin_falls_back_to_local_default
}

test_main
echo "all fm-delivery-proof tests passed"
