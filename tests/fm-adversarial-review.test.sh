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
#   (h) a RED lens verdict with no parsed MAJOR/BLOCKER reconciles RED
#   (i) a resolution note naming another finding does not resolve it
#   (j) an unseated lens, and a lens seated on the lane's own model, are RED
#   (k) a T0 waiver without a recorded captain answer writes no marker, and it
#     must name this lane task's own captain call
#   (l) a tier below the one the change requires is refused, and a marker
#     below its recorded floor fails check-green
#   (m) ensure-watch re-arms after the watch has fired and been retired
#   (n) record-lens --seat seats a round dispatched with no seats
#   (o) a --base narrower than the PR's own base is refused
#   (p) a MAJOR/BLOCKER from an earlier round stays RED until it is disposed of
#   (q) a lens report whose id or severity cannot be read is refused rather
#     than parsed into a finding that vanishes from reconciliation
#   (r) a --seat carrying a line break cannot rewrite the round meta
#   (s) --round is held to a number outside dispatch too
#   (t) a lane with no resolvable worktree does not starve the other PRs
#   (u) a dispatch that fails after claiming its round leaves that round named
#     for its PR, so the lane is not re-selected and wedged forever
#   (v) finding-shaped content the scanner cannot key refuses the report
#   (w) a UI-impacting round dispatches the Design/UX lens it then requires,
#     and reconciles that lens's own verdict and findings
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

# The watch commands address a whole home rather than a bare state dir, and the
# process-event claim root is machine-wide, so the fixture takes its own to stay
# clear of any watch really armed on this machine.
run_watch_home() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" \
  FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
  FM_TEST_GH_AXI_LOG="$home/state/gh-axi.log" \
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
    --tier T2 --wt "$wt" --base "$base" --head "$head" \
    --seat frontier=fable-5.1 --seat deep=opus-5 >/dev/null \
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
  assert_grep "tier=T2" "$case_dir/state/task-a.adversarial-review-green" \
    "reconcile: GREEN marker misses the tier the loop ran"
  assert_grep "required=T1" "$case_dir/state/task-a.adversarial-review-green" \
    "reconcile: GREEN marker misses the tier floor the change required"
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

# Stage a dispatched T2 round with both seats filled. Sets CASE_DIR and FAKEBIN
# in the caller's shell (the fake gh reads exported FAKE_GH_*,
# which a subshell could not hand back). Args: name [extra dispatch args...]
setup_round() {
  local name=$1 wt
  shift
  CASE_DIR="$TMP_ROOT/$name"
  FAKEBIN="$CASE_DIR/fakebin"
  mkdir -p "$CASE_DIR/state" "$FAKEBIN"
  read -r base head wt < <(make_repo "$CASE_DIR/wt")
  add_fake_gh "$FAKEBIN"
  add_fake_gh_axi "$FAKEBIN"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$CASE_DIR/state/gh-axi.log"
  run_adv "$CASE_DIR/state" "$FAKEBIN" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" \
    --seat frontier=fable-5.1 --seat deep=opus-5 "$@" >/dev/null \
    || fail "$name: dispatch failed"
}

# Regression: a lens that judged the change RED but whose findings never
# parsed into id/severity pairs used to contribute nothing, so the round
# reconciled GREEN and wrote a merge-clearing marker over unreconciled blockers.
test_red_verdict_without_parsed_findings_is_red() {
  local case_dir fakebin out
  setup_round red-verdict
  case_dir=$CASE_DIR fakebin=$FAKEBIN
  write_lens_report "$case_dir/frontier.md" GREEN ''
  # A RED verdict whose findings live in the markdown table the dispatch prompt
  # asks for: nothing here parses as an id/severity pair.
  write_lens_report "$case_dir/deep.md" RED '  |d1|BLOCKER|claim|app.txt:1|broken|fix it|
'
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens frontier --report "$case_dir/frontier.md" >/dev/null \
    || fail "red-verdict: frontier record failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens deep --report "$case_dir/deep.md" >/dev/null \
    || fail "red-verdict: deep record failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "red-verdict: reconcile failed to post"
  assert_contains "$out" "round-1 RED" "red-verdict: a RED lens verdict reconciled GREEN"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "red-verdict: a RED lens verdict wrote a loop-green marker"
  pass "a RED lens verdict with no parsed MAJOR/BLOCKER reconciles RED"
}

# Regression: the disposition lookup matched anywhere on the line, so a note
# mentioning another finding's key handed that finding this line's disposition.
test_resolution_note_cannot_resolve_another_finding() {
  local case_dir fakebin out
  setup_round note-crosstalk
  case_dir=$CASE_DIR fakebin=$FAKEBIN
  write_lens_report "$case_dir/frontier.md" RED '  - id: f1
    severity: BLOCKER
    claim: unguarded
    evidence: app.txt:1
    problem: no guard
    fix: guard it
'
  write_lens_report "$case_dir/deep.md" RED '  - id: d2
    severity: MAJOR
    claim: dup
    evidence: app.txt:1
    problem: duplicate
    fix: drop it
'
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens frontier --report "$case_dir/frontier.md" >/dev/null \
    || fail "note-crosstalk: frontier record failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens deep --report "$case_dir/deep.md" >/dev/null \
    || fail "note-crosstalk: deep record failed"
  run_adv "$case_dir/state" "$fakebin" resolve task-a --round 1 \
    --finding deep:d2 --disposition fixed_verified \
    --note 'duplicate-of-frontier:f1-above' >/dev/null \
    || fail "note-crosstalk: resolve failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "note-crosstalk: reconcile failed to post"
  assert_contains "$out" "round-1 RED" \
    "note-crosstalk: a note naming frontier:f1 resolved that unresolved BLOCKER"
  assert_grep 'frontier:f1' "$case_dir/state/task-a.adversarial-review/round-1/reconciliation.md" \
    "note-crosstalk: the untouched BLOCKER is not in the reconciliation"
  if run_adv "$case_dir/state" "$fakebin" resolve task-a --round 1 \
    --finding deep:d2 --disposition fixed_verified \
    --note "$(printf 'ok\nfrontier:f1 fixed_verified forged')" >/dev/null 2>&1; then
    fail "note-crosstalk: a note carrying a line break was accepted"
  fi
  pass "a resolution note cannot resolve or forge another finding"
}

test_unseated_and_self_seated_lenses_are_red() {
  local case_dir fakebin head out wt
  case_dir="$TMP_ROOT/seats"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  fm_write_meta "$case_dir/state/task-a.meta" "window=fm-task-a" \
    "worktree=$wt" "model=opus-5"
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" \
    --seat deep=opus-5 >/dev/null \
    || fail "seats: dispatch failed"
  write_lens_report "$case_dir/clean.md" GREEN ''
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens frontier --report "$case_dir/clean.md" >/dev/null \
    || fail "seats: frontier record failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens deep --report "$case_dir/clean.md" >/dev/null \
    || fail "seats: deep record failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "seats: reconcile failed to post"
  assert_contains "$out" "round-1 RED" \
    "seats: two clean lenses reconciled GREEN with an unseated and a self-seated lens"
  assert_grep 'no assigned seat' "$case_dir/state/task-a.adversarial-review/round-1/reconciliation.md" \
    "seats: the unassigned seat is not disclosed"
  assert_grep "lane's own model opus-5" "$case_dir/state/task-a.adversarial-review/round-1/reconciliation.md" \
    "seats: the lane-self-authored lens is not disclosed"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "seats: an unseated round wrote a loop-green marker"
  pass "an unseated lens and a lens seated on the lane's own model are RED"
}

test_t0_waiver_needs_a_captain_answer() {
  local case_dir fakebin wt base head
  case_dir="$TMP_ROOT/t0-waiver"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  if run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T0 --wt "$wt" --base "$base" --head "$head" \
    --waiver-class trivial --waiver-reason 'captain said so' \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "t0-waiver: a free-text waiver with no captain call was accepted"
  fi
  assert_grep 'waiver-hold' "$case_dir/stderr" \
    "t0-waiver: the refusal does not name the missing captain call"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "t0-waiver: a self-attested waiver wrote a loop-green marker"
  # Regression: the waiver used to accept ANY answered captain call in the
  # backlog, so a captain's words about unrelated work cleared this gate. Only
  # this lane task's own call may be named.
  if run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T0 --wt "$wt" --base "$base" --head "$head" \
    --waiver-class trivial --waiver-reason 'captain said so' \
    --waiver-hold task-other \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "t0-waiver: a waiver naming another task's captain call was accepted"
  fi
  assert_grep "own captain call (task-a)" "$case_dir/stderr" \
    "t0-waiver: the refusal does not name the lane's own captain call"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "t0-waiver: another task's captain call wrote a loop-green marker"
  # This lane's own id, with no backlog recording any decision for it.
  if run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T0 --wt "$wt" --base "$base" --head "$head" \
    --waiver-class trivial --waiver-reason 'captain said so' \
    --waiver-hold task-a \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "t0-waiver: a waiver with no recorded captain decision was accepted"
  fi
  assert_grep 'records no captain decision' "$case_dir/stderr" \
    "t0-waiver: the refusal does not name the missing captain decision"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "t0-waiver: an unanswered captain call wrote a loop-green marker"
  pass "a T0 waiver needs this lane's own captain call to have decided it"
}

# Regression: ensure-watch used to read liveness from the watch's private spec
# file, which a fire never removes. Once the runner retired the REGISTRATION,
# every later call reported "already armed" and no PR ever got a loop again.
test_ensure_watch_rearms_after_a_fire() {
  local home fakebin wt registration result
  home="$TMP_ROOT/h-rearm"
  fakebin="$home/fakebin"
  mkdir -p "$home/state" "$fakebin"
  read -r base head wt < <(make_repo "$home/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  fm_write_meta "$home/state/task-a.meta" "window=fm-task-a" "worktree=$wt"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='Add the feature' FAKE_GH_body='It works.'
  export FM_TEST_GH_AXI_LOG="$home/state/gh-axi.log"
  : > "$home/state/gh-axi.log"
  registration="$home/state/procevent/when-adversarial-review-pr.source"

  run_watch_home "$home" "$fakebin" ensure-watch --interval 0.1 --stable 1 >/dev/null \
    || fail "rearm: the first ensure-watch did not arm"
  assert_present "$registration" "rearm: the first ensure-watch registered no source"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
  printf 'done: PR %s\n' "$PR_URL" > "$home/state/task-a.status"
  result=
  for _ in $(seq 1 200); do
    result=$(printf '%s\n' "$home"/state/procevent-inbox/when-adversarial-review-pr.*.result 2>/dev/null | head -1)
    [ -n "$result" ] && [ -e "$result" ] && break
    sleep 0.1
  done
  [ -n "${result:-}" ] && [ -e "$result" ] || fail "rearm: the armed watch never fired"
  assert_grep 'status: fired' "$result" "rearm: the outcome is not a fired action"
  # The runner drops the registration on a terminal outcome; the watch's own
  # spec and fired marker survive, which is what used to look like "armed".
  # Retirement happens just after the result is captured, so give it a moment.
  for _ in $(seq 1 100); do
    [ -e "$registration" ] || break
    sleep 0.1
  done
  assert_absent "$registration" "rearm: the fired watch kept its registration"
  assert_present "$home/state/when/when-adversarial-review-pr.spec" \
    "rearm: the fired watch dropped the private spec a re-arm has to clear"

  run_watch_home "$home" "$fakebin" ensure-watch --interval 0.1 --stable 1 >/dev/null \
    || fail "rearm: ensure-watch did not re-arm after the fire"
  assert_present "$registration" \
    "rearm: ensure-watch reported success without registering a source"
  assert_present "${result%.result}.handled" \
    "rearm: the fired outcome was re-armed over without being acknowledged"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    "$ROOT/bin/fm-procevent.sh" retire when-adversarial-review-pr >/dev/null 2>&1 || true
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  pass "ensure-watch re-arms the PR-open watch after it has fired and retired"
}

# Regression: cmd_action dispatches with no --seat, and reconcile REDs an
# unseated lens, so the automatic loop could never reach GREEN in the round it
# created. The seat is only known when the lens runs, so record-lens carries it.
test_record_lens_seats_a_round_dispatched_without_seats() {
  local case_dir fakebin wt out
  case_dir="$TMP_ROOT/record-seat"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  # Exactly what the auto-dispatched action passes: no tier, no seats.
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --wt "$wt" --base "$base" --head "$head" >/dev/null \
    || fail "record-seat: dispatch failed"
  write_lens_report "$case_dir/clean.md" GREEN ''
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens frontier --report "$case_dir/clean.md" --seat fable-5.1 >/dev/null \
    || fail "record-seat: frontier record failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens deep --report "$case_dir/clean.md" --seat opus-5 >/dev/null \
    || fail "record-seat: deep record failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "record-seat: reconcile failed to post"
  assert_contains "$out" "round-1 GREEN" \
    "record-seat: a round seated at record-lens time still reconciled RED"
  assert_grep "head=$head" "$case_dir/state/task-a.adversarial-review-green" \
    "record-seat: the GREEN round wrote no loop-green marker"
  # An unseated lens is still RED, and "unassigned" is not a seat.
  if run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens advisory:design-ux --report "$case_dir/clean.md" \
    --seat unassigned >/dev/null 2>&1; then
    fail "record-seat: the literal seat 'unassigned' was accepted"
  fi
  pass "record-lens seats a round the automatic dispatch left unseated"
}

# Regression: --base was taken on trust, so a caller could stage only the last
# commit of a security-sensitive branch and have it classified as ordinary.
test_narrower_base_than_the_pr_base_is_refused() {
  local case_dir fakebin wt base mid head out
  case_dir="$TMP_ROOT/base-bind"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/wt"
  wt="$case_dir/wt"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  mkdir -p "$wt/auth"
  printf 'token\n' > "$wt/auth/session.go"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m 'add session handling'
  printf 'hello\n' > "$wt/app.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m 'trivial follow-up'
  base=$(git -C "$wt" rev-parse 'HEAD~2')
  mid=$(git -C "$wt" rev-parse 'HEAD~1')
  head=$(git -C "$wt" rev-parse HEAD)
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"

  if run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --wt "$wt" --base "$mid" --head "$head" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "base-bind: a base narrower than the PR base was accepted"
  fi
  assert_grep 'nor an ancestor of it' "$case_dir/stderr" \
    "base-bind: the refusal does not name the PR base"
  assert_absent "$case_dir/state/task-a.adversarial-review/round-1/diff.patch" \
    "base-bind: the refused dispatch still staged a narrowed diff"
  # The PR's own base sees the security-sensitive commit and classifies T3.
  out=$(run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --wt "$wt" --head "$head" --reclaim) \
    || fail "base-bind: the forge-base dispatch failed"
  assert_contains "$out" "tier=T3" \
    "base-bind: the PR's own base did not classify the change at T3"
  pass "a --base narrower than the PR's own base is refused"
}

# Regression: reconciliation read only its own round, so a round-2 pair of
# clean lens reports at the same head closed a round-1 BLOCKER nobody fixed.
test_open_findings_carry_into_later_rounds() {
  local case_dir fakebin wt out
  case_dir="$TMP_ROOT/carry-forward"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" \
    --seat frontier=fable-5.1 --seat deep=opus-5 >/dev/null \
    || fail "carry: round 1 dispatch failed"
  write_lens_report "$case_dir/clean.md" GREEN ''
  write_lens_report "$case_dir/blocker.md" RED '  - id: f1
    severity: BLOCKER
    claim: unguarded
    evidence: app.txt:1
    problem: no guard
    fix: guard it
'
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens frontier --report "$case_dir/blocker.md" >/dev/null \
    || fail "carry: round 1 frontier record failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens deep --report "$case_dir/clean.md" >/dev/null \
    || fail "carry: round 1 deep record failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "carry: round 1 reconcile failed to post"
  assert_contains "$out" "round-1 RED" "carry: an unresolved BLOCKER did not stay RED"

  # Round 2 at the same head, with two clean lenses and nothing fixed.
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" --round 2 \
    --seat frontier=fable-5.1 --seat deep=opus-5 >/dev/null \
    || fail "carry: round 2 dispatch failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 2 --lens frontier --report "$case_dir/clean.md" >/dev/null \
    || fail "carry: round 2 frontier record failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 2 --lens deep --report "$case_dir/clean.md" >/dev/null \
    || fail "carry: round 2 deep record failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 2) \
    || fail "carry: round 2 reconcile failed to post"
  assert_contains "$out" "round-2 RED" \
    "carry: a clean round 2 closed an unresolved round-1 BLOCKER"
  assert_grep 'frontier:f1' "$case_dir/state/task-a.adversarial-review/round-2/reconciliation.md" \
    "carry: the round-1 BLOCKER is absent from the round-2 reconciliation"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "carry: a carried-forward BLOCKER still wrote a loop-green marker"

  # Disposing of it in round 2 is what closes it.
  run_adv "$case_dir/state" "$fakebin" resolve task-a --round 2 \
    --finding frontier:f1 --disposition fixed_verified >/dev/null \
    || fail "carry: resolve failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 2) \
    || fail "carry: the second round 2 reconcile failed to post"
  assert_contains "$out" "round-2 GREEN" \
    "carry: disposing of the carried BLOCKER did not reach GREEN"
  pass "an earlier round's MAJOR/BLOCKER stays RED until it is disposed of"
}

test_tier_floor_is_enforced_at_dispatch_and_at_check_green() {
  local case_dir fakebin wt base head marker
  case_dir="$TMP_ROOT/tier-floor"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin/x"
  mkdir -p "$case_dir/wt"
  git -C "$case_dir/wt" init -q
  git -C "$case_dir/wt" commit -q --allow-empty -m init
  mkdir -p "$case_dir/wt/auth"
  printf 'token\n' > "$case_dir/wt/auth/session.go"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -q -m 'add session handling'
  wt="$case_dir/wt"
  base=$(git -C "$wt" rev-parse 'HEAD~1')
  head=$(git -C "$wt" rev-parse HEAD)
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  if run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "tier-floor: T2 was accepted for a security-sensitive change"
  fi
  assert_grep 'below the T3' "$case_dir/stderr" \
    "tier-floor: the refusal does not name the required tier"
  # An unnamed tier adopts the derived one instead of the hardcoded default.
  # The refused round above is left claimed and failed, so this reclaims it.
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --wt "$wt" --base "$base" --head "$head" --reclaim \
    > "$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "tier-floor: the derived dispatch failed"
  assert_grep 'tier=T3' "$case_dir/stdout" \
    "tier-floor: an unnamed tier did not adopt the derived T3"
  # A marker recording a weaker run than the change required fails check-green.
  marker="$case_dir/state/task-a.adversarial-review-green"
  printf 'pr=%s\nhead=%s\ntier=T2\nrequired=T3\n' "$PR_URL" "$head" > "$marker"
  if run_adv "$case_dir/state" "$fakebin" check-green task-a "$PR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "tier-floor: check-green passed a marker below its own recorded floor"
  fi
  assert_grep 'requires T3' "$case_dir/stderr" \
    "tier-floor: the check-green refusal does not name the required tier"
  pass "the derived tier floor is enforced at dispatch and again at check-green"
}

# Regression: the scanner read the id and severity by awk field POSITION while
# matching by a regex that tolerates any spacing, so `severity:BLOCKER` parsed
# to an EMPTY severity, sailed past record-lens, and then missed
# reconciliation's BLOCKER|MAJOR branch - a BLOCKER that reconciled GREEN.
test_unreadable_finding_fields_are_refused() {
  local case_dir fakebin wt out
  case_dir="$TMP_ROOT/lens-parse"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" \
    --seat frontier=fable-5.1 --seat deep=opus-5 >/dev/null \
    || fail "lens-parse: dispatch failed"

  # A BLOCKER whose severity label carries no space after the colon.
  write_lens_report "$case_dir/tight.md" RED '  - id: a1
    severity: MAJOR
  - id: b2
    severity:BLOCKER
'
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens frontier --report "$case_dir/tight.md" >/dev/null \
    || fail "lens-parse: a readable tight-severity report was refused"
  run_adv "$case_dir/state" "$fakebin" resolve task-a --round 1 \
    --finding frontier:a1 --disposition fixed_verified >/dev/null \
    || fail "lens-parse: resolving a1 failed"
  write_lens_report "$case_dir/clean.md" GREEN ''
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens deep --report "$case_dir/clean.md" >/dev/null \
    || fail "lens-parse: deep record failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "lens-parse: reconcile failed to post"
  assert_contains "$out" "round-1 RED" \
    "lens-parse: a BLOCKER written as 'severity:BLOCKER' reconciled GREEN"
  assert_grep 'frontier:b2' "$case_dir/state/task-a.adversarial-review/round-1/reconciliation.md" \
    "lens-parse: the tight-severity BLOCKER is missing from the reconciliation"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "lens-parse: an unreconciled BLOCKER wrote a loop-green marker"

  # An id carrying a colon would corrupt the id:severity key, and an id line
  # with nothing after the label carries no id at all: both are refused.
  write_lens_report "$case_dir/colon.md" RED '  - id: a:b
    severity: MAJOR
'
  if run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens advisory:design-ux --report "$case_dir/colon.md" >/dev/null 2>&1; then
    fail "lens-parse: an id containing a colon was recorded"
  fi
  write_lens_report "$case_dir/noid.md" RED '  -id: c3
    severity: MAJOR
'
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens advisory:design-ux --report "$case_dir/noid.md" >/dev/null \
    || fail "lens-parse: a dash-tight id line was refused instead of read"
  pass "a lens report whose id or severity cannot be read is refused"
}

# Regression: --seat went into the round meta verbatim, and round_meta_get
# takes the LAST matching line, so a seat carrying newlines appended its own
# tier=/required_tier=/slots= lines below the real ones and talked a T3 change
# down to a two-lens T2 round.
test_seat_cannot_rewrite_the_round_meta() {
  local case_dir fakebin wt
  case_dir="$TMP_ROOT/seat-injection"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/wt"
  wt="$case_dir/wt"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  mkdir -p "$wt/auth"
  printf 'token\n' > "$wt/auth/session.go"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m 'add session handling'
  base=$(git -C "$wt" rev-parse 'HEAD~1')
  head=$(git -C "$wt" rev-parse HEAD)
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  if run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --wt "$wt" --base "$base" --head "$head" \
    --seat "$(printf 'frontier=x\nslots=frontier deep\ntier=T2\nrequired_tier=T2')" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "seat-injection: a seat carrying line breaks was accepted"
  fi
  assert_grep 'SLOT=MODEL' "$case_dir/stderr" \
    "seat-injection: the refusal does not name the seat shape"
  assert_absent "$case_dir/state/task-a.adversarial-review/round-1/meta" \
    "seat-injection: the refused dispatch still wrote a round meta"
  # A waiver reason is free text that lands in the same record.
  if run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T0 --wt "$wt" --base "$base" --head "$head" \
    --waiver-class trivial --waiver-hold task-a \
    --waiver-reason "$(printf 'ok\nstatus=green')" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"; then
    fail "seat-injection: a waiver reason carrying a line break was accepted"
  fi
  assert_grep 'line break' "$case_dir/stderr" \
    "seat-injection: the refusal does not name the line break"
  pass "a seat or waiver reason carrying a line break cannot rewrite the round meta"
}

test_round_is_validated_outside_dispatch() {
  local case_dir fakebin cmd
  case_dir="$TMP_ROOT/round-shape"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  : > "$case_dir/state/gh-axi.log"
  : > "$case_dir/report.md"
  for cmd in record-lens resolve reconcile; do
    case "$cmd" in
      record-lens)
        run_adv "$case_dir/state" "$fakebin" record-lens task-a \
          --round ../../escape --lens frontier --report "$case_dir/report.md" \
          >/dev/null 2>"$case_dir/stderr" && fail "round-shape: $cmd took a traversal round"
        ;;
      resolve)
        run_adv "$case_dir/state" "$fakebin" resolve task-a \
          --round ../../escape --finding frontier:f1 --disposition fixed_verified \
          >/dev/null 2>"$case_dir/stderr" && fail "round-shape: $cmd took a traversal round"
        ;;
      reconcile)
        run_adv "$case_dir/state" "$fakebin" reconcile task-a \
          --round ../../escape >/dev/null 2>"$case_dir/stderr" \
          && fail "round-shape: $cmd took a traversal round"
        ;;
    esac
    assert_grep 'invalid round' "$case_dir/stderr" \
      "round-shape: $cmd did not refuse the round for its shape"
  done
  pass "--round is held to a number outside dispatch too"
}

# Regression: dispatch fails before it creates the round directory, so a lane
# whose worktree is gone stayed pending forever - every fire re-selected it,
# failed again, and left the watch refusing to re-arm, starving every other PR.
test_an_unstageable_lane_does_not_starve_the_others() {
  local case_dir fakebin wt out rc
  case_dir="$TMP_ROOT/unstageable"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  # task-dead's worktree was returned; task-live is an ordinary lane.
  fm_write_meta "$case_dir/state/task-dead.meta" "window=fm-task-dead" \
    "worktree=$case_dir/gone"
  fm_write_meta "$case_dir/state/task-live.meta" "window=fm-task-live" \
    "worktree=$wt"
  printf 'done: PR %s\n' https://github.com/example/repo/pull/7 \
    > "$case_dir/state/task-dead.status"
  printf 'done: PR %s\n' "$PR_URL" > "$case_dir/state/task-live.status"

  run_adv "$case_dir/state" "$fakebin" condition \
    || fail "unstageable: the condition went false with lanes pending"
  set +e
  out=$(run_adv "$case_dir/state" "$fakebin" action 2>"$case_dir/stderr")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unstageable: the failed lane was not reported as a failure"
  assert_contains "$out" "dispatched: task-live" \
    "unstageable: the live lane never got its loop"
  assert_absent "$case_dir/state/task-dead.adversarial-review/round-1/diff.patch" \
    "unstageable: the dead lane staged evidence from a worktree that is gone"
  assert_absent "$case_dir/state/task-dead.adversarial-review-green" \
    "unstageable: the undispatchable lane was cleared for merge"
  # The failed claim is what stops the next fire re-selecting it forever.
  assert_grep 'status=failed' "$case_dir/state/task-dead.adversarial-review/round-1/meta" \
    "unstageable: the undispatchable lane recorded no failed round"
  out=$(run_adv "$case_dir/state" "$fakebin" condition 2>/dev/null; printf 'rc=%s' "$?")
  assert_contains "$out" "rc=1" \
    "unstageable: the dead lane is still pending after its round was claimed failed"
  pass "an undispatchable lane claims a failed round instead of starving the others"
}

# Regression: dispatch claimed its round directory and only wrote the meta at
# the very end, so a failure in between (a forge outage staging the prose, an
# empty diff) left a round naming no PR. pending_loops then did not see the
# lane as claimed, re-selected it on every fire, and dispatch died on the
# directory it had left behind - the lane, and the shared watch, wedged.
test_a_failed_dispatch_still_names_its_pr() {
  local case_dir fakebin wt out rc
  case_dir="$TMP_ROOT/failed-claim"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  fm_write_meta "$case_dir/state/task-a.meta" "window=fm-task-a" "worktree=$wt"
  printf 'done: PR %s\n' "$PR_URL" > "$case_dir/state/task-a.status"
  # A PR whose forge base IS its head: the empty-diff refusal lands AFTER the
  # round directory is claimed, which is the window this covers.
  export FAKE_GH_baseRefOid="$head"
  set +e
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --wt "$wt" --head "$head" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  export FAKE_GH_baseRefOid="$base"
  [ "$rc" -ne 0 ] || fail "failed-claim: an empty diff was dispatched"
  assert_grep 'empty diff' "$case_dir/stderr" \
    "failed-claim: the dispatch failed before it claimed its round"
  assert_grep "url=$PR_URL" "$case_dir/state/task-a.adversarial-review/round-1/meta" \
    "failed-claim: the failed round names no PR"
  assert_grep 'status=failed' "$case_dir/state/task-a.adversarial-review/round-1/meta" \
    "failed-claim: the failed round is not marked failed"
  # The lane is claimed, so it is no longer pending and no fire re-selects it.
  out=$(run_adv "$case_dir/state" "$fakebin" condition 2>/dev/null; printf 'rc=%s' "$?")
  assert_contains "$out" "rc=1" \
    "failed-claim: the lane is still pending after its round was claimed failed"
  # --reclaim is what clears it once the cause is fixed.
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --wt "$wt" --head "$head" --reclaim >/dev/null \
    || fail "failed-claim: --reclaim could not re-dispatch the fixed lane"
  assert_present "$case_dir/state/task-a.adversarial-review/round-1/diff.patch" \
    "failed-claim: the reclaimed round staged no evidence"
  pass "a dispatch that fails after claiming its round still names its PR"
}

# Regression: content the strict rules did not consume was dropped in silence,
# so a BLOCKER written in an unkeyable shape never reached reconciliation while
# a sibling well-formed finding kept the degradation guard from firing.
test_unkeyable_finding_shapes_refuse_the_report() {
  local case_dir fakebin wt shape
  case_dir="$TMP_ROOT/unkeyable"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  read -r base head wt < <(make_repo "$case_dir/wt")
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --tier T2 --wt "$wt" --base "$base" --head "$head" \
    --seat frontier=fable-5.1 --seat deep=opus-5 >/dev/null \
    || fail "unkeyable: dispatch failed"
  # Each of these carries a real BLOCKER the reconciler could not key.
  local n=0
  for shape in \
'  - id: a1
    severity: MAJOR
  - id:
    severity: BLOCKER
' \
'  - id: a1
    severity: MAJOR
  - severity: BLOCKER
    id: b2
' \
'  - id: a1
    severity: MAJOR
    id: b2
    severity: BLOCKER
' \
'  - id: a1
    severity: MAJOR
  - id: b2
    severity: SHOWSTOPPER
'; do
    n=$((n + 1))
    write_lens_report "$case_dir/shape-$n.md" RED "$shape"
    if run_adv "$case_dir/state" "$fakebin" record-lens task-a \
      --round 1 --lens frontier --report "$case_dir/shape-$n.md" \
      >/dev/null 2>&1; then
      fail "unkeyable: shape $n was recorded with a BLOCKER the reconciler cannot key"
    fi
    assert_absent "$case_dir/state/task-a.adversarial-review/round-1/lens-frontier.report" \
      "unkeyable: shape $n stored a report the reconciler cannot fully read"
  done
  pass "finding-shaped content the scanner cannot key refuses the report"
}

# Regression: reconcile hard-RED'd a UI-impacting round for the absence of the
# Design/UX lens, but dispatch never staged a prompt or a seat for it - the one
# lens whose absence is red was the one lens the loop did not ask anybody to
# run. Its own verdict and findings were never reconciled either.
test_ui_round_dispatches_and_reconciles_the_design_lens() {
  local case_dir fakebin wt out
  case_dir="$TMP_ROOT/ui-lens"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/wt"
  wt="$case_dir/wt"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  printf '.a { color: red }\n' > "$wt/app.css"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m 'restyle the panel'
  base=$(git -C "$wt" rev-parse 'HEAD~1')
  head=$(git -C "$wt" rev-parse HEAD)
  add_fake_gh "$fakebin"
  add_fake_gh_axi "$fakebin"
  export FAKE_GH_headRefOid="$head" FAKE_GH_baseRefOid="$base"
  export FAKE_GH_title='t' FAKE_GH_body='b'
  : > "$case_dir/state/gh-axi.log"
  # Exactly what the auto-dispatched action passes: no tier, no --ui-impacting.
  run_adv "$case_dir/state" "$fakebin" dispatch task-a "$PR_URL" \
    --wt "$wt" --base "$base" --head "$head" \
    --seat frontier=fable-5.1 --seat deep=opus-5 \
    --seat advisory:design-ux=astra >/dev/null \
    || fail "ui-lens: dispatch failed"
  local dir="$case_dir/state/task-a.adversarial-review/round-1"
  assert_present "$dir/prompt-advisory:design-ux.md" \
    "ui-lens: the required Design/UX lens got no staged prompt"
  assert_grep 'advisory:design-ux' "$dir/comment.md" \
    "ui-lens: the round comment does not name the Design/UX lens"

  write_lens_report "$case_dir/clean.md" GREEN ''
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens frontier --report "$case_dir/clean.md" >/dev/null \
    || fail "ui-lens: frontier record failed"
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens deep --report "$case_dir/clean.md" >/dev/null \
    || fail "ui-lens: deep record failed"
  # Both required lenses are clean, but the Design/UX lens has not reported.
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "ui-lens: reconcile failed to post"
  assert_contains "$out" "round-1 RED" \
    "ui-lens: a UI round reconciled GREEN without its Design/UX lens"

  # The advisory lens's own BLOCKER carries full reconciliation weight.
  write_lens_report "$case_dir/design.md" RED '  - id: d1
    severity: BLOCKER
    claim: contrast
    evidence: app.css:1
    problem: unreadable
    fix: darken it
'
  run_adv "$case_dir/state" "$fakebin" record-lens task-a \
    --round 1 --lens advisory:design-ux --report "$case_dir/design.md" >/dev/null \
    || fail "ui-lens: design-ux record failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "ui-lens: the second reconcile failed to post"
  assert_contains "$out" "round-1 RED" \
    "ui-lens: an unresolved Design/UX BLOCKER reconciled GREEN"
  assert_grep 'advisory:design-ux:d1' "$dir/reconciliation.md" \
    "ui-lens: the Design/UX lens's own finding was never reconciled"
  assert_absent "$case_dir/state/task-a.adversarial-review-green" \
    "ui-lens: an unresolved Design/UX BLOCKER wrote a loop-green marker"

  run_adv "$case_dir/state" "$fakebin" resolve task-a --round 1 \
    --finding advisory:design-ux:d1 --disposition fixed_verified >/dev/null \
    || fail "ui-lens: resolving the Design/UX BLOCKER failed"
  out=$(run_adv "$case_dir/state" "$fakebin" reconcile task-a --round 1) \
    || fail "ui-lens: the third reconcile failed to post"
  assert_contains "$out" "round-1 GREEN" \
    "ui-lens: a fully reconciled UI round did not reach GREEN"
  pass "a UI-impacting round dispatches and reconciles its Design/UX lens"
}

test_condition_needs_a_pr_open_line
test_watch_fires_on_pr_open_line
test_dispatch_stages_evidence_and_posts
test_reconcile_red_then_green
test_check_green_refuses_without_marker
test_t1_cap_refuses_round_two
test_red_verdict_without_parsed_findings_is_red
test_resolution_note_cannot_resolve_another_finding
test_unseated_and_self_seated_lenses_are_red
test_t0_waiver_needs_a_captain_answer
test_tier_floor_is_enforced_at_dispatch_and_at_check_green
test_ensure_watch_rearms_after_a_fire
test_record_lens_seats_a_round_dispatched_without_seats
test_narrower_base_than_the_pr_base_is_refused
test_open_findings_carry_into_later_rounds
test_unreadable_finding_fields_are_refused
test_seat_cannot_rewrite_the_round_meta
test_round_is_validated_outside_dispatch
test_an_unstageable_lane_does_not_starve_the_others
test_a_failed_dispatch_still_names_its_pr
test_unkeyable_finding_shapes_refuse_the_report
test_ui_round_dispatches_and_reconciles_the_design_lens
