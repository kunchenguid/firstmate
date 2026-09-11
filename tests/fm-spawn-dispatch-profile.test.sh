#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
  printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value,
  # which would make launch assertions depend on the developer's environment.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_non_cursor_launch_clears_inherited_cursor_markers() {
  local rec id out status launch
  id=profile-claude-cursor-markers-z1b
  rec=$(make_spawn_case profile-claude-cursor-markers claude "$id")
  read_case_record "$rec"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn under Cursor markers should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=profile-relative-paths-z1b
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/launch-brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=profile-relative-home-defaults-z1c
  absolute_id=profile-absolute-home-defaults-z1d
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/launch-brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/launch-brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=profile-absolute-paths-z1c
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/launch-brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=profile-unresolvable-paths-z1d
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement: $out"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  assert_not_contains "$launch" "--tui-mode" "non-Pi launches must not receive Pi's TUI mode override"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_omits_invalid_xhigh_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported xhigh reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported xhigh reasoning effort"
}

test_cursor_threads_model_workspace_and_omits_effort_axis() {
  local rec id out status launch
  id=profile-cursor-z6c
  rec=$(make_spawn_case profile-cursor cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with a model-qualified reasoning class should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-grok-4.5-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--trust --yolo --model 'cursor-grok-4.5-high' --workspace '$WT_DIR'" \
    "cursor launch did not carry trust, autonomy, model, and exact workspace flags"
  # The executable is RESOLVED, never named: `cursor` is not the CLI, so a
  # literal `cursor agent` command cannot run on a machine that has only the
  # real installed names.
  assert_not_contains "$launch" "cursor agent --trust" \
    "cursor launch must resolve its executable, not invoke a literal 'cursor agent'"
  assert_contains "$launch" "cursor-agent" "cursor launch did not resolve a cursor executable"
  # -w/--worktree would allocate a SECOND worktree under ~/.cursor/worktrees and
  # break the isolation contract the spawn assertion depends on.
  assert_not_contains "$launch" " --worktree" "cursor launch must never allocate a second worktree"
  assert_not_contains "$launch" " -w " "cursor launch must never allocate a second worktree"
  # An inherited CLAUDECODE would otherwise outrank cursor's own marker.
  assert_contains "$launch" "env -u CLAUDECODE" "cursor launch must clear foreign primary markers"
  assert_contains "$launch" "encode launch-brief" "cursor launch did not deliver the brief positionally"
  assert_not_contains "$launch" "--effort" "cursor launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not invent a separate reasoning-effort flag"
  assert_grep 'harness=cursor' "$HOME_DIR/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'model=cursor-grok-4.5-high' "$HOME_DIR/state/$id.meta" "cursor model was recorded as default"
  pass "cursor receives its model-qualified reasoning class and exact task workspace"
}

test_cursor_refuses_model_absent_from_live_catalog() {
  local rec id out status
  id=profile-cursor-unsupported-z6d
  rec=$(make_spawn_case profile-cursor-unsupported cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5)
  status=$?
  expect_code 1 "$status" "cursor spawn should refuse a model absent from a successful catalog"
  assert_contains "$out" "Cursor model 'cursor-grok-4.5' is not available" \
    "cursor model refusal did not identify the unavailable model"
  assert_contains "$out" "--list-models" \
    "cursor model refusal did not tell the caller how to find valid ids"
  [ ! -s "$LAUNCH_LOG" ] || fail "cursor model refusal must happen before launch"
  pass "cursor refuses model ids absent from its resolved binary's live catalog"
}

test_cursor_failed_catalog_probe_does_not_block_spawn() {
  local rec id out status launch
  id=profile-cursor-catalog-unreachable-z6e
  rec=$(make_spawn_case profile-cursor-catalog-unreachable cursor "$id")
  read_case_record "$rec"

  FM_TEST_CURSOR_LIST_STATUS=124 \
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-catalog-unreachable)
  status=$?
  expect_code 0 "$status" "cursor spawn should fail open when the bounded catalog query fails"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cursor-catalog-unreachable'" \
    "failed catalog lookup incorrectly removed the requested model"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-catalog-unreachable default
  pass "cursor preserves the requested model when its live catalog is unreachable"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_native_effort_validator_keeps_axes_separate() {
  local harness
  for harness in pi pi-signed; do
    "$ROOT/bin/fm-harness.sh" validate-native-effort "$harness" codex-native/gpt-6-astra ultra \
      || fail "native validator refused supported harness $harness"
  done
  if "$ROOT/bin/fm-harness.sh" validate-native-effort 'pi:codex-native/forged' '' ultra 2>/dev/null; then
    fail "native validator accepted a model prefix embedded in the harness axis"
  fi
  pass "native effort validator checks harness and model as separate axes"
}

test_native_pi_ultra_is_explicit_and_model_scoped() {
  local rec id out launch harness mode native_profile model
  for harness in pi pi-signed; do
    for mode in no-mistakes direct-PR; do
      id="ultra-$harness-$mode"
      rec=$(make_spawn_case "$id" "$harness" "$id")
      read_case_record "$rec"
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
        --harness "$harness" --model codex-native/gpt-6-astra --effort ultra --mode "$mode" --yolo off)
      expect_code 0 "$?" "native Ultra spawn failed: $out"
      assert_meta_profile "$HOME_DIR/state/$id.meta" "$harness" codex-native/gpt-6-astra ultra
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "--model 'codex-native/gpt-6-astra' --codex-effort 'ultra'" "native Ultra flag missing"
      assert_not_contains "$launch" "--thinking" "native Ultra was converted into Pi thinking"
      assert_not_contains "$launch" "'max'" "native Ultra was aliased to max"
    done
  done
  for native_profile in 'claude:codex-native/gpt-6-astra' 'codex:codex-native/gpt-6-astra' 'pi:openai-codex/gpt-6-astra' 'pi:default' 'pi:codex-native/'; do
    harness=${native_profile%%:*}; model=${native_profile#*:}; id="ultra-refused-$RANDOM"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --harness "$harness" --model "$model" --effort ultra 2>&1)
    expect_code 1 "$?" "unsupported Ultra profile should refuse: $native_profile"
    assert_contains "$out" "ultra effort requires pi or pi-signed" "native-only refusal missing"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "unsupported Ultra published metadata"
    [ ! -e "$HOME_DIR/state/$id.busy-gen" ] || fail "unsupported Ultra provisioned lifecycle wiring"
    [ ! -s "$LAUNCH_LOG" ] || fail "unsupported Ultra launched an agent"
  done
  id=ultra-raw-refused
  rec=$(make_spawn_case "$id" pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    'pi --offline' --model codex-native/gpt-6-astra --effort ultra 2>&1)
  expect_code 1 "$?" "raw launch silently omitted the native Ultra flag"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "raw Ultra launch published metadata"
  assert_contains "$out" "canonical --harness pi or pi-signed" "raw launch refusal was not actionable"
  pass "Ultra is explicit for native Pi and Pi-signed, including direct-PR, and refuses unsupported profiles before provisioning"
}

test_batch_preserves_native_ultra() {
  local rec id1=ultra-batch-a id2=ultra-batch-b out launch
  rec=$(make_spawn_case ultra-batch pi "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness pi --model codex-native/gpt-6-astra --effort ultra)
  expect_code 0 "$?" "native Ultra batch failed: $out"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" pi codex-native/gpt-6-astra ultra
  assert_meta_profile "$HOME_DIR/state/$id2.meta" pi codex-native/gpt-6-astra ultra
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--codex-effort 'ultra'" "batch dropped native effort"
  assert_not_contains "$launch" "--thinking 'ultra'" "batch passed an invalid Pi level"
  pass "batch dispatch preserves native Ultra in metadata and launch flags"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not force the regular TUI while threading the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=profile-pi-signed-z8b
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not force the regular TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_tui_mode_probe_is_safe_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      if [ "$version" = 0.82.0 ]; then
        assert_not_contains "$launch" "--tui-mode" \
          "$harness $version launch must omit unsupported --tui-mode"
      else
        assert_contains "$launch" "'$FAKEBIN_DIR/$harness' --tui-mode regular" \
          "$harness $version launch must preserve the regular TUI"
      fi
    done
  done
  pass "Pi launch probing omits --tui-mode on older Pi and preserves it on supporting Pi"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=profile-pi-signed-missing-z8c
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id=profile-pi-signed-secondmate-z8d
  rec=$(make_spawn_case profile-pi-signed-secondmate codex "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)
  cp "$ROOT/AGENTS.md" "$sm/AGENTS.md"
  cp "$sm/data/charter.md" "$CASE_DIR/charter-before"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  cmp -s "$ROOT/AGENTS.md" "$sm/AGENTS.md" || fail "secondmate launch rewrote the supervisor contract"
  cmp -s "$CASE_DIR/charter-before" "$sm/data/charter.md" || fail "secondmate launch rewrote the charter"
  assert_absent "$HOME_DIR/data/$id/launch-brief.md" "secondmate launch received a worker overlay"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "< '$sm/data/charter.md'" "secondmate launch lost its original charter"
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: persistent secondmate\n%s\n' "$out"
    printf 'launch command:\n%s\noriginal charter:\n' "$launch"
    cat "$sm/data/charter.md"
    printf 'supervisor AGENTS.md and charter remain byte-identical; no worker overlay created\n# evidence end\n'
  fi
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_claude_forwards_firstmate_config_dir_when_set() {
  local rec id out status launch
  id=profile-claude-cfgdir-z17
  rec=$(make_spawn_case profile-claude-cfgdir claude "$id")
  read_case_record "$rec"

  # A creatable path: this spawn now pre-registers workspace trust in that store
  # (bin/fm-claude-trust.sh), so an unwritable directory is a genuine blocker.
  # The forwarding assertion below is what this case proves and is unchanged.
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE_DIR/claude-work' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}'" \
    "claude launch did not forward firstmate's CLAUDE_CONFIG_DIR to the crewmate pane"
  pass "claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store"
}

test_claude_omits_config_dir_prefix_when_unset() {
  local rec id out status launch
  id=profile-claude-nocfgdir-z18
  rec=$(make_spawn_case profile-claude-nocfgdir claude "$id")
  read_case_record "$rec"

  # run_spawn pins CLAUDE_CONFIG_DIR empty by default, exercising the single-store
  # default path where fm-spawn adds no prefix.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "claude launch must not add a config-dir prefix when firstmate has no CLAUDE_CONFIG_DIR set"
  pass "claude omits the config-dir prefix when firstmate runs with the single-store default"
}

test_non_claude_harness_ignores_config_dir() {
  local rec id out status launch
  id=profile-codex-nocfgdir-z19
  rec=$(make_spawn_case profile-codex-nocfgdir codex "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "non-claude harness launch must not receive the claude-specific config-dir prefix"
  pass "non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix"
}

# The captain's attribution policy lives in the `user` settings scope, which a
# spawned worker's settings sources are not guaranteed to load. Every claude
# launch must therefore carry the policy itself, or a spawned worker writes
# Co-Authored-By and Claude-Session trailers into commits and PR bodies.
assert_attribution_policy() {  # <launch-command> <what>
  local launch=$1 what=$2
  assert_contains "$launch" '"attribution":' "$what launch carries no attribution policy"
  assert_contains "$launch" '"commit":""' "$what launch does not silence the commit trailer"
  assert_contains "$launch" '"pr":""' "$what launch does not silence the PR-body attribution"
  assert_contains "$launch" '"sessionUrl":false' "$what launch does not silence the session URL"
}

test_claude_crewmate_launch_carries_the_attribution_policy() {
  local rec id out status launch
  id=profile-claude-attribution-z22
  rec=$(make_spawn_case profile-claude-attribution claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude crewmate spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_attribution_policy "$launch" "claude crewmate"
  pass "a claude crewmate launch carries the attribution-off policy in its own settings"
}

test_claude_secondmate_launch_carries_the_attribution_policy() {
  local rec id sm out status launch
  id=profile-secondmate-attribution-z23
  rec=$(make_spawn_case profile-secondmate-attribution claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/claude-work" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate claude spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_attribution_policy "$launch" "claude secondmate"
  pass "a claude secondmate launch carries the attribution-off policy too"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

# Execute the actual emitted command in a synthetic pane environment: the
# fake backend records delivery, while real shells exercise the env boundary.
# No developer environment or credential values are inspected by these probes.
test_launch_environment_allowlist() {
  local setting rec id out status probe result expected launch value pane_shell pane_path
  # shellcheck disable=SC2016
  value='synthetic value; $(touch SHOULD_NOT_EXIST) `false` "quoted"'
  for setting in absent missing-config enabled empty; do
    id="env-$setting"
    rec=$(make_spawn_case "$id" codex "$id")
    read_case_record "$rec"
    case "$setting" in
      missing-config) rm "$HOME_DIR/config/crew-harness"; rmdir "$HOME_DIR/config" ;;
      enabled) printf '# Synthetic credential name\nFM_TEST_ALLOWED\nFM_TEST_EMPTY\nFM_TEST_UNSET\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
      empty) : > "$HOME_DIR/config/launch-env-allowlist" ;;
    esac
    probe="$CASE_DIR/probe.sh"
    cat > "$probe" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "${FM_TEST_ALLOWED-unset}" \
  "${FM_TEST_EMPTY-unset}" "${FM_TEST_UNSET-unset}" "$HOME" "$PATH" "$TERM" "$TMUX" "$GOTMPDIR"
SH
    out=$(FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness "/bin/sh '$probe'")
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    for pane_shell in /bin/sh /bin/bash /bin/zsh; do
      [ -x "$pane_shell" ] || continue
      pane_path=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
        TMUX=synthetic-pane GOTMPDIR=/synthetic/gotmp \
        "$pane_shell" -c "printf %s \"\$PATH\"") \
        || fail "could not read $pane_shell startup PATH"
      result=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
      TMUX=synthetic-pane GOTMPDIR=/synthetic/gotmp \
      FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED="$value" FM_TEST_EMPTY='' \
      "$pane_shell" -c "$launch") || fail "allowlist=$setting emitted launch failed in $pane_shell"
      case "$setting" in
        absent|missing-config) expected=$(printf '%s\n' synthetic-unrelated "$value" '' unset) ;;
        enabled) expected=$(printf '%s\n' unset "$value" '' unset) ;;
        empty) expected=$(printf '%s\n' unset unset unset unset) ;;
      esac
      expected="$expected"$'\n'"$HOME_DIR/user-home"$'\n'"$pane_path"$'\nxterm\nsynthetic-pane\n/synthetic/gotmp'
      [ "$result" = "$expected" ] || fail "allowlist=$setting worker environment mismatch: $result"
    done
    pass "allowlist=$setting preserves the operational floor and filters only when opted in"
  done
}

test_launch_environment_invalid_config_refuses() {
  local rec id bad out status
  id=env-invalid
  rec=$(make_spawn_case "$id" codex "$id")
  read_case_record "$rec"
  for bad in 'FM_TEST_ALLOWED=value' 'NAME;false' '1INVALID' '*'; do
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "invalid allowlist must refuse spawn"
    assert_contains "$out" 'launch-env-allowlist' "refusal must identify the config file"
    [ ! -s "$LAUNCH_LOG" ] || fail "invalid allowlist delivered a launch command"
    [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "invalid allowlist published a task"
  done
  pass "invalid allowlist names refuse before launch or task publication"
}

test_launch_environment_inaccessible_config_refuses() {
  local setting presence rec id blocked out status
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - inaccessible launch configuration requires a non-root user\n'
    return
  fi
  for setting in config ancestor; do
    for presence in present absent; do
      id="env-inaccessible-$setting-$presence"
      rec=$(make_spawn_case "$id" codex "$id")
      read_case_record "$rec"
      if [ "$presence" = present ]; then
        printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
      fi
      blocked="$HOME_DIR/config"
      if [ "$setting" = ancestor ]; then
        blocked="$HOME_DIR/config-parent"
        mkdir "$blocked"
        mv "$HOME_DIR/config" "$blocked/config"
        ln -s config-parent/config "$HOME_DIR/config"
      fi
      chmod 600 "$blocked" || fail "could not remove configuration search permission"
      out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --harness codex --backend tmux)
      status=$?
      chmod 700 "$blocked" || fail "could not restore configuration search permission"
      expect_code 1 "$status" "inaccessible $setting with $presence allowlist must refuse spawn: $out"
      assert_contains "$out" 'launch-env-allowlist' "refusal must identify the launch configuration"
      [ ! -s "$LAUNCH_LOG" ] || fail "inaccessible configuration delivered a launch command"
      [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "inaccessible configuration published a task"
      pass "inaccessible $setting with $presence allowlist refuses before launch or task publication"
    done
  done
}

test_launch_environment_inherited_by_secondmate() {
  local rec id sm out status result
  id=env-secondmate
  rec=$(make_spawn_case "$id" codex "$id")
  read_case_record "$rec"
  printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate with an allowlist should spawn: $out"
  cmp -s "$HOME_DIR/config/launch-env-allowlist" "$sm/config/launch-env-allowlist" \
    || fail "secondmate did not inherit the launch environment contract"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "$FM_TEST_ALLOWED" "$FM_HOME" "${FM_STATE_OVERRIDE-unset}"
SH
  chmod +x "$FAKEBIN_DIR/codex"
  result=$(env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" \
    FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED=synthetic-provider \
    /bin/sh -c "$(cat "$LAUNCH_LOG")") || fail "secondmate's emitted command failed"
  [ "$result" = "unset"$'\nsynthetic-provider\n'"$sm" ] \
    || fail "secondmate's environment lost filtering or explicit home assignments: $result"
  # Exercise the same inheritance owner used by local and remote transfers;
  # removal must restore absence downstream as well as copying an opt-in.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    rm "$HOME_DIR/config/launch-env-allowlist"
    propagate_secondmate_inheritance "$HOME_DIR" "$sm" >/dev/null
  ) || fail "allowlist removal failed to converge"
  [ ! -e "$sm/config/launch-env-allowlist" ] || fail "secondmate retained a removed allowlist"
  pass "secondmate launch inherits the allowlist for subsequent worker launches"
}

run_launch_environment_inheritance() {
  local route=$1 home=$2 dest=$3 fakebin=$4 generation=$5
  if [ "$route" = local ]; then
    (
      # shellcheck source=/dev/null
      . "$ROOT/bin/fm-config-inherit-lib.sh"
      FM_INHERITABLE_CONFIG=launch-env-allowlist \
        propagate_inheritable_config "$home/config" "$dest/config"
    )
  else
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
      FM_DATA_OVERRIDE="$home/data" FM_INHERITABLE_CONFIG=launch-env-allowlist \
      FM_SSH_BIN="$fakebin/inherit-ssh" \
      "$ROOT/bin/fm-remote-inherit-push.sh" inherited-env "$generation"
  fi
}

test_launch_environment_inheritance_preserves_on_source_errors() {
  local route rec id dest out status
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - inaccessible inheritance sources require a non-root user\n'
    return
  fi
  for route in local remote; do
    id="env-inherit-$route"
    rec=$(make_spawn_case "$id" codex "$id")
    read_case_record "$rec"
    dest="$CASE_DIR/inherited-home"
    mkdir -p "$dest/config"
    printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
    printf -- '- inherited-env - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-09-05)\n' \
      "$ROOT" "$dest" > "$HOME_DIR/data/secondmates.md"
    cat > "$FAKEBIN_DIR/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = inherit-host ] && [ "$2" = fm-remote-entrypoint.sh ] && [ "$3" = 1 ] || exit 91
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
    chmod +x "$FAKEBIN_DIR/inherit-ssh"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 1 2>&1)
    status=$?
    expect_code 0 "$status" "$route allowlist inheritance should succeed: $out"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance did not publish the allowlist"

    chmod 600 "$HOME_DIR/config" || fail "could not remove source search permission"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 2 2>&1)
    status=$?
    chmod 700 "$HOME_DIR/config" || fail "could not restore source search permission"
    expect_code 1 "$status" "$route inheritance must refuse an inaccessible source: $out"
    assert_contains "$out" launch-env-allowlist "$route inspection error must identify the allowlist"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance removed or changed the allowlist after an inspection error"

    rm "$HOME_DIR/config/launch-env-allowlist"
    ln -s missing-allowlist "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 3 2>&1)
    status=$?
    expect_code 1 "$status" "$route inheritance must refuse a dangling source link: $out"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance treated a dangling source link as absence"

    rm "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 4 2>&1)
    status=$?
    expect_code 0 "$status" "$route inheritance should mirror proven absence: $out"
    [ ! -e "$dest/config/launch-env-allowlist" ] || fail "$route inheritance retained a removed allowlist"
    pass "$route inheritance preserves the allowlist on source errors and mirrors proven absence"
  done
}

test_launch_environment_allowlist
test_launch_environment_invalid_config_refuses
test_launch_environment_inaccessible_config_refuses
test_launch_environment_inherited_by_secondmate
test_launch_environment_inheritance_preserves_on_source_errors

test_worker_launch_delivers_role_scope() {
  local rec id out launch kind prompt brief_kind brief content
  for brief_kind in heading legacy scaffold; do
  for kind in no-mistakes direct-PR local-only scout; do
    [ "$brief_kind" = heading ] && [ "$kind" != no-mistakes ] && continue
    id="role-launch-$brief_kind-$kind"
    rec=$(make_spawn_case "$id" codex)
    read_case_record "$rec"
    if [ "$brief_kind" != scaffold ]; then
      fm_test_spawn_brief "$HOME_DIR" "$id"
      if [ "$brief_kind" = heading ]; then
        printf '\n# Worker role\nFollow the project instructions.\n' >> "$HOME_DIR/data/$id/brief.md"
      fi
    else
      if [ "$kind" = scout ]; then
        FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" arbitrary-project-name --scout >/dev/null || fail "scout scaffold failed"
      else
        FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" arbitrary-project-name --mode "$kind" >/dev/null || fail "$kind scaffold failed"
      fi
      brief="$HOME_DIR/data/$id/brief.md"
      content=$(cat "$brief")
      content=${content//'{TASK}'/brief for $id}
      content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn behavior under test.}
      printf '%s\n' "$content" > "$brief"
    fi
    cp "$HOME_DIR/data/$id/brief.md" "$CASE_DIR/brief-before"
    cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_ROLE_PROMPT"
SH
    chmod +x "$FAKEBIN_DIR/codex"
    if [ "$kind" = scout ]; then
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
    else
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode "$kind" --yolo off)
    fi
    expect_code 0 "$?" "$kind worker spawn failed: $out"
    launch=$(cat "$LAUNCH_LOG")
    prompt="$CASE_DIR/prompt"
    FM_ROLE_PROMPT="$prompt" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" || fail "could not consume $kind launch command"
    # The final prompt delivered to the harness is the generated interface.
    # An authored role heading must neither suppress nor duplicate the current
    # worker contract; the launch section is its single, superseding owner.
    assert_grep 'follow this brief instead of that supervisor contract' "$prompt" "$kind command did not deliver the role correction"
    assert_grep 'brief for' "$prompt" "$kind command lost the task"
    [ "$(grep -c '^# Current worker role contract$' "$prompt")" -eq 1 ] ||
      fail "$brief_kind $kind duplicated the delivered worker contract"
    if [ "$brief_kind" = heading ]; then
      assert_grep 'Follow the project instructions' "$prompt" "$kind command dropped the authored role section"
    fi
    cmp -s "$CASE_DIR/brief-before" "$HOME_DIR/data/$id/brief.md" || fail "spawn rewrote the authored brief"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# evidence begin: %s %s worker\n%s\n' "$brief_kind" "$kind" "$out"
      printf 'launch command executed with an argv-capture harness:\n%s\nreceived arguments and final prompt:\n' "$launch"
      cat "$prompt"
      printf 'authored brief remains byte-identical\n# evidence end\n'
    fi
  done
  done
  pass "fm-spawn: actual ship/scout launch commands deliver the worker role contract"
}

# Record every backend retirement a spawn performs: window kills and treehouse
# invocations, the latter with the physical directory they ran from.
arm_retire_log() {
  RETIRE_LOG="$CASE_DIR/retire.log"
  export FM_RETIRE_LOG="$RETIRE_LOG"
  : > "$RETIRE_LOG"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-unlogged"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/bin/bash
[ "${1:-}" != kill-window ] || printf 'tmux %s\n' "$*" >> "$FM_RETIRE_LOG"
if [ -n "${FM_FAKE_PANE_DRIFT:-}" ]; then
  case "$*" in
    *'#{pane_current_path}'*)
      n=$(( $(cat "$FM_RETIRE_LOG.reads" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$FM_RETIRE_LOG.reads"
      if [ "$n" -gt "$FM_FAKE_PANE_DRIFT_AFTER" ]; then printf '%s\n' "$FM_FAKE_PANE_DRIFT"; exit 0; fi ;;
  esac
fi
exec "$(dirname "$0")/tmux-unlogged" "$@"
SH
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/bin/bash
printf 'treehouse %s in %s\n' "$*" "$(pwd -P)" >> "$FM_RETIRE_LOG"
SH
  chmod +x "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/treehouse"
}

# Run the delivered command, not just its spelling: Pi's process cwd changes,
# while the invoking endpoint shell and durable worktree identity stay rooted.
test_pi_start_directory_contract() {
  local rec id out launch expected before harness
  for harness in pi pi-signed; do
    id="start-$harness"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    arm_retire_log
    mkdir -p "$WT_DIR/games/a b's"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --start-dir "games/a b's" --model codex-native/gpt-6-astra --effort high)
    expect_code 0 "$?" "nested $harness spawn failed: $out"
    assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "root identity changed"
    assert_grep "start_dir=games/a b's" "$HOME_DIR/state/$id.meta" "relative directory was not persisted"
    assert_meta_profile "$HOME_DIR/state/$id.meta" "$harness" codex-native/gpt-6-astra high
    launch=$(cat "$LAUNCH_LOG")
    cat > "$FAKEBIN_DIR/$harness" <<'CAPTURE'
#!/bin/sh
if [ "${1:-}" = --help ]; then exit 0; fi
pwd -P > "$FM_START_CAPTURE"
printf '%s\n' "$@" >> "$FM_START_CAPTURE"
CAPTURE
    chmod +x "$FAKEBIN_DIR/$harness"
    expected=$(cd "$WT_DIR/games/a b's" && pwd -P)
    (cd "$WT_DIR" && FM_START_CAPTURE="$CASE_DIR/capture" sh -c "$launch" && pwd -P > "$CASE_DIR/after") || fail "nested launch failed"
    assert_grep "$expected" "$CASE_DIR/capture" "Pi did not start in nested directory"
    assert_grep 'codex-native/gpt-6-astra' "$CASE_DIR/capture" "native model lost"
    assert_grep 'high' "$CASE_DIR/capture" "effort lost"
    assert_grep "$HOME_DIR/state/$id.pi-ext.ts" "$CASE_DIR/capture" "absolute worker extension lost"
    [ "$(cat "$CASE_DIR/after")" = "$(cd "$WT_DIR" && pwd -P)" ] || fail "endpoint shell left root"

    # A fake stopped endpoint supplies only the backend inputs; actual relaunch
    # performs the same metadata adoption and isolated-root checks as production.
    mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-base"
    cat > "$FAKEBIN_DIR/tmux" <<'TMUX'
#!/bin/bash
case "$*" in
  *'#{pane_current_command}'*) echo zsh; exit 0 ;;
  'list-windows '*) printf '%s\n' "fm-$FM_START_ID"; exit 0 ;;
esac
exec "$(dirname "$0")/tmux-base" "$@"
TMUX
    chmod +x "$FAKEBIN_DIR/tmux"
    before=$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$id.meta")
    out=$(FM_START_ID="$id" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" --relaunch)
    expect_code 0 "$?" "relaunch failed: $out"
    [ "$before" != "$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$id.meta")" ] || fail "relaunch did not replace generation"
    launch=$(cat "$LAUNCH_LOG")
    (cd "$WT_DIR" && FM_START_CAPTURE="$CASE_DIR/relaunch" sh -c "$launch") || fail "relaunch command failed"
    assert_grep "$expected" "$CASE_DIR/relaunch" "relaunch lost start directory"
    assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "relaunch changed root identity"
    out=$(FM_START_ID="$id" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" --relaunch --harness codex)
    expect_code 1 "$?" "relaunch into unsupported harness accepted: $out"
    assert_contains "$out" 'supports only canonical Pi' "relaunch did not explain unsupported harness"
    # The relaunch command carries its own `;`-separated prefix; a directory
    # that vanished after spawn must still end the subshell before Pi runs.
    rm -d "$WT_DIR/games/a b's"
    out=$(cd "$WT_DIR" && FM_START_CAPTURE="$CASE_DIR/relaunch-missing" sh -c "$launch" 2>&1)
    expect_code 1 "$?" "relaunch command ran without its start directory: $out"
    assert_contains "$out" 'start directory changed before launch' 'missing-directory launch refusal absent'
    [ ! -f "$CASE_DIR/relaunch-missing" ] || fail 'harness executed after its start directory vanished'
    out=$(FM_START_ID="$id" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" --relaunch)
    expect_code 1 "$?" "relaunch accepted missing start directory: $out"
    assert_contains "$out" 'not an accessible directory' "missing relaunch directory diagnostic absent"
    assert_no_grep 'kill-window' "$RETIRE_LOG" "relaunch refusal closed the task's own endpoint"
    assert_no_grep 'treehouse return' "$RETIRE_LOG" "relaunch refusal returned the task's own worktree"
    assert_grep "start_dir=games/a b's" "$HOME_DIR/state/$id.meta" "relaunch refusal dropped the recorded start directory"
    assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "relaunch refusal changed root identity"
  done
  pass 'Pi/Pi-signed nested startup executes in contained cwd, preserves root shell and metadata through relaunch, and never starts without its directory'
}

test_start_directory_refusals() {
  local rec out value axis proj_real
  rec=$(make_spawn_case start-refusals pi refused)
  read_case_record "$rec"
  arm_retire_log
  proj_real=$(cd "$PROJ_DIR" && pwd -P)
  mkdir -p "$WT_DIR/games" "$CASE_DIR/outside"
  ln -s "$CASE_DIR/outside" "$WT_DIR/escape"
  printf 'escape\n' >> "$(git -C "$WT_DIR" rev-parse --git-path info/exclude)"
  mkdir -p "$WT_DIR/a"$'\n'"b"
  for value in '' /tmp .. games/../../outside "a"$'\n'"b"; do
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" --start-dir="$value")
    expect_code 1 "$?" "invalid directory was accepted: $value: $out"
    assert_contains "$out" '--start-dir' "directory refusal is unexplained"
    [ ! -f "$HOME_DIR/state/refused.meta" ] || fail "invalid directory published metadata"
    [ ! -s "$RETIRE_LOG" ] || fail "refusal before allocation retired a resource: $(cat "$RETIRE_LOG")"
  done
  # These are only refusable once `treehouse get` has produced the slot, so the
  # refusal must give back that clean slot and close its window itself.
  for value in missing escape; do
    : > "$RETIRE_LOG"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" --start-dir="$value")
    expect_code 1 "$?" "invalid directory was accepted: $value: $out"
    assert_contains "$out" '--start-dir' "directory refusal is unexplained"
    [ ! -f "$HOME_DIR/state/refused.meta" ] || fail "invalid directory published metadata"
    assert_contains "$out" "returned pooled worktree '$WT_DIR' and asked tmux to close window" "post-allocation refusal did not report retiring its slot"
    assert_grep "treehouse return --force $WT_DIR in $proj_real" "$RETIRE_LOG" "allocated slot was not returned from the project for $value"
    assert_grep 'kill-window' "$RETIRE_LOG" "new window was not closed for $value"
    assert_grep 'fm-refused' "$RETIRE_LOG" "a window other than the refused launch's own was closed for $value"
  done
  # Ownership is proven at retirement time, not assumed: an endpoint that no
  # longer sits in the slot after the two discovery reads means the slot is
  # not provably this launch's own, so nothing is returned or closed.
  : > "$RETIRE_LOG"
  out=$(FM_FAKE_PANE_DRIFT="$CASE_DIR/outside" FM_FAKE_PANE_DRIFT_AFTER=2 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" --start-dir=missing)
  expect_code 1 "$?" "drifted endpoint refusal did not fail: $out"
  assert_contains "$out" 'not an accessible directory' 'directory refusal is unexplained after endpoint drift'
  assert_contains "$out" "cannot be proven this launch's own" 'drifted endpoint was not named as the reason to keep the slot'
  [ ! -s "$RETIRE_LOG" ] || fail "unproven slot was retired after endpoint drift: $(cat "$RETIRE_LOG")"
  [ ! -f "$HOME_DIR/state/refused.meta" ] || fail "drifted refusal published metadata"
  rm -f "$RETIRE_LOG.reads"
  cat > "$FAKEBIN_DIR/orca" <<'SH'
#!/bin/sh
printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
SH
  chmod +x "$FAKEBIN_DIR/orca"
  for axis in claude codex opencode grok kimi cursor muse gemini rovo omp; do
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" --harness "$axis" --start-dir .)
    expect_code 1 "$?" "unsupported $axis accepted: $out"
    assert_contains "$out" 'supports only canonical Pi' "unsupported harness not explicitly refused"
  done
  for axis in orca zellij cmux; do
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" --backend "$axis" --start-dir .)
    expect_code 1 "$?" "unsupported $axis accepted: $out"
    assert_contains "$out" 'supports only canonical Pi' "unsupported backend not explicitly refused"
  done
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" 'pi --model custom' --start-dir .)
  expect_code 1 "$?" "raw launch accepted: $out"
  assert_contains "$out" 'supports only canonical Pi' "raw launch not explicitly refused"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused --relaunch --start-dir .)
  expect_code 1 "$?" "relaunch override accepted: $out"
  assert_contains "$out" 'cannot override' "relaunch override diagnostic missing"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" --secondmate --start-dir .)
  expect_code 1 "$?" "secondmate accepted start directory: $out"
  assert_contains "$out" 'not secondmates' 'secondmate refusal missing'
  [ ! -f "$HOME_DIR/state/refused.meta" ] || fail "an unsupported axis published metadata"
  # Without an origin the slot is never reset to a base, so a clean tree still
  # cannot prove its commits landed; the refusal keeps slot and window and
  # names the manual return.
  git -C "$PROJ_DIR" remote remove origin
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m unlanded
  : > "$RETIRE_LOG"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" --start-dir=missing)
  expect_code 1 "$?" "origin-less refusal did not fail: $out"
  assert_contains "$out" 'not an accessible directory' 'directory refusal is unexplained for an origin-less slot'
  assert_contains "$out" 'cannot be proven landed' 'origin-less slot was not named as unprovable'
  assert_contains "$out" "treehouse return --force '$WT_DIR'" 'origin-less refusal did not name the manual return'
  [ ! -s "$RETIRE_LOG" ] || fail "origin-less slot with an unlanded commit was retired: $(cat "$RETIRE_LOG")"
  [ ! -f "$HOME_DIR/state/refused.meta" ] || fail "origin-less refusal published metadata"
  [ "$(git -C "$WT_DIR" log -1 --format=%s)" = unlanded ] || fail 'origin-less refusal discarded the unlanded commit'
  pass 'invalid directories and unsupported start-directory axes fail explicitly without task publication; refused fresh allocations are returned only with ownership proof'
}

# A stateful herdr stand-in for a projected spawn: workspaces and tabs carry
# focus, `pane get` reports the pane's cwd until the pane is closed and a
# pane_not_found body afterwards, and every call records who holds the
# presentation lock at that moment, so lock discipline is observable.
make_spawn_herdr_statefake() {  # <fakebin> <state-file>
  local fakebin=$1 state=$2
  printf '%s\n' '{"next":3,"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t2"}],"tabs":[{"tab_id":"w1:t2","label":"1","workspace_id":"w1","pane_id":"w1:p2","focused":true}]}' > "$state"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE=$FM_FAKE_HERDR_STATE
holder=$(cat "$FM_FAKE_HERDR_LOCK/pid" 2>/dev/null || echo none)
{ printf 'lock=%s' "$holder"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FM_HERDR_LOG"
jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
cmd=${1:-}; sub=${2:-}
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done
case "$cmd $sub" in
  "status --json") printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true}}\n' ;;
  "session list") printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s"}]}\n' "$FM_FAKE_HERDR_SOCKET" ;;
  "workspace list") jq_state '{result:{workspaces:.workspaces}}' ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; tabid="w$n:t$((n + 1))"; paneid="w$n:p$((n + 1))"
    jq_state --arg wsid "$wsid" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel, focused:false, active_tab_id:$tabid}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid, focused:true}]
       | .next += 2' | save
    jq -n --arg wsid "$wsid" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '{result:{workspace:{workspace_id:$wsid,label:$wlabel},tab:{tab_id:$tabid},root_pane:{pane_id:$paneid}}}' ;;
  "tab list") jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, focused:false}] | .next += 1' | save
    jq -n --arg tabid "$tabid" --arg paneid "$paneid" '{result:{tab:{tab_id:$tabid},root_pane:{pane_id:$paneid}}}' ;;
  "pane list") jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}' ;;
  "pane get")
    pane=${3:-}
    row=$(jq_state -c --arg p "$pane" '[.tabs[]|select(.pane_id==$p)][0] // empty')
    if [ -n "$row" ]; then
      printf '%s' "$row" | jq --arg cwd "$FM_FAKE_HERDR_CWD" '{result:{pane:{pane_id:.pane_id, tab_id:.tab_id, workspace_id:.workspace_id, foreground_cwd:$cwd}}}'
    else
      jq -n --arg p "$pane" '{error:{code:"pane_not_found",message:("pane " + $p + " not found")}}'
      exit 1
    fi ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save ;;
  "agent get") printf '{"error":{"code":"agent_not_found","message":"no agent"}}\n' ;;
  "pane process-info") printf '{"result":{"type":"unavailable"}}\n' ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
}

# On projected Herdr the refused launch's pane belongs to the armed abort
# cleanup, which closes it under the presentation lock this process holds from
# projection until exit. Closing it directly would re-enter that lock and
# release it before the cleanup ran.
test_start_directory_refusal_on_projected_herdr_keeps_the_presentation_lock() {
  local rec out sock_real key lock proj_real state log
  rec=$(make_spawn_case start-herdr pi refused)
  read_case_record "$rec"
  arm_retire_log
  mkdir -p "$HOME_DIR/config"
  printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  state="$CASE_DIR/herdr-state.json"
  log="$CASE_DIR/herdr.log"
  : > "$log"
  make_spawn_herdr_statefake "$FAKEBIN_DIR" "$state"
  sock_real="$(cd "$CASE_DIR" && pwd -P)/herdr.sock"
  key=$(printf '%s\0%s' default "$sock_real" | shasum -a 256 | awk '{print $1}')
  lock="/tmp/firstmate-herdr-presentation/order-${key:0:32}.lock"
  proj_real=$(cd "$PROJ_DIR" && pwd -P)
  out=$(
    unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
    export FM_FAKE_HERDR_STATE="$state" FM_HERDR_LOG="$log" FM_FAKE_HERDR_LOCK="$lock" \
      FM_FAKE_HERDR_SOCKET="$CASE_DIR/herdr.sock" FM_FAKE_HERDR_CWD="$WT_DIR"
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" refused "$PROJ_DIR" --backend herdr --start-dir=missing
  )
  expect_code 1 "$?" "projected herdr start-directory refusal did not fail: $out"
  assert_contains "$out" 'not an accessible directory' 'directory refusal is unexplained on projected herdr'
  assert_contains "$out" "returned pooled worktree '$WT_DIR'; projected herdr pane default:w3:p5 is closed by this launch's abort cleanup" \
    'projected refusal did not defer its pane to the abort cleanup'
  assert_grep "treehouse return --force $WT_DIR in $proj_real" "$RETIRE_LOG" 'projected refusal did not return the slot from the project'
  [ ! -f "$HOME_DIR/state/refused.meta" ] || fail 'projected refusal published metadata'
  assert_grep $'\x1f''pane'$'\x1f''run'$'\x1f''w3:p5'$'\x1f''treehouse get' "$log" 'the projected task pane never received treehouse get'
  [ "$(grep -c $'\x1f''pane'$'\x1f''close'$'\x1f''w3:p5'$'\x1f' "$log")" = 1 ] || fail "the task pane was not closed exactly once:"$'\n'"$(cat "$log")"
  jq -e '[.tabs[] | select(.workspace_id == "w3")] | length == 0' "$state" >/dev/null || fail 'the projected workspace still holds panes after cleanup'
  # From the moment the lock is first seen held, every later herdr call up to
  # the last one must still see the same holder: the lock is released only
  # after the abort cleanup finished.
  awk -F"$(printf '\037')" '
    { split($1, kv, "="); holder = kv[2] }
    holder != "none" && first == "" { first = holder }
    first != "" && holder != first { bad = NR }
    END { if (first == "") { print "lock never held"; exit 1 } if (bad) { print "lock released before herdr call " bad; exit 1 } }
  ' "$log" || fail "presentation lock was not held through the abort cleanup:"$'\n'"$(cat "$log")"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail 'presentation lock was left held after exit'
  pass 'a projected herdr start-directory refusal returns its slot and leaves its pane to the locked abort cleanup'
}


test_start_directory_root_batch_and_retarget() {
  local rec out launch id
  rec=$(make_spawn_case start-root-batch pi start-root start-a start-b)
  read_case_record "$rec"
  mkdir -p "$WT_DIR/game" "$CASE_DIR/outside"
  ln -s game "$WT_DIR/game-link"
  printf 'game-link\n' >> "$(git -C "$WT_DIR" rev-parse --git-path info/exclude)"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" start-root "$PROJ_DIR" --start-dir .)
  expect_code 0 "$?" "explicit root failed: $out"
  launch=$(cat "$LAUNCH_LOG")
  cat > "$FAKEBIN_DIR/pi" <<'CAPTURE'
#!/bin/sh
[ "${1:-}" != --help ] || exit 0
pwd -P > "$FM_START_CAPTURE"
CAPTURE
  (cd "$WT_DIR" && FM_START_CAPTURE="$CASE_DIR/root" sh -c "$launch") || fail 'explicit root launch failed'
  [ "$(cat "$CASE_DIR/root")" = "$(cd "$WT_DIR" && pwd -P)" ] || fail 'explicit root changed cwd'
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "start-a=$PROJ_DIR" "start-b=$PROJ_DIR" --harness pi --start-dir game-link)
  expect_code 0 "$?" "batch failed: $out"
  for id in start-a start-b; do
    assert_grep 'start_dir=game-link' "$HOME_DIR/state/$id.meta" "batch dropped relative directory"
    assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "batch changed root identity"
  done
  # Execute the contained symlink first, then retarget the same delivered command.
  launch=$(tail -n 1 "$LAUNCH_LOG")
  (cd "$WT_DIR" && FM_START_CAPTURE="$CASE_DIR/contained" sh -c "$launch") || fail 'contained symlink launch failed'
  [ "$(cat "$CASE_DIR/contained")" = "$(cd "$WT_DIR/game" && pwd -P)" ] || fail 'contained symlink did not resolve to game'
  rm "$WT_DIR/game-link"
  ln -s "$CASE_DIR/outside" "$WT_DIR/game-link"
  out=$(cd "$WT_DIR" && FM_START_CAPTURE="$CASE_DIR/escaped" sh -c "$launch" 2>&1)
  expect_code 1 "$?" "retargeted directory ran the harness: $out"
  assert_contains "$out" 'start directory changed before launch' 'retarget refusal missing'
  [ ! -f "$CASE_DIR/escaped" ] || fail 'harness executed after symlink escape'
  pass 'explicit root and batch startup work; a launch-time symlink retarget refuses before harness execution'
}


test_start_directory_root_batch_and_retarget

test_pi_start_directory_contract
test_start_directory_refusals
test_start_directory_refusal_on_projected_herdr_keeps_the_presentation_lock

test_worker_launch_delivers_role_scope
test_no_profile_keeps_claude_profile_defaults
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_cursor_threads_model_workspace_and_omits_effort_axis
test_cursor_refuses_model_absent_from_live_catalog
test_cursor_failed_catalog_probe_does_not_block_spawn
test_opencode_threads_model_and_ignores_effort_axis
test_native_effort_validator_keeps_axes_separate
test_native_pi_ultra_is_explicit_and_model_scoped
test_batch_preserves_native_ultra
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_claude_crewmate_launch_carries_the_attribution_policy
test_claude_secondmate_launch_carries_the_attribution_policy
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
