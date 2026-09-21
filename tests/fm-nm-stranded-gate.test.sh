#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-stranded-gate.sh: recognizing a no-mistakes gate
# mirror ref stranded at a pre-rebase tip, refusing when that ref holds work the
# current head lacks, and never writing to the mirror.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-nm-stranded-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-stranded-gate)
fm_git_identity

# A fake gh on PATH so no test reaches the network. FAKE_GH_PRS holds the open-PR
# URLs `gh pr list` reports (default none); FAKE_GH_FAIL=1 makes the query fail.
# Every call is logged so tests can prove the helper only lists PRs.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
GH_LOG="$TMP_ROOT/gh.log"
export GH_LOG
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "${FAKE_GH_FAIL:-0}" = 1 ] && { echo 'HTTP 401: Bad credentials' >&2; exit 1; }
[ "$1 $2" = "pr list" ] || exit 1
[ -n "${FAKE_GH_PRS:-}" ] && printf '%s\n' "$FAKE_GH_PRS"
exit 0
SH
chmod +x "$FAKEBIN/gh"
PATH="$FAKEBIN:$PATH"

# world <name>: a repo with main advanced past the task branch's base, a bare
# gate mirror registered as the `no-mistakes` remote, and branch `task` holding
# commit A pushed to the mirror. Leaves the repo checked out on `task` at A.
world() {
  local dir="$TMP_ROOT/$1"
  fm_git_init_commit "$dir/repo" >/dev/null
  git -C "$dir/repo" switch -q -c task
  echo a > "$dir/repo/a.txt"
  git -C "$dir/repo" add a.txt
  git -C "$dir/repo" commit -qm 'task: A'
  git init -q --bare "$dir/mirror.git"
  git -C "$dir/repo" remote add no-mistakes "$dir/mirror.git"
  git -C "$dir/repo" push -q no-mistakes task
  git -C "$dir/repo" switch -q main
  echo m > "$dir/repo/m.txt"
  git -C "$dir/repo" add m.txt
  git -C "$dir/repo" commit -qm 'main: advance'
  git -C "$dir/repo" switch -q task
  printf '%s\n' "$dir"
}

# rebase_task <dir>: custody recovery's effect - task rebased onto main.
rebase_task() {
  git -C "$1/repo" rebase -q main task
}

# Mirror bytes plus refs, to prove the script never writes there.
mirror_fingerprint() {
  (cd "$1/mirror.git" && find . -type f -exec cksum {} + | sort)
}

run() {
  OUT=$("$SCRIPT" "$@" 2>&1)
  RC=$?
}

test_refuses_when_mirror_ref_holds_commit_head_lacks() {
  local dir before sha
  dir=$(world refuse)
  # A killed fix round left a pipeline fix commit on the mirror ref only.
  git -C "$dir/repo" switch -q -c fixround task
  echo fix > "$dir/repo/fix.txt"
  git -C "$dir/repo" add fix.txt
  git -C "$dir/repo" commit -qm 'pipeline: fix'
  sha=$(git -C "$dir/repo" rev-parse HEAD)
  git -C "$dir/repo" push -q no-mistakes fixround:task
  git -C "$dir/repo" switch -q task
  git -C "$dir/repo" branch -q -D fixround
  rebase_task "$dir"
  before=$(mirror_fingerprint "$dir")
  run "$dir/repo"
  [ "$RC" = 1 ] || fail "unlanded mirror commit must refuse with exit 1, got $RC: $OUT"
  assert_contains "$OUT" "state: refused" "refusal state"
  assert_contains "$OUT" "unlanded: $sha pipeline: fix" "refusal names the unlanded commit"
  assert_not_contains "$OUT" "fresh_branch:" "refusal must not recommend a fresh branch"
  assert_not_contains "$OUT" "git switch -c" "refusal must not print the fresh-branch command"
  [ "$(mirror_fingerprint "$dir")" = "$before" ] || fail "refusal wrote to the mirror"
  pass "refuses a fresh branch when the stranded ref holds a commit HEAD lacks"
}

test_refuses_when_mirror_ref_holds_merge_commit() {
  local dir
  dir=$(world merge)
  # A merge has no patch identity, so it can never be proven present in HEAD.
  git -C "$dir/repo" switch -q -c side main~1
  echo s > "$dir/repo/s.txt"
  git -C "$dir/repo" add s.txt
  git -C "$dir/repo" commit -qm 'side'
  git -C "$dir/repo" switch -q -c merged task
  git -C "$dir/repo" merge -q --no-edit side
  git -C "$dir/repo" push -q no-mistakes merged:task
  git -C "$dir/repo" switch -q task
  rebase_task "$dir"
  run "$dir/repo"
  [ "$RC" = 1 ] || fail "a stranded merge commit must refuse, got $RC: $OUT"
  assert_not_contains "$OUT" "fresh_branch:" "merge refusal must not recommend a fresh branch"
  pass "refuses when the stranded ref holds a merge commit"
}

test_recommends_fresh_branch_when_equivalent() {
  local dir before
  dir=$(world safe)
  rebase_task "$dir"
  before=$(mirror_fingerprint "$dir")
  # The real symptom: the mirror refuses the rewritten history.
  git -C "$dir/repo" push -q no-mistakes task 2>/dev/null \
    && fail "fixture must reproduce the non-fast-forward rejection"
  run "$dir/repo"
  [ "$RC" = 0 ] || fail "patch-equivalent stranded ref must exit 0, got $RC: $OUT"
  assert_contains "$OUT" "state: stranded" "stranded state"
  assert_contains "$OUT" "fresh_branch: task-r2" "fresh branch name"
  assert_contains "$OUT" "next: git switch -c task-r2" "fresh-branch command"
  [ "$(mirror_fingerprint "$dir")" = "$before" ] || fail "check wrote to the mirror"
  [ "$(git -C "$dir/repo" symbolic-ref --short HEAD)" = task ] \
    || fail "the check must not switch branches itself"
  git -C "$dir/repo" show-ref --verify --quiet refs/heads/task-r2 \
    && fail "the check must not create the fresh branch"
  # The printed remedy works: the mirror accepts the fresh name.
  git -C "$dir/repo" switch -q -c task-r2
  git -C "$dir/repo" push -q no-mistakes task-r2 \
    || fail "mirror must accept the fresh branch as a new ref"
  pass "recommends a fresh branch when every stranded commit is in HEAD"
}

test_fresh_name_skips_taken_and_increments_suffix() {
  local dir
  dir=$(world names)
  git -C "$dir/repo" branch -q -m task task-r2
  git -C "$dir/repo" push -q no-mistakes task-r2
  git -C "$dir/repo" push -q no-mistakes task-r2:task-r3
  git -C "$dir/repo" branch -q task-r4 main
  rebase_task_r2() { git -C "$dir/repo" rebase -q main task-r2; }
  rebase_task_r2
  run "$dir/repo"
  [ "$RC" = 0 ] || fail "expected stranded, got $RC: $OUT"
  assert_contains "$OUT" "fresh_branch: task-r5" "skips names taken locally or in the mirror"
  pass "fresh branch name increments an -rN suffix and skips taken names"
}

test_refuses_when_pr_open_for_stranded_branch() {
  local dir before url=https://github.com/o/r/pull/7
  dir=$(world openpr)
  rebase_task "$dir"
  before=$(mirror_fingerprint "$dir")
  : > "$GH_LOG"
  OUT=$(FAKE_GH_PRS=$url "$SCRIPT" "$dir/repo" 2>&1)
  RC=$?
  [ "$RC" = 1 ] || fail "an open PR on the stranded branch must refuse with exit 1, got $RC: $OUT"
  assert_contains "$OUT" "state: refused" "open-PR refusal state"
  assert_contains "$OUT" "open_pr: $url" "refusal names the open PR"
  assert_contains "$OUT" "report blocked naming this PR" "refusal tells the worker to report blocked"
  assert_not_contains "$OUT" "fresh_branch:" "open-PR refusal must not recommend a fresh branch"
  assert_not_contains "$OUT" "git switch -c" "open-PR refusal must not print the fresh-branch command"
  [ "$(mirror_fingerprint "$dir")" = "$before" ] || fail "open-PR refusal wrote to the mirror"
  [ "$(cat "$GH_LOG")" = "pr list --head task --state open --json url -q .[].url" ] \
    || fail "the helper must only list open PRs for the branch, got: $(cat "$GH_LOG")"
  pass "refuses a fresh branch while a PR is open for the stranded branch"
}

test_refuses_when_pr_query_fails() {
  local dir
  dir=$(world ghfail)
  rebase_task "$dir"
  OUT=$(FAKE_GH_FAIL=1 "$SCRIPT" "$dir/repo" 2>&1)
  RC=$?
  [ "$RC" = 1 ] || fail "a failed open-PR query must refuse with exit 1, got $RC: $OUT"
  assert_contains "$OUT" "state: refused" "query-failure refusal state"
  assert_contains "$OUT" "could not prove no PR is open" "query-failure reason"
  assert_not_contains "$OUT" "fresh_branch:" "query failure must not recommend a fresh branch"
  pass "refuses a fresh branch when the open-PR query cannot complete"
}

test_not_stranded_cases() {
  local dir
  dir=$(world plain)
  run "$dir/repo"
  [ "$RC" = 3 ] || fail "equal mirror ref must be not-stranded, got $RC: $OUT"
  echo b > "$dir/repo/b.txt"
  git -C "$dir/repo" add b.txt
  git -C "$dir/repo" commit -qm 'task: B'
  run "$dir/repo"
  [ "$RC" = 3 ] || fail "fast-forwardable mirror ref must be not-stranded, got $RC: $OUT"
  git -C "$dir/repo" switch -q -c unpushed
  run "$dir/repo"
  [ "$RC" = 3 ] || fail "absent mirror ref must be not-stranded, got $RC: $OUT"
  assert_contains "$OUT" "no ref for this branch" "absent-ref reason"
  pass "reports not-stranded for equal, fast-forward, and absent mirror refs"
}

test_errors_without_mirror_or_branch() {
  local dir
  dir=$(world errors)
  run --remote nope "$dir/repo"
  [ "$RC" = 2 ] || fail "missing remote must exit 2, got $RC: $OUT"
  git -C "$dir/repo" switch -q --detach
  run "$dir/repo"
  [ "$RC" = 2 ] || fail "detached HEAD must exit 2, got $RC: $OUT"
  pass "exits 2 for a missing remote or detached HEAD"
}

test_refuses_when_mirror_ref_holds_commit_head_lacks
test_refuses_when_mirror_ref_holds_merge_commit
test_recommends_fresh_branch_when_equivalent
test_fresh_name_skips_taken_and_increments_suffix
test_refuses_when_pr_open_for_stranded_branch
test_refuses_when_pr_query_fails
test_not_stranded_cases
test_errors_without_mirror_or_branch
