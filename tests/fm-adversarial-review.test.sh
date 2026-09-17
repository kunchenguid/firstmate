#!/usr/bin/env bash
# Tests for bin/fm-adversarial-review.sh: the deterministic half of the
# adversarial-review gate. Firstmate dispatches tier lenses and reconciles
# findings; this script stages evidence before dispatch, posts each round's
# evidence and results into the PR, reconciles reports under the skill's
# GREEN conditions, and owns the loop-green marker bin/fm-pr-merge.sh
# enforces.
#
# Matrix:
#   (a) condition is false with no PR-open status line, true with one
#   (b) an armed watch fires its action on a synthetic PR-open status line
#   (c) dispatch stages diff minus generated files, prose, prompts, and posts
#     a round comment plus a PR body section
#   (d) reconcile is RED with an unresolved MAJOR and writes no marker
#   (e) reconcile is GREEN once the MAJOR is fixed_verified and the marker
#     passes check-green at the head and fails it past the head
#   (f) check-green refuses without a marker
#   (g) T1 refuses a second round past its cap of one
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

ADV="$ROOT/bin/fm-adversarial-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-adversarial-review-tests)
PR_URL=https://github.com/example/repo/pull/9

# Build a fixture lane repo with two commits and return base head wt.
make_repo() {
  local wt=$1
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  printf 'hello\n' > "$wt/app.txt"
  printf '{"lock": 1}\n' > "$wt/package-lock.json"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m 'add the feature'
  printf '%s %s %s\n' "$(git -C "$wt" rev-parse 'HEAD~1')" "$(git -C "$wt" rev-parse HEAD)" "$wt"
}

# Fake gh answering selectable PR fields from FAKE_GH_* env vars.
add_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) field=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  headRefOid) printf '%s\n' "${FAKE_GH_headRefOid:-}" ;;
  baseRefOid) printf '%s\n' "${FAKE_GH_baseRefOid:-}" ;;
  title) printf '%s\n' "${FAKE_GH_title:-untitled}" ;;
  body) printf '%s\n' "${FAKE_GH_body:-nobody}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
}

# Fake gh-axi recording every invocation and succeeding.
add_fake_gh_axi() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$fakebin/gh-axi"
}

run_adv() {
  local state_dir=$1 fakebin=$2
  shift 2
  FM_STATE_OVERRIDE="$state_dir" \
  FM_TEST_GH_AXI_LOG="$state_dir/gh-axi.log" \
  PATH="$fakebin:$PATH" \
    "$ADV" "$@"
}

write_lens_report() {
  local file=$1 verdict=$2 findings=$3
  {
    printf 'verdict: %s\nboundary_class: merge\nfindings:\n' "$verdict"
    printf '%s' "$findings"
    printf 'blind_spots: none seen\n'
  } > "$file"
}

test_condition_needs_a_pr_open_line() {
  local case_dir="$TMP_ROOT/condition"
  mkdir -p "$case_dir/state"
  if FM_STATE_OVERRIDE="$case_dir/state" "$ADV" condition; then
    fail "condition: true with no status lines"
  fi
  printf 'working: implementing\n' > "$case_dir/state/task-a.status"
  if FM_STATE_OVERRIDE="$case_dir/state" "$ADV" condition; then
    fail "condition: true with no PR-open line"
  fi
  printf 'done: PR %s\n' "$PR_URL" >> "$case_dir/state/task-a.status"
  FM_STATE_OVERRIDE="$case_dir/state" "$ADV" condition \
    || fail "condition: false with a synthetic PR-open status line"
  pass "condition fires only on a PR-open status line"
}

test_watch_fires_on_pr_open_line() {
  local home="$TMP_ROOT/h-fire" wt
  local fakebin="$home/fakebin"
  mkdir -p "$home/state" "$fakebin"
  read -r base head wt < <(make_repo "$home/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  fm_write_meta "$home/state/task-a.meta" "window=fm-task-a" "worktree=$wt"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='Add the feature' FAKE_GH_body='It works.'
  export FM_TEST_GH_AXI_LOG="$home/state/gh-axi.log"
  : > "$home/state/gh-axi.log"
  FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" arm adv-pr-open \
    --interval 0.1 --stable 1 \
    --condition "$ADV" condition \
    --action "$ADV" action >/dev/null
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
  printf 'working: implementing\n' > "$home/state/task-a.status"
  sleep 0.4
  printf 'done: PR %s\n' "$PR_URL" >> "$home/state/task-a.status"
  local result n=0
  for _ in $(seq 1 150); do
    result=$(printf '%s\n' "$home"/state/procevent-inbox/when-adv-pr-open.*.result 2>/dev/null | head -1)
    [ -n "$result" ] && [ -e "$result" ] && break
    sleep 0.1
    n=$((n + 1))
  done
  [ -n "${result:-}" ] && [ -e "$result" ] || fail "watch: no outcome after the PR-open line"
  assert_grep 'status: fired' "$result" "watch: outcome is not a fired action"
  assert_grep 'dispatched: task-a' "$result" "watch: action did not dispatch the loop"
  assert_present "$home/state/task-a.adversarial-review/round-1/diff.patch" \
    "watch: the fired action staged no evidence"
  assert_grep 'pr comment 9 --repo example/repo --body-file' "$home/state/gh-axi.log" \
    "watch: the fired action posted no round comment"
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  pass "an armed watch fires the loop on a synthetic PR-open status line"
}

test_dispatch_stages_evidence_and_posts() {
  local case_dir="$TMP_ROOT/dispatch" wt
  local fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='Add the feature' FAKE_GH_body='It works.'
  : > "$case_dir/state/gh-axi.log"
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" >/dev/null \
    || fail "dispatch: dispatch failed"
  local dir="$case_dir/state/task-a.adversarial-review/round-1"
  assert_grep 'hello' "$dir/diff.patch" "dispatch: the staged diff misses the change"
  assert_no_grep 'lock' "$dir/diff.patch" "dispatch: the staged diff keeps the lockfile"
  assert_grep 'Add the feature' "$dir/prose.md" "dispatch: prose misses the PR title"
  assert_grep 'It works.' "$dir/prose.md" "dispatch: prose misses the PR body"
  assert_grep 'add the feature' "$dir/prose.md" "dispatch: prose misses commit messages"
  assert_grep 'app.txt' "$dir/files.txt" "dispatch: file list misses the changed file"
  assert_present "$dir/prompt-frontier.md" "dispatch: T2 misses the frontier prompt"
  assert_present "$dir/prompt-deep.md" "dispatch: T2 misses the deep prompt"
  assert_grep 'READ-ONLY' "$dir/prompt-frontier.md" "dispatch: prompt drops read-only"
  assert_grep 'git stash' "$dir/prompt-frontier.md" "dispatch: prompt drops the forbidden commands"
  assert_grep 'round 1 dispatched' "$dir/comment.md" "dispatch: comment misses the round"
  assert_grep 'pr comment 9 --repo example/repo --body-file' "$case_dir/state/gh-axi.log" \
    "dispatch: no round comment posted"
  assert_grep 'pr edit 9 --repo example/repo --body-file' "$case_dir/state/gh-axi.log" \
    "dispatch: no PR body section synced"
  pass "dispatch stages evidence and posts the round comment plus body section"
}

test_reconcile_red_then_green() {
  local case_dir="$TMP_ROOT/reconcile" wt
  local fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='Add the feature' FAKE_GH_body='It works.'
  : > "$case_dir/state/gh-axi.log"
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" >/dev/null \
    || fail "reconcile: dispatch failed"
  write_lens_report "$case_dir/frontier.md" GREEN '  - id: f1
    severity: MINOR
    claim: naming
    evidence: app.txt:1
    problem: terse name
    fix: rename
'
  write_lens_report "$case_dir/deep.md" RED '  - id: d1
    severity: MAJOR
    claim: empty state
    evidence: app.txt:1
    problem: no empty handling
    fix: guard it
'
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens frontier --report "$case_dir/frontier.md" >/dev/null \
    || fail "reconcile: frontier record failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens deep --report "$case_dir/deep.md" >/dev/null \
    || fail "reconcile: deep record failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "reconcile: RED reconcile failed to post"
  assert_contains "$out" "round-1 RED" "reconcile: unresolved MAJOR did not stay RED"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "reconcile: RED wrote a loop-green marker"
  run_adv "$case_dir/state" "$fakebin" resolve task-a --round 1 \
    --finding deep:d1 --disposition fixed_verified >/dev/null \
    || fail "reconcile: resolve failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "reconcile: GREEN reconcile failed to post"
  assert_contains "$out" "round-1 GREEN" "reconcile: fixed MAJOR did not go GREEN"
  assert_grep "head=$head" "$case_dir/state/task-a.adversarial-review-green" \
    "reconcile: GREEN marker misses the reviewed head"
  run_adv "$case_dir/state" "$fakebin" check-green task-a "$PR_URL" >/dev/null \
    || fail "reconcile: check-green refuses its own GREEN marker"
  if run_adv "$case_dir/state" "$fakebin" check-green task-a "$PR_URL" \
    --head 0000000000000000000000000000000000000000 >/dev/null 2>&1; then
    fail "reconcile: check-green passes past the reviewed head"
  fi
  pass "reconcile stays RED on an unresolved MAJOR and greens the marker once fixed"
}

test_check_green_refuses_without_marker() {
  local case_dir="$TMP_ROOT/no-marker"
  local fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  : > "$case_dir/state/gh-axi.log"
  fm_write_meta "$case_dir/state/task-a.meta" "window=fm-task-a"
  if run_adv "$case_dir/state" "$fakebin" check-green task-a "$PR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "check-green: passed with no marker"
  fi
  assert_grep 'loop-green evidence is missing' "$case_dir/stderr" \
    "check-green: refusal does not name the missing evidence"
  printf 'garbage\n' > "$case_dir/state/task-a.adversarial-review-green"
  if run_adv "$case_dir/state" "$fakebin" check-green task-a "$PR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "check-green: passed with a malformed marker"
  fi
  assert_grep 'malformed' "$case_dir/stderr" \
    "check-green: refusal does not name the malformed evidence"
  pass "check-green refuses without a loop-green marker"
}

test_t1_cap_refuses_round_two() {
  local case_dir="$TMP_ROOT/t1cap" wt
  local fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T1 --wt "$wt" --base "$base" --head "$head" >/dev/null \
    || fail "t1cap: round 1 dispatch failed"
  if run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T1 --wt "$wt" --base "$base" --head "$head" --round 2 \
    >/dev/null 2>&1; then
    fail "t1cap: round 2 dispatched past the T1 cap of one"
  fi
  pass "T1 refuses a second round past its cap"
}

test_condition_needs_a_pr_open_line
test_watch_fires_on_pr_open_line
test_dispatch_stages_evidence_and_posts
test_reconcile_red_then_green
test_check_green_refuses_without_marker
test_t1_cap_refuses_round_two
