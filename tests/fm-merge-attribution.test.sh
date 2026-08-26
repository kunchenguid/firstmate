#!/usr/bin/env bash
# Tests for bin/fm-merge-attribution-lib.sh's durable merge-provenance record
# and bin/fm-merge-attribution.sh, the checker that reads it back.
#
# The forge's own merged-by field cannot say who decided to merge, because
# firstmate, every crewmate, and the captain act through the same forge
# identity. These scripts answer a narrower question instead: did this exact
# merge go through the one path firstmate uses to merge (bin/fm-pr-merge.sh
# for a PR, bin/fm-merge-local.sh for a local-only fast-forward)? That path
# stamps a durable, firstmate-private record at the moment its own merge
# succeeds; the checker reads it back in a completely separate process
# invocation, proving the record is real file state and not anything carried
# in memory.
#
# Matrix:
#   (a) a GitHub PR merged through bin/fm-pr-merge.sh reads attributed
#   (b) a merged GitHub PR with no provenance record reads unattributed, and
#       the verdict text never says "firstmate"
#   (c) a merged GitHub PR whose provenance record names a different head
#       (i.e. a push landed after the recorded merge) reads unattributed
#   (d) an open (not yet merged) GitHub PR reads unmerged, not unattributed
#   (e) a failed gh-axi merge writes no provenance record at all
#   (f) a local-only fast-forward through bin/fm-merge-local.sh reads
#       attributed
#   (g) a project whose default branch was advanced by some other means, with
#       no matching provenance record, reads unattributed
#   (h) a refused (diverged) local-only merge writes no provenance record
#   (i) a PR whose head changed since fm-pr-merge.sh's pre-merge read is
#       refused outright (mirroring GitHub's --match-head-commit), rather
#       than merging under a head this run never verified
#   (j) a local-only merge stays attributed after later, unrelated commits
#       land on the default branch - the recorded merge itself never moves
#   (k) a GitHub merge invoked with --auto that only queues (the PR is still
#       open right after the call) writes no provenance record until the PR
#       actually reads merged
#   (l) a PR-based task (mode=direct-PR) with no recorded pr= reports an
#       error rather than a verdict guessed from unrelated local git state,
#       even when that local state looks exactly like a genuine local-only
#       merge
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
ATTRIBUTION="$ROOT/bin/fm-merge-attribution.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-attribution-tests)

# make_pr_case <name>: a state dir with a task meta and a fakebin, mirroring
# tests/fm-pr-merge.test.sh's fixture shape. Echoes the case dir.
make_pr_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin" "$case_dir/wt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=direct-PR"
  printf '%s\n' "$case_dir"
}

# add_gh_mock <case_dir> <head> <state>: a gh mock answering the headRefOid
# lookup (fm-pr-check.sh's and fm-pr-merge.sh's single-field read), the
# combined state+headRefOid @tsv lookup (the checker's single-call read, and
# fm-pr-merge.sh's post-merge completion check), and the bare state lookup
# (fm-pr-merge.sh's post-merge completion check uses --json state alone,
# which does not contain "headRefOid"), plus a "pr merge" case that always
# succeeds so fm-pr-merge.sh's real-gh merge call (bound to a valid head)
# has somewhere to land. A gh-axi mock records every invocation it receives
# and always succeeds, for the unbound-head fallback path.
add_gh_mock() {
  local case_dir=$1 head=$2 state=$3
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *'@tsv'*) printf '%s\t%s\n' '$state' '$head' ; exit 0 ;;
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *) printf '%s\n' '$state' ; exit 0 ;;
    esac
    ;;
  "pr merge")
    printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"
}

# add_gh_mock_merge_fails <case_dir> <head> <state>: like add_gh_mock, but the
# merge call itself fails - on gh, the binary a valid, bound head routes to,
# and on gh-axi too for defense in depth - so provenance recording after a
# real failure can be told apart from provenance recording after a real
# success.
add_gh_mock_merge_fails() {
  local case_dir=$1 head=$2 state=$3
  add_gh_mock "$case_dir" "$head" "$state"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *'@tsv'*) printf '%s\t%s\n' '$state' '$head' ; exit 0 ;;
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *) printf '%s\n' '$state' ; exit 0 ;;
    esac
    ;;
  "pr merge")
    printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
    echo "error: pr merge failed" >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

run_attribution() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$ATTRIBUTION" "$@"
}

test_github_merge_via_recorded_path_is_attributed() {
  local case_dir rc out
  case_dir=$(make_pr_case github-attributed)
  add_gh_mock "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa MERGED

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/merge.out" 2> "$case_dir/merge.err" \
    || fail "github-attributed: fm-pr-merge should have succeeded: $(cat "$case_dir/merge.err")"
  assert_present "$case_dir/state/task-x1.merge-provenance" \
    "github-attributed: no provenance record was written after a successful merge"

  # A completely separate process invocation, proving the record is durable
  # file state rather than anything the merging process kept in memory.
  set +e
  out=$(run_attribution "$case_dir" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 0 "$rc" "github-attributed: attribution check should exit 0"
  assert_contains "$out" "attributed:" "github-attributed: verdict was not attributed: $out"
  pass "a GitHub PR merged through bin/fm-pr-merge.sh reads attributed by a fresh process"
}

test_github_merge_without_provenance_is_unattributed() {
  local case_dir rc out
  case_dir=$(make_pr_case github-no-provenance)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=direct-PR" \
    "pr=https://github.com/example/repo/pull/9"
  add_gh_mock "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb MERGED

  set +e
  out=$(run_attribution "$case_dir" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 1 "$rc" "github-no-provenance: attribution check should exit 1"
  assert_contains "$out" "unattributed:" "github-no-provenance: verdict was not unattributed: $out"
  assert_not_contains "$out" "firstmate" \
    "github-no-provenance: an unattributed merge must never be described as firstmate's"
  pass "a merged GitHub PR with no recorded-path provenance reads unattributed, never firstmate's"
}

test_github_merge_with_stale_provenance_is_unattributed() {
  local case_dir rc out
  case_dir=$(make_pr_case github-stale-provenance)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=direct-PR" \
    "pr=https://github.com/example/repo/pull/9"
  # First merge cleanly through the recorded path, recording head c...c.
  add_gh_mock "$case_dir" cccccccccccccccccccccccccccccccccccccccc MERGED

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/merge.out" 2> "$case_dir/merge.err"
  set -e
  assert_present "$case_dir/state/task-x1.merge-provenance" \
    "github-stale-provenance: setup should have recorded a provenance record"

  # Now the live head moves without going through the recorded path again.
  add_gh_mock "$case_dir" dddddddddddddddddddddddddddddddddddddddd MERGED

  set +e
  out=$(run_attribution "$case_dir" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 1 "$rc" "github-stale-provenance: attribution check should exit 1"
  assert_contains "$out" "unattributed:" \
    "github-stale-provenance: a head mismatch was not reported as unattributed: $out"
  pass "a merged GitHub PR whose live head disagrees with the recorded provenance reads unattributed"
}

test_github_open_pr_is_unmerged_not_unattributed() {
  local case_dir rc out
  case_dir=$(make_pr_case github-open)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=direct-PR" \
    "pr=https://github.com/example/repo/pull/9"
  add_gh_mock "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee OPEN

  set +e
  out=$(run_attribution "$case_dir" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 2 "$rc" "github-open: attribution check should exit 2 for an unmerged PR"
  assert_contains "$out" "unmerged:" "github-open: verdict was not unmerged: $out"
  pass "an open GitHub PR reads unmerged rather than unattributed"
}

test_failed_github_merge_writes_no_provenance() {
  local case_dir rc
  case_dir=$(make_pr_case github-merge-fails)
  add_gh_mock_merge_fails "$case_dir" ffffffffffffffffffffffffffffffffffffffff OPEN

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/merge.out" 2> "$case_dir/merge.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-merge-fails: fm-pr-merge should propagate the gh-axi failure"
  assert_absent "$case_dir/state/task-x1.merge-provenance" \
    "github-merge-fails: a failed merge must not write a provenance record"
  pass "a failed gh-axi merge writes no provenance record"
}

# add_gh_mock_head_changes_during_merge <case_dir> <old_head> <new_head>: a gh
# mock that answers headRefOid from a file, and whose "pr merge" call
# simulates a push landing exactly in the window between fm-pr-merge.sh's
# pre-merge head read and this call: it flips the live head to new_head, then
# refuses the merge whenever it was invoked bound to a head (old_head) that no
# longer matches. This lives on the gh mock, not gh-axi: fm-pr-merge.sh routes
# a bound-head GitHub merge to the real gh binary, because gh-axi does not
# support --match-head-commit and would silently drop it - a mock on gh-axi
# would be asserting behavior gh-axi does not actually have.
add_gh_mock_head_changes_during_merge() {
  local case_dir=$1 old_head=$2 new_head=$3
  printf '%s\n' "$old_head" > "$case_dir/live-head"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *'@tsv'*)
        printf 'MERGED\t%s\n' "\$(cat '$case_dir/live-head')"
        exit 0
        ;;
      *headRefOid*) cat '$case_dir/live-head' ; exit 0 ;;
      *) printf 'MERGED\n' ; exit 0 ;;
    esac
    ;;
  "pr merge")
    printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
    printf '%s\n' '$new_head' > '$case_dir/live-head'
    case " \$* " in
      *"--match-head-commit $old_head"*)
        echo "error: head commit does not match" >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"
}

test_github_merge_refuses_when_head_changes_during_merge_window() {
  local case_dir rc old_head new_head
  case_dir=$(make_pr_case github-race)
  old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  new_head=cccccccccccccccccccccccccccccccccccccccc
  add_gh_mock_head_changes_during_merge "$case_dir" "$old_head" "$new_head"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/merge.out" 2> "$case_dir/merge.err"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-race: fm-pr-merge should refuse when the bound head no longer matches"
  assert_absent "$case_dir/state/task-x1.merge-provenance" \
    "github-race: a refused (head-mismatch) merge must not write a provenance record"
  pass "fm-pr-merge refuses to merge, and records nothing, when the PR head changed since its pre-merge read"
}

test_github_auto_queue_does_not_stamp_before_actual_merge() {
  local case_dir rc out
  case_dir=$(make_pr_case github-auto-queue)
  # --auto can exit 0 having only queued the merge; the PR is still open right
  # after the call, exactly as this mock reports it before and after.
  add_gh_mock "$case_dir" 1111111111111111111111111111111111111111 OPEN

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 -- --auto \
    > "$case_dir/merge.out" 2> "$case_dir/merge.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "github-auto-queue: fm-pr-merge should succeed when --auto only queues the merge"
  assert_grep 'not yet merged' "$case_dir/merge.err" \
    "github-auto-queue: no warning was printed for a queued, not-yet-completed auto-merge"
  assert_absent "$case_dir/state/task-x1.merge-provenance" \
    "github-auto-queue: provenance must not be stamped before the PR actually merges"

  set +e
  out=$(run_attribution "$case_dir" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 2 "$rc" "github-auto-queue: attribution check should read unmerged while the auto-merge is only queued"
  assert_contains "$out" "unmerged:" "github-auto-queue: verdict was not unmerged: $out"
  pass "a GitHub --auto merge that only queues is not stamped with provenance until it actually merges"
}

test_pr_mode_without_recorded_pr_is_error_not_local_only() {
  local case_dir rc out proj
  case_dir=$(make_local_case pr-mode-missing-pr)
  proj="$case_dir/project"
  # This project's fm/task-x1 branch is already merged into its default
  # branch, exactly as a genuine local-only merge would leave it - but the
  # task's own meta says mode=direct-PR, so this is a PR-based task whose pr=
  # was simply never recorded (fm-pr-check.sh never ran, e.g. the PR was
  # opened and merged by hand), not a local-only task. Local git state must
  # not stand in for a PR verdict it says nothing about.
  git -C "$proj" merge --ff-only "fm/task-x1" > /dev/null
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$proj-wt" \
    "project=$proj" \
    "kind=ship" \
    "mode=direct-PR"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ATTRIBUTION" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 3 "$rc" "pr-mode-missing-pr: attribution check should error, not guess from local git state"
  assert_grep 'error:' "$case_dir/attr.err" \
    "pr-mode-missing-pr: no error was reported: $(cat "$case_dir/attr.err")"
  assert_not_contains "$out" "attributed:" \
    "pr-mode-missing-pr: a PR-based task with no recorded pr= must never read as attributed from unrelated local git state"
  assert_not_contains "$out" "unmerged:" \
    "pr-mode-missing-pr: a PR-based task with no recorded pr= must never read as unmerged from unrelated local git state"
  pass "a PR-based task with no recorded pr= reports an error instead of a verdict guessed from local git state"
}

# --- local-only ---------------------------------------------------------

# make_local_case <name>: a real project git repo on its default branch, a
# crewmate branch fm-<id> one commit ahead, and the local-only task meta
# fm-merge-local.sh requires. Echoes the case dir.
make_local_case() {
  local name=$1 case_dir proj
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  mkdir -p "$case_dir/state"
  fm_git_init_commit "$proj"
  git -C "$proj" checkout -q -b "fm/task-x1"
  printf 'change\n' > "$proj/change.txt"
  git -C "$proj" add change.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "task change"
  git -C "$proj" checkout -q main 2>/dev/null || git -C "$proj" checkout -q master
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$proj-wt" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

test_local_only_merge_via_recorded_path_is_attributed() {
  local case_dir rc out
  case_dir=$(make_local_case local-attributed)

  run_merge_local "$case_dir" task-x1 > "$case_dir/merge.out" 2> "$case_dir/merge.err" \
    || fail "local-attributed: fm-merge-local should have succeeded: $(cat "$case_dir/merge.err")"
  assert_present "$case_dir/state/task-x1.merge-provenance" \
    "local-attributed: no provenance record was written after a successful fast-forward"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ATTRIBUTION" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 0 "$rc" "local-attributed: attribution check should exit 0"
  assert_contains "$out" "attributed:" "local-attributed: verdict was not attributed: $out"
  pass "a local-only fast-forward through bin/fm-merge-local.sh reads attributed by a fresh process"
}

test_local_only_advance_without_recorded_path_is_unattributed() {
  local case_dir rc out proj
  case_dir=$(make_local_case local-no-provenance)
  proj="$case_dir/project"

  # The default branch advances to the crewmate's commit by some other means
  # entirely (a captain running git merge by hand, say) - never through
  # bin/fm-merge-local.sh, so no provenance record is ever written.
  git -C "$proj" merge --ff-only "fm/task-x1" > /dev/null

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ATTRIBUTION" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 1 "$rc" "local-no-provenance: attribution check should exit 1"
  assert_contains "$out" "unattributed:" "local-no-provenance: verdict was not unattributed: $out"
  assert_not_contains "$out" "firstmate" \
    "local-no-provenance: an unattributed merge must never be described as firstmate's"
  pass "a local default-branch advance with no recorded-path provenance reads unattributed"
}

test_local_only_stays_attributed_after_default_branch_advances() {
  local case_dir rc out proj
  case_dir=$(make_local_case local-attributed-ages-well)
  proj="$case_dir/project"

  run_merge_local "$case_dir" task-x1 > "$case_dir/merge.out" 2> "$case_dir/merge.err" \
    || fail "local-ages-well: fm-merge-local should have succeeded: $(cat "$case_dir/merge.err")"

  # The default branch keeps moving after this task's own merge landed - some
  # unrelated later commit lands on top, exactly like real fleet activity.
  # Comparing against the default branch's live tip would make this stale the
  # instant that later commit lands; the recorded merge itself never changes.
  printf 'later\n' > "$proj/later.txt"
  git -C "$proj" add later.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "unrelated later change"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ATTRIBUTION" task-x1 2> "$case_dir/attr.err")
  rc=$?
  set -e
  expect_code 0 "$rc" "local-ages-well: attribution check should still exit 0 after later commits land"
  assert_contains "$out" "attributed:" "local-ages-well: verdict was not attributed: $out"
  pass "a local-only merge stays attributed after later default-branch commits land"
}

test_refused_local_only_merge_writes_no_provenance() {
  local case_dir rc proj
  case_dir=$(make_local_case local-diverged)
  proj="$case_dir/project"
  # Diverge the default branch so the fast-forward is refused.
  printf 'unrelated\n' > "$proj/unrelated.txt"
  git -C "$proj" add unrelated.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "unrelated change"

  set +e
  run_merge_local "$case_dir" task-x1 > "$case_dir/merge.out" 2> "$case_dir/merge.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "local-diverged: fm-merge-local should refuse a diverged branch"
  assert_absent "$case_dir/state/task-x1.merge-provenance" \
    "local-diverged: a refused merge must not write a provenance record"
  pass "a refused (diverged) local-only merge writes no provenance record"
}

test_github_merge_via_recorded_path_is_attributed
test_github_merge_without_provenance_is_unattributed
test_github_merge_with_stale_provenance_is_unattributed
test_github_open_pr_is_unmerged_not_unattributed
test_failed_github_merge_writes_no_provenance
test_github_merge_refuses_when_head_changes_during_merge_window
test_github_auto_queue_does_not_stamp_before_actual_merge
test_pr_mode_without_recorded_pr_is_error_not_local_only
test_local_only_merge_via_recorded_path_is_attributed
test_local_only_advance_without_recorded_path_is_unattributed
test_local_only_stays_attributed_after_default_branch_advances
test_refused_local_only_merge_writes_no_provenance
