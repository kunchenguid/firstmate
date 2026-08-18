#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh's agent-co-author guard: a local-only merge
# must be refused, without touching the default branch, when any commit being
# merged carries a "Co-authored-by:" trailer naming an AI agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# make_case <name>: a project repo on branch "main" with one commit, plus a
# task branch fm/task-x1 with one additional commit whose message is passed
# in. Meta records mode=local-only. Echoes the case dir.
make_case() {
  local name=$1 body=$2 case_dir proj
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  mkdir -p "$case_dir/state" "$proj"
  git -C "$proj" init -q -b main
  git -C "$proj" commit -q --allow-empty -m initial
  git -C "$proj" checkout -q -b fm/task-x1
  git -C "$proj" commit -q --allow-empty -m "$body"
  git -C "$proj" checkout -q main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

# (a) refuses and does not fast-forward when the task branch carries an agent
# co-author trailer.
case_dir=$(make_case agent-trailer "fix: add x

Co-authored-by: Claude Sonnet 5 <noreply@anthropic.com>")
before_head=$(git -C "$case_dir/project" rev-parse main)
task_head=$(git -C "$case_dir/project" rev-parse fm/task-x1)
[ "$before_head" != "$task_head" ] || fail "fm-merge-local: test setup did not actually diverge main from the task branch"
out=$(run_merge_local "$case_dir" 2>&1)
rc=$?
expect_code 1 "$rc" "fm-merge-local refuses a task branch with an agent co-author trailer"
assert_contains "$out" "agent co-author trailer" "fm-merge-local refuses a task branch with an agent co-author trailer"
main_head=$(git -C "$case_dir/project" rev-parse main)
[ "$main_head" = "$before_head" ] || fail "fm-merge-local: refused merge must not move main"
pass "fm-merge-local refuses a task branch with an agent co-author trailer"

# (b) a clean task branch with no offending trailer still merges normally.
case_dir=$(make_case clean "fix: add y")
out=$(run_merge_local "$case_dir" 2>&1)
rc=$?
expect_code 0 "$rc" "fm-merge-local merges a clean task branch: $out"
main_head=$(git -C "$case_dir/project" rev-parse main)
task_head=$(git -C "$case_dir/project" rev-parse fm/task-x1)
[ "$main_head" = "$task_head" ] || fail "fm-merge-local: clean merge did not fast-forward main to the task branch"
pass "fm-merge-local merges a clean task branch"
