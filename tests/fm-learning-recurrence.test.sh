#!/usr/bin/env bash
# Tests for bin/fm-learning-recurrence.sh and bin/fm-learning-recurrence-lib.sh.
#
# A promoted learning is not "learned" until its recurrence is measured
# rather than remembered (data/learnings.md). This suite proves the counter
# actually counts: a pre-rule introduction, a fix, and a post-rule
# recurrence in a fixture repo must be told apart, and a comment line that
# happens to contain the banned text must never be counted as a real
# occurrence (it is never emitted to a worker).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-learning-recurrence-lib.sh
. "$ROOT/bin/fm-learning-recurrence-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-learning-recurrence)

commit_at() {
  local repo=$1 date=$2 msg=$3
  GIT_AUTHOR_DATE="$date 12:00:00 +0000" GIT_COMMITTER_DATE="$date 12:00:00 +0000" \
    git -C "$repo" commit -q -m "$msg"
}

# Builds a fixture repo with a known history against the fixture path
# fixture/target.txt: a pre-rule introduction of the pattern, a fix that
# removes it, a post-rule recurrence in different wording, and a comment
# line that must never be counted.
build_fixture() {
  local repo=$1
  mkdir -p "$repo/fixture"
  git -C "$repo" init -q

  printf 'line one\nline two\n' > "$repo/fixture/target.txt"
  git -C "$repo" add fixture/target.txt
  commit_at "$repo" "2026-06-01" "baseline, no banned text"

  printf 'line one\nplease run /demo-pattern now\nline two\n' > "$repo/fixture/target.txt"
  git -C "$repo" add fixture/target.txt
  commit_at "$repo" "2026-06-15" "pre-rule introduction"

  printf 'line one\nline two\n' > "$repo/fixture/target.txt"
  git -C "$repo" add fixture/target.txt
  commit_at "$repo" "2026-06-20" "fix: remove banned text"

  printf 'line one\nline two\ninvoke /demo-pattern instead\n' > "$repo/fixture/target.txt"
  git -C "$repo" add fixture/target.txt
  commit_at "$repo" "2026-09-01" "post-rule recurrence, reworded"

  printf 'line one\nline two\ninvoke /demo-pattern instead\n# see /demo-pattern docs\n' > "$repo/fixture/target.txt"
  git -C "$repo" add fixture/target.txt
  commit_at "$repo" "2026-09-05" "comment mentioning the pattern, must not count"
}

# The lib function in isolation: proves the count is exactly the two real
# additions (pre-rule and post-rule), not the fix (a removal) and not the
# comment (excluded by construction, never emitted to a worker).
test_introductions_for_path_counts_additions_only() {
  local repo out lines
  repo="$TMP_ROOT/lib-fixture"
  build_fixture "$repo"
  out=$(introductions_for_path "$repo" fixture/target.txt '/demo-pattern')
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" -eq 2 ] || fail "expected 2 introduction commits, got $lines:"$'\n'"$out"
  assert_contains "$out" "2026-06-15" "pre-rule introduction date missing from output"
  assert_contains "$out" "2026-09-01" "post-rule recurrence date missing from output"
  assert_not_contains "$out" "2026-09-05" "comment-only commit was counted as a real occurrence"
  pass "fm-learning-recurrence-lib.sh: introductions_for_path counts additions only, excludes comments"
}

# The full CLI wrapper, against the real production rule id (no-mistakes-cli-not-skill)
# pointed at the fixture repo via FM_ROOT_OVERRIDE: proves the recorded-date
# split (introductions_total vs recurrences_since_recorded) that makes the
# rule's own recorded date meaningful, without depending on this repo's own
# live history (which would make the test's expected numbers drift over time).
test_recurrence_since_recorded_splits_on_rule_date() {
  local repo out
  repo="$TMP_ROOT/cli-fixture"
  mkdir -p "$repo/bin"
  build_fixture "$repo"
  # The registered rule guards bin/fm-brief.sh; give the fixture a file at
  # that exact relative path with the same fixture history.
  git -C "$repo" mv fixture/target.txt bin/fm-brief.sh
  commit_at "$repo" "2026-09-06" "relocate fixture to the guarded path"
  # The rule's own pattern is the literal string "/no-mistakes", not the
  # fixture's "/demo-pattern" placeholder, so give the relocated file one
  # real occurrence after the move: this exercises the actual production
  # pattern end to end, on top of the already-proven addition/comment logic.
  printf 'line one\nline two\ninvoke /demo-pattern instead\nrun /no-mistakes here\n' \
    > "$repo/bin/fm-brief.sh"
  git -C "$repo" add bin/fm-brief.sh
  commit_at "$repo" "2026-09-07" "add the real production pattern after the rule date"

  out=$(FM_ROOT_OVERRIDE="$repo" "$ROOT/bin/fm-learning-recurrence.sh" no-mistakes-cli-not-skill)
  assert_contains "$out" "rule=no-mistakes-cli-not-skill" "CLI output must name the resolved rule"
  assert_contains "$out" "introductions_total=1" \
    "expected exactly 1 introduction of the literal /no-mistakes pattern (got a different total)"
  assert_contains "$out" "recurrences_since_recorded=1" \
    "the 2026-09-07 introduction is after the rule's 2026-08-22 recorded date and must count as a recurrence"
  pass "fm-learning-recurrence.sh: CLI wrapper measures the real rule and splits on its recorded date"
}

# Regression test: a commit that rewrites a line the pattern already
# matches (e.g. a reformat) must not be counted as a fresh occurrence. The
# defect never went away in between, so this is the same unbroken breach
# continuing to exist, not "the same defect showing up again."
test_introductions_for_path_ignores_rewrite_of_still_present_pattern() {
  local repo out lines
  repo="$TMP_ROOT/rewrite-fixture"
  build_fixture "$repo"
  # Reformat the already-present "invoke /demo-pattern instead" line (add
  # trailing whitespace) without the pattern ever leaving the file in
  # between - git still emits a "-"/"+" pair for the touched line.
  printf 'line one\nline two\ninvoke /demo-pattern instead \n# see /demo-pattern docs\n' \
    > "$repo/fixture/target.txt"
  git -C "$repo" add fixture/target.txt
  commit_at "$repo" "2026-09-10" "reformat: trailing whitespace on an already-present line"

  out=$(introductions_for_path "$repo" fixture/target.txt '/demo-pattern')
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" -eq 2 ] || fail "expected the reformat commit not to inflate the count, got $lines:"$'\n'"$out"
  assert_not_contains "$out" "2026-09-10" "reformat of an already-present pattern was counted as a fresh introduction"
  pass "fm-learning-recurrence-lib.sh: rewriting an already-present pattern line does not inflate the recurrence count"
}

test_introductions_for_path_counts_additions_only
test_recurrence_since_recorded_splits_on_rule_date
test_introductions_for_path_ignores_rewrite_of_still_present_pattern
