#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh wrapper-harness delivery.
#
# These tests drive fm-spawn with PATH wrapper executables in unverified
# claude/codex families through meta writing and launch construction with a
# fake tmux pane. The fake tmux captures the literal launch command sent with
# `tmux send-keys -l`, so assertions pin the command firstmate would run
# without starting any real harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-wrapper)

make_wrapper_fakebin() {
  local fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
  cat > "$fakebin/claude-stubw" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = --list-models ]; then printf '%s\n' 'alpha Alpha model' 'beta Beta model'; exit 0; fi
exit 0
SH
  cat > "$fakebin/claude-pinnedw" <<'SH'
#!/usr/bin/env sh
echo "error: unknown option '--list-models'" >&2; exit 1
SH
  cat > "$fakebin/codex-stubw" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = --list-models ]; then printf '%s\n' 'alpha Alpha model' 'beta Beta model'; exit 0; fi
exit 0
SH
  chmod +x "$fakebin"/claude-stubw "$fakebin"/claude-pinnedw "$fakebin"/codex-stubw
  printf '%s\n' "$fakebin"
}

make_wrapper_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_wrapper_fakebin)
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

run_wrapper_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

run_wrapper_ship_spawn() {
  run_wrapper_spawn "$@" --mode no-mistakes --yolo off
}

read_wrapper_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
${1#*|}
EOF
}

wrapper_brief_ref() {
  printf '"$(%s encode launch-brief < %s)"' \
    "'$ROOT/bin/fm-operational-input.sh'" "'$HOME_DIR/data/$1/launch-brief.md'"
}

test_claude_wrapper_threads_listed_alias_before_separator() {
  local rec id out status launch expected
  id=wrap-claude-alias-z1
  rec=$(make_wrapper_case claude-alias "$id")
  read_wrapper_case "$rec"

  out=$(run_wrapper_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness claude-stubw --model beta --effort high)
  status=$?
  expect_code 0 "$status" "claude wrapper spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude-stubw" "spawn did not report wrapper harness"
  assert_grep "harness=claude-stubw" "$HOME_DIR/state/$id.meta" "meta missing wrapper harness"
  assert_grep "model=beta" "$HOME_DIR/state/$id.meta" "meta missing wrapper model"

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 '$FAKEBIN_DIR/claude-stubw' 'beta' -- --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' --effort 'high' $(wrapper_brief_ref "$id")"
  [ "$launch" = "$expected" ] || fail "claude wrapper launch mismatch"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "claude wrapper threads listed alias before separator with family flags"
}

test_claude_pinned_wrapper_takes_no_positional_model() {
  local rec id out status launch expected
  id=wrap-claude-pinned-z1
  rec=$(make_wrapper_case claude-pinned "$id")
  read_wrapper_case "$rec"

  out=$(run_wrapper_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness claude-pinnedw --effort high)
  status=$?
  expect_code 0 "$status" "pinned wrapper spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 '$FAKEBIN_DIR/claude-pinnedw' -- --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' --effort 'high' $(wrapper_brief_ref "$id")"
  [ "$launch" = "$expected" ] || fail "pinned wrapper launch mismatch"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "pinned wrapper passes no positional model"
}

test_codex_wrapper_keeps_notify_and_brief_position() {
  local rec id out status launch
  id=wrap-codex-alias-z1
  rec=$(make_wrapper_case codex-alias "$id")
  read_wrapper_case "$rec"

  out=$(run_wrapper_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness codex-stubw --model alpha --effort high)
  status=$?
  expect_code 0 "$status" "codex wrapper spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/codex-stubw' 'alpha' -- -c 'model_reasoning_effort=" "codex wrapper launch shape wrong"
  assert_contains "$launch" "\"high\"' --dangerously-bypass-approvals-and-sandbox" "codex wrapper launch shape wrong"
  assert_contains "$launch" "touch '$HOME_DIR/state/$id.turn-ended'" "codex wrapper launch lost turn-end notification"
  assert_contains "$launch" "$(wrapper_brief_ref "$id")" "codex wrapper launch lost brief position"
  pass "codex wrapper keeps notify wiring and brief position behind separator"
}

test_pool_claude_wrapper_carries_no_codex_notify_or_home() {
  local rec id out status launch
  id=wrap-pool-claude-z1
  rec=$(make_wrapper_case pool-claude "$id")
  read_wrapper_case "$rec"
  cat > "$HOME_DIR/config/dispatch-pools.json" <<'JSON'
{"schemaVersion":1,"defaults":{},"pools":{"wpool":[{"id":"w","harness":"claude-stubw","model":"beta","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1}]}}
JSON

  out=$(run_wrapper_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --pool wpool)
  status=$?
  expect_code 0 "$status" "pool claude wrapper spawn should succeed"
  assert_contains "$out" "candidate=w" "pool spawn did not report wrapper candidate"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/claude-stubw' 'beta' --" "pool claude wrapper launch shape wrong"
  if printf '%s' "$launch" | grep -F -q -- '-c "notify='; then fail "pool claude wrapper launch carries codex notify flag"; fi
  if printf '%s' "$launch" | grep -F -q 'CODEX_HOME='; then fail "pool claude wrapper launch carries null codex home"; fi
  pass "pool claude wrapper delivery keeps family shape without codex-only wiring"
}

test_pool_codex_wrapper_keeps_notify_without_home() {
  local rec id out status launch
  id=wrap-pool-codex-z1
  rec=$(make_wrapper_case pool-codex "$id")
  read_wrapper_case "$rec"
  cat > "$HOME_DIR/config/dispatch-pools.json" <<'JSON'
{"schemaVersion":1,"defaults":{},"pools":{"wpool":[{"id":"w","harness":"codex-stubw","model":"alpha","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1}]}}
JSON

  out=$(run_wrapper_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --pool wpool)
  status=$?
  expect_code 0 "$status" "pool codex wrapper spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/codex-stubw' 'alpha' --" "pool codex wrapper launch shape wrong"
  assert_contains "$launch" '-c "notify=' "pool codex wrapper launch lost notify wiring"
  if printf '%s' "$launch" | grep -F -q 'CODEX_HOME='; then fail "pool codex wrapper launch carries null codex home"; fi
  pass "pool codex wrapper delivery keeps notify wiring without codex home"
}

test_wrapper_refusals_fail_before_endpoint() {
  local rec id out status
  id=wrap-refuse-z1
  rec=$(make_wrapper_case refuse "$id")
  read_wrapper_case "$rec"

  out=$(run_wrapper_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness zzz-thing --effort high 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unknown wrapper family spawned"
  assert_contains "$out" "unknown harness 'zzz-thing'" "unknown family refusal wrong"

  out=$(run_wrapper_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness claude-nope --effort high 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "missing wrapper spawned"
  assert_contains "$out" "not installed on PATH" "missing wrapper refusal wrong"

  out=$(run_wrapper_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness claude-stubw --model gamma --effort high 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unlisted alias spawned"
  assert_contains "$out" "does not list model 'gamma'" "unlisted alias refusal wrong"

  out=$(run_wrapper_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness claude-pinnedw --model beta --effort high 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "alias on pinned wrapper spawned"
  assert_contains "$out" "model must be default" "pinned alias refusal wrong"

  out=$(run_wrapper_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness claude-stubw --model beta --effort ultra 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "ultra on wrapper spawned"
  assert_contains "$out" "canonical --harness pi or pi-signed" "ultra refusal wrong"

  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published metadata"
  pass "unknown, missing, unlisted, pinned-alias and ultra wrapper launches refuse before endpoint"
}

test_claude_wrapper_threads_listed_alias_before_separator
test_claude_pinned_wrapper_takes_no_positional_model
test_codex_wrapper_keeps_notify_and_brief_position
test_pool_claude_wrapper_carries_no_codex_notify_or_home
test_pool_codex_wrapper_keeps_notify_without_home
test_wrapper_refusals_fail_before_endpoint

echo "# all fm-spawn-wrapper tests passed"
