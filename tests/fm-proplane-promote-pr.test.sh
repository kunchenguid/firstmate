#!/usr/bin/env bash
# Tests for the PropPlane ladder's promotion-record PR: the pull request that
# bin/fm-proplane-promote-prakrit-to-main.sh opens for every prakrit -> main
# promotion (bin/fm-proplane-promote-pr-lib.sh owns the contract).
#
# The behavior that matters is that the PR is a RECORD, not a gate: it must
# never stop, delay, or reverse a promotion, and it must not duplicate itself.
#
# Matrix:
#   (a) the body states the promoted range, security outcome, validation outcome
#   (b) no open PR for the pair -> gh-axi pr create with base, head, title, body
#   (c) an open PR for the pair -> gh-axi pr edit on it, never a second create
#   (d) gh-axi failure -> non-zero return and the reason on stderr
#   (e) dry run -> prints the PR it would open and makes no gh-axi call
#   (f) end to end: --push-main opens the record, then fast-forwards origin/main
#   (g) end to end: a failing gh-axi warns but still fast-forwards origin/main
#   (h) end to end: --dry-run opens nothing and pushes nothing
#   (k) every gh-axi call is bounded, and a timed-out one only warns
#   (l) an open PR that is not a promotion record is never rewritten
#   (m) end to end: a failed fast-forward annotates the record it already opened
#   (p) end to end: a failure AFTER main lands leaves that record alone
#   (s) the body reconciles the promoted range against the diff GitHub renders
#   (t) end to end: a plain --dry-run runs no gate and still previews the record
#   (u) the reset guard refuses when it cannot read a worktree's state
#   (v) the reconciliation reads the head branch as GitHub has it, not a stale ref
#   (w) a head branch that cannot be read is recorded as unavailable, not guessed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_LIB="$ROOT/bin/fm-proplane-promote-pr-lib.sh"
PROMOTE_MAIN="$ROOT/bin/fm-proplane-promote-prakrit-to-main.sh"
TMP_ROOT=$(fm_test_tmproot fm-proplane-promote-pr-tests)

# shellcheck source=bin/fm-proplane-promote-pr-lib.sh
. "$PR_LIB"

# --- fixtures ---------------------------------------------------------------

# make_repo <dir>: a PropPlane-shaped git root with origin, a main branch, and a
# prakrit branch holding one commit main does not have.
make_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
  git -C "$dir" checkout -q -b prakrit
  printf 'feature\n' > "$dir/feature.txt"
  git -C "$dir" add feature.txt
  git -C "$dir" commit -qm 'feat: promoted change'
  git -C "$dir" checkout -q main
  fm_git_add_origin "$dir" "$dir.origin"
  git -C "$dir" push -q origin main prakrit
  git -C "$dir" fetch -q origin
}

# make_gh_axi <fakebin> <mode>: gh-axi stub logging every call to
# $FM_TEST_GH_AXI_LOG. Modes: none (no open PR), existing (one open PR #77),
# foreign (one open PR #66 that is NOT a promotion record), buried (a foreign PR
# listed ahead of the record, so only a listing wider than one row finds it),
# create-fails (listing works, create does not), create-silent (create succeeds
# but prints no URL), list-fails, comment-fails.
#
# `pr list` honors --limit the way the real one does, so a test that needs a row
# gh-axi would have truncated away cannot pass on a stub that ignores the cap.
make_gh_axi() {
  local fakebin=$1 mode=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
mode=$mode
# Keep the generated body, which the caller deletes as soon as the call returns.
if [ -n "\${FM_TEST_GH_AXI_BODY:-}" ] && [ "\$#" -gt 0 ] && [ -f "\${!#}" ]; then
  cat "\${!#}" > "\$FM_TEST_GH_AXI_BODY"
fi
case "\${1:-} \${2:-}" in
  "pr list")
    [ "\$mode" = list-fails ] && { echo "error: HTTP 401" >&2; exit 1; }
    limit=1
    prev=
    for a in "\$@"; do
      [ "\$prev" = --limit ] && limit=\$a
      prev=\$a
    done
    if [ "\$mode" = existing ]; then
      echo 'count: 1 of 1 total'
      echo 'pull_requests[1]{number,title,state,author,draft,review}:'
      echo '  77,"promote(ladder): prakrit -> main (aaa..bbb)",open,prakrit,no,none'
    elif [ "\$mode" = foreign ]; then
      # A listing that leads with a real, unrelated PR: what a gh-axi that
      # stopped honoring --base/--head would hand back.
      echo 'count: 1 of 1 total'
      echo 'pull_requests[1]{number,title,state,author,draft,review}:'
      echo '  66,"feat(billing): someone elses open work",open,someone,no,none'
    elif [ "\$mode" = buried ]; then
      echo 'count: 2 of 2 total'
      echo 'pull_requests[2]{number,title,state,author,draft,review}:'
      echo '  66,"feat(billing): someone elses open work",open,someone,no,none'
      [ "\$limit" -ge 2 ] &&
        echo '  77,"promote(ladder): prakrit -> main (aaa..bbb)",open,prakrit,no,none'
    else
      echo 'count: 0'
      echo 'pull_requests: []'
    fi
    exit 0
    ;;
  "pr comment")
    [ "\$mode" = comment-fails ] && { echo "error: HTTP 502" >&2; exit 1; }
    echo 'commented: https://github.com/PrakritR/PropLane/pull/91#issuecomment-1'
    exit 0
    ;;
  "pr create")
    # Proof of ordering for the end-to-end cases: what origin/main pointed at
    # when the record was opened, so a PR opened after the fast-forward (which
    # would never close as merged) is detectable.
    [ -n "\${FM_TEST_ORIGIN:-}" ] &&
      printf 'origin-main-at-create:%s\n' "\$(git --git-dir="\$FM_TEST_ORIGIN" rev-parse main)" >> "\$FM_TEST_GH_AXI_LOG"
    [ "\$mode" = create-fails ] && { echo "error: rate limit exceeded" >&2; exit 1; }
    # create-silent: the PR really is opened, but the output carries no URL, so
    # its number cannot be scraped back out.
    [ "\$mode" = create-silent ] && { echo 'created'; exit 0; }
    echo 'created: https://github.com/PrakritR/PropLane/pull/91'
    exit 0
    ;;
  "pr edit")
    echo 'updated: https://github.com/PrakritR/PropLane/pull/77'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
}

# --- (a) body states range, security outcome, validation outcome -------------

case_a="$TMP_ROOT/a"
mkdir -p "$case_a"
make_repo "$case_a/repo"
body=$(fm_proplane_promote_pr_body "$case_a/repo" origin/main origin/prakrit \
  'passed (no Critical or High findings)' 'proplane-security-review-abc1234.md' \
  'passed (no-mistakes: review, tests, document, lint)')
assert_contains "$body" 'origin/main..origin/prakrit' 'body names the promoted range'
assert_contains "$body" '- commits: 1' 'body counts the promoted commits'
assert_contains "$body" 'feat: promoted change' 'body lists the promoted commit'
assert_contains "$body" 'passed (no Critical or High findings)' 'body states the security outcome'
assert_contains "$body" 'proplane-security-review-abc1234.md' 'body names the security report'
assert_contains "$body" 'passed (no-mistakes: review, tests, document, lint)' 'body states the validation outcome'
assert_contains "$body" 'not a second approval gate' 'body says the PR does not gate the promotion'
pass 'promotion PR body states range, security outcome, and validation outcome'

# The record is published on GitHub, so the evidence pointer must be the report's
# sha-keyed filename and never the absolute $FM_HOME path that produced it.
[ "$(fm_proplane_promote_pr_report_label "/Users/somebody/firstmate/state/proplane-security-review-abc1234.md")" \
  = 'proplane-security-review-abc1234.md' ] || fail 'report label should be the filename alone'
[ -z "$(fm_proplane_promote_pr_report_label '')" ] || fail 'an empty report path should stay empty'
report_body=$(fm_proplane_promote_pr_body "$case_a/repo" origin/main origin/prakrit 'passed' \
  "$(fm_proplane_promote_pr_report_label "/Users/somebody/firstmate/state/proplane-security-review-abc1234.md")" 'passed')
assert_not_contains "$report_body" '/Users/somebody' 'the record must not carry a local directory path'
pass 'the security report is recorded by filename, never by absolute path'

# --- the commit listing marks truncation, so it is not read as the filter ------

case_cap="$TMP_ROOT/cap"
mkdir -p "$case_cap"
make_repo "$case_cap/repo"
git -C "$case_cap/repo" checkout -q prakrit
for n in 1 2 3 4 5; do
  printf '%s\n' "$n" > "$case_cap/repo/bulk-$n.txt"
  git -C "$case_cap/repo" add "bulk-$n.txt"
  git -C "$case_cap/repo" commit -qm "feat: bulk change $n"
done
git -C "$case_cap/repo" push -q origin prakrit
git -C "$case_cap/repo" fetch -q origin
capped=$(FM_PROPLANE_PR_COMMIT_CAP=2 bash -c '
  . "$1"
  fm_proplane_promote_pr_body "$2" origin/main origin/prakrit passed "" passed
' _ "$PR_LIB" "$case_cap/repo")
assert_contains "$capped" '- commits: 6' 'the count above the listing stays exact'
assert_contains "$capped" '- (... 4 more, listing capped at 2)' 'a truncated listing says how much it dropped'
uncapped=$(FM_PROPLANE_PR_COMMIT_CAP=40 bash -c '
  . "$1"
  fm_proplane_promote_pr_body "$2" origin/main origin/prakrit passed "" passed
' _ "$PR_LIB" "$case_cap/repo")
assert_not_contains "$uncapped" 'listing capped at' 'an untruncated listing carries no marker'
pass 'a capped commit listing is marked as truncated, not left to look filtered'

# An empty report path must not leave a dangling "report:" line.
body_no_report=$(fm_proplane_promote_pr_body "$case_a/repo" origin/main origin/prakrit \
  'SKIPPED (captain-authorized)' '' 'SKIPPED by --skip-gates (captain-authorized)')
assert_contains "$body_no_report" 'SKIPPED (captain-authorized)' 'skipped security outcome is stated'
assert_not_contains "$body_no_report" '- report:' 'no report line without a report'
pass 'promotion PR body reports skipped gates as skipped'

# --- (s) the body reconciles the promoted range against the rendered diff -----
#
# The PR is opened FROM prakrit, because the keeper-branch rule never pushes
# integrate/* to GitHub, while the promoted range is built ON the integrate
# branch that the no-mistakes validation commits its fixes onto. GitHub renders
# prakrit's diff either way, so a body that states only the range leaves a reader
# unable to tell which commits that diff omits and which it shows but never
# landed. Both directions have to be named.

case_s="$TMP_ROOT/s"
mkdir -p "$case_s"
make_repo "$case_s/repo"
# main moves first, so merging prakrit into it produces a REAL merge commit
# rather than a fast-forward. Without that the promoted range holds no merge at
# all, and the count assertions below pass whether or not the counts and their
# listings share a filter, which would document nothing.
git -C "$case_s/repo" checkout -q main
printf 'hotfix\n' > "$case_s/repo/hotfix.txt"
git -C "$case_s/repo" add hotfix.txt
git -C "$case_s/repo" commit -qm 'fix: landed on main before this promotion'
git -C "$case_s/repo" push -q origin main
git -C "$case_s/repo" fetch -q origin
# What a real promotion validates on: origin/prakrit merged into origin/main,
# plus a fix the validation committed there, which never reaches prakrit.
git -C "$case_s/repo" checkout -q -B integrate/prakrit-to-main origin/main
git -C "$case_s/repo" merge -q --no-edit origin/prakrit -m 'integrate(prakrit): test fixture'
[ "$(git -C "$case_s/repo" rev-list --count --merges origin/main..integrate/prakrit-to-main)" -ge 1 ] ||
  fail 'the fixture must carry a real integration merge for the count assertions to discriminate'
printf 'fix\n' > "$case_s/repo/fix.txt"
git -C "$case_s/repo" add fix.txt
git -C "$case_s/repo" commit -qm 'fix: committed onto integrate by the validation'
# And a commit another agent pushed to prakrit after the integrate branch was
# cut, which this promotion does not deliver.
git -C "$case_s/repo" checkout -q prakrit
printf 'later\n' > "$case_s/repo/later.txt"
git -C "$case_s/repo" add later.txt
git -C "$case_s/repo" commit -qm 'feat: pushed to prakrit after the cut'
git -C "$case_s/repo" push -q origin prakrit
git -C "$case_s/repo" fetch -q origin
integrate_tip=$(git -C "$case_s/repo" rev-parse integrate/prakrit-to-main)

diverged=$(fm_proplane_promote_pr_body "$case_s/repo" origin/main integrate/prakrit-to-main \
  passed '' passed origin/prakrit)
assert_contains "$diverged" "$integrate_tip" 'the body names the exact tip main is fast-forwarded to'
assert_contains "$diverged" 'Promoted but NOT on' 'the body says the diff omits promoted commits'
assert_contains "$diverged" 'committed onto integrate by the validation' \
  'the body lists the promoted commit GitHub cannot show'
assert_contains "$diverged" 'but NOT promoted, so this PR' 'the body says the diff shows unpromoted commits'
assert_contains "$diverged" 'pushed to prakrit after the cut' \
  'the body lists the head-branch commit this promotion does not land'
assert_contains "$diverged" 'does NOT close as merged' 'the body stops claiming a close it will not get'
assert_contains "$diverged" 'authoritative' 'the promoted range is stated as the authority'
# The integration merge is in the promoted range and not on prakrit, so a count
# that included merges would print a number the bullet list below it contradicts.
assert_contains "$diverged" 'does not show them (1):' 'the count describes the same set as the list'
assert_contains "$diverged" 'did not land them (1):' 'the unlanded count describes its own list'
pass 'the body reconciles the promoted range against the diff GitHub renders'

# The same rule one section up: the promoted total counts merges, the listing
# under it does not, so the record must say which number the list is showing.
assert_contains "$diverged" 'merges included' 'a total larger than its listing says so'
assert_contains "$diverged" 'non-merge commits are what the listing below shows' \
  'the record names the number the listing actually shows'
promoted_total=$(printf '%s\n' "$diverged" | sed -n 's/^- commits: \([0-9][0-9]*\).*/\1/p')
promoted_listed=$(printf '%s\n' "$diverged" | sed -n 's/.*; the \([0-9][0-9]*\) non-merge commits are what.*/\1/p')
[ "$promoted_total" -gt "$promoted_listed" ] ||
  fail 'the fixture must make the promoted total exceed its non-merge listing'
[ "$promoted_listed" = "$(printf '%s\n' "$diverged" | awk '
  /^- commits: / { on = 1; next }
  on && /^- / && !/^- .main. is/ { n++ }
  on && /^## / { exit }
  END { print n + 0 }')" ] ||
  fail 'the stated non-merge count must match the promoted listing'
pass 'the promoted commit total says which of its commits the listing shows'

# A count and the bullet list under it must describe the same set, or a section
# whose whole purpose is saying what is missing disagrees with itself.
for section in 'does not show them' 'did not land them'; do
  stated=$(printf '%s\n' "$diverged" | sed -n "s/.*$section (\([0-9][0-9]*\)):.*/\1/p")
  listed=$(printf '%s\n' "$diverged" | awk -v s="$section" '
    index($0, s) { on = 1; next }
    on && /^- / { n++ }
    on && /^$/ && n { on = 0 }
    END { print n + 0 }')
  [ "$stated" = "$listed" ] ||
    fail "the '$section' count ($stated) must match its listing ($listed)"
done
pass 'each reconciliation count matches the commits actually listed under it'

# When the head branch and the promoted range agree, the record says so, and the
# close-as-merged claim is the accurate one to make.
aligned=$(fm_proplane_promote_pr_body "$case_a/repo" origin/main origin/prakrit passed '' passed origin/prakrit)
assert_contains "$aligned" 'the same non-merge commits as the promoted range' 'an aligned head is recorded as aligned'
assert_contains "$aligned" 'which closes this PR as merged' 'an aligned record states the close it does get'
assert_not_contains "$aligned" 'NOT promoted' 'nothing is reported as unlanded when nothing is'
pass 'a head branch matching the promoted range is recorded as the promotion itself'

# A divergence made only of merge commits is routine: sync_prakrit_from_main and
# fm-prakrit-sync-agent-branches.sh both put a bare merge(main) on prakrit. The
# head then carries no non-merge commit the promotion misses, yet is still not
# contained in it, so a body that decided alignment and closing separately would
# call the head aligned and in the next breath say it carries undelivered work.
case_x="$TMP_ROOT/x"
mkdir -p "$case_x"
make_repo "$case_x/repo"
# main moves, so the integrate branch is a real merge of main and prakrit, and
# the ladder's own realignment merge of main back into prakrit is a real merge
# too. Both sides then hold the same content and differ only by which merge
# commit carries it.
git -C "$case_x/repo" checkout -q main
printf 'hotfix\n' > "$case_x/repo/hotfix.txt"
git -C "$case_x/repo" add hotfix.txt
git -C "$case_x/repo" commit -qm 'fix: landed on main before this promotion'
git -C "$case_x/repo" push -q origin main
git -C "$case_x/repo" fetch -q origin
git -C "$case_x/repo" checkout -q -B integrate/prakrit-to-main origin/main
git -C "$case_x/repo" merge -q --no-edit origin/prakrit -m 'integrate(prakrit): test fixture'
git -C "$case_x/repo" checkout -q prakrit
git -C "$case_x/repo" merge -q --no-edit origin/main -m 'merge(main): keep integration aligned after main promote'
git -C "$case_x/repo" push -q origin prakrit
git -C "$case_x/repo" fetch -q origin
[ "$(fm_proplane_promote_pr_commit_count "$case_x/repo" no-merges origin/prakrit --not integrate/prakrit-to-main)" = 0 ] &&
  [ "$(fm_proplane_promote_pr_commit_count "$case_x/repo" no-merges origin/main..integrate/prakrit-to-main --not origin/prakrit)" = 0 ] ||
  fail 'the fixture must diverge by merge commits alone'
! git -C "$case_x/repo" merge-base --is-ancestor origin/prakrit integrate/prakrit-to-main 2>/dev/null ||
  fail 'the fixture must leave prakrit outside the promoted range'

merge_only=$(fm_proplane_promote_pr_body "$case_x/repo" origin/main integrate/prakrit-to-main \
  passed '' passed origin/prakrit)
assert_contains "$merge_only" 'the difference is merge commits only (1):' \
  'a merge-only divergence is named and counted'
assert_contains "$merge_only" 'keep integration aligned after main promote' \
  'the merge that causes it is listed as evidence'
assert_contains "$merge_only" 'is still not contained in it' \
  'the head is never called aligned outright when it is not contained in the range'
assert_contains "$merge_only" 'does NOT close as merged' 'a record that will not close says so'
assert_contains "$merge_only" 'merge commits only, listed above' \
  'the reason the record will not close points at the evidence'
assert_not_contains "$merge_only" 'diff is the promotion.' \
  'the aligned wording is never printed for a head the promotion does not contain'
pass 'a divergence of merge commits alone is explained, never self-contradicted'

# With no head ref to reconcile against, the record states the condition for
# closing rather than asserting an outcome it cannot know.
unknown_head=$(fm_proplane_promote_pr_body "$case_s/repo" origin/main integrate/prakrit-to-main passed '' passed)
assert_contains "$unknown_head" 'closes this PR as merged once' 'an unreconciled record states the condition'
assert_not_contains "$unknown_head" 'right after opening this PR, which closes' \
  'an unreconciled record never asserts the close unconditionally'
pass 'a record with no head ref to reconcile states the condition, not the outcome'

# --- (v) the reconciliation reads the head branch as GitHub has it -------------
#
# GitHub renders the PR from the REMOTE branch, and the record is opened long
# after this run's first fetch: the security review and the no-mistakes gates run
# in between. A sandbox that promotes into prakrit from another clone in that
# window never moves this repo's tracking ref, so answering from that ref would
# report a clean reconciliation and an unconditional close for a PR that will not
# close at all.

case_v="$TMP_ROOT/v"
mkdir -p "$case_v"
make_repo "$case_v/repo"
git -C "$case_v/repo" checkout -q -B integrate/prakrit-to-main origin/main
git -C "$case_v/repo" merge -q --no-edit origin/prakrit -m 'integrate(prakrit): test fixture'
git -C "$case_v/repo" checkout -q main
git clone -q "$case_v/repo.origin" "$case_v/other"
git -C "$case_v/other" checkout -q -b prakrit origin/prakrit
printf 'elsewhere\n' > "$case_v/other/elsewhere.txt"
git -C "$case_v/other" add elsewhere.txt
git -C "$case_v/other" commit -qm 'feat: promoted into prakrit from another clone'
git -C "$case_v/other" push -q origin prakrit
[ "$(git -C "$case_v/repo" rev-parse refs/remotes/origin/prakrit)" \
  != "$(git -C "$case_v/other" rev-parse HEAD)" ] ||
  fail 'the fixture must leave this repo tracking a stale prakrit'

fresh=$(fm_proplane_promote_pr_body "$case_v/repo" origin/main integrate/prakrit-to-main \
  passed '' passed origin/prakrit)
assert_contains "$fresh" 'promoted into prakrit from another clone' \
  'the reconciliation reads prakrit as GitHub has it, not the stale tracking ref'
assert_contains "$fresh" 'does NOT close as merged' \
  'a record read from a stale ref must not claim a close it will not get'
pass 'the reconciliation refetches the head branch instead of trusting a stale ref'

# --- (w) a head branch that cannot be read is recorded as unavailable ----------
#
# Falling back to the stale ref would answer with a number that might be wrong,
# which is the failure this refetch exists to prevent.

case_w="$TMP_ROOT/w"
mkdir -p "$case_w"
make_repo "$case_w/repo"
git -C "$case_w/repo" checkout -q -B integrate/prakrit-to-main origin/main
git -C "$case_w/repo" merge -q --no-edit origin/prakrit -m 'integrate(prakrit): test fixture'
git -C "$case_w/repo" checkout -q main
git -C "$case_w/repo" remote set-url origin "file://$case_w/no-such-origin"
set +e
unavailable=$(fm_proplane_promote_pr_body "$case_w/repo" origin/main integrate/prakrit-to-main \
  passed '' passed origin/prakrit 2>/dev/null)
rc=$?
set -e
expect_code 0 "$rc" 'an unreadable head branch must not fail the record'
assert_contains "$unavailable" 'could not be read from' 'the record says the head branch could not be read'
assert_contains "$unavailable" 'still states exactly what lands' 'the promoted range stays authoritative'
assert_not_contains "$unavailable" 'Promoted but NOT on' 'no reconciliation is answered from a stale ref'
assert_contains "$unavailable" 'closes this PR as merged once' 'the close is stated as a condition'
assert_not_contains "$unavailable" 'which closes this PR as merged' 'no close is asserted without a readable head'
pass 'a head branch that cannot be refetched is recorded as unavailable, never guessed'

[ "$(fm_proplane_promote_pr_range_count "$case_a/repo" origin/main origin/prakrit)" = 1 ] ||
  fail 'range count should be 1'
[ "$(fm_proplane_promote_pr_range_count "$case_a/repo" origin/main origin/main)" = 0 ] ||
  fail 'empty range count should be 0'
[ "$(fm_proplane_promote_pr_range_count "$case_a/repo" origin/main refs/heads/no-such-branch)" = 0 ] ||
  fail 'unreadable range count should be 0, not empty'
pass 'promotion PR range count is 0 for an empty or unreadable range'

# --- (b) no open PR -> create ------------------------------------------------

case_b="$TMP_ROOT/b"
mkdir -p "$case_b"
make_repo "$case_b/repo"
make_gh_axi "$case_b/fakebin" none
printf 'body\n' > "$case_b/body.md"
export FM_TEST_GH_AXI_LOG="$case_b/gh.log"
: > "$FM_TEST_GH_AXI_LOG"
out=$(PATH="$case_b/fakebin:$PATH" bash -c '
  . "$1"
  fm_proplane_promote_pr_sync "$2" main prakrit "promote(ladder): prakrit -> main (aaa..bbb)" "$3" 0
' _ "$PR_LIB" "$case_b/repo" "$case_b/body.md" 2>&1) || fail "sync should succeed: $out"
log=$(cat "$FM_TEST_GH_AXI_LOG")
assert_contains "$log" 'pr list --state open --base main --head prakrit' 'looks for an existing PR first'
assert_contains "$log" 'pr create --base main --head prakrit' 'creates the PR for prakrit into main'
assert_contains "$log" "--body-file $case_b/body.md" 'creates the PR with the generated body'
assert_not_contains "$log" 'pr edit' 'does not edit when no PR is open'
assert_contains "$out" 'https://github.com/PrakritR/PropLane/pull/91' 'reports the full PR URL'
pass 'promotion PR is created when none is open for prakrit into main'

# --- (c) an open PR -> edit, never a duplicate -------------------------------

case_c="$TMP_ROOT/c"
mkdir -p "$case_c"
make_repo "$case_c/repo"
make_gh_axi "$case_c/fakebin" existing
printf 'body\n' > "$case_c/body.md"
export FM_TEST_GH_AXI_LOG="$case_c/gh.log"
: > "$FM_TEST_GH_AXI_LOG"
out=$(PATH="$case_c/fakebin:$PATH" bash -c '
  . "$1"
  fm_proplane_promote_pr_sync "$2" main prakrit "promote(ladder): prakrit -> main (ccc..ddd)" "$3" 0
' _ "$PR_LIB" "$case_c/repo" "$case_c/body.md" 2>&1) || fail "sync should succeed: $out"
log=$(cat "$FM_TEST_GH_AXI_LOG")
assert_contains "$log" 'pr edit 77 --title' 'updates the open promotion record'
assert_contains "$log" "--body-file $case_c/body.md" 'refreshes the body of the open record'
assert_not_contains "$log" 'pr create' 'never opens a duplicate promotion record'
assert_contains "$out" '#77' 'names the reused PR'
pass 'a re-run updates the open promotion record instead of duplicating it'

# --- (d) gh-axi failure -> non-zero, reason on stderr ------------------------

for mode in create-fails list-fails; do
  case_d="$TMP_ROOT/d-$mode"
  mkdir -p "$case_d"
  make_repo "$case_d/repo"
  make_gh_axi "$case_d/fakebin" "$mode"
  printf 'body\n' > "$case_d/body.md"
  export FM_TEST_GH_AXI_LOG="$case_d/gh.log"
  : > "$FM_TEST_GH_AXI_LOG"
  set +e
  out=$(PATH="$case_d/fakebin:$PATH" bash -c '
    . "$1"
    fm_proplane_promote_pr_sync "$2" main prakrit "t" "$3" 0
  ' _ "$PR_LIB" "$case_d/repo" "$case_d/body.md" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "sync should report failure for $mode"
  assert_contains "$out" 'proplane-promote-pr:' "explains the $mode failure"
done
pass 'a GitHub failure is reported as a failure the caller can warn on'

# gh-axi missing entirely is the same shape: reported, not fatal on its own.
case_d_missing="$TMP_ROOT/d-missing"
mkdir -p "$case_d_missing/emptybin"
make_repo "$case_d_missing/repo"
printf 'body\n' > "$case_d_missing/body.md"
# A PATH with the system tools but no gh-axi (the real one lives elsewhere, e.g.
# /opt/homebrew/bin), so the absent-tool branch is the one under test.
set +e
out=$(PATH="$case_d_missing/emptybin:/usr/bin:/bin" /bin/bash -c '
  . "$1"
  fm_proplane_promote_pr_sync "$2" main prakrit "t" "$3" 0
' _ "$PR_LIB" "$case_d_missing/repo" "$case_d_missing/body.md" 2>&1)
rc=$?
set -e
expect_code 1 "$rc" 'sync should report failure when gh-axi is absent'
assert_contains "$out" 'gh-axi unavailable' 'names the missing tool'
pass 'a missing gh-axi is reported rather than silently skipped'

# --- (e) dry run prints the PR and calls nothing ------------------------------

case_e="$TMP_ROOT/e"
mkdir -p "$case_e"
make_repo "$case_e/repo"
make_gh_axi "$case_e/fakebin" none
printf 'BODY-MARKER\n' > "$case_e/body.md"
export FM_TEST_GH_AXI_LOG="$case_e/gh.log"
: > "$FM_TEST_GH_AXI_LOG"
out=$(PATH="$case_e/fakebin:$PATH" bash -c '
  . "$1"
  fm_proplane_promote_pr_sync "$2" main prakrit "promote(ladder): prakrit -> main (eee..fff)" "$3" 1
' _ "$PR_LIB" "$case_e/repo" "$case_e/body.md" 2>&1) || fail "dry run should succeed: $out"
assert_contains "$out" 'DRY gh-axi pr create --base main --head prakrit' 'dry run prints the PR it would open'
assert_contains "$out" 'BODY-MARKER' 'dry run prints the PR body'
[ ! -s "$FM_TEST_GH_AXI_LOG" ] || fail 'dry run must not call gh-axi'
pass 'dry run prints the promotion PR and opens none'

# --- (k) every GitHub call is bounded, and a timed-out one only warns ---------
#
# The record is opened between the passing gates and the fast-forward, so an
# unbounded hang there strands a promotion that has already earned its push.

# make_timeout <fakebin> <mode>: a `timeout` stub recording the bound it was
# given. Modes: pass (run the wrapped command), expire (exit 124 like a real
# timeout that fired).
make_timeout() {
  local fakebin=$1 mode=$2
  cat > "$fakebin/timeout" <<SH
#!/usr/bin/env bash
printf 'timeout-wrapper:%s\n' "\$1" >> "\$FM_TEST_GH_AXI_LOG"
[ "$mode" = expire ] && exit 124
shift
exec "\$@"
SH
  chmod +x "$fakebin/timeout"
}

case_k="$TMP_ROOT/k"
mkdir -p "$case_k"
make_repo "$case_k/repo"
make_gh_axi "$case_k/fakebin" none
make_timeout "$case_k/fakebin" pass
printf 'body\n' > "$case_k/body.md"
export FM_TEST_GH_AXI_LOG="$case_k/gh.log"
: > "$FM_TEST_GH_AXI_LOG"
out=$(PATH="$case_k/fakebin:$PATH" FM_PROPLANE_PR_GH_TIMEOUT=17 bash -c '
  . "$1"
  fm_proplane_promote_pr_sync "$2" main prakrit "promote(ladder): prakrit -> main (kkk..lll)" "$3" 0
' _ "$PR_LIB" "$case_k/repo" "$case_k/body.md" 2>&1) || fail "bounded sync should succeed: $out"
log=$(cat "$FM_TEST_GH_AXI_LOG")
assert_contains "$log" 'timeout-wrapper:17' 'the GitHub call runs under the configured bound'
[ "$(grep -c '^timeout-wrapper:' "$FM_TEST_GH_AXI_LOG")" = 2 ] ||
  fail 'both the list and the create call must be bounded'
assert_contains "$log" 'pr create --base main --head prakrit' 'the bounded call still opens the record'
pass 'every GitHub call in the promotion record path is bounded'

# A bound that fires is a failure like any other: reported, never fatal here.
case_k2="$TMP_ROOT/k-expired"
mkdir -p "$case_k2"
make_repo "$case_k2/repo"
make_gh_axi "$case_k2/fakebin" none
make_timeout "$case_k2/fakebin" expire
printf 'body\n' > "$case_k2/body.md"
export FM_TEST_GH_AXI_LOG="$case_k2/gh.log"
: > "$FM_TEST_GH_AXI_LOG"
set +e
out=$(PATH="$case_k2/fakebin:$PATH" bash -c '
  . "$1"
  fm_proplane_promote_pr_sync "$2" main prakrit "t" "$3" 0
' _ "$PR_LIB" "$case_k2/repo" "$case_k2/body.md" 2>&1)
rc=$?
set -e
expect_code 1 "$rc" 'a timed-out GitHub call should report failure'
assert_contains "$out" 'could not list open PRs' 'the timed-out call is named'
assert_no_grep 'pr create' "$FM_TEST_GH_AXI_LOG" 'a timed-out listing must not fall through to a create'
pass 'a timed-out GitHub call is reported as a failure the caller can warn on'

# --- (l) an open PR that is not a promotion record is never rewritten ---------
#
# Reuse rests on gh-axi honoring --base/--head. If that ever stops holding, the
# tool must open its own record rather than overwrite somebody else's PR.

case_l="$TMP_ROOT/l"
mkdir -p "$case_l"
make_repo "$case_l/repo"
make_gh_axi "$case_l/fakebin" foreign
printf 'body\n' > "$case_l/body.md"
export FM_TEST_GH_AXI_LOG="$case_l/gh.log"
: > "$FM_TEST_GH_AXI_LOG"
out=$(PATH="$case_l/fakebin:$PATH" bash -c '
  . "$1"
  fm_proplane_promote_pr_sync "$2" main prakrit "promote(ladder): prakrit -> main (lll..mmm)" "$3" 0
' _ "$PR_LIB" "$case_l/repo" "$case_l/body.md" 2>&1) || fail "sync should succeed: $out"
log=$(cat "$FM_TEST_GH_AXI_LOG")
assert_not_contains "$log" 'pr edit' 'a PR that is not a promotion record is never rewritten'
assert_contains "$log" 'pr create --base main --head prakrit' 'a fresh record is opened instead'
assert_contains "$out" 'rather than rewriting an unrelated PR' 'the skipped reuse is explained'
pass 'reuse is refused for an open PR that is not a promotion record'

# The scan only works if the listing is wide enough to hold more than the first
# row. With a one-row listing the record hides behind any unrelated open PR for
# the same pair, and the create that follows is rejected as a duplicate.
case_l2="$TMP_ROOT/l-buried"
mkdir -p "$case_l2"
make_repo "$case_l2/repo"
make_gh_axi "$case_l2/fakebin" buried
printf 'body\n' > "$case_l2/body.md"
export FM_TEST_GH_AXI_LOG="$case_l2/gh.log"
: > "$FM_TEST_GH_AXI_LOG"
out=$(PATH="$case_l2/fakebin:$PATH" bash -c '
  . "$1"
  fm_proplane_promote_pr_sync "$2" main prakrit "promote(ladder): prakrit -> main (nnn..ooo)" "$3" 0
' _ "$PR_LIB" "$case_l2/repo" "$case_l2/body.md" 2>&1) || fail "sync should succeed: $out"
log=$(cat "$FM_TEST_GH_AXI_LOG")
assert_contains "$log" 'pr edit 77 --title' 'the record is found behind an unrelated open PR'
assert_not_contains "$log" 'pr create' 'a found record is never duplicated'
assert_not_contains "$out" 'rather than rewriting an unrelated PR' 'a found record is not reported as missing'
pass 'the reuse scan reads past the first row to find the promotion record'

# --- end-to-end promotion fixtures -------------------------------------------

# make_promotion_case <name> <gh-axi mode>: a full FM_HOME + git root wired so
# fm-proplane-promote-prakrit-to-main.sh can run with the expensive gates
# skipped. The config carries no prakrit row on purpose: that leaves the
# post-push sandbox realignment out of scope for these tests, which are about
# the PR and the fast-forward.
#
# A third argument adds a prakrit integration row, which is what makes the
# post-push sync run at all; without one it returns before doing anything.
make_promotion_case() {
  local name=$1 mode=$2 prakrit_worktree=${3:-} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/config" "$case_dir/fakebin"
  make_repo "$case_dir/repo"
  printf 'GIT_ROOT\t%s\n' "$case_dir/repo" > "$case_dir/home/config/proplane-agent-branches"
  printf 'cursor-2\t%s\t3011\n' "$case_dir/sandbox" >> "$case_dir/home/config/proplane-agent-branches"
  [ -n "$prakrit_worktree" ] &&
    printf 'prakrit\t%s\t3000\n' "$prakrit_worktree" >> "$case_dir/home/config/proplane-agent-branches"
  # The integrate branch is what a real promotion run leaves behind: main with
  # prakrit merged in, so main can fast-forward onto it.
  git -C "$case_dir/repo" checkout -q -B integrate/prakrit-to-main origin/main
  git -C "$case_dir/repo" merge -q --no-edit origin/prakrit -m 'integrate(prakrit): test fixture'
  make_gh_axi "$case_dir/fakebin" "$mode"
  fm_fake_exit0 "$case_dir/fakebin" no-mistakes
  printf '%s\n' "$case_dir"
}

run_promotion() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" PATH="$case_dir/fakebin:$PATH" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh.log" FM_TEST_ORIGIN="$case_dir/repo.origin" \
    FM_TEST_GH_AXI_BODY="$case_dir/pr-body.md" \
    "$PROMOTE_MAIN" "$@" 2>&1
}

origin_sha() {
  git -C "$1/repo" rev-parse "refs/remotes/origin/$2"
}

# --- (f) the record is opened, then main fast-forwards ------------------------

case_f=$(make_promotion_case f none)
: > "$case_f/gh.log"
prakrit_sha=$(origin_sha "$case_f" prakrit)
main_sha_before=$(origin_sha "$case_f" main)
set +e
out=$(run_promotion "$case_f" --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 0 "$rc" 'promotion with the record PR should succeed'
log=$(cat "$case_f/gh.log")
assert_contains "$log" 'pr create --base main --head prakrit' 'the promotion opens the record PR'
assert_contains "$out" 'promotion record PR' 'the promotion announces the record'
assert_contains "$out" 'SKIPPED' 'skipped gates are announced'
[ "$(origin_sha "$case_f" main)" = "$prakrit_sha" ] || fail 'origin/main should be fast-forwarded to prakrit'
pass 'a promotion opens the record PR and then fast-forwards main'

# The PR must be opened before the fast-forward, since the fast-forward is what
# closes it as merged. A PR created after the push would open against a base
# that already contained the range, and would never close.
[ "$main_sha_before" != "$prakrit_sha" ] || fail 'fixture must have main behind prakrit'
assert_grep "origin-main-at-create:$main_sha_before" "$case_f/gh.log" \
  'the record PR must be opened while origin/main is still behind prakrit'
pass 'the record PR is opened ahead of the fast-forward that closes it'

# The record describes the integrate branch this promotion was built on, not a
# fresh read of prakrit. A commit another agent pushes to prakrit after the
# integrate branch was cut is NOT delivered by this promotion, so listing it
# would make the record claim commits main never received.
case_r=$(make_promotion_case r none)
: > "$case_r/gh.log"
git -C "$case_r/repo" checkout -q prakrit
printf 'later\n' > "$case_r/repo/later.txt"
git -C "$case_r/repo" add later.txt
git -C "$case_r/repo" commit -qm 'feat: pushed to prakrit after the integrate branch was cut'
git -C "$case_r/repo" push -q origin prakrit
git -C "$case_r/repo" checkout -q main
integrate_sha=$(git -C "$case_r/repo" rev-parse integrate/prakrit-to-main)
set +e
out=$(run_promotion "$case_r" --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 0 "$rc" 'the promotion should succeed'
recorded=$(cat "$case_r/pr-body.md")
# Everything above the reconciliation section is what the record promotes; the
# section below it is what GitHub's diff disagrees about.
promoted=$(printf '%s\n' "$recorded" | awk '/^## Record versus/ { exit } { print }')
assert_contains "$promoted" 'feat: promoted change' 'the record lists the commits this promotion delivers'
assert_not_contains "$promoted" 'after the integrate branch was cut' \
  'the record must not promote a commit this promotion does not push'
assert_contains "$recorded" 'but NOT promoted, so this PR' \
  'a commit the PR diff shows but the promotion never delivers is called out as unlanded'
assert_contains "$recorded" '- commits: 1' 'the recorded count matches what is fast-forwarded'
[ "$(origin_sha "$case_r" main)" = "$integrate_sha" ] || fail 'main should land the integrate tip'
pass 'the record describes the refs the promotion was built on, not a fresh read of prakrit'

# --- (g) a failing PR call warns but never strands the promotion --------------

case_g=$(make_promotion_case g create-fails)
: > "$case_g/gh.log"
prakrit_sha=$(origin_sha "$case_g" prakrit)
set +e
out=$(run_promotion "$case_g" --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 0 "$rc" 'a failed PR call must not fail the promotion'
assert_contains "$out" 'WARNING' 'the lost record is warned about'
assert_contains "$out" 'rate limit exceeded' 'the underlying GitHub error is shown'
[ "$(origin_sha "$case_g" main)" = "$prakrit_sha" ] || fail 'origin/main must still be fast-forwarded'
pass 'a promotion whose record PR fails still lands main, with a warning'

# --- (m) a failed fast-forward annotates the record it already opened ---------
#
# The record states that the ladder fast-forwards main right after opening it.
# If that push never lands, an unannotated record permanently asserts a
# promotion that did not happen.

# advance_origin_main <case_dir>: put a commit on origin/main that the integrate
# branch does not carry, so the promotion's push is rejected.
advance_origin_main() {
  local repo="$1/repo"
  git -C "$repo" checkout -q -B other-main origin/main
  printf 'hotfix\n' > "$repo/hotfix.txt"
  git -C "$repo" add hotfix.txt
  git -C "$repo" commit -qm 'fix: landed on main behind our back'
  git -C "$repo" push -q origin other-main:main
  git -C "$repo" checkout -q main
}

case_m=$(make_promotion_case m none)
: > "$case_m/gh.log"
advance_origin_main "$case_m"
main_sha_before=$(origin_sha "$case_m" main)
set +e
out=$(run_promotion "$case_m" --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 1 "$rc" 'a failed fast-forward must still fail the promotion'
log=$(cat "$case_m/gh.log")
assert_contains "$log" 'pr create --base main --head prakrit' 'the record was opened before the push failed'
assert_contains "$log" 'pr comment 91' 'the opened record is annotated when the push does not land'
assert_contains "$log" 'did NOT complete' 'the annotation says the fast-forward did not complete'
[ "$(origin_sha "$case_m" main)" = "$main_sha_before" ] || fail 'a rejected push must not move origin/main'
pass 'a fast-forward that fails annotates the record so it claims nothing that did not land'

# The annotation is best-effort: failing to post it must not change the exit code
# of the push that actually failed, and must not go unmentioned either.
case_n=$(make_promotion_case n comment-fails)
: > "$case_n/gh.log"
advance_origin_main "$case_n"
set +e
out=$(run_promotion "$case_n" --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 1 "$rc" 'a failed annotation must not mask the failed push exit'
assert_contains "$out" 'WARNING could not annotate' 'the unannotated record is warned about'
pass 'an annotation that cannot be posted warns without changing the promotion outcome'

# A record whose number could not be read is not the same as no record at all.
# Falling silent there leaves a record permanently claiming a promotion that
# never landed, with nothing on stderr for an operator to act on.
case_o=$(make_promotion_case o create-silent)
: > "$case_o/gh.log"
advance_origin_main "$case_o"
set +e
out=$(run_promotion "$case_o" --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 1 "$rc" 'a failed fast-forward should still fail the promotion'
assert_contains "$out" 'number could not be read' 'an unannotatable record is called out'
assert_contains "$out" 'by hand' 'the operator is told to correct it themselves'
assert_no_grep 'pr comment' "$case_o/gh.log" 'no annotation can be posted without a number'
pass 'a record opened without a readable number is warned about, never left silent'

# --- (p) a failure after main lands must not annotate the record --------------
#
# Everything after the push is realignment. It can fail on its own, and the
# promotion record is accurate either way: annotating it there would tell a later
# reader that a promotion which did go live never happened.

case_p=$(make_promotion_case p none "$TMP_ROOT/p/no-such-prakrit-worktree")
: > "$case_p/gh.log"
prakrit_sha=$(origin_sha "$case_p" prakrit)
set +e
out=$(run_promotion "$case_p" --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 1 "$rc" 'a failed post-push sync should still fail the promotion'
log=$(cat "$case_p/gh.log")
assert_contains "$log" 'pr create --base main --head prakrit' 'the record was opened'
assert_contains "$out" 'pushed origin/main' 'the promotion did land main'
[ "$(origin_sha "$case_p" main)" = "$prakrit_sha" ] || fail 'origin/main must have been fast-forwarded'
assert_not_contains "$log" 'pr comment' 'a record for a landed promotion is never annotated as failed'
assert_not_contains "$out" 'could not be read' 'no unannotatable-record warning when nothing needed annotating'
pass 'a failure after main lands leaves the accurate promotion record alone'

# --- (h) dry run opens nothing and pushes nothing -----------------------------

case_h=$(make_promotion_case h none)
: > "$case_h/gh.log"
main_sha_before=$(origin_sha "$case_h" main)
set +e
out=$(run_promotion "$case_h" --dry-run --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 0 "$rc" 'dry run should succeed'
assert_contains "$out" 'DRY gh-axi pr create --base main --head prakrit' 'dry run prints the PR it would open'
# The recorded range is the integrate branch this promotion was built on, never a
# fresh read of prakrit, which may have moved since.
assert_contains "$out" 'origin/main..integrate/prakrit-to-main' 'dry run prints the promoted range'
[ ! -s "$case_h/gh.log" ] || fail 'dry run must not call gh-axi'
[ "$(origin_sha "$case_h" main)" = "$main_sha_before" ] || fail 'dry run must not move origin/main'
pass 'a dry-run promotion prints the record PR and opens none'

# --- (t) a plain --dry-run runs no gate and still previews the record ----------
#
# Printing what a promotion would do is the whole job of the flag. The security
# review spends real model quota and writes a report under $FM_HOME/state, so a
# dry run that fires it is not dry; and a dry run that stops at the push gate
# before the preview never does the one thing it exists for.

case_t=$(make_promotion_case t none)
: > "$case_t/gh.log"
main_sha_before=$(origin_sha "$case_t" main)
set +e
out=$(run_promotion "$case_t" --dry-run)
rc=$?
set -e
expect_code 0 "$rc" 'a plain dry run should succeed'
assert_contains "$out" 'fm-proplane-security-review.sh' 'the dry run names the review it would run'
assert_not_contains "$out" 'proplane-security-review:' 'the dry run must not run the real security review'
assert_absent "$case_t/home/state" 'a dry run must not write a security review report'
assert_contains "$out" 'DRY gh-axi pr create --base main --head prakrit' 'the dry run previews the record PR'
assert_contains "$out" 'origin/main..integrate/prakrit-to-main' 'the dry run prints the promoted range'
assert_contains "$out" 'NOT RUN' 'the previewed record says the gates did not run'
[ ! -s "$case_t/gh.log" ] || fail 'a plain dry run must not call gh-axi'
[ "$(origin_sha "$case_t" main)" = "$main_sha_before" ] || fail 'a plain dry run must not move origin/main'
pass 'a plain --dry-run runs no security review and still previews the promotion record'

# A dry run has not built the integrate branch this run would promote, so it must
# say what it does not know rather than reporting a leftover branch as the record.
# It does know the tip of the ref it read, though, so it names that instead of
# claiming ignorance directly beneath a range it printed from that same ref.
assert_contains "$out" 'This is a preview, not a record' 'the dry run marks its output as a preview'
assert_contains "$out" "integrate/prakrit-to-main\` is at" 'the preview names the tip of the ref it read'
assert_contains "$out" "$(git -C "$case_t/repo" rev-parse integrate/prakrit-to-main)" \
  'the preview names the sha it actually has'
assert_contains "$out" 'as that branch stands when it runs' \
  'the preview says the recorded tip comes from the real run, not from this read'
assert_not_contains "$out" 'main` is fast-forwarded to' 'the preview claims no fast-forward target'
assert_not_contains "$out" 'which closes this PR as merged' 'the preview asserts no close it cannot know'
assert_not_contains "$out" 'the same non-merge commits as the promoted range' \
  'the preview claims no alignment it cannot know'
pass 'a dry-run record is presented as a preview, not as facts about the promotion'

# The preview reconciles nothing, so it needs no network: an unreachable origin
# cannot change what it prints, which is what keeps a dry run inert.
git -C "$case_t/repo" remote set-url origin "file://$case_t/no-such-origin"
set +e
offline=$(run_promotion "$case_t" --dry-run)
rc=$?
set -e
expect_code 0 "$rc" 'a dry run must not need the network'
assert_contains "$offline" 'This is a preview, not a record' 'the offline dry run still previews the record'
assert_not_contains "$offline" 'could not refresh' 'a dry run never tries to refresh the head branch'
pass 'a dry run previews the record without touching the network'

# A dry run before any integrate branch exists is the common case (nothing has
# been promoted yet), and it must preview cleanly rather than die resolving a ref
# that a real run would have created.
case_t2=$(make_promotion_case t-no-integrate none)
: > "$case_t2/gh.log"
git -C "$case_t2/repo" checkout -q main
git -C "$case_t2/repo" branch -q -D integrate/prakrit-to-main
set +e
out=$(run_promotion "$case_t2" --dry-run)
rc=$?
set -e
expect_code 0 "$rc" 'a dry run with no integrate branch should succeed'
assert_contains "$out" 'DRY gh-axi pr create --base main --head prakrit' 'it still previews the record PR'
assert_contains "$out" 'origin/main..origin/prakrit' 'it previews the range a real promotion would carry'
[ ! -s "$case_t2/gh.log" ] || fail 'a dry run must not call gh-axi'
pass 'a dry run with no integrate branch previews cleanly instead of dying on a missing ref'

# --- nothing to promote -------------------------------------------------------

case_i=$(make_promotion_case i none)
: > "$case_i/gh.log"
git -C "$case_i/repo" push -q origin origin/prakrit:main
git -C "$case_i/repo" fetch -q origin
set +e
out=$(run_promotion "$case_i" --validate-only --push-main --skip-gates)
rc=$?
set -e
expect_code 0 "$rc" 'a no-op promotion should succeed'
assert_contains "$out" 'no promotion record needed' 'an empty range opens no PR'
[ ! -s "$case_i/gh.log" ] || fail 'an empty range must not call gh-axi'
pass 'an empty promotion range opens no record PR'

# --- the full ladder's dry run previews the same record -----------------------

case_j=$(make_promotion_case j none)
: > "$case_j/gh.log"
git -C "$case_j/repo" worktree add -q -b cursor-2 "$case_j/sandbox" origin/prakrit
main_sha_before=$(origin_sha "$case_j" main)
set +e
out=$(FM_HOME="$case_j/home" PATH="$case_j/fakebin:$PATH" FM_TEST_GH_AXI_LOG="$case_j/gh.log" \
  "$ROOT/bin/fm-proplane-promote-full.sh" cursor-2 --dry-run 2>&1)
rc=$?
set -e
expect_code 0 "$rc" 'the full ladder dry run should succeed'
assert_contains "$out" 'DRY gh-axi pr create --base main --head prakrit' 'the ladder dry run previews the record PR'
assert_contains "$out" 'origin/main..origin/prakrit' 'the ladder dry run shows the range'
[ ! -s "$case_j/gh.log" ] || fail 'the ladder dry run must not call gh-axi'
[ "$(origin_sha "$case_j" main)" = "$main_sha_before" ] || fail 'the ladder dry run must not move origin/main'
pass 'the full ladder dry run previews the promotion record PR without opening it'

# At preview time the integrate branch does not exist, so the ladder preview knows
# neither the tip main lands on nor how prakrit compares to it. Reporting
# origin/prakrit as both would print three sentences that are normally false: the
# real promotion lands an integrate tip carrying the integration merge and the
# validation's own commits.
assert_contains "$out" 'This is a preview, not a record' 'the ladder preview says it is a preview'
assert_not_contains "$out" 'main` is fast-forwarded to' 'the ladder preview claims no fast-forward target'
assert_contains "$out" 'as that branch stands when it runs' \
  'the ladder preview says the recorded tip comes from the real run'
assert_contains "$out" 'integrate/prakrit-to-main' 'the preview names where the real record comes from'
assert_contains "$out" 'no-mistakes validation itself makes' \
  'the preview says the real record can carry commits the validation adds'
assert_not_contains "$out" 'which closes this PR as merged' 'the preview asserts no close it cannot know'
assert_not_contains "$out" 'the same non-merge commits as the promoted range' \
  'the preview claims no alignment it cannot know'
pass 'the ladder dry run preview asserts no tip and no alignment it cannot know'

# --- (u) the reset guard refuses when it cannot read a worktree's state --------
#
# fm_proplane_assert_resettable is what stops this ladder from hard-resetting a
# sandbox that still holds unlanded work, and the promote flow consults it before
# staging the integrate tip. A `git status` that FAILS answers "unknown", not
# "clean": reading a stale .git pointer or a held index lock as an empty worktree
# would let the reset through exactly when the guard cannot see what it destroys.

BRANCH_LIB="$ROOT/bin/fm-proplane-agent-branches-lib.sh"
case_u="$TMP_ROOT/u"
mkdir -p "$case_u/home/config"
fm_git_init_commit "$case_u/clean"
cp -R "$case_u/clean" "$case_u/dirty"
printf 'unlanded\n' > "$case_u/dirty/unlanded.txt"
# A worktree whose .git pointer no longer resolves: `git status` fails, and its
# porcelain output is empty for a reason that has nothing to do with being clean.
mkdir -p "$case_u/unreadable"
printf 'gitdir: %s\n' "$case_u/no-such-gitdir" > "$case_u/unreadable/.git"

run_guard() {
  FM_HOME="$case_u/home" bash -c '
    . "$1"
    fm_proplane_assert_resettable "$2" guard-test "$3"
  ' _ "$BRANCH_LIB" "$1" "${2:-0}" 2>&1
}

set +e
out=$(run_guard "$case_u/clean")
rc=$?
set -e
expect_code 0 "$rc" 'a clean worktree stays resettable'

set +e
out=$(run_guard "$case_u/dirty")
rc=$?
set -e
expect_code 1 "$rc" 'a worktree with unlanded work must not be reset'
assert_contains "$out" 'REFUSING to reset' 'the refusal is explained'

set +e
out=$(run_guard "$case_u/unreadable")
rc=$?
set -e
expect_code 1 "$rc" 'a worktree whose state cannot be read must not be reset'
assert_contains "$out" 'REFUSING to reset' 'the unreadable worktree is refused, not assumed clean'
assert_contains "$out" 'could not be read' 'the refusal says the state was unreadable'
assert_contains "$out" 'git status failed' 'the underlying git error is shown, not an empty listing'

# --force is the captain's explicit authorization to discard, and this change
# only ever tightens the guard: it must still be honored where it was before.
set +e
out=$(run_guard "$case_u/dirty" 1)
rc=$?
set -e
expect_code 0 "$rc" '--force must still allow an authorized discard'
assert_contains "$out" 'discarding uncommitted work' 'the authorized discard is announced'
pass 'the reset guard fails closed when it cannot read a worktree state'

# --- the standing instructions match what the tooling now does ----------------
#
# The ladder skill used to forbid opening a PR at all. Leaving that rule in place
# would put the instructions the captain's agents read in direct conflict with a
# promotion that now opens one every time.

LADDER_SKILL="$ROOT/.agents/skills/proplane-ladder/SKILL.md"
PROMOTE_SKILL="$ROOT/.agents/skills/promote/SKILL.md"
assert_no_grep 'Never open a PR' "$LADDER_SKILL" \
  'the ladder skill must not still forbid the PR the promotion now opens'
assert_no_grep 'Do not open a PR unless the captain explicitly asks' "$PROMOTE_SKILL" \
  'the promote skill must not still forbid the PR the promotion now opens'
assert_grep 'promotion-record PR' "$LADDER_SKILL" 'the ladder skill states the promotion PR order'
assert_grep 'fm-proplane-promote-pr-lib.sh' "$LADDER_SKILL" 'the ladder skill names the contract owner'
assert_grep 'promotion record PR' "$PROMOTE_SKILL" 'the promote skill states the promotion PR'
pass 'the ladder and promote instructions match the promotion PR the tooling opens'

pass 'fm-proplane-promote-pr: all cases'
