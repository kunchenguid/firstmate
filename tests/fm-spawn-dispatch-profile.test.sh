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

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ] && [ "$(basename "$0")" = prime-agent ]; then
  printf '%s\n' '0.8.1'
  exit 0
fi
if [ "${1:-}" = --help ]; then
  if [ "$(basename "$0")" = prime-agent ]; then
    printf '%s\n' 'Prime Agent 0.8.1' 'Options: --daemon-socket <path>'
    exit 0
  fi
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
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
if [ "${FM_TEST_RELAUNCH_DEAD:-0}" = 1 ]; then
  case "$*" in
    *"#{window_name}"*) printf '%b\n' "${FM_TEST_RELAUNCH_WINDOWS:-}"; exit 0 ;;
    *"#{pane_current_command}"*) printf '%s\n' zsh; exit 0 ;;
    *"#{pane_tty}"*) exit 0 ;;
  esac
fi
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
  fm_fake_exit0 "$fakebin" treehouse
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
  make_spawn_pi_probe "$fakebin" prime-agent
  fm_fake_exit0 "$fakebin" claude
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
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
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
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
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
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
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

test_active_dispatch_profile_rejects_raw_launch_command() {
  local rec id out status
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 1 "$status" "raw launch command must be rejected"
  assert_contains "$out" "cannot prove complete runtime identity" "raw launch refusal did not name the identity boundary"
  assert_absent "$HOME_DIR/state/$id.meta" "raw launch refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "raw launch refusal sent a command"
  pass "active dispatch profiles require a verified harness"
}

test_raw_prime_launch_is_rejected_before_endpoint_creation() {
  local rec id out status index prime_package
  local -a ids commands
  ids=(profile-raw-prime-z15b profile-raw-prime-command-z15b profile-raw-prime-exec-z15b profile-raw-prime-env-z15b profile-raw-prime-node-z15b profile-raw-prime-shell-z15b profile-raw-prime-quoted-z15b profile-raw-prime-alias-z15b profile-raw-prime-wrapper-z15b profile-raw-prime-opaque-wrapper-z15b profile-raw-prime-variable-z15b profile-raw-prime-semicolon-z15b profile-raw-prime-substitution-z15b profile-raw-prime-allowlisted-wrapper-z15b profile-raw-prime-launcher-alias-z15b profile-raw-prime-system-launcher-z15b)
  rec=$(make_spawn_case profile-raw-prime claude "${ids[@]}" profile-raw-prime-mislabeled-z15b profile-raw-prime-opaque-mislabeled-z15b)
  read_case_record "$rec"
  prime_package="$CASE_DIR/prime-package"
  mkdir -p "$prime_package/dist/bundle"
  printf '%s\n' '{"name":"prime-agent","bin":{"prime-agent":"dist/bundle/cli.js"}}' > "$prime_package/package.json"
  cat > "$prime_package/dist/bundle/cli.js" <<'SH'
#!/usr/bin/env node
SH
  cat > "$FAKEBIN_DIR/prime-wrapper" <<'SH'
#!/usr/bin/env bash
exec prime-agent "$@"
SH
  cat > "$FAKEBIN_DIR/opaque-wrapper" <<'SH'
#!/usr/bin/env bash
runner=prime-agent
exec "$runner" "$@"
SH
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
runner=prime-agent
exec "$runner" "$@"
SH
  chmod +x "$prime_package/dist/bundle/cli.js" "$FAKEBIN_DIR/prime-wrapper" "$FAKEBIN_DIR/opaque-wrapper" "$FAKEBIN_DIR/claude"
  ln -sf "$(type -P true)" "$FAKEBIN_DIR/prime-agent"
  ln -s "$prime_package/dist/bundle/cli.js" "$FAKEBIN_DIR/prime-proxy"
  ln -s "$(type -P env)" "$FAKEBIN_DIR/envx"
  # shellcheck disable=SC2016 # The raw commands must keep literal shell syntax.
  commands=("prime-agent --flag" "command prime-agent --flag" "exec prime-agent --flag" "env prime-agent --flag" "node $prime_package/dist/bundle/cli.js" "bash $FAKEBIN_DIR/opaque-wrapper --flag" "'$FAKEBIN_DIR/prime-agent' --flag" "prime-proxy --flag" "prime-wrapper --flag" "opaque-wrapper --flag" 'x=prime-; y=agent; exec "$x$y"' "claude --flag;prime-agent" 'claude --flag $(prime-agent)' "claude --flag" "envx prime-agent --flag" "/usr/bin/arch prime-agent --flag")

  for index in "${!ids[@]}"; do
    id=${ids[$index]}
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "${commands[$index]}")
    status=$?
    expect_code 1 "$status" "raw Prime launch form must be rejected: ${commands[$index]}"
    assert_contains "$out" "Prime isolation boundary" "raw Prime refusal did not name the isolation boundary"
    assert_absent "$HOME_DIR/state/$id.meta" "raw Prime refusal wrote task metadata"
    [ ! -s "$LAUNCH_LOG" ] || fail "raw Prime refusal sent a launch command"
    assert_absent "$HOME_DIR/state/$id.prime-ext.ts" "raw Prime refusal installed an extension"
    assert_absent "$HOME_DIR/state/$id.busy-gen" "raw Prime refusal armed busy state"
  done
  id=profile-raw-prime-mislabeled-z15b
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "prime-agent --flag" --harness claude)
  status=$?
  expect_code 1 "$status" "a non-Prime harness label must not admit a raw Prime command"
  assert_contains "$out" "Prime isolation boundary" "mislabeled raw Prime refusal did not name the isolation boundary"
  assert_absent "$HOME_DIR/state/$id.meta" "mislabeled raw Prime refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "mislabeled raw Prime refusal sent a launch command"
  id=profile-raw-prime-opaque-mislabeled-z15b
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "opaque-wrapper --flag" --harness claude)
  status=$?
  expect_code 1 "$status" "an opaque wrapper must not claim a verified non-Prime executable identity"
  assert_contains "$out" "Prime isolation boundary" "opaque wrapper refusal did not name the isolation boundary"
  assert_absent "$HOME_DIR/state/$id.meta" "opaque wrapper refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "opaque wrapper refusal sent a launch command"
  pass "raw launch commands fail closed before endpoint creation"
}

test_native_non_prime_raw_launch_is_preserved() {
  local rec id out status launch system_id copied_id
  id=profile-raw-native-z15c
  system_id=profile-raw-system-native-z15c
  copied_id=profile-raw-copied-native-z15c
  rec=$(make_spawn_case profile-raw-native claude "$id" "$system_id" "$copied_id")
  read_case_record "$rec"
  ln -sf "$(type -P true)" "$FAKEBIN_DIR/custom-agent"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "direct non-Prime raw launch should remain available"
  assert_contains "$out" "spawned $id harness=custom-agent" "raw launch did not retain executable identity"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "custom-agent --flag" "non-Prime raw command was not preserved"
  ln -sf "$(type -P uname)" "$FAKEBIN_DIR/system-agent"
  : > "$LAUNCH_LOG"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$system_id" "$PROJ_DIR" "system-agent --flag")
  status=$?
  expect_code 1 "$status" "an unlisted protected system executable must not cross the raw launch boundary"
  assert_contains "$out" "Prime isolation boundary" "unlisted system executable refusal did not name the isolation boundary"
  assert_absent "$HOME_DIR/state/$system_id.meta" "unlisted system executable refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "unlisted system executable refusal sent a launch command"
  cp "$(type -P true)" "$FAKEBIN_DIR/copied-agent"
  chmod +x "$FAKEBIN_DIR/copied-agent"
  : > "$LAUNCH_LOG"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$copied_id" "$PROJ_DIR" "copied-agent --flag")
  status=$?
  expect_code 1 "$status" "an arbitrary native executable must not cross the raw launch boundary"
  assert_contains "$out" "Prime isolation boundary" "arbitrary native executable refusal did not name the isolation boundary"
  assert_absent "$HOME_DIR/state/$copied_id.meta" "arbitrary native executable refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "arbitrary native executable refusal sent a launch command"
  pass "trusted native non-Prime raw launch commands remain available"
}

test_prime_extension_serializes_generated_values() {
  local rec id out status extension state_literal turnend_literal quoted_home
  id=profile-prime-serialized-z15d
  rec=$(make_spawn_case profile-prime-special-path prime-agent "$id")
  read_case_record "$rec"
  quoted_home="$CASE_DIR/home-'\\path"
  mv "$HOME_DIR" "$quoted_home"
  HOME_DIR=$quoted_home

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "prime-agent spawn with quoted state paths should succeed"
  extension=$(cat "$HOME_DIR/state/$id.prime-ext.ts")
  state_literal=$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$(cd "$HOME_DIR/state" && pwd -P)")
  turnend_literal=$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$(cd "$HOME_DIR/state" && pwd -P)/$id.turn-ended")
  assert_contains "$extension" "$state_literal" "Prime extension did not serialize its state path"
  assert_contains "$extension" "$turnend_literal" "Prime extension did not serialize its turn-end path"
  pass "prime-agent extension serializes generated string values"
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
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
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

test_prime_agent_threads_model_thinking_and_semantic_extension() {
  local rec id out status launch prime_dir prime_home prime_session_dir prime_daemon_socket first_launch env_log operator_home root_line
  local second_id second_proj second_wt second_prime_dir second_prime_home second_prime_session_dir second_daemon_socket second_launch second_env_log
  local alternate_home alternate_id alternate_daemon_socket
  id=profile-prime-agent-z8c
  rec=$(make_spawn_case profile-prime-agent prime-agent "$id")
  read_case_record "$rec"
  operator_home="$CASE_DIR/operator-home"
  mkdir -p "$operator_home/.agents/skills/no-mistakes"
  printf '%s\n' '---' 'name: no-mistakes' '---' '# no-mistakes' > "$operator_home/.agents/skills/no-mistakes/SKILL.md"
  git config --file "$operator_home/.gitconfig" user.name "Prime Test"
  git config --file "$operator_home/.gitconfig" user.email "prime-test@example.test"
  git config --file "$operator_home/.gitconfig" credential.helper "shared-secret-helper"

  cat > "$FAKEBIN_DIR/shasum" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'not-a-digest  -'
SH
  cat > "$FAKEBIN_DIR/sha256sum" <<'SH'
#!/usr/bin/env bash
node -e 'const { createHash } = require("node:crypto"); let data = ""; process.stdin.setEncoding("utf8"); process.stdin.on("data", chunk => data += chunk); process.stdin.on("end", () => process.stdout.write(createHash("sha256").update(data).digest("hex") + "  -\n"));'
SH
  cat > "$FAKEBIN_DIR/prime-agent" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --version ]; then printf '%s\n' 'Prime Agent version v0.8.1 (project daemon build)'; exit 0; fi
if [ "${1:-}" = --help ]; then printf '%s\n' 'Options: --daemon-socket <path>'; exit 0; fi
: "${FM_FAKE_PRIME_ENV_LOG:?}"
runtime_home=$(node -p 'require("node:os").homedir()')
daemon_socket=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --daemon-socket ]; then daemon_socket=${2:-}; break; fi
  shift
done
  {
  printf 'home=%s\n' "$runtime_home"
  printf 'agent_dir=%s\n' "${PRIME_AGENT_CODING_AGENT_DIR:-}"
  printf 'session_dir=%s\n' "${PRIME_AGENT_SESSION_DIR:-}"
  printf 'daemon_socket=%s\n' "$daemon_socket"
  printf 'xdg_config=%s\n' "${XDG_CONFIG_HOME:-}"
  printf 'xdg_data=%s\n' "${XDG_DATA_HOME:-}"
  printf 'xdg_cache=%s\n' "${XDG_CACHE_HOME:-}"
  printf 'xdg_state=%s\n' "${XDG_STATE_HOME:-}"
  printf 'xdg_runtime=%s\n' "${XDG_RUNTIME_DIR:-}"
  printf 'gh_config=%s\n' "${GH_CONFIG_DIR:-}"
  printf 'cloudsdk_config=%s\n' "${CLOUDSDK_CONFIG:-}"
  printf 'kernel_venv=%s\n' "${PRIME_AGENT_KERNEL_VENV:-}"
  printf 'kernel_python=%s\n' "${PRIME_AGENT_KERNEL_PYTHON:-}"
  printf 'aws_credentials=%s\n' "${AWS_SHARED_CREDENTIALS_FILE:-}"
  printf 'aws_config=%s\n' "${AWS_CONFIG_FILE:-}"
  printf 'azure_config=%s\n' "${AZURE_CONFIG_DIR:-}"
  printf 'docker_config=%s\n' "${DOCKER_CONFIG:-}"
  printf 'kube_config=%s\n' "${KUBECONFIG:-}"
  printf 'hf_home=%s\n' "${HF_HOME:-}"
  printf 'gnupg_home=%s\n' "${GNUPGHOME:-}"
  printf 'npm_config=%s\n' "${NPM_CONFIG_USERCONFIG:-}"
  printf 'netrc=%s\n' "${NETRC:-}"
  for name in PRIME_AGENT_CODING_AGENT_SESSION_DIR PRIME_API_KEY PRIME_AGENT_TRACES_API_KEY PRIME_AGENT_INTERNAL_DAEMON_WORKER_TOKEN PRIME_TEAM_ID OPENAI_API_KEY ANTHROPIC_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN GH_TOKEN SERPER_API_KEY GOOGLE_APPLICATION_CREDENTIALS google_application_credentials AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY SSH_AUTH_SOCK SSH_AGENT_PID GIT_ASKPASS SSH_ASKPASS SUDO_ASKPASS GIT_SSH GIT_SSH_COMMAND GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
    [ -z "${!name+x}" ] || printf 'visible=%s\n' "$name"
  done
  if [ -f "$runtime_home/.prime/config.json" ]; then
    node --input-type=commonjs - "$runtime_home/.prime/config.json" <<'NODE'
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
process.stdout.write(`config_project=${config.project}\n`);
NODE
  else
    printf '%s\n' 'config_project=missing'
  fi
  [ ! -f "$runtime_home/.agents/skills/no-mistakes/SKILL.md" ] || printf '%s\n' 'skill=no-mistakes'
  printf 'git_name=%s\n' "$(git -C "$FM_FAKE_PRIME_GIT_REPO" config user.name)"
  printf 'git_email=%s\n' "$(git -C "$FM_FAKE_PRIME_GIT_REPO" config user.email)"
  if git -C "$FM_FAKE_PRIME_GIT_REPO" config --global --get credential.helper >/dev/null 2>&1; then
    printf '%s\n' 'credential_helper=visible'
  fi
  printf '%s\n' 'prime tooling probe' > "$FM_FAKE_PRIME_GIT_REPO/$FM_FAKE_PRIME_COMMIT_FILE"
  git -C "$FM_FAKE_PRIME_GIT_REPO" add "$FM_FAKE_PRIME_COMMIT_FILE"
  git -C "$FM_FAKE_PRIME_GIT_REPO" commit -m 'Prime tooling probe' >/dev/null
  printf '%s\n' 'git_commit=ok'
} > "$FM_FAKE_PRIME_ENV_LOG"
SH
  chmod +x "$FAKEBIN_DIR/shasum" "$FAKEBIN_DIR/sha256sum" "$FAKEBIN_DIR/prime-agent"
  mkdir -p "$HOME_DIR/.prime"
  printf '%s\n' '{"project":"global"}' > "$HOME_DIR/.prime/config.json"

  out=$(HOME="$operator_home" GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model deepseek-v4-flash --effort max)
  status=$?
  expect_code 0 "$status" "prime-agent spawn with model and max effort should succeed"
  assert_contains "$out" "spawned $id harness=prime-agent" \
    "prime-agent spawn did not preserve its adapter identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" prime-agent deepseek-v4-flash max
  prime_home=$(sed -n 's/^prime_home=//p' "$HOME_DIR/state/$id.meta")
  prime_dir=$(sed -n 's/^prime_agent_dir=//p' "$HOME_DIR/state/$id.meta")
  prime_session_dir=$(sed -n 's/^prime_session_dir=//p' "$HOME_DIR/state/$id.meta")
  prime_daemon_socket=$(sed -n 's/^prime_daemon_socket=//p' "$HOME_DIR/state/$id.meta")
  case "$prime_dir" in
    "$HOME_DIR/state/prime-projects/"*/home/.prime/agent) : ;;
    *) fail "prime-agent metadata did not record project-scoped state: $prime_dir" ;;
  esac
  [ "$prime_dir" = "$prime_home/.prime/agent" ] || \
    fail "prime-agent home and agent directory are not aligned: $prime_home | $prime_dir"
  [ "$prime_session_dir" = "$prime_dir/sessions" ] || \
    fail "prime-agent session directory is not project scoped: $prime_session_dir"
  assert_present "$prime_dir" "prime-agent did not create its project-scoped state directory"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "HOME='$prime_home' GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL='$prime_home/.gitconfig' PRIME_AGENT_CODING_AGENT_DIR='$prime_dir' PRIME_AGENT_SESSION_DIR='$prime_session_dir'" \
    "prime-agent launch dropped project isolation, model, thinking, or its explicit extension flag"
  assert_contains "$launch" "'$FAKEBIN_DIR/prime-agent' --model 'deepseek-v4-flash' --thinking 'max' --daemon-socket '$prime_daemon_socket' -e '$HOME_DIR/state/$id.prime-ext.ts'" \
    "prime-agent launch dropped its model, thinking, daemon socket, or extension"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "prime-agent launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.prime-ext.ts" \
    "prime-agent launch did not install its semantic lifecycle extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" \
    "prime-agent spawn did not arm the busy-state contract"
  printf '%s\n' '{"project":"one"}' > "$prime_home/.prime/config.json"
  chmod 600 "$prime_home/.prime/config.json"
  first_launch=$launch
  env_log="$CASE_DIR/prime-one.env"
  out=$(
    cd "$WT_DIR" || exit 1
    HOME="$HOME_DIR" PRIME_API_KEY=ambient-prime OPENAI_API_KEY=ambient-openai \
      ANTHROPIC_OAUTH_TOKEN=ambient-anthropic ANTHROPIC_AUTH_TOKEN=ambient-anthropic-auth \
      GH_TOKEN=ambient-github SERPER_API_KEY=ambient-serper \
      PRIME_AGENT_INTERNAL_DAEMON_WORKER_TOKEN=ambient-daemon-token \
      PRIME_AGENT_SESSION_DIR=/tmp/ambient-prime-sessions \
      PRIME_AGENT_CODING_AGENT_SESSION_DIR=/tmp/ambient-prime-legacy-sessions \
      PRIME_TEAM_ID=ambient-team GOOGLE_APPLICATION_CREDENTIALS=/tmp/ambient-google.json \
      google_application_credentials=/tmp/ambient-google-lower.json \
      AWS_ACCESS_KEY_ID=ambient-aws AWS_SECRET_ACCESS_KEY=ambient-aws-secret \
      GIT_AUTHOR_NAME=ambient-author GIT_AUTHOR_EMAIL=ambient-author@example.test \
      GIT_COMMITTER_NAME=ambient-committer GIT_COMMITTER_EMAIL=ambient-committer@example.test \
      SSH_AUTH_SOCK=/tmp/ambient-ssh-agent.sock SSH_AGENT_PID=999 \
      GIT_ASKPASS=/tmp/ambient-git-askpass SSH_ASKPASS=/tmp/ambient-ssh-askpass \
      SUDO_ASKPASS=/tmp/ambient-sudo-askpass GIT_SSH=/tmp/ambient-git-ssh \
      GIT_SSH_COMMAND='ssh -i /tmp/ambient-key' \
      XDG_CONFIG_HOME=/tmp/ambient-xdg-config XDG_DATA_HOME=/tmp/ambient-xdg-data \
      XDG_CACHE_HOME=/tmp/ambient-xdg-cache XDG_STATE_HOME=/tmp/ambient-xdg-state \
      XDG_RUNTIME_DIR=/tmp/ambient-xdg-runtime GH_CONFIG_DIR=/tmp/ambient-gh \
      CLOUDSDK_CONFIG=/tmp/ambient-gcloud PRIME_AGENT_KERNEL_VENV=/tmp/ambient-kernel \
      PRIME_AGENT_KERNEL_PYTHON=/tmp/ambient-python AWS_SHARED_CREDENTIALS_FILE=/tmp/ambient-aws-creds \
      AWS_CONFIG_FILE=/tmp/ambient-aws-config AZURE_CONFIG_DIR=/tmp/ambient-azure \
      DOCKER_CONFIG=/tmp/ambient-docker KUBECONFIG=/tmp/ambient-kube HF_HOME=/tmp/ambient-hf \
      GNUPGHOME=/tmp/ambient-gnupg NPM_CONFIG_USERCONFIG=/tmp/ambient-npmrc NETRC=/tmp/ambient-netrc \
      GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" FM_FAKE_PRIME_GIT_REPO="$WT_DIR" \
      FM_FAKE_PRIME_COMMIT_FILE=prime-tooling-one.txt FM_FAKE_PRIME_ENV_LOG="$env_log" bash -c "$first_launch"
  )
  status=$?
  expect_code 0 "$status" "isolated prime-agent launch command should execute"
  assert_grep "home=$prime_home" "$env_log" "prime-agent did not receive its project-scoped home"
  assert_grep "agent_dir=$prime_dir" "$env_log" "prime-agent did not receive its project-scoped agent directory"
  assert_grep "session_dir=$prime_session_dir" "$env_log" "prime-agent did not receive its project-scoped session directory"
  assert_grep "daemon_socket=/tmp/firstmate-prime-" "$env_log" "prime-agent did not receive a short scoped daemon socket"
  for root_line in \
    "xdg_config=$prime_home/.config" "xdg_data=$prime_home/.local/share" \
    "xdg_cache=$prime_home/.cache" "xdg_state=$prime_home/.local/state" \
    "xdg_runtime=$prime_home/.local/run" "gh_config=$prime_home/.config/gh" \
    "cloudsdk_config=$prime_home/.config/gcloud" "kernel_venv=$prime_dir/kernel-venv" \
    "kernel_python=$prime_dir/kernel-venv/bin/python" "aws_credentials=$prime_home/.aws/credentials" \
    "aws_config=$prime_home/.aws/config" "azure_config=$prime_home/.azure" \
    "docker_config=$prime_home/.docker" "kube_config=$prime_home/.kube/config" \
    "hf_home=$prime_home/.cache/huggingface" "gnupg_home=$prime_home/.gnupg" \
    "npm_config=$prime_home/.npmrc" "netrc=$prime_home/.netrc"; do
    assert_grep "$root_line" "$env_log" "prime-agent configuration root escaped project isolation: $root_line"
  done
  assert_grep "config_project=one" "$env_log" "prime-agent did not read the first project's CLI config"
  assert_grep "skill=no-mistakes" "$env_log" "prime-agent did not discover the permitted no-mistakes skill"
  assert_grep "git_name=Prime Test" "$env_log" "prime-agent did not receive the permitted Git author name"
  assert_grep "git_email=prime-test@example.test" "$env_log" "prime-agent did not receive the permitted Git author email"
  assert_grep "git_commit=ok" "$env_log" "prime-agent could not commit with its isolated tooling config"
  [ "$(git -C "$WT_DIR" log -1 --format=%s)" = "Prime tooling probe" ] || \
    fail "prime-agent tooling probe did not create a real commit"
  assert_no_grep "credential_helper=visible" "$env_log" "prime-agent inherited the operator's Git credential helper"
  assert_no_grep "visible=" "$env_log" "prime-agent inherited an ambient credential source"

  second_id=profile-prime-agent-other-project-z8c
  second_proj="$CASE_DIR/project-two"
  second_wt="$CASE_DIR/wt-two"
  fm_git_worktree "$second_proj" "$second_wt" profile-prime-agent-other-project
  mkdir -p "$HOME_DIR/data/$second_id"
  printf 'brief for %s\n' "$second_id" > "$HOME_DIR/data/$second_id/brief.md"
  out=$(HOME="$operator_home" GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" \
    run_ship_spawn "$HOME_DIR" "$second_wt" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$second_id" "$second_proj")
  status=$?
  expect_code 0 "$status" "prime-agent spawn for a second project should succeed"
  second_prime_home=$(sed -n 's/^prime_home=//p' "$HOME_DIR/state/$second_id.meta")
  second_prime_dir=$(sed -n 's/^prime_agent_dir=//p' "$HOME_DIR/state/$second_id.meta")
  second_prime_session_dir=$(sed -n 's/^prime_session_dir=//p' "$HOME_DIR/state/$second_id.meta")
  second_daemon_socket=$(sed -n 's/^prime_daemon_socket=//p' "$HOME_DIR/state/$second_id.meta")
  [ -n "$second_prime_home" ] && [ "$second_prime_home" != "$prime_home" ] && \
    [ -n "$second_prime_dir" ] && [ "$second_prime_dir" != "$prime_dir" ] || \
    fail "distinct projects must not share Prime Agent state: $prime_dir"
  [ "$second_prime_session_dir" = "$second_prime_dir/sessions" ] || \
    fail "second project did not receive an isolated Prime session directory"
  assert_present "$second_prime_dir" "second project did not receive its own Prime Agent state directory"
  printf '%s\n' '{"project":"two"}' > "$second_prime_home/.prime/config.json"
  chmod 600 "$second_prime_home/.prime/config.json"
  second_launch=$(cat "$LAUNCH_LOG")
  second_env_log="$CASE_DIR/prime-two.env"
  out=$(
    cd "$second_wt" || exit 1
    HOME="$HOME_DIR" PRIME_API_KEY=ambient-prime OPENAI_API_KEY=ambient-openai \
      ANTHROPIC_OAUTH_TOKEN=ambient-anthropic ANTHROPIC_AUTH_TOKEN=ambient-anthropic-auth \
      GH_TOKEN=ambient-github SERPER_API_KEY=ambient-serper \
      PRIME_AGENT_INTERNAL_DAEMON_WORKER_TOKEN=ambient-daemon-token \
      PRIME_AGENT_SESSION_DIR=/tmp/ambient-prime-sessions \
      PRIME_AGENT_CODING_AGENT_SESSION_DIR=/tmp/ambient-prime-legacy-sessions \
      PRIME_TEAM_ID=ambient-team GOOGLE_APPLICATION_CREDENTIALS=/tmp/ambient-google.json \
      google_application_credentials=/tmp/ambient-google-lower.json \
      AWS_ACCESS_KEY_ID=ambient-aws AWS_SECRET_ACCESS_KEY=ambient-aws-secret \
      GIT_AUTHOR_NAME=ambient-author GIT_AUTHOR_EMAIL=ambient-author@example.test \
      GIT_COMMITTER_NAME=ambient-committer GIT_COMMITTER_EMAIL=ambient-committer@example.test \
      SSH_AUTH_SOCK=/tmp/ambient-ssh-agent.sock SSH_AGENT_PID=999 \
      GIT_ASKPASS=/tmp/ambient-git-askpass SSH_ASKPASS=/tmp/ambient-ssh-askpass \
      SUDO_ASKPASS=/tmp/ambient-sudo-askpass GIT_SSH=/tmp/ambient-git-ssh \
      GIT_SSH_COMMAND='ssh -i /tmp/ambient-key' \
      XDG_CONFIG_HOME=/tmp/ambient-xdg-config XDG_DATA_HOME=/tmp/ambient-xdg-data \
      XDG_CACHE_HOME=/tmp/ambient-xdg-cache XDG_STATE_HOME=/tmp/ambient-xdg-state \
      XDG_RUNTIME_DIR=/tmp/ambient-xdg-runtime GH_CONFIG_DIR=/tmp/ambient-gh \
      CLOUDSDK_CONFIG=/tmp/ambient-gcloud PRIME_AGENT_KERNEL_VENV=/tmp/ambient-kernel \
      PRIME_AGENT_KERNEL_PYTHON=/tmp/ambient-python AWS_SHARED_CREDENTIALS_FILE=/tmp/ambient-aws-creds \
      AWS_CONFIG_FILE=/tmp/ambient-aws-config AZURE_CONFIG_DIR=/tmp/ambient-azure \
      DOCKER_CONFIG=/tmp/ambient-docker KUBECONFIG=/tmp/ambient-kube HF_HOME=/tmp/ambient-hf \
      GNUPGHOME=/tmp/ambient-gnupg NPM_CONFIG_USERCONFIG=/tmp/ambient-npmrc NETRC=/tmp/ambient-netrc \
      GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" FM_FAKE_PRIME_GIT_REPO="$second_wt" \
      FM_FAKE_PRIME_COMMIT_FILE=prime-tooling-two.txt FM_FAKE_PRIME_ENV_LOG="$second_env_log" bash -c "$second_launch"
  )
  status=$?
  expect_code 0 "$status" "second isolated prime-agent launch command should execute"
  assert_grep "home=$second_prime_home" "$second_env_log" "second prime-agent launch did not receive its project home"
  assert_grep "agent_dir=$second_prime_dir" "$second_env_log" "second prime-agent launch did not receive its agent directory"
  assert_grep "session_dir=$second_prime_session_dir" "$second_env_log" "second prime-agent launch did not receive its session directory"
  assert_grep "xdg_config=$second_prime_home/.config" "$second_env_log" "second prime-agent launch did not receive isolated configuration roots"
  assert_grep "kernel_python=$second_prime_dir/kernel-venv/bin/python" "$second_env_log" "second prime-agent launch did not receive its scoped kernel Python path"
  [ "$second_daemon_socket" != "$prime_daemon_socket" ] || \
    fail "distinct projects shared a Prime daemon socket"
  assert_grep "config_project=two" "$second_env_log" "second prime-agent launch observed another project's CLI config"
  assert_grep "skill=no-mistakes" "$second_env_log" "second prime-agent launch lost the permitted no-mistakes skill"
  assert_grep "git_commit=ok" "$second_env_log" "second prime-agent launch could not commit with isolated tooling config"
  [ "$(git -C "$second_wt" log -1 --format=%s)" = "Prime tooling probe" ] || \
    fail "second prime-agent tooling probe did not create a real commit"
  assert_no_grep "credential_helper=visible" "$second_env_log" "second prime-agent launch inherited the operator's Git credential helper"
  assert_no_grep "visible=" "$second_env_log" "second prime-agent launch inherited an ambient credential source"
  alternate_home="$CASE_DIR/alternate-firstmate-home"
  alternate_id=profile-prime-agent-other-home-z8c
  mkdir -p "$alternate_home/data/$alternate_id" "$alternate_home/projects" "$alternate_home/state" "$alternate_home/config"
  printf '%s\n' prime-agent > "$alternate_home/config/crew-harness"
  printf 'brief for %s\n' "$alternate_id" > "$alternate_home/data/$alternate_id/brief.md"
  touch "$alternate_home/state/.last-watcher-beat"
  out=$(HOME="$operator_home" GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" \
    run_ship_spawn "$alternate_home" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$alternate_id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "prime-agent spawn from a second Firstmate home should succeed"
  alternate_daemon_socket=$(sed -n 's/^prime_daemon_socket=//p' "$alternate_home/state/$alternate_id.meta")
  [ "$alternate_daemon_socket" != "$prime_daemon_socket" ] || \
    fail "distinct Firstmate homes shared a Prime daemon socket for one project"
  pass "prime-agent receives isolated project state, model, thinking, and its semantic extension"
}

test_prime_git_config_drops_stale_identity() {
  local rec id out status operator_home prime_home relaunch_window
  id=profile-prime-stale-git-z8c
  rec=$(make_spawn_case profile-prime-stale-git prime-agent "$id")
  read_case_record "$rec"
  operator_home="$CASE_DIR/operator-home"
  mkdir -p "$operator_home/.agents/skills/no-mistakes"
  printf '%s\n' '---' 'name: no-mistakes' '---' '# no-mistakes' > "$operator_home/.agents/skills/no-mistakes/SKILL.md"
  git config --file "$operator_home/.gitconfig" user.name "Prime Stale"
  git config --file "$operator_home/.gitconfig" user.email "prime-stale@example.test"

  out=$(HOME="$operator_home" GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "initial Prime spawn for stale identity coverage should succeed"
  prime_home=$(sed -n 's/^prime_home=//p' "$HOME_DIR/state/$id.meta")
  relaunch_window=$(sed -n 's/^window=.*://p' "$HOME_DIR/state/$id.meta")
  [ "$(git config --file "$prime_home/.gitconfig" user.email)" = "prime-stale@example.test" ] || \
    fail "initial Prime tooling config did not copy the effective identity"
  git config --file "$operator_home/.gitconfig" --unset user.email

  out=$(HOME="$operator_home" GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" \
    FM_TEST_RELAUNCH_DEAD=1 FM_TEST_RELAUNCH_WINDOWS="$relaunch_window" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" --relaunch --harness prime-agent)
  status=$?
  expect_code 0 "$status" "Prime relaunch with incomplete identity should succeed"
  if git config --file "$prime_home/.gitconfig" --get user.name >/dev/null 2>&1 || \
     git config --file "$prime_home/.gitconfig" --get user.email >/dev/null 2>&1; then
    fail "Prime tooling config retained a stale partial author identity"
  fi
  pass "prime-agent atomically removes stale Git author identity"
}

test_prime_project_setup_serializes_concurrent_relaunches() {
  local rec id_one id_two out status operator_home real_git guard log_one log_two out_one out_two pid_one pid_two rc_one rc_two relaunch_windows
  id_one=profile-prime-relaunch-one-z8c
  id_two=profile-prime-relaunch-two-z8c
  rec=$(make_spawn_case profile-prime-relaunch-lock prime-agent "$id_one" "$id_two")
  read_case_record "$rec"
  operator_home="$CASE_DIR/operator-home"
  mkdir -p "$operator_home/.agents/skills/no-mistakes"
  printf '%s\n' '---' 'name: no-mistakes' '---' '# no-mistakes' > "$operator_home/.agents/skills/no-mistakes/SKILL.md"
  git config --file "$operator_home/.gitconfig" user.name "Prime Relaunch"
  git config --file "$operator_home/.gitconfig" user.email "prime-relaunch@example.test"
  for id in "$id_one" "$id_two"; do
    out=$(HOME="$operator_home" GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "initial Prime spawn for relaunch lock coverage should succeed"
  done
  relaunch_windows=$(sed -n 's/^window=.*://p' "$HOME_DIR/state/$id_one.meta" "$HOME_DIR/state/$id_two.meta")
  real_git=$(type -P git)
  guard="$CASE_DIR/git-config.guard"
  cat > "$FAKEBIN_DIR/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = config ] && [ "\${2:-}" = --file ]; then
  if ! mkdir "\$FM_TEST_GIT_GUARD" 2>/dev/null; then
    printf '%s\n' overlap >> "\$FM_TEST_GIT_GUARD.overlap"
    exit 97
  fi
  sleep 0.2
  '$real_git' "\$@"
  status=\$?
  rmdir "\$FM_TEST_GIT_GUARD"
  exit "\$status"
fi
exec '$real_git' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/git"
  log_one="$CASE_DIR/relaunch-one.log"
  log_two="$CASE_DIR/relaunch-two.log"
  out_one="$CASE_DIR/relaunch-one.out"
  out_two="$CASE_DIR/relaunch-two.out"
  (
    HOME="$operator_home" GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" FM_TEST_GIT_GUARD="$guard" \
      FM_TEST_RELAUNCH_DEAD=1 FM_TEST_RELAUNCH_WINDOWS="$relaunch_windows" \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$log_one" "$id_one" --relaunch --harness prime-agent > "$out_one" 2>&1
    printf '%s\n' "$?" > "$CASE_DIR/relaunch-one.rc"
  ) &
  pid_one=$!
  (
    HOME="$operator_home" GIT_CONFIG_GLOBAL="$operator_home/.gitconfig" FM_TEST_GIT_GUARD="$guard" \
      FM_TEST_RELAUNCH_DEAD=1 FM_TEST_RELAUNCH_WINDOWS="$relaunch_windows" \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$log_two" "$id_two" --relaunch --harness prime-agent > "$out_two" 2>&1
    printf '%s\n' "$?" > "$CASE_DIR/relaunch-two.rc"
  ) &
  pid_two=$!
  wait "$pid_one"
  wait "$pid_two"
  rc_one=$(cat "$CASE_DIR/relaunch-one.rc")
  rc_two=$(cat "$CASE_DIR/relaunch-two.rc")
  expect_code 0 "$rc_one" "first concurrent Prime relaunch should succeed: $(cat "$out_one")"
  expect_code 0 "$rc_two" "second concurrent Prime relaunch should succeed: $(cat "$out_two")"
  assert_absent "$guard.overlap" "concurrent Prime relaunches entered shared provisioning together"
  pass "prime-agent serializes shared project setup across relaunches"
}

test_prime_agent_refuses_invalid_project_digest() {
  local rec id out status
  id=profile-prime-agent-invalid-digest-z8c
  rec=$(make_spawn_case profile-prime-agent-invalid-digest prime-agent "$id")
  read_case_record "$rec"
  for tool in shasum sha256sum; do
    cat > "$FAKEBIN_DIR/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'not-a-digest  -'
SH
    chmod +x "$FAKEBIN_DIR/$tool"
  done

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "prime-agent spawn must reject invalid project digests"
  assert_contains "$out" "cannot create project-scoped Prime Agent state" \
    "invalid project digest refusal did not name project-scoped state"
  assert_absent "$HOME_DIR/state/$id.meta" "invalid project digest refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "invalid project digest refusal sent a launch command"
  pass "prime-agent project keys require a validated SHA-256 digest"
}

test_prime_agent_refuses_unscoped_daemon_versions() {
  local rec id out status version_exit version_text
  id=profile-prime-agent-old-daemon-z8c
  rec=$(make_spawn_case profile-prime-agent-old-daemon prime-agent "$id")
  read_case_record "$rec"
  cat > "$FAKEBIN_DIR/prime-agent" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' "${FM_TEST_PRIME_VERSION:-0.8.0}"; exit "${FM_TEST_PRIME_VERSION_EXIT:-0}" ;;
  --help) printf '%s\n' 'Options: --daemon-socket <path>' ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/prime-agent"

  for version_exit in 0 1; do
    : > "$LAUNCH_LOG"
    version_text=0.8.0
    [ "$version_exit" -eq 0 ] || version_text=0.8.1
    out=$(FM_TEST_PRIME_VERSION="$version_text" \
      FM_TEST_PRIME_VERSION_EXIT="$version_exit" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "Prime without a successful scoped-daemon version probe must refuse"
    assert_contains "$out" "requires version 0.8.1 or newer with --daemon-socket support" \
      "Prime daemon probe refusal did not name the upgrade requirement"
    assert_absent "$HOME_DIR/state/$id.meta" "unsupported Prime daemon launch wrote task metadata"
    [ ! -s "$LAUNCH_LOG" ] || fail "unsupported Prime daemon launch sent a command"
  done
  pass "prime-agent refuses when scoped daemon support is unavailable"
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
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
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
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
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_rejects_raw_launch_command
test_raw_prime_launch_is_rejected_before_endpoint_creation
test_native_non_prime_raw_launch_is_preserved
test_prime_extension_serializes_generated_values
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
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_prime_agent_threads_model_thinking_and_semantic_extension
test_prime_git_config_drops_stale_identity
test_prime_project_setup_serializes_concurrent_relaunches
test_prime_agent_refuses_invalid_project_digest
test_prime_agent_refuses_unscoped_daemon_versions
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
