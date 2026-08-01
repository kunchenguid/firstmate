#!/usr/bin/env bash
# Behavioral tests for the different-family independent review readiness gate.
# shellcheck disable=SC2016 # Literal shell expressions are fixture source code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW="$ROOT/bin/fm-independent-review.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-independent-review)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

write_spawn_mock() {
  local fake_root=$1
  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
id=$1
project=$2
shift 2
harness=
model=default
while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness) harness=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --effort) shift 2 ;;
    --scout) shift ;;
    *) exit 2 ;;
  esac
done
printf '%s\t%s\t%s\n' "$id" "$harness" "$model" >> "$FM_TEST_SPAWN_LOG"
{
  printf 'window=fm-%s\n' "$id"
  printf 'endpoint_task_id=%s\n' "$id"
  printf 'worktree=%s\n' "$project"
  printf 'project=%s\n' "$project"
  printf 'harness=%s\n' "$harness"
  printf 'model=%s\n' "$model"
  printf 'kind=scout\nmode=scout\nyolo=off\n'
} > "$FM_STATE_OVERRIDE/$id.meta"
SH
  chmod +x "$fake_root/bin/fm-spawn.sh"
}

make_case() {
  local name=$1 builder_harness=$2 builder_model=$3 implementation=$4
  local dir="$TMP_ROOT/$name" source remote project wt home fake_root fakebin
  source="$dir/source"
  remote="$dir/remote.git"
  project="$dir/project"
  wt="$dir/wt"
  home="$dir/home"
  fake_root="$dir/root"
  fakebin="$dir/fakebin"

  mkdir -p "$source" "$home/state" "$home/data/task-a" "$home/config" "$fake_root/bin" "$fakebin"
  git -C "$source" init -q -b main
  printf '%s\n' '# fixture' > "$source/README.md"
  git -C "$source" add README.md
  git -C "$source" commit -qm initial
  git clone --quiet --bare "$source" "$remote"
  git -C "$source" remote add origin "file://$remote"
  git -C "$source" push -q -u origin main
  git clone --quiet "$remote" "$project"
  git clone --quiet "$remote" "$wt"
  git -C "$wt" checkout -qb feature
  printf '%s\n' "$implementation" > "$wt/authorize.sh"
  git -C "$wt" add authorize.sh
  git -C "$wt" commit -qm feature
  git -C "$wt" push -q origin HEAD:refs/pull/1/head

  cat > "$home/data/task-a/brief.md" <<'EOF'
You are a builder.

# Task
Reject every authorization request except the literal value `allowed`.

## Acceptance criteria

- `allowed` succeeds.
- Every other value fails.
- No caller can bypass the check.

# Builder summary
BUILDER_REASONING_SENTINEL: trust me, the implementation is correct.

# Definition of done
Open a pull request.
EOF

  fm_write_meta "$home/state/task-a.meta" \
    'window=fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$wt" \
    "project=$project" \
    "harness=$builder_harness" \
    "model=$builder_model" \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off'
  printf '%s\n' 'done: PR https://github.com/example/repo/pull/1 checks green' > "$home/state/task-a.status"

  # Mirrors the real `gh pr view --json ... -q` contract: only the documented
  # field selection answers, so a call shape the forge CLI does not support
  # fails the test instead of passing on a hand-written fixture shape.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = 'pr view' ] || exit 1
shift 2
json=
query=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json=$2; shift 2 ;;
    -q|--jq) query=$2; shift 2 ;;
    --repo) shift 2 ;;
    *) shift ;;
  esac
done
[ "$json" = state,isDraft,headRefOid ] || exit 1
[ -n "$query" ] || exit 1
head=$(git --git-dir="$FM_TEST_REMOTE" rev-parse refs/pull/1/head)
printf '%s\t%s\t%s\n' "${FM_TEST_PR_STATE:-OPEN}" "${FM_TEST_PR_DRAFT:-false}" "$head"
SH
  write_spawn_mock "$fake_root"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake_root/bin/fm-independent-review.sh" <<'SH'
#!/usr/bin/env bash
exec "$FM_TEST_REAL_REVIEW" "$@"
SH
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/claude" "$fakebin/codex" \
    "$fake_root/bin/fm-spawn.sh" "$fake_root/bin/fm-guard.sh" "$fake_root/bin/fm-independent-review.sh"
  : > "$dir/spawn.log"
  printf '%s\n' "$dir"
}

run_pr_check() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" \
  FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_TEST_REMOTE="$dir/remote.git" \
  FM_TEST_REAL_REVIEW="$REVIEW" \
  PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

run_review() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" \
  FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_DATA_OVERRIDE="$dir/home/data" \
  FM_CONFIG_OVERRIDE="$dir/home/config" \
  FM_TEST_REMOTE="$dir/remote.git" \
  FM_TEST_SPAWN_LOG="$dir/spawn.log" \
  PATH="$dir/fakebin:$BASE_PATH" \
    "$REVIEW" "$@"
}

round_value() {
  local dir=$1 round=$2 key=$3
  sed -n "s/^$key=//p" "$dir/home/state/task-a.independent-review.round-$round" | tail -1
}

submit_fixture_review() {
  local dir=$1 round=$2 verdict summary reviewer head diff
  reviewer=$(round_value "$dir" "$round" reviewer_task)
  head=$(round_value "$dir" "$round" head)
  diff=$(round_value "$dir" "$round" diff)
  if grep -F 'DEFECT_ACCEPTS_EVERYTHING' "$diff" >/dev/null; then
    verdict=reject
    summary='authorization accepts every input'
    run_review "$dir" submit task-a "$reviewer" "$head" "$verdict" "$summary" \
      --block correctness 'authorize.sh returns success for unauthorized values'
  else
    verdict=clear
    summary='no blocking findings'
    run_review "$dir" submit task-a "$reviewer" "$head" "$verdict" "$summary"
  fi
}

advance_pr_head() {
  local dir=$1 implementation=$2 message=${3:-update}
  printf '%s\n' "$implementation" > "$dir/wt/authorize.sh"
  git -C "$dir/wt" add authorize.sh
  git -C "$dir/wt" commit -qm "$message"
  git -C "$dir/wt" push -q --force origin HEAD:refs/pull/1/head
}

convert_case_to_gitlab() {
  local dir=$1
  local head
  head=$(git --git-dir="$dir/remote.git" rev-parse refs/pull/1/head)
  git --git-dir="$dir/remote.git" update-ref refs/merge-requests/1/head "$head"
  printf '%s\n' 'done: PR https://gitlab.example/group/repo/-/merge_requests/1 checks green' > "$dir/home/state/task-a.status"
  cat > "$dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  api)
    head=$(git --git-dir="$FM_TEST_REMOTE" rev-parse refs/merge-requests/1/head)
    printf '{"state":"opened","draft":false,"sha":"%s"}\n' "$head"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/glab"
}

test_codex_builder_selects_different_family() {
  local dir rc builder_family reviewer_family
  dir=$(make_case codex-selects-other codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 3 "$rc" "Codex selection should start a cold review and remain not ready: $(cat "$dir/err")"
  builder_family=$(round_value "$dir" 1 builder_family)
  reviewer_family=$(round_value "$dir" 1 reviewer_family)
  [ -n "$builder_family" ] || fail 'Codex selection did not record the builder family'
  [ -n "$reviewer_family" ] || fail 'Codex selection did not record the reviewer family'
  [ "$builder_family" != "$reviewer_family" ] || fail 'Codex selection chose the builder family for review'
  pass 'a Codex-built task selects an available reviewer from a different recorded family'
}

test_claude_builder_selects_different_family() {
  local dir rc builder_family reviewer_family
  dir=$(make_case claude-selects-other claude default 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 3 "$rc" 'Claude selection should start a cold review and remain not ready'
  builder_family=$(round_value "$dir" 1 builder_family)
  reviewer_family=$(round_value "$dir" 1 reviewer_family)
  [ -n "$builder_family" ] || fail 'Claude selection did not record the builder family'
  [ -n "$reviewer_family" ] || fail 'Claude selection did not record the reviewer family'
  [ "$builder_family" != "$reviewer_family" ] || fail 'Claude selection chose the builder family for review'
  pass 'a Claude-built task selects an available reviewer from a different recorded family'
}

test_pi_family_comes_from_recorded_model() {
  local anthropic_dir xai_dir rc anthropic_family xai_family
  anthropic_dir=$(make_case pi-anthropic pi openrouter/anthropic/claude-sonnet-4.6 'authorize() { [ "${1:-}" = allowed ]; }')
  xai_dir=$(make_case pi-xai pi openrouter/x-ai/grok-latest 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$anthropic_dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'Pi Anthropic review should start'
  set +e
  run_review "$xai_dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'Pi xAI review should start'
  anthropic_family=$(round_value "$anthropic_dir" 1 builder_family)
  xai_family=$(round_value "$xai_dir" 1 builder_family)
  [ -n "$anthropic_family" ] && [ -n "$xai_family" ] || fail 'Pi family resolution left a known provider empty'
  [ "$anthropic_family" != "$xai_family" ] || fail 'Pi family resolution ignored the recorded model provider'
  pass 'a model-routing harness derives family from its recorded model rather than its adapter name'
}

test_defective_pr_is_rejected() {
  local dir rc out
  dir=$(make_case defective-rejected codex gpt-5.6-sol 'authorize() { return 0; } # DEFECT_ACCEPTS_EVERYTHING')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'defective PR should enter review before it can be ready'
  submit_fixture_review "$dir" 1 >/dev/null
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'defective PR should be rejected by the readiness gate'
  assert_contains "$out" 'correctness' 'defective PR rejection did not carry the blocking risk category'
  assert_contains "$out" 'authorize.sh returns success for unauthorized values' 'defective PR rejection lost the concrete finding'
  pass 'a deliberately defective pull request is rejected with its concrete blocking finding'
}

test_sound_pr_passes_and_binds_exact_head() {
  local dir rc out reviewed_head current_head reviewer
  dir=$(make_case sound-passes codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'sound PR should enter review before it can be ready'
  submit_fixture_review "$dir" 1 >/dev/null
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1) \
    || fail 'sound PR did not pass after an independent clear verdict'
  reviewed_head=$(sed -n 's/^head=//p' "$dir/home/state/task-a.independent-review.verdict")
  reviewer=$(sed -n 's/^reviewer_task=//p' "$dir/home/state/task-a.independent-review.verdict")
  current_head=$(git --git-dir="$dir/remote.git" rev-parse refs/pull/1/head)
  [ "$reviewed_head" = "$current_head" ] || fail 'clear verdict was not bound to the exact reviewed head'
  assert_contains "$out" 'Independent review:' 'ready output did not begin with the traveling independent verdict'
  assert_contains "$out" "$reviewer" 'ready output did not name the specific independent reader'
  assert_contains "$out" 'no blocking findings' 'ready output lost what the reviewer found'
  pass 'a sound pull request passes with a traveling verdict bound to its exact head'
}

test_verdict_text_refuses_terminal_control_bytes() {
  local dir rc reviewer head
  dir=$(make_case verdict-control-bytes codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'control-byte fixture should start its cold review'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  head=$(round_value "$dir" 1 head)
  set +e
  run_review "$dir" submit task-a "$reviewer" "$head" clear $'clear\033[2Jspoofed' \
    >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'verdict accepted terminal control bytes from reviewer text'
  assert_absent "$dir/home/state/task-a.independent-review.verdict" \
    'rejected control-byte verdict reached durable state'
  pass 'verdict text rejects terminal control bytes before recording or presentation'
}

test_stale_verdict_does_not_clear_new_head() {
  local dir rc old_head new_head
  dir=$(make_case stale-head codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'initial review should start'
  submit_fixture_review "$dir" 1 >/dev/null
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null \
    || fail 'initial reviewed head should clear'
  old_head=$(sed -n 's/^head=//p' "$dir/home/state/task-a.independent-review.verdict")
  advance_pr_head "$dir" 'authorize() { [ "${1:-}" = allowed ]; } # amended' amended
  new_head=$(git --git-dir="$dir/remote.git" rev-parse refs/pull/1/head)
  [ "$old_head" != "$new_head" ] || fail 'stale-head fixture did not move the PR head'
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 > "$dir/out2" 2> "$dir/err2"
  rc=$?
  set -e
  expect_code 3 "$rc" 'a moved head should require the one permitted fresh review round'
  [ "$(round_value "$dir" 2 head)" = "$new_head" ] || fail 'second review round did not bind the new head'
  pass 'a verdict never clears a pull request head it was not produced against'
}

test_missing_different_family_refuses_loudly() {
  local dir rc out
  dir=$(make_case no-reviewer codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  rm -f "$dir/fakebin/claude" "$dir/fakebin/codex"
  set +e
  out=$(FM_INDEPENDENT_REVIEW_CANDIDATES='claude|default|high' run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'missing different-family adapter should refuse readiness'
  assert_contains "$out" 'could not establish an available verified different-family reviewer' \
    'missing reviewer refusal did not name the fact it could not establish'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'missing reviewer refusal recorded a review round that cannot run'
  [ ! -s "$dir/spawn.log" ] || fail 'missing reviewer refusal attempted to spawn an unverified or unavailable reviewer'
  pass 'no available different-family reviewer produces a loud refusal and no ready state'
}

test_selection_considers_each_available_verified_fixed_family() {
  local dir rc builder_family reviewer_family
  dir=$(make_case alternate-verified-family codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  rm -f "$dir/fakebin/claude" "$dir/fakebin/codex"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/fakebin/grok"
  chmod +x "$dir/fakebin/grok"
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'an available verified alternate family should start the cold review'
  builder_family=$(round_value "$dir" 1 builder_family)
  reviewer_family=$(round_value "$dir" 1 reviewer_family)
  [ -n "$reviewer_family" ] || fail 'alternate verified adapter did not record its model family'
  [ "$builder_family" != "$reviewer_family" ] || fail 'alternate verified adapter used the builder model family'
  pass 'selection considers available verified fixed-family adapters beyond the first two candidates'
}

test_second_rejection_opens_circuit() {
  local dir rc out spawn_count
  dir=$(make_case second-rejection codex gpt-5.6-sol 'authorize() { return 0; } # DEFECT_ACCEPTS_EVERYTHING')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'first review should start'
  submit_fixture_review "$dir" 1 >/dev/null
  advance_pr_head "$dir" 'authorize() { return 0; } # DEFECT_ACCEPTS_EVERYTHING round two' second-defect
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'one fix review should start after the first rejection and a new head'
  submit_fixture_review "$dir" 2 >/dev/null
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'second rejection should stop the lifecycle'
  assert_contains "$out" 'second rejection' 'circuit-breaker refusal did not name the terminal condition'
  assert_contains "$out" 're-scope' 'circuit-breaker refusal did not direct the scope or design back for reconsideration'
  assert_absent "$dir/home/state/task-a.independent-review.round-3" 'second rejection created a forbidden third review round'
  spawn_count=$(wc -l < "$dir/spawn.log" | tr -d ' ')
  [ "$spawn_count" = 2 ] || fail "circuit breaker spawned $spawn_count reviewers instead of exactly two"
  pass 'a second rejection opens the circuit instead of producing a third patch round'
}

test_reviewer_context_is_cold_on_both_rounds() {
  local dir rc brief_one brief_two criteria_one criteria_two diff_two
  dir=$(make_case cold-context codex gpt-5.6-sol 'authorize() { return 0; } # DEFECT_ACCEPTS_EVERYTHING')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'cold-context first review should start'
  brief_one=$(round_value "$dir" 1 brief)
  criteria_one=$(round_value "$dir" 1 criteria)
  assert_no_grep 'BUILDER_REASONING_SENTINEL' "$brief_one" 'reviewer received the builder summary'
  assert_no_grep 'BUILDER_REASONING_SENTINEL' "$criteria_one" 'cold criteria included the builder summary'
  assert_grep 'Every other value fails' "$criteria_one" 'cold criteria omitted the original acceptance criteria'
  assert_grep 'try to refute' "$brief_one" 'reviewer was not told to refute the change'
  assert_grep 'correctness, security, privacy, data loss, or unmet acceptance criteria' "$brief_one" \
    'reviewer did not receive the named blocking risk boundary'
  submit_fixture_review "$dir" 1 >/dev/null
  advance_pr_head "$dir" 'authorize() { [ "${1:-}" = allowed ]; } # fixed' fixed
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'cold-context fix review should start'
  brief_two=$(round_value "$dir" 2 brief)
  criteria_two=$(round_value "$dir" 2 criteria)
  diff_two=$(round_value "$dir" 2 diff)
  assert_no_grep 'BUILDER_REASONING_SENTINEL' "$brief_two" 'fix reviewer received the builder summary'
  assert_no_grep 'BUILDER_REASONING_SENTINEL' "$criteria_two" 'fix criteria included the builder summary'
  assert_no_grep 'authorization accepts every input' "$brief_two" 'fix reviewer received the prior reviewer verdict'
  assert_no_grep 'authorization accepts every input' "$criteria_two" 'fix criteria included the prior reviewer verdict'
  assert_no_grep 'authorization accepts every input' "$diff_two" 'fix diff included the prior reviewer verdict'
  pass 'each review round receives only the cold criteria and exact diff, never builder or prior-review reasoning'
}

test_unknown_builder_family_names_missing_fact() {
  local dir rc out
  dir=$(make_case unknown-family pi default 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'unknown builder family should refuse readiness'
  assert_contains "$out" 'harness=pi requires a recorded model with a verified provider family' \
    'unknown-family refusal did not name the missing recorded model fact'
  [ ! -s "$dir/spawn.log" ] || fail 'unknown builder family spawned a reviewer by guessing'
  pass 'an unresolved builder family refuses without guessing and identifies the missing fact'
}

test_draft_and_merged_prs_never_start_review() {
  local draft_dir merged_dir rc
  draft_dir=$(make_case draft-skip codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  merged_dir=$(make_case merged-skip codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  FM_TEST_PR_DRAFT=true run_review "$draft_dir" ready task-a https://github.com/example/repo/pull/1 > "$draft_dir/out" 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" 'draft PR should remain outside finished-PR review scope'
  assert_grep 'still a draft' "$draft_dir/out" 'draft refusal did not name the unfinished state'
  set +e
  FM_TEST_PR_STATE=MERGED run_review "$merged_dir" ready task-a https://github.com/example/repo/pull/1 > "$merged_dir/out" 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" 'merged PR should remain outside review scope'
  assert_grep 'already merged' "$merged_dir/out" 'merged refusal did not name the terminal state'
  [ ! -s "$draft_dir/spawn.log" ] || fail 'draft PR spawned an independent reviewer'
  [ ! -s "$merged_dir/spawn.log" ] || fail 'merged PR spawned an independent reviewer'
  pass 'independent review is scoped to finished open pull requests, never drafts or merged work'
}

test_work_in_progress_task_never_starts_review() {
  local dir rc out
  dir=$(make_case wip-skip codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  printf '%s\n' 'working: implementation still under way' > "$dir/home/state/task-a.status"
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'work-in-progress task should remain outside independent-review scope'
  assert_contains "$out" 'has not recorded a finished pull request' 'WIP refusal did not name the missing finished signal'
  [ ! -s "$dir/spawn.log" ] || fail 'work-in-progress task spawned an independent reviewer'
  pass 'independent review never starts for work in progress without its finished-PR signal'
}

test_gitlab_finished_merge_request_binds_exact_head() {
  local dir rc expected
  dir=$(make_case gitlab-exact-head codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  convert_case_to_gitlab "$dir"
  expected=$(git --git-dir="$dir/remote.git" rev-parse refs/merge-requests/1/head)
  set +e
  run_review "$dir" ready task-a https://gitlab.example/group/repo/-/merge_requests/1 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 3 "$rc" "GitLab merge request should start a cold review: $(cat "$dir/err")"
  [ "$(round_value "$dir" 1 head)" = "$expected" ] || fail 'GitLab review round did not bind the exact merge-request head'
  submit_fixture_review "$dir" 1 >/dev/null
  run_review "$dir" ready task-a https://gitlab.example/group/repo/-/merge_requests/1 >/dev/null \
    || fail 'GitLab merge request did not pass after its exact-head clear verdict'
  pass 'a finished GitLab merge request uses the same exact-head independent-review boundary'
}

test_fenced_hash_comment_never_truncates_criteria() {
  local dir rc criteria
  dir=$(make_case fenced-criteria codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  cat > "$dir/home/data/task-a/brief.md" <<'EOF'
You are a builder.

# Task
Reject every authorization request except the literal value `allowed`.

Reproduce it with:

```sh
# Setup
authorize allowed
```

## Acceptance criteria

- `allowed` succeeds.
- Every other value fails.
- CRITERIA_TAIL_SENTINEL: no caller can bypass the check.

# Builder summary
BUILDER_REASONING_SENTINEL: trust me, the implementation is correct.

# Definition of done
Open a pull request.
EOF
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'fenced-criteria fixture should start its cold review'
  criteria=$(round_value "$dir" 1 criteria)
  assert_grep 'CRITERIA_TAIL_SENTINEL' "$criteria" \
    'a fenced shell comment silently truncated the acceptance criteria the gate exists to check'
  assert_no_grep 'BUILDER_REASONING_SENTINEL' "$criteria" \
    'criteria extraction ran past the task section into builder reasoning'
  pass 'a fenced shell comment inside the task section never truncates the cold acceptance criteria'
}

test_reviewer_that_never_launched_is_retired_and_redispatched() {
  local dir rc out
  dir=$(make_case launch-failure codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  cat > "$dir/root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/root/bin/fm-spawn.sh"
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a failed reviewer launch should refuse readiness'
  assert_contains "$out" 'launch failed' 'failed launch refusal did not name the launch failure'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'a reviewer that never launched left a review round that can never produce a verdict'
  write_spawn_mock "$dir/root"
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'readiness stayed wedged after a reviewer launch failure'
  [ -n "$(round_value "$dir" 1 reviewer_task)" ] \
    || fail 're-dispatch did not record a fresh first-round reviewer'
  assert_absent "$dir/home/state/task-a.independent-review.round-2" \
    'a failed launch consumed one of the two permitted review rounds'
  pass 'a reviewer that never launched is retired so the next readiness call re-dispatches its round'
}

test_pr_check_is_structurally_blocked_without_clear_verdict() {
  local dir rc out
  dir=$(make_case pr-check-blocked codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  rm -f "$dir/fakebin/claude" "$dir/fakebin/codex"
  set +e
  out=$(FM_INDEPENDENT_REVIEW_CANDIDATES='claude|default|high' \
    run_pr_check "$dir" task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'fm-pr-check reported an unreviewed pull request as ready'
  assert_contains "$out" 'could not establish an available verified different-family reviewer' \
    'fm-pr-check did not expose the independent-review refusal'
  assert_absent "$dir/home/state/task-a.check.sh" 'fm-pr-check armed a ready poll without a clear independent verdict'
  pass 'the real PR readiness entry point cannot report or arm an unreviewed pull request'
}

test_pr_check_quarantines_legacy_poll_before_pending_review() {
  local dir rc quarantined
  dir=$(make_case pr-check-migrates-first codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  printf '%s\n' 'legacy executable bytes' > "$dir/home/state/legacy-task.check.sh"
  chmod 0700 "$dir/home/state/legacy-task.check.sh"
  cat > "$dir/root/bin/fm-independent-review.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'independent review pending: fixture' >&2
exit 3
SH
  chmod +x "$dir/root/bin/fm-independent-review.sh"
  set +e
  run_pr_check "$dir" task-a https://github.com/example/repo/pull/1 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 3 "$rc" 'pending independent review should remain not ready'
  assert_absent "$dir/home/state/legacy-task.check.sh" \
    'pending independent review left an unsafe legacy ready poll armed'
  quarantined=$(find "$dir/home/state/.pr-check-quarantine" -name 'legacy-task.check.*' -type f -print 2>/dev/null | head -1)
  [ -n "$quarantined" ] || fail 'legacy poll was removed without private quarantine evidence'
  pass 'legacy ready polls are neutralized before a pending independent review can wait'
}

test_pr_check_leads_with_traveling_clear_verdict() {
  local dir rc out
  dir=$(make_case pr-check-cleared codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'PR-check clear fixture should start independent review'
  submit_fixture_review "$dir" 1 >/dev/null
  out=$(run_pr_check "$dir" task-a https://github.com/example/repo/pull/1) \
    || fail 'fm-pr-check refused a current independently cleared head'
  [ "${out%%$'\n'*}" != "$out" ] || fail 'fm-pr-check output omitted either the verdict or armed result'
  assert_contains "${out%%$'\n'*}" 'Independent review:' 'fm-pr-check did not lead with the traveling verdict line'
  assert_grep 'pr_head=' "$dir/home/state/task-a.meta" 'fm-pr-check did not record the reviewed exact head'
  assert_present "$dir/home/state/task-a.check.sh" 'fm-pr-check did not arm the merge poll after independent clearance'
  pass 'the PR readiness entry point leads with the reviewer identity and finding after exact-head clearance'
}

test_codex_builder_selects_different_family
test_claude_builder_selects_different_family
test_pi_family_comes_from_recorded_model
test_defective_pr_is_rejected
test_sound_pr_passes_and_binds_exact_head
test_verdict_text_refuses_terminal_control_bytes
test_stale_verdict_does_not_clear_new_head
test_missing_different_family_refuses_loudly
test_selection_considers_each_available_verified_fixed_family
test_second_rejection_opens_circuit
test_reviewer_context_is_cold_on_both_rounds
test_unknown_builder_family_names_missing_fact
test_draft_and_merged_prs_never_start_review
test_work_in_progress_task_never_starts_review
test_gitlab_finished_merge_request_binds_exact_head
test_fenced_hash_comment_never_truncates_criteria
test_reviewer_that_never_launched_is_retired_and_redispatched
test_pr_check_is_structurally_blocked_without_clear_verdict
test_pr_check_quarantines_legacy_poll_before_pending_review
test_pr_check_leads_with_traveling_clear_verdict
