#!/usr/bin/env bash
# Behavioral tests for the different-family independent review readiness gate.
# shellcheck disable=SC2016 # Literal shell expressions are fixture source code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW="$ROOT/bin/fm-independent-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-independent-review)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

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

# Definition of done
Open a pull request.
BUILDER_REASONING_SENTINEL: trust me, the implementation is correct.
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

  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'pr view')
    if [ -n "${FM_TEST_PR_VIEW_ENTERED:-}" ]; then
      : > "$FM_TEST_PR_VIEW_ENTERED"
      while [ ! -e "$FM_TEST_PR_VIEW_RELEASE" ]; do sleep 0.02; done
    fi
    head=$(git --git-dir="$FM_TEST_REMOTE" rev-parse refs/pull/1/head)
    printf '%s\t%s\t%s\t%s\n' \
      "${FM_TEST_PR_STATE:-OPEN}" "${FM_TEST_PR_DRAFT:-false}" "$head" "${FM_TEST_PR_BASE-main}"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'pr view') git --git-dir="$FM_TEST_REMOTE" rev-parse refs/pull/1/head ;;
  *) exit 1 ;;
esac
SH
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
if [ "${FM_TEST_SPAWN_FAIL:-0}" = 1 ]; then
  exit 1
fi
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
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake_root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_CREW_STATE_LINE:-state: done · source: status-log · PR ready}"
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
  chmod +x "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/claude" "$fakebin/codex" \
    "$fake_root/bin/fm-spawn.sh" "$fake_root/bin/fm-guard.sh" "$fake_root/bin/fm-crew-state.sh" \
    "$fake_root/bin/fm-independent-review.sh"
  : > "$dir/spawn.log"
  printf '%s\n' "$dir"
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
  round_value_for "$dir" task-a "$round" "$key"
}

round_value_for() {
  local dir=$1 id=$2 round=$3 key=$4
  sed -n "s/^$key=//p" "$dir/home/state/$id.independent-review.round-$round" | tail -1
}

rename_case_task() {
  local dir=$1 id=$2
  mv "$dir/home/data/task-a" "$dir/home/data/$id"
  mv "$dir/home/state/task-a.meta" "$dir/home/state/$id.meta"
  mv "$dir/home/state/task-a.status" "$dir/home/state/$id.status"
  sed -i "s/^endpoint_task_id=.*/endpoint_task_id=$id/" "$dir/home/state/$id.meta"
}

# Record a reviewer result the way the generated brief prescribes: submit the
# bounded deliverable, then complete the supervised scout path that promotes it.
submit_fixture_review() {
  local dir=$1 round=$2 verdict summary reviewer head diff
  reviewer=$(round_value "$dir" "$round" reviewer_task)
  head=$(round_value "$dir" "$round" head)
  diff=$(round_value "$dir" "$round" diff)
  if grep -F 'DEFECT_ACCEPTS_EVERYTHING' "$diff" >/dev/null; then
    verdict=reject
    summary='authorization accepts every input'
    run_review "$dir" submit task-a "$reviewer" "$head" "$verdict" "$summary" \
      --block correctness 'authorize.sh returns success for unauthorized values' || return 1
  else
    verdict=clear
    summary='no blocking findings'
    run_review "$dir" submit task-a "$reviewer" "$head" "$verdict" "$summary" || return 1
  fi
  complete_fixture_review "$dir" "$reviewer" "$head" "$verdict"
}

# The supervised half: the decision-hold completion attestation fm-decision-hold
# writes into the reviewer's metadata, and the exact done line the brief names.
complete_fixture_review() {
  local dir=$1 reviewer=$2 head=$3 verdict=$4
  printf 'decisions_reviewed=1\n' >> "$dir/home/state/$reviewer.meta"
  printf 'done: independent review %s for task-a at %s\n' "$verdict" "$head" \
    >> "$dir/home/state/$reviewer.status"
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
    printf '{"state":"opened","draft":false,"sha":"%s","target_branch":"%s"}\n' \
      "$head" "${FM_TEST_PR_BASE-main}"
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

test_muse_builder_uses_meta_family() {
  local dir rc
  dir=$(make_case muse-builder muse default 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a Muse-built task should start a cold review'
  [ "$(round_value "$dir" 1 builder_family)" = meta ] \
    || fail 'Muse did not resolve to its verified Meta provider family'
  pass 'a Muse-built task resolves its fixed provider family and starts review'
}

test_cursor_builder_family_is_derived_and_fail_closed() {
  local routed default unknown rc out reviewer_family
  routed=$(make_case cursor-grok-builder cursor cursor-grok-4.5-high 'authorize() { [ "${1:-}" = allowed ]; }')
  default=$(make_case cursor-default-builder cursor default 'authorize() { [ "${1:-}" = allowed ]; }')
  unknown=$(make_case cursor-unknown-builder cursor cursor-claude-unverified 'authorize() { [ "${1:-}" = allowed ]; }')

  set +e
  run_review "$routed" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a Cursor-routed Grok task should start a cold review'
  [ "$(round_value "$routed" 1 builder_family)" = xai ] \
    || fail 'Cursor Grok did not resolve to the routed xAI family'
  reviewer_family=$(round_value "$routed" 1 reviewer_family)
  [ -n "$reviewer_family" ] && [ "$reviewer_family" != xai ] \
    || fail 'Cursor Grok selected a same-family xAI reviewer'

  set +e
  out=$(run_review "$default" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'Cursor with no recorded routed model should refuse readiness'
  assert_contains "$out" 'harness=cursor requires a recorded model with a verified provider family' \
    'Cursor default refusal did not name the missing recorded model fact'
  [ ! -s "$default/spawn.log" ] || fail 'Cursor default guessed a family and spawned a reviewer'

  set +e
  out=$(run_review "$unknown" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'an unknown Cursor model should refuse readiness'
  assert_contains "$out" 'has no verified provider-family mapping' \
    'unknown Cursor model refusal did not name the absent mapping'
  [ ! -s "$unknown/spawn.log" ] || fail 'unknown Cursor model guessed a family and spawned a reviewer'
  pass 'Cursor derives only verified routed families and refuses unknown models'
}

test_defective_pr_is_rejected() {
  local dir rc out reviewer head first_line
  dir=$(make_case defective-rejected codex gpt-5.6-sol 'authorize() { return 0; } # DEFECT_ACCEPTS_EVERYTHING')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'defective PR should enter review before it can be ready'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  head=$(round_value "$dir" 1 head)
  submit_fixture_review "$dir" 1 >/dev/null
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'defective PR should be rejected by the readiness gate'
  first_line=${out%%$'\n'*}
  assert_contains "$first_line" "$reviewer" 'rejection lead did not name the reviewer task'
  assert_contains "$first_line" "$head" 'rejection lead did not name the reviewed head'
  assert_contains "$first_line" 'authorization accepts every input' 'rejection lead did not name the finding summary'
  assert_contains "$out" 'correctness' 'defective PR rejection did not carry the blocking risk category'
  assert_contains "$out" 'authorize.sh returns success for unauthorized values' 'defective PR rejection lost the concrete finding'
  pass 'a deliberately defective pull request is rejected with its concrete blocking finding'
}

test_sound_pr_passes_and_binds_exact_head() {
  local dir rc out reviewed_head current_head reviewer head_file bash_env
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
  head_file="$dir/reviewed-head"
  bash_env="$dir/fail-head-printf.sh"
  : > "$head_file"
  cat > "$bash_env" <<'SH'
printf() {
  if [ "${1:-}" = '%s\n' ] && [ "${2:-}" = "${FM_TEST_FAIL_HEAD_PRINTF:-}" ]; then
    return 1
  fi
  builtin printf "$@"
}
SH
  set +e
  out=$(BASH_ENV="$bash_env" FM_TEST_FAIL_HEAD_PRINTF="$current_head" \
    run_review "$dir" ready task-a https://github.com/example/repo/pull/1 \
      --head-file "$head_file" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a failed reviewed-head write must refuse readiness'
  assert_contains "$out" 'could not publish the reviewed head binding' \
    'reviewed-head write failure did not name the failed binding publication'
  [ ! -s "$head_file" ] || fail 'failed reviewed-head publication wrote a binding'
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
  assert_absent "$dir/home/data/$reviewer/independent-review-verdict" \
    'rejected control-byte verdict reached the reviewer deliverable'
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

test_base_advance_invalidates_reviewed_diff() {
  local dir rc base_commit head_before head_after spawn_count
  dir=$(make_case base-advance-invalidates-diff codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  base_commit=$(git --git-dir="$dir/remote.git" rev-parse refs/pull/1/head)
  advance_pr_head "$dir" 'authorize() { [ "${1:-}" = allowed ]; } # final change' final-change
  head_before=$(git --git-dir="$dir/remote.git" rev-parse refs/pull/1/head)
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'base-advance fixture should start its first review'
  submit_fixture_review "$dir" 1 >/dev/null
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null \
    || fail 'unchanged base and head did not clear their exact reviewed diff'
  git --git-dir="$dir/remote.git" update-ref refs/heads/main "$base_commit"
  head_after=$(git --git-dir="$dir/remote.git" rev-parse refs/pull/1/head)
  [ "$head_after" = "$head_before" ] || fail 'base-advance fixture moved the pull request head'
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a changed base-dependent diff should consume the fresh review round'
  [ "$(round_value "$dir" 2 head)" = "$head_before" ] \
    || fail 'base-dependent diff change did not preserve the unchanged pull request head'
  [ "$(round_value "$dir" 2 base)" = main ] \
    || fail 'base-dependent diff change altered the target branch name'
  spawn_count=$(wc -l < "$dir/spawn.log" | tr -d ' ')
  [ "$spawn_count" = 2 ] || fail "base-dependent diff change spawned $spawn_count reviewers instead of two"
  pass 'advancing the named base invalidates a verdict when the exact diff changes'
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

test_current_finished_state_and_delivery_mode_are_required() {
  local stale nongreen no_mistakes direct rc out
  stale=$(make_case stale-finished-state codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  nongreen=$(make_case nongreen-finished-state codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  no_mistakes=$(make_case current-no-mistakes codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  direct=$(make_case current-direct-pr codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')

  set +e
  out=$(FM_TEST_CREW_STATE_LINE='state: working · source: run-step · validating (fixing)' \
    run_review "$stale" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a historical green event must not authorize a currently working task'
  assert_contains "$out" 'current state' 'stale finished-state refusal did not name current state'
  [ ! -s "$stale/spawn.log" ] || fail 'a stale finished event spawned a reviewer while the task was working'

  printf '%s\n' 'done: PR https://github.com/example/repo/pull/1' > "$nongreen/home/state/task-a.status"
  set +e
  out=$(run_review "$nongreen" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'no-mistakes completion without checks green must refuse readiness'
  assert_contains "$out" 'required mode=no-mistakes form' \
    'no-mistakes refusal did not name its mode-specific finished form'
  [ ! -s "$nongreen/spawn.log" ] || fail 'non-green no-mistakes completion spawned a reviewer'

  set +e
  run_review "$no_mistakes" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a currently green no-mistakes task should start review'

  sed -i 's/^mode=.*/mode=direct-PR/' "$direct/home/state/task-a.meta"
  printf '%s\n' 'done: PR https://github.com/example/repo/pull/1' > "$direct/home/state/task-a.status"
  set +e
  run_review "$direct" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a currently finished direct-PR task should start review'
  pass 'readiness requires current, mode-specific pull-request completion'
}

test_finished_pr_requires_exact_url_token() {
  local dir rc out
  dir=$(make_case finished-pr-exact-url codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  printf '%s\n' 'done: PR https://github.com/example/repo/pull/10 checks green' \
    > "$dir/home/state/task-a.status"
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a longer pull-request number must not satisfy a shorter URL'
  assert_contains "$out" 'has not recorded a finished pull request' \
    'wrong-URL refusal did not name the missing finished pull request'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'a longer pull-request URL started an independent review for a shorter URL'
  [ ! -s "$dir/spawn.log" ] || fail 'a longer pull-request URL spawned a reviewer for a shorter URL'

  printf '%s\n' 'done [key=delivery]: PR https://github.com/example/repo/pull/1 checks green' \
    > "$dir/home/state/task-a.status"
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'an exact keyed finished-PR URL should start independent review'
  pass 'finished pull-request status requires an exact URL token'
}

test_non_default_target_base_bounds_diff() {
  local dir rc diff
  dir=$(make_case non-default-base codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  git -C "$dir/wt" checkout -q -B release origin/main
  printf '%s\n' 'RELEASE_BASE_SENTINEL' > "$dir/wt/release-base.txt"
  git -C "$dir/wt" add release-base.txt
  git -C "$dir/wt" commit -qm release-base
  git -C "$dir/wt" push -q origin HEAD:refs/heads/release
  git -C "$dir/wt" checkout -q -B feature
  printf '%s\n' 'authorize() { [ "${1:-}" = allowed ]; }' > "$dir/wt/authorize.sh"
  git -C "$dir/wt" add authorize.sh
  git -C "$dir/wt" commit -qm feature-on-release
  git -C "$dir/wt" push -q --force origin HEAD:refs/pull/1/head

  set +e
  FM_TEST_PR_BASE=release run_review "$dir" ready task-a https://github.com/example/repo/pull/1 \
    >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a non-default target branch should start its bounded review'
  [ "$(round_value "$dir" 1 base)" = release ] \
    || fail 'the review round did not record its non-default target base'
  diff=$(round_value "$dir" 1 diff)
  assert_grep 'authorize.sh' "$diff" 'the target-relative bundle omitted the pull-request change'
  assert_no_grep 'RELEASE_BASE_SENTINEL' "$diff" \
    'the bundle diff used the default branch instead of the pull-request target'
  pass 'the review bundle is diffed against its recorded target branch'
}

test_missing_target_base_refuses_review() {
  local dir rc out
  dir=$(make_case missing-target-base codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  out=$(FM_TEST_PR_BASE='' run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a forge response without a target base must refuse readiness'
  assert_contains "$out" 'target base branch' 'missing-base refusal did not name the missing forge fact'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'a missing target base recorded an independent review round'
  [ ! -s "$dir/spawn.log" ] || fail 'a missing target base spawned an independent reviewer'
  pass 'a missing forge target base refuses before review starts'
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

test_submitted_result_alone_never_clears_a_head() {
  local dir rc out reviewer head
  dir=$(make_case submit-without-completion codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'submit-only fixture should start its cold review'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  head=$(round_value "$dir" 1 head)
  run_review "$dir" submit task-a "$reviewer" "$head" clear 'no blocking findings' >/dev/null \
    || fail 'reviewer could not record its own bounded deliverable'
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" 'a recorded result without supervised completion must not clear the head'
  assert_contains "$out" 'has not completed its supervised review' \
    'pending report did not name the missing supervised completion'
  assert_absent "$dir/home/state/task-a.independent-review.verdict" \
    'an unsupervised result was promoted to the task verdict'
  complete_fixture_review "$dir" "$reviewer" "$head" clear
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null \
    || fail 'the same result did not clear once its supervised completion landed'
  pass 'a recorded result clears a head only after the reviewer completes the supervised path'
}

test_promotion_storage_failure_is_reported() {
  local dir rc out reviewer head verdict
  dir=$(make_case promotion-storage-failure codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'promotion storage fixture should start its cold review'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  head=$(round_value "$dir" 1 head)
  run_review "$dir" submit task-a "$reviewer" "$head" clear 'no blocking findings' >/dev/null \
    || fail 'promotion storage fixture could not record its reviewer result'
  complete_fixture_review "$dir" "$reviewer" "$head" clear
  verdict="$dir/home/state/task-a.independent-review.verdict"
  ln -s "$dir/unwritable-verdict-target" "$verdict"
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a promoted verdict storage failure must refuse readiness'
  assert_contains "$out" 'could not store promoted independent review verdict for round 1' \
    'promotion storage failure did not report the failed durable write'
  assert_not_contains "$out" 'has not completed its supervised review' \
    'promotion storage failure was misreported as missing supervised completion'
  [ -L "$verdict" ] || fail 'promotion storage failure replaced the refusing destination'
  pass 'verdict promotion reports storage failure separately from incomplete review'
}

test_abandoned_unpromoted_submission_can_retire() {
  local dir rc reviewer head spawn_count
  dir=$(make_case abandoned-submission codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'abandoned-submission fixture should start its cold review'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  head=$(round_value "$dir" 1 head)
  run_review "$dir" submit task-a "$reviewer" "$head" clear 'no blocking findings' >/dev/null \
    || fail 'abandoned reviewer could not record its bounded proposal'
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'an unpromoted proposal must remain pending before retirement'
  run_review "$dir" retire-failed task-a 1 >/dev/null \
    || fail 'an abandoned unpromoted proposal could not be retired'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'abandoned proposal retirement retained the round record'
  assert_absent "$dir/home/state/task-a.independent-review.bundle-1" \
    'abandoned proposal retirement retained the bounded bundle'
  assert_absent "$dir/home/data/$reviewer" \
    'abandoned proposal retirement retained reviewer data and proposal'
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'retiring an abandoned proposal should launch a fresh reviewer'
  spawn_count=$(wc -l < "$dir/spawn.log" | tr -d ' ')
  [ "$spawn_count" = 2 ] || fail "abandoned-proposal retry attempted $spawn_count launches instead of two"
  pass 'an abandoned unpromoted proposal can retire and retry'
}

test_reviewer_attestation_must_name_the_submitted_verdict() {
  local dir rc reviewer head
  dir=$(make_case attestation-mismatch codex gpt-5.6-sol 'authorize() { return 0; } # DEFECT_ACCEPTS_EVERYTHING')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'attestation fixture should start its cold review'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  head=$(round_value "$dir" 1 head)
  run_review "$dir" submit task-a "$reviewer" "$head" reject 'authorization accepts every input' \
    --block correctness 'authorize.sh returns success for unauthorized values' >/dev/null \
    || fail 'reviewer could not record its rejection'
  complete_fixture_review "$dir" "$reviewer" "$head" clear
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a completion line naming another verdict must not promote the result'
  assert_absent "$dir/home/state/task-a.independent-review.verdict" \
    'a mismatched attestation promoted a result the reviewer never attested to'
  pass 'promotion requires the completion line to name the same verdict the reviewer submitted'
}

test_generated_herdr_terminators_start_review() {
  local scout_dir ship_dir rc criteria
  scout_dir=$(make_case herdr-isolation-scout codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  cat > "$scout_dir/home/data/task-a/brief.md" <<'EOF'
You are a builder.

# Task
Reject every authorization request except the literal value `allowed`.

# Herdr isolation - HARD SAFETY CONTRACT
Use the isolated Herdr laboratory.

# Setup
This is a scout brief.

# Rules
Do not push.

# Definition of done
Write the report.
EOF
  set +e
  run_review "$scout_dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'the Herdr isolation scout brief should start a cold review'
  criteria=$(round_value "$scout_dir" 1 criteria)
  assert_grep 'Reject every authorization request' "$criteria" \
    'the Herdr isolation scout brief lost its task criteria'
  assert_no_grep 'Herdr isolation' "$criteria" \
    'the Herdr isolation heading leaked scaffold text into task criteria'

  ship_dir=$(make_case herdr-lifecycle-ship codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  {
    cat <<'EOF'
You are a builder.

# Task
Reject every authorization request except the literal value `allowed`.

EOF
    printf '# Herdr lifecycle declaration - NOT ENABLED \t\n'
    cat <<'EOF'
Regenerate the brief before Herdr lifecycle work.

# Setup
This is a ship brief.

# Rules
Never merge the pull request.

# Project memory
Keep durable facts only.

# Definition of done
Open a pull request.
EOF
  } > "$ship_dir/home/data/task-a/brief.md"
  set +e
  run_review "$ship_dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'the Herdr lifecycle ship brief should start a cold review'
  criteria=$(round_value "$ship_dir" 1 criteria)
  assert_grep 'Reject every authorization request' "$criteria" \
    'the Herdr lifecycle ship brief lost its task criteria'
  assert_no_grep 'Herdr lifecycle declaration' "$criteria" \
    'the Herdr lifecycle heading leaked scaffold text into task criteria'
  pass 'both generated Herdr brief shapes terminate criteria and start review'
}

test_near_miss_task_heading_refuses_criteria() {
  local dir rc out
  dir=$(make_case near-miss-heading codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  cat > "$dir/home/data/task-a/brief.md" <<'EOF'
You are a builder.

# Task
Reject every authorization request except the literal value `allowed`.

# Setup notes
BUILDER_REASONING_SENTINEL: trust me, the implementation is correct.

# Definition of done
Open a pull request.
EOF
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a near-miss generated heading must refuse rather than truncate criteria'
  assert_contains "$out" '# Setup notes' 'criteria refusal did not name the exact near-miss heading'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'near-miss criteria refusal recorded a review round'
  [ ! -s "$dir/spawn.log" ] || fail 'near-miss criteria refusal spawned a reviewer'
  pass 'a near-miss generated heading refuses without recording or spawning'
}

test_unterminated_task_section_refuses_criteria() {
  local dir rc out
  dir=$(make_case unterminated-task codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  printf '%s\n' 'You are a builder.' '' '# Task' \
    'Reject every authorization request except the literal value `allowed`.' \
    > "$dir/home/data/task-a/brief.md"
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a Task section reaching EOF without a generated terminator must refuse'
  assert_contains "$out" 'reach EOF without a recognized generated terminator' \
    'unterminated Task refusal did not name the malformed brief boundary'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'unterminated Task criteria recorded a review round'
  [ ! -s "$dir/spawn.log" ] || fail 'unterminated Task criteria spawned a reviewer'
  pass 'an unterminated Task section refuses before review starts'
}

test_failed_round_retirement_allows_retry() {
  local dir rc out reviewer retry_reviewer spawn_count
  dir=$(make_case failed-round-retry codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  out=$(FM_TEST_SPAWN_FAIL=1 run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a reviewer launch failure should refuse readiness'
  assert_contains "$out" 'retire-failed task-a 1' \
    'launch failure did not name the supported failed-round retirement path'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  assert_present "$dir/home/state/task-a.independent-review.bundle-1" \
    'launch failure did not retain the bounded review bundle'
  assert_present "$dir/home/data/$reviewer/brief.md" \
    'launch failure did not retain the generated reviewer brief'
  run_review "$dir" retire-failed task-a 1 >/dev/null \
    || fail 'supported retirement could not retire a failed launch round'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'failed-round retirement retained the round record'
  assert_absent "$dir/home/state/task-a.independent-review.bundle-1" \
    'failed-round retirement retained the bounded bundle'
  assert_absent "$dir/home/data/$reviewer" \
    'failed-round retirement retained generated reviewer data'
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a retired failed round should launch a fresh cold reviewer'
  retry_reviewer=$(round_value "$dir" 1 reviewer_task)
  [ "$retry_reviewer" = "$reviewer" ] \
    || fail 'the same parent, round, and head derived a different reviewer id on retry'
  spawn_count=$(wc -l < "$dir/spawn.log" | tr -d ' ')
  [ "$spawn_count" = 2 ] || fail "failed-round retry attempted $spawn_count launches instead of two"
  pass 'failed-round retirement removes its artifacts and permits a fresh launch'
}

test_unrecorded_bundle_publication_recovers_on_retry() {
  local dir rc reviewer
  dir=$(make_case orphaned-bundle codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'owned recovery fixture should publish its first round'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  printf '%s\n' stranded > "$dir/home/data/$reviewer/interrupted"
  rm "$dir/home/state/task-a.independent-review.round-1"
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'a retry should recover an unrecorded published bundle and start review'
  assert_present "$dir/home/state/task-a.independent-review.round-1" \
    'orphaned-bundle recovery did not publish recoverable round state'
  assert_absent "$dir/home/data/$reviewer/interrupted" \
    'owned reviewer-data recovery retained the interrupted artifact'
  [ "$(wc -l < "$dir/spawn.log" | tr -d ' ')" = 2 ] \
    || fail 'orphaned-bundle recovery launched an unexpected number of reviewers'
  pass 'owned interrupted round artifacts recover idempotently on retry'
}

test_reviewer_directory_publication_is_atomic() {
  local dir rc reviewer
  dir=$(make_case atomic-reviewer-publication codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
case "$last" in
  "$FM_TEST_REVIEW_PUBLISH_PARENT"/ir-*)
    kill -TERM "$PPID"
    exit 1
    ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$dir/fakebin/mv"
  set +e
  FM_TEST_REVIEW_PUBLISH_PARENT="$dir/home/data" \
    run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" 'interruption before reviewer publication should refuse readiness'
  [ -z "$(find "$dir/home/data" -mindepth 1 -maxdepth 1 -type d -name 'ir-*' -print -quit)" ] \
    || fail 'interruption exposed a final reviewer directory before its ownership marker'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'interrupted reviewer publication recorded a review round'
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'retry after interrupted reviewer publication should start review'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  assert_present "$dir/home/data/$reviewer/.firstmate-independent-review-owner" \
    'published reviewer directory did not carry its ownership marker'
  pass 'reviewer data publishes atomically with its ownership marker'
}

test_recovery_refuses_mismatched_reviewer_data_ownership() {
  local dir rc out reviewer marker owner
  dir=$(make_case mismatched-review-owner codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'mismatched-owner fixture should publish its first round'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  marker="$dir/home/data/$reviewer/keep-me"
  owner="$dir/home/data/$reviewer/.firstmate-independent-review-owner"
  printf '%s\n' unrelated > "$marker"
  sed -i 's/^task=.*/task=another-task/' "$owner"
  rm "$dir/home/state/task-a.independent-review.round-1"
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'mismatched reviewer-data ownership must refuse recovery'
  assert_contains "$out" 'without their ownership binding' \
    'mismatched reviewer-data refusal did not name the missing ownership proof'
  assert_present "$marker" 'mismatched reviewer-data ownership was deleted'
  [ "$(wc -l < "$dir/spawn.log" | tr -d ' ')" = 1 ] \
    || fail 'mismatched reviewer-data ownership launched another reviewer'
  pass 'recovery refuses to delete reviewer data owned by another task'
}

test_long_parent_prefixes_derive_distinct_reviewer_ids() {
  local dir id_one id_two rc reviewer_one reviewer_two prefix
  prefix=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  id_one=${prefix}-one
  id_two=${prefix}-two
  dir=$(make_case long-parent-prefixes codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  rename_case_task "$dir" "$id_one"
  cp -R "$dir/home/data/$id_one" "$dir/home/data/$id_two"
  cp "$dir/home/state/$id_one.meta" "$dir/home/state/$id_two.meta"
  cp "$dir/home/state/$id_one.status" "$dir/home/state/$id_two.status"
  sed -i "s/^endpoint_task_id=.*/endpoint_task_id=$id_two/" "$dir/home/state/$id_two.meta"
  set +e
  run_review "$dir" ready "$id_one" https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'first long-prefix parent should start review'
  set +e
  run_review "$dir" ready "$id_two" https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'second long-prefix parent should start review'
  reviewer_one=$(round_value_for "$dir" "$id_one" 1 reviewer_task)
  reviewer_two=$(round_value_for "$dir" "$id_two" 1 reviewer_task)
  [ -n "$reviewer_one" ] && [ -n "$reviewer_two" ] && [ "$reviewer_one" != "$reviewer_two" ] \
    || fail 'distinct full parent task ids derived the same reviewer id'
  [ "${#reviewer_one}" -le 64 ] && [ "${#reviewer_two}" -le 64 ] \
    || fail 'collision-resistant reviewer id exceeded the task-id limit'
  pass 'full parent identities derive distinct bounded reviewer ids'
}

test_failed_digest_refuses_reviewer_id_derivation() {
  local dir rc out
  dir=$(make_case failed-review-id-digest codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  cat > "$dir/fakebin/shasum" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/shasum"
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a failed digest command must refuse reviewer id derivation'
  assert_contains "$out" 'could not derive a safe reviewer task id' \
    'digest failure did not name reviewer id derivation'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'digest failure recorded an independent review round'
  [ ! -s "$dir/spawn.log" ] || fail 'digest failure spawned a reviewer with a malformed id'
  pass 'reviewer id derivation refuses an empty successful hash pipeline result'
}

test_launching_round_can_retire_and_retry() {
  local dir rc
  dir=$(make_case interrupted-launch codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'interrupted-launch fixture should publish its round'
  printf '%s\n' 'status=launching' >> "$dir/home/state/task-a.independent-review.round-1"
  run_review "$dir" retire-failed task-a 1 >/dev/null \
    || fail 'a round interrupted while launching could not be retired'
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'retiring an interrupted launch should permit a fresh review'
  [ "$(wc -l < "$dir/spawn.log" | tr -d ' ')" = 2 ] \
    || fail 'interrupted-launch recovery did not attempt exactly two launches'
  pass 'a launching round can retire transactionally and retry'
}

test_promoted_round_cannot_be_retired() {
  local dir rc out reviewer
  dir=$(make_case promoted-round-retirement codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'promoted-round fixture should start its cold review'
  reviewer=$(round_value "$dir" 1 reviewer_task)
  submit_fixture_review "$dir" 1 >/dev/null
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null \
    || fail 'promoted-round fixture did not promote its verdict'
  set +e
  out=$(run_review "$dir" retire-failed task-a 1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'a promoted review round must refuse retirement'
  assert_contains "$out" 'has a promoted verdict and cannot be retired' \
    'promoted-round retirement refusal did not name the consumed verdict'
  assert_present "$dir/home/state/task-a.independent-review.round-1" \
    'promoted-round retirement removed consumed round history'
  assert_present "$dir/home/state/task-a.independent-review.bundle-1" \
    'promoted-round retirement removed its bounded bundle'
  assert_present "$dir/home/data/$reviewer/brief.md" \
    'promoted-round retirement removed reviewer data'
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null \
    || fail 'retirement refusal damaged the promoted ready verdict'
  pass 'promoted verdict history cannot be retired or reset'
}

test_round_transitions_share_task_lock() {
  local dir rc out reviewer head ready_pid retire_pid ready_rc retire_rc attempts retired_before_release spawn_count
  dir=$(make_case serialized-round-transitions codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'serialized transition fixture should start its first review'
  submit_fixture_review "$dir" 1 >/dev/null
  (
    set +e
    FM_TEST_PR_VIEW_ENTERED="$dir/ready.entered" FM_TEST_PR_VIEW_RELEASE="$dir/ready.release" \
      run_review "$dir" ready task-a https://github.com/example/repo/pull/1 \
      > "$dir/ready.out" 2> "$dir/ready.err"
    printf '%s\n' "$?" > "$dir/ready.rc"
  ) &
  ready_pid=$!
  attempts=0
  while [ ! -e "$dir/ready.entered" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -le 100 ] || { touch "$dir/ready.release"; wait "$ready_pid"; fail 'ready never entered its locked promotion path'; }
    sleep 0.02
  done
  (
    set +e
    run_review "$dir" retire-failed task-a 1 > "$dir/retire.out" 2> "$dir/retire.err"
    printf '%s\n' "$?" > "$dir/retire.rc"
  ) &
  retire_pid=$!
  attempts=0
  while [ ! -e "$dir/retire.rc" ] && [ "$attempts" -lt 100 ]; do
    attempts=$((attempts + 1))
    sleep 0.02
  done
  retired_before_release=0
  [ ! -e "$dir/retire.rc" ] || retired_before_release=1
  touch "$dir/ready.release"
  wait "$ready_pid"
  wait "$retire_pid"
  ready_rc=$(cat "$dir/ready.rc")
  retire_rc=$(cat "$dir/retire.rc")
  [ "$retired_before_release" = 0 ] \
    || fail 'retire-failed passed the verdict check while ready held the review transition'
  expect_code 0 "$ready_rc" 'locked ready transition should promote the completed review'
  expect_code 1 "$retire_rc" 'retirement after locked promotion must refuse the consumed round'
  assert_present "$dir/home/state/task-a.independent-review.round-1" \
    'serialized retirement removed consumed round history'

  advance_pr_head "$dir" 'authorize() { [ "${1:-}" = allowed ]; } # second head' second-head
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'the one permitted fix round should start after serialized promotion'
  submit_fixture_review "$dir" 2 >/dev/null
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null \
    || fail 'the second serialized review did not promote'
  advance_pr_head "$dir" 'authorize() { [ "${1:-}" = allowed ]; } # third head' third-head
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'another head after two serialized rounds must open the circuit'
  assert_contains "$out" 'circuit is open' 'third-round refusal did not name the open circuit'
  spawn_count=$(wc -l < "$dir/spawn.log" | tr -d ' ')
  [ "$spawn_count" = 2 ] || fail "serialized circuit attempted $spawn_count reviewers instead of two"
  pass 'review transitions serialize promotion and preserve the two-round circuit breaker'
}

test_unrecognized_task_heading_refuses_criteria() {
  local dir rc out
  dir=$(make_case unknown-heading codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  cat > "$dir/home/data/task-a/brief.md" <<'EOF'
You are a builder.

# Task
Reject every authorization request except the literal value `allowed`.

# Builder summary
BUILDER_REASONING_SENTINEL: trust me, the implementation is correct.

# Definition of done
Open a pull request.
EOF
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'an unrecognized top-level heading must refuse rather than truncate the criteria'
  assert_contains "$out" 'unrecognized top-level heading' 'criteria refusal did not name what it could not classify'
  assert_contains "$out" '# Builder summary' 'criteria refusal did not name the exact offending line'
  assert_absent "$dir/home/state/task-a.independent-review.round-1" \
    'criteria refusal recorded a review round on truncated criteria'
  [ ! -s "$dir/spawn.log" ] || fail 'criteria refusal spawned a reviewer on truncated criteria'
  pass 'an unrecognized top-level heading refuses instead of silently truncating the criteria'
}

test_criteria_following_collision_looking_heading_are_preserved() {
  local dir rc criteria brief
  dir=$(make_case collision-preserved codex gpt-5.6-sol 'authorize() { [ "${1:-}" = allowed ]; }')
  cat > "$dir/home/data/task-a/brief.md" <<'EOF'
You are a builder.

# Task
Reject every authorization request except the literal value `allowed`.

## Acceptance criteria

Phase one setup:
# Setup
Configure the allowed token in the environment.

Phase two rules:
# Rules
1. Reject any request without an authorized token.

Phase three done:
# Definition of done
CRITERIA_AFTER_COLLISION_SENTINEL: every failure must log an audit event.

# Definition of done
Open a pull request.
BUILDER_REASONING_SENTINEL: trust me, the implementation is correct.
EOF

  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'review should start with criteria containing collision-looking headings'
  criteria=$(round_value "$dir" 1 criteria)
  brief=$(round_value "$dir" 1 brief)

  assert_grep 'CRITERIA_AFTER_COLLISION_SENTINEL' "$criteria" \
    'criteria following collision-looking heading were truncated'
  assert_grep 'Configure the allowed token in the environment' "$criteria" \
    'criteria under collision # Setup heading were omitted'
  assert_grep 'Reject any request without an authorized token' "$criteria" \
    'criteria under collision # Rules heading were omitted'
  assert_no_grep 'BUILDER_REASONING_SENTINEL' "$criteria" \
    'cold criteria included the builder summary after the real scaffold'
  assert_no_grep 'BUILDER_REASONING_SENTINEL' "$brief" \
    'reviewer brief included the builder summary after the real scaffold'

  pass 'a task whose criteria follow a collision-looking line keeps its criteria'
}

test_authorized_finding_is_never_dropped_by_gate() {
  local dir rc out reviewer head
  dir=$(make_case dropped-findings codex gpt-5.6-sol 'authorize() { return 0; } # DEFECT_ACCEPTS_EVERYTHING')

  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'round 1 should start'

  submit_fixture_review "$dir" 1 >/dev/null

  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'round 1 rejection should report not ready'
  assert_contains "$out" 'authorize.sh returns success for unauthorized values' \
    'round 1 rejection did not name the blocking finding'

  assert_present "$dir/home/state/task-a.independent-review.authorized-findings" \
    'authorized findings file was not created on rejection'
  assert_grep 'finding_1=authorize.sh returns success for unauthorized values' \
    "$dir/home/state/task-a.independent-review.authorized-findings" \
    'authorized finding was not recorded in state'

  advance_pr_head "$dir" 'authorize() { [ "${1:-}" = allowed ]; } # fixed' fixed
  set +e
  run_review "$dir" ready task-a https://github.com/example/repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" 'round 2 fix review should start'

  reviewer=$(round_value "$dir" 2 reviewer_task)
  head=$(round_value "$dir" 2 head)
  run_review "$dir" submit task-a "$reviewer" "$head" clear 'diff looks fine to me' >/dev/null
  complete_fixture_review "$dir" "$reviewer" "$head" clear

  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 --head-file "$dir/home/state/reviewed-head" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'gate must not clear while an authorized finding is unresolved'
  assert_contains "$out" 'authorized finding was dropped without resolution' \
    'refusal did not identify dropped authorized finding'
  assert_contains "$out" 'blocker: correctness: authorize.sh returns success for unauthorized values' \
    'refusal did not carry the unresolved blocker'
  assert_absent "$dir/home/state/reviewed-head" \
    'head file must not be written when an authorized finding is unresolved'

  run_review "$dir" add-finding task-a correctness 'review-diff-not-bound-to-target-base-state' >/dev/null
  assert_grep 'review-diff-not-bound-to-target-base-state' \
    "$dir/home/state/task-a.independent-review.authorized-findings" \
    'add-finding failed to record finding'

  run_review "$dir" resolve-finding task-a 'authorize.sh returns success for unauthorized values' 'fixed by allowlist check' >/dev/null
  assert_grep 'finding_1_resolution=fixed by allowlist check' \
    "$dir/home/state/task-a.independent-review.authorized-findings" \
    'resolve-finding did not record the resolution reason'
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'gate must stay blocked while any authorized finding remains unresolved'
  assert_contains "$out" 'review-diff-not-bound-to-target-base-state' \
    'refusal did not name the second unresolved finding'

  ln "$dir/home/state/task-a.independent-review.authorized-findings" "$dir/findings-link"
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 --head-file "$dir/home/state/reviewed-head" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'gate must fail closed on an invalid authorized findings file'
  assert_contains "$out" 'could not validate authorized findings file for task-a' \
    'invalid authorized findings refusal was not named'
  assert_absent "$dir/home/state/reviewed-head" \
    'head file must not be written when the authorized findings file is invalid'
  rm -f -- "$dir/findings-link"

  run_review "$dir" resolve-finding task-a 'review-diff-not-bound-to-target-base-state' >/dev/null
  assert_grep 'finding_1_resolution=fixed by allowlist check' \
    "$dir/home/state/task-a.independent-review.authorized-findings" \
    'a later resolution dropped an earlier resolution reason'
  set +e
  out=$(run_review "$dir" ready task-a https://github.com/example/repo/pull/1 --head-file "$dir/home/state/reviewed-head" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" 'gate must clear once all authorized findings are resolved'
  assert_contains "$out" 'Independent review:' 'clear verdict summary was not printed'
  assert_present "$dir/home/state/reviewed-head" 'head file was not written after clearance'
  [ "$(cat "$dir/home/state/reviewed-head")" = "$head" ] || fail 'head file did not record the reviewed head'

  pass 'an authorized finding is never dropped by the gate'
}

test_codex_builder_selects_different_family
test_claude_builder_selects_different_family
test_pi_family_comes_from_recorded_model
test_muse_builder_uses_meta_family
test_cursor_builder_family_is_derived_and_fail_closed
test_defective_pr_is_rejected
test_sound_pr_passes_and_binds_exact_head
test_verdict_text_refuses_terminal_control_bytes
test_stale_verdict_does_not_clear_new_head
test_base_advance_invalidates_reviewed_diff
test_missing_different_family_refuses_loudly
test_selection_considers_each_available_verified_fixed_family
test_second_rejection_opens_circuit
test_reviewer_context_is_cold_on_both_rounds
test_unknown_builder_family_names_missing_fact
test_draft_and_merged_prs_never_start_review
test_work_in_progress_task_never_starts_review
test_current_finished_state_and_delivery_mode_are_required
test_finished_pr_requires_exact_url_token
test_non_default_target_base_bounds_diff
test_missing_target_base_refuses_review
test_gitlab_finished_merge_request_binds_exact_head
test_submitted_result_alone_never_clears_a_head
test_promotion_storage_failure_is_reported
test_abandoned_unpromoted_submission_can_retire
test_reviewer_attestation_must_name_the_submitted_verdict
test_generated_herdr_terminators_start_review
test_near_miss_task_heading_refuses_criteria
test_unterminated_task_section_refuses_criteria
test_failed_round_retirement_allows_retry
test_unrecorded_bundle_publication_recovers_on_retry
test_reviewer_directory_publication_is_atomic
test_recovery_refuses_mismatched_reviewer_data_ownership
test_long_parent_prefixes_derive_distinct_reviewer_ids
test_failed_digest_refuses_reviewer_id_derivation
test_launching_round_can_retire_and_retry
test_promoted_round_cannot_be_retired
test_round_transitions_share_task_lock
test_unrecognized_task_heading_refuses_criteria
test_criteria_following_collision_looking_heading_are_preserved
test_authorized_finding_is_never_dropped_by_gate
