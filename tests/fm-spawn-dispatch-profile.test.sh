#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi-signed
  cat > "$fakebin/custom-agent" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_TEST_ADAPTER_ARG_LOG:-}" ]; then
  : > "$FM_TEST_ADAPTER_ARG_LOG"
  printf '%s\n' "$@" > "$FM_TEST_ADAPTER_ARG_LOG"
fi
SH
  chmod +x "$fakebin/custom-agent"
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
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
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
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
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

assert_claude_auto_permissions() {
  local launch=$1 context=$2
  assert_contains "$launch" "claude --permission-mode auto" \
    "$context did not select Claude's auto permission classifier"
  assert_not_contains "$launch" "--dangerously-skip-permissions" \
    "$context still used Claude's root-incompatible unrestricted bypass"
}

assert_no_claude_auto_permission_mode() {
  local launch=$1 context=$2
  assert_not_contains "$launch" "--permission-mode auto" \
    "$context received Claude's harness-specific permission mode"
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
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --permission-mode auto \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_claude_auto_permissions "$launch" "default Claude launch"
  pass "no --model/--effort records defaults and types the Claude auto-mode launch instructions"
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
  assert_contains "$launch" "< '$home_real/data/$id/brief.md'" \
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
  assert_contains "$launch" "< '$home_real/data/$relative_id/brief.md'" \
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
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/brief.md'" \
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
  assert_contains "$launch" "< '$linked_home/data/$id/brief.md'" \
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
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness or structured unverified adapter resolved from the dispatch rules" \
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
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness or structured unverified adapter resolved from the dispatch rules" \
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

test_active_dispatch_profile_allows_structured_unverified_adapter() {
  local rec id out status launch expected
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter custom-agent --adapter-arg=--flag)
  status=$?
  expect_code 0 "$status" "structured unverified adapter should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report unverified adapter identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  expected="'$FAKEBIN_DIR/custom-agent' '--flag'"
  [ "$launch" = "$expected" ] || fail "structured unverified adapter launch changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the structured unverified-adapter escape path"
}

assert_unsafe_claude_raw_refused() {
  local out=$1 status=$2 home=$3 launchlog=$4 id=$5 context=$6
  expect_code 1 "$status" "$context should reject a non-canonical Claude launch"
  assert_contains "$out" "refusing unverified adapter launch" \
    "$context refusal did not identify the invalid unverified-adapter launch"
  assert_contains "$out" "--unverified-adapter <name-ending-in--agent-or--adapter>" \
    "$context refusal did not provide migration guidance"
  assert_contains "$out" "--harness claude" \
    "$context refusal did not direct Claude launches to the canonical harness"
  assert_absent "$home/state/$id.meta" "$context refusal should happen before meta is written"
  assert_absent "$home/state/.spawn-$id.lock" "$context refusal should happen before task-lock acquisition"
  [ ! -s "$launchlog" ] || fail "$context refusal reached backend launch delivery"
}

test_claude_raw_bypass_refused_for_ship_before_launch() {
  local rec id out status
  id=profile-raw-claude-ship-z15a
  rec=$(make_spawn_case profile-raw-claude-ship claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "claude --dangerously-skip-permissions --model sonnet")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "raw Claude ship launch"
  pass "raw Claude ship bypass is refused before launch"
}

test_claude_raw_bypass_refused_for_scout_before_launch() {
  local rec id out status
  id=profile-raw-claude-scout-z15b
  rec=$(make_spawn_case profile-raw-claude-scout claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "claude --dangerously-skip-permissions --model sonnet" --scout)
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "raw Claude scout launch"
  pass "raw Claude scout bypass is refused before launch"
}

test_claude_raw_bypass_refused_for_secondmate_before_launch() {
  local rec id sm out status
  id=profile-raw-claude-secondmate-z15c
  rec=$(make_spawn_case profile-raw-claude-secondmate claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$sm" "claude --dangerously-skip-permissions --model sonnet" --secondmate)
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "raw Claude secondmate launch"
  pass "raw Claude secondmate bypass is refused before launch"
}

test_raw_claude_auto_mode_requires_canonical_harness() {
  local rec id raw out status
  id=profile-raw-claude-auto-z15d
  raw="claude --permission-mode auto --model sonnet"
  rec=$(make_spawn_case profile-raw-claude-auto claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "raw Claude auto-mode launch"
  pass "raw Claude auto mode is redirected to the canonical harness"
}

test_quoted_concatenation_claude_bypass_is_refused() {
  local rec id raw out status
  id=profile-raw-claude-quoted-z15e
  raw="clau''de --dangerously-skip-permis''sions --model sonnet"
  rec=$(make_spawn_case profile-raw-claude-quoted claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "quoted-concatenation Claude bypass"
  pass "quoted-concatenation Claude bypass is refused before launch"
}

test_env_wrapped_claude_bypass_is_refused() {
  local rec id raw out status
  id=profile-raw-claude-env-z15f
  raw="env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions"
  rec=$(make_spawn_case profile-raw-claude-env claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "env-wrapped Claude bypass"
  pass "env-wrapped Claude bypass is refused before launch"
}

test_shell_obfuscated_claude_bypass_is_refused() {
  local rec id raw out status
  id=profile-raw-claude-shell-z15g
  raw='$(printf clau%s de) --dangerously-skip-permissions'
  rec=$(make_spawn_case profile-raw-claude-shell claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "shell-obfuscated Claude bypass"
  pass "shell-obfuscated Claude bypass is refused before launch"
}

test_quoted_non_claude_legacy_launch_is_refused() {
  local rec id raw out status
  id=profile-raw-custom-quoted-z15h
  raw="custom-agent --prompt 'harmless review'"
  rec=$(make_spawn_case profile-raw-custom-quoted claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "quoted legacy launch command"
  pass "quoted legacy launch command is refused with migration guidance"
}

test_source_dispatcher_is_refused() {
  local rec id raw out status
  id=profile-raw-source-z15i
  raw="source ./worker-launch"
  rec=$(make_spawn_case profile-raw-source claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "source-dispatched raw launch"
  pass "source dispatcher is refused before launch"
}

test_posix_dot_dispatcher_is_refused() {
  local rec id raw out status
  id=profile-raw-dot-z15j
  raw=". ./worker-launch"
  rec=$(make_spawn_case profile-raw-dot claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "POSIX dot-dispatched raw launch"
  pass "POSIX dot dispatcher is refused before launch"
}

test_coproc_dispatcher_is_refused() {
  local rec id raw out status
  id=profile-raw-coproc-z15l
  raw="coproc claude --dangerously-skip-permissions"
  rec=$(make_spawn_case profile-raw-coproc claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "coproc-dispatched Claude bypass"
  pass "coproc dispatcher is refused before launch"
}

test_remaining_dispatchers_are_refused() {
  local spec name raw rec id out status
  local -a cases=(
    "noglob|noglob claude --dangerously-skip-permissions"
    "nocorrect|nocorrect claude --dangerously-skip-permissions"
    "dash-precommand|- claude --dangerously-skip-permissions"
    "script|script -c 'claude --dangerously-skip-permissions'"
    "watch|watch claude --dangerously-skip-permissions"
    "ash|ash -c 'claude --dangerously-skip-permissions'"
    "mksh|mksh -c 'claude --dangerously-skip-permissions'"
    "csh|csh -c 'claude --dangerously-skip-permissions'"
    "tcsh|tcsh -c 'claude --dangerously-skip-permissions'"
    "strace|strace claude --dangerously-skip-permissions"
    "perf|perf stat -n claude --dangerously-skip-permissions"
    "fish-not|not claude --dangerously-skip-permissions"
    "zsh-emulate|emulate sh -c 'claude --dangerously-skip-permissions'"
    "flock|/usr/bin/flock .lock claude --dangerously-skip-permissions"
    "setpriv|setpriv --no-new-privs claude --dangerously-skip-permissions"
    "prlimit|prlimit --nofile=1024:1024 claude --dangerously-skip-permissions"
    "unshare|unshare claude --dangerously-skip-permissions"
    "taskset|taskset -c 0 claude --dangerously-skip-permissions"
    "nsenter|nsenter claude --dangerously-skip-permissions"
    "numactl|numactl --localalloc claude --dangerously-skip-permissions"
    "setarch|setarch x86_64 claude --dangerously-skip-permissions"
    "linux32|linux32 claude --dangerously-skip-permissions"
    "linux64|linux64 claude --dangerously-skip-permissions"
    "chroot|chroot / claude --dangerously-skip-permissions"
    "runuser|runuser -u root -- claude --dangerously-skip-permissions"
    "su|su root -c 'claude --dangerously-skip-permissions'"
    "sg|sg root -c 'claude --dangerously-skip-permissions'"
    "start-stop-daemon|start-stop-daemon --start --exec claude -- --dangerously-skip-permissions"
    "systemd-run|systemd-run --scope claude --dangerously-skip-permissions"
    "npx|npx -c 'claude --dangerously-skip-permissions'"
    "npm|npm exec -c 'claude --dangerously-skip-permissions'"
  )

  for spec in "${cases[@]}"; do
    name=${spec%%|*}
    raw=${spec#*|}
    id="profile-raw-${name}-z15m"
    rec=$(make_spawn_case "profile-raw-$name" claude "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$raw")
    status=$?
    assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
      "$name-dispatched Claude bypass"
  done
  pass "remaining raw-launch dispatchers are refused before launch"
}

test_forbidden_permission_flag_is_refused_across_raw_commands() {
  local spec name raw rec id out status
  local -a cases=(
    "direct|custom-agent --dangerously-skip-permissions"
    "quote-split|custom-agent --dangerously-skip-permis''sions"
    "git-alias|git -c alias.x='!/root/.local/bin/claude --dangerously-skip-permissions' x"
  )

  for spec in "${cases[@]}"; do
    name=${spec%%|*}
    raw=${spec#*|}
    id="profile-raw-forbidden-${name}-z15n"
    rec=$(make_spawn_case "profile-raw-forbidden-$name" claude "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$raw")
    status=$?
    assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
      "$name forbidden-permission flag"
  done
  pass "forbidden permission flags are refused across raw commands"
}

test_forbidden_permission_glob_is_refused() {
  local rec id raw out status
  id=profile-raw-forbidden-glob-z15o
  raw="git -c alias.x='!/root/.local/bin/claude --dangerously-skip-*' x"
  rec=$(make_spawn_case profile-raw-forbidden-glob claude "$id")
  read_case_record "$rec"
  : > "$WT_DIR/--dangerously-skip-permissions"
  git -C "$WT_DIR" add -- --dangerously-skip-permissions

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$raw")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "glob-synthesized forbidden-permission flag"
  pass "glob-synthesized forbidden permission flag is refused before launch"
}

test_unverified_adapter_boundary_rejects_unsafe_forms() {
  local rec id out status

  id=profile-unverified-interpreter-z15p
  rec=$(make_spawn_case profile-unverified-interpreter claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter perl --adapter-arg=-e --adapter-arg=print)
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "interpreter unverified adapter"

  id=profile-unverified-inline-z15q
  rec=$(make_spawn_case profile-unverified-inline claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter custom-agent --adapter-arg='exec("claude")')
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "inline-code unverified adapter argument"

  id=profile-unverified-glob-z15r
  rec=$(make_spawn_case profile-unverified-glob claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter custom-agent --adapter-arg='src/*.sh')
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "glob unverified adapter argument"

  id=profile-unverified-forbidden-z15s
  rec=$(make_spawn_case profile-unverified-forbidden claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter custom-agent --adapter-arg=--dangerously-skip-permissions)
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "forbidden permission unverified adapter argument"
  pass "unverified adapter boundary rejects interpreters, inline code, globs, and forbidden permissions"
}

test_unverified_adapter_preserves_literal_non_claude_arguments() {
  local rec id expected out status launch arglog claude_log rcfile
  id=profile-raw-custom-claude-model-z15k
  rec=$(make_spawn_case profile-raw-custom-claude-model claude "$id")
  read_case_record "$rec"
  expected="'$FAKEBIN_DIR/custom-agent' '--model' 'anthropic/claude-sonnet-4-5'"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter custom-agent \
    --adapter-arg=--model --adapter-arg=anthropic/claude-sonnet-4-5)
  status=$?
  expect_code 0 "$status" "direct unverified adapter with literal Claude model argument should succeed"
  assert_contains "$out" "spawned $id harness=custom-agent" \
    "direct unverified adapter lost its identity"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "$expected" ] || fail "direct unverified adapter literal argv changed"$'\n'"actual: $launch"
  arglog="$CASE_DIR/adapter-args.log"
  claude_log="$CASE_DIR/claude.log"
  rcfile="$CASE_DIR/bashrc"
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_TEST_CLAUDE_LOG"
SH
  chmod +x "$FAKEBIN_DIR/claude"
  printf "%s\n" "alias custom-agent='claude --dangerously-skip-permissions'" > "$rcfile"
  FM_TEST_ADAPTER_ARG_LOG="$arglog" FM_TEST_CLAUDE_LOG="$claude_log" PATH="$FAKEBIN_DIR:$PATH" \
    bash --noprofile --rcfile "$rcfile" -ic "$launch" >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "quoted absolute adapter launch should survive a hostile pane alias"
  assert_absent "$claude_log" "hostile pane alias intercepted the resolved adapter executable"
  [ "$(cat "$arglog")" = $'--model\nanthropic/claude-sonnet-4-5' ] || \
    fail "interactive pane execution changed literal adapter arguments"
  pass "resolved adapter path defeats aliases and preserves literal argv"
}

test_unverified_adapter_rejects_invalid_executables() {
  local rec id out status bad_path

  id=profile-unverified-missing-z15t
  rec=$(make_spawn_case profile-unverified-missing claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter missing-agent)
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "missing unverified adapter"
  assert_contains "$out" "could not be resolved on PATH" "missing adapter refusal was not specific"

  id=profile-unverified-nonexec-z15u
  rec=$(make_spawn_case profile-unverified-nonexec claude "$id")
  read_case_record "$rec"
  bad_path="$CASE_DIR/nonexec-agent"
  : > "$bad_path"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter "$bad_path")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "non-executable unverified adapter"
  assert_contains "$out" "not a regular executable file" "non-executable adapter refusal was not specific"

  id=profile-unverified-unsafe-z15v
  rec=$(make_spawn_case profile-unverified-unsafe claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter 'unsafe agent')
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "unsafe-path unverified adapter"
  assert_contains "$out" "contains unsafe syntax" "unsafe adapter path refusal was not specific"

  id=profile-unverified-unresolvable-z15w
  rec=$(make_spawn_case profile-unverified-unresolvable claude "$id")
  read_case_record "$rec"
  bad_path="$CASE_DIR/absent/unresolvable-agent"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --unverified-adapter "$bad_path")
  status=$?
  assert_unsafe_claude_raw_refused "$out" "$status" "$HOME_DIR" "$LAUNCH_LOG" "$id" \
    "unresolvable-path unverified adapter"
  assert_contains "$out" "path could not be resolved" "unresolvable adapter path refusal was not specific"
  pass "unverified adapter rejects missing, non-executable, unsafe, and unresolvable paths"
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
  assert_claude_auto_permissions "$launch" "profiled Claude ship launch"
  assert_contains "$launch" "claude --permission-mode auto --model 'sonnet' --effort 'high'" \
    "Claude launch did not thread model and effort flags after auto permission mode"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md'" \
    "Claude launch lost typed prompt delivery"
  pass "Claude receives auto permissions plus --model, --effort, and typed prompt delivery"
}

test_claude_scout_uses_auto_permissions_and_delivers_profiled_prompt() {
  local rec id out status launch
  id=profile-claude-scout-z2b
  rec=$(make_spawn_case profile-claude-scout claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "profiled Claude scout spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=scout" \
    "Claude scout spawn did not report the expected harness and kind"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_claude_auto_permissions "$launch" "profiled Claude scout launch"
  assert_contains "$launch" "claude --permission-mode auto --model 'sonnet' --effort 'high'" \
    "Claude scout launch lost model or effort delivery"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md'" \
    "Claude scout launch lost typed prompt delivery"
  pass "Claude scout launches share auto permissions and retain profile plus prompt delivery"
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
  assert_no_claude_auto_permission_mode "$launch" "Codex launch"
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
  assert_no_claude_auto_permission_mode "$launch" "Codex max-effort launch"
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
  assert_no_claude_auto_permission_mode "$launch" "Grok launch"
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
  assert_no_claude_auto_permission_mode "$launch" "OpenCode launch"
  pass "opencode receives --model and omits the unsupported effort axis"
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
  assert_contains "$launch" "FM_PI_HARNESS=pi pi --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  assert_no_claude_auto_permission_mode "$launch" "Pi launch"
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
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed pi-signed --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not share Pi's model, thinking, and extension semantics"
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed pi-signed -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not share Pi's primary extension launch shape"
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

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
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

test_no_profile_keeps_claude_profile_defaults
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_structured_unverified_adapter
test_claude_raw_bypass_refused_for_ship_before_launch
test_claude_raw_bypass_refused_for_scout_before_launch
test_claude_raw_bypass_refused_for_secondmate_before_launch
test_raw_claude_auto_mode_requires_canonical_harness
test_quoted_concatenation_claude_bypass_is_refused
test_env_wrapped_claude_bypass_is_refused
test_shell_obfuscated_claude_bypass_is_refused
test_quoted_non_claude_legacy_launch_is_refused
test_source_dispatcher_is_refused
test_posix_dot_dispatcher_is_refused
test_coproc_dispatcher_is_refused
test_remaining_dispatchers_are_refused
test_forbidden_permission_flag_is_refused_across_raw_commands
test_forbidden_permission_glob_is_refused
test_unverified_adapter_boundary_rejects_unsafe_forms
test_unverified_adapter_preserves_literal_non_claude_arguments
test_unverified_adapter_rejects_invalid_executables
test_claude_threads_model_and_effort
test_claude_scout_uses_auto_permissions_and_delivers_profiled_prompt
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
