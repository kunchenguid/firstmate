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
# shellcheck source=bin/fm-chrome-devtools-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-chrome-devtools-lib.sh"

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
    if [ -n "${FM_FAKE_TEXT_LOG:-}" ]; then
      for a in "$@"; do
        case "$a" in
          *CHROME_DEVTOOLS_AXI_SESSION=*) printf '%s\n' "$a" >> "$FM_FAKE_TEXT_LOG" ;;
        esac
      done
    fi
    if [ -n "${FM_FAKE_CHROME_SEND_STATUS:-}" ]; then
      for a in "$@"; do
        case "$a" in
          *CHROME_DEVTOOLS_AXI_SESSION=*) exit "$FM_FAKE_CHROME_SEND_STATUS" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse chrome-devtools-axi
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
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_TEXT_LOG="${FM_TEST_TEXT_LOG:-}" \
    FM_FAKE_CHROME_SEND_STATUS="${FM_TEST_CHROME_SEND_STATUS:-}" \
    FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:${FM_TEST_SPAWN_PATH:-$PATH}" \
    "$SPAWN" "$@" 2>&1
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, so a host that happens to install that
# tool cannot make an absent-tool test pass vacuously.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
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

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
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

test_task_scoped_chrome_bridge_binding_is_exported_before_launch() {
  local rec id out status record session textlog tasktmp wrapper launcher_dir mode
  id=profile-chrome-session-z20
  rm -rf "/tmp/fm-$id"
  rec=$(make_spawn_case profile-chrome-session claude "$id")
  read_case_record "$rec"
  textlog="$CASE_DIR/text.log"

  out=$(FM_TEST_TEXT_LOG="$textlog" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn with a task-scoped Chrome binding should succeed"
  record="$HOME_DIR/state/$id.chrome-devtools-session"
  assert_present "$record" "spawn did not record the task-scoped Chrome binding"
  session=$(sed -n 's/^session=//p' "$record")
  case "$session" in
    fm-*) ;;
    *) fail "spawn recorded an invalid or default Chrome session: ${session:-empty}" ;;
  esac
  assert_grep 'started=0' "$record" "a fresh Chrome binding was not marked unused"
  assert_grep "unset CHROME_DEVTOOLS_AXI_PORT; export CHROME_DEVTOOLS_AXI_SESSION=$session; export PATH=" "$textlog" \
    "spawn did not export the recorded Chrome session and task-private launcher before launching the worker"
  tasktmp=$(sed -n 's/^tasktmp=//p' "$HOME_DIR/state/$id.meta")
  launcher_dir=$(sed -n 's/.*export PATH=\([^:]*\):.*/\1/p' "$textlog" | tail -n 1)
  case "$launcher_dir" in
    "$tasktmp"/?*) ;;
    *) fail "spawn put an unexpected directory first on the worker's PATH: ${launcher_dir:-empty}" ;;
  esac
  [ "$launcher_dir" != "$tasktmp/bin" ] \
    || fail "the task-private Chrome launcher lives at a path derivable from the task id"
  assert_absent "$tasktmp/bin" \
    "spawn created the task-private Chrome launcher at a name derivable from the task id"
  wrapper="$launcher_dir/chrome-devtools-axi"
  assert_present "$wrapper" "spawn did not create the task-private Chrome launcher"
  chmod 600 "$record"
  ( umask 022; CHROME_DEVTOOLS_AXI_SESSION="$session" "$wrapper" pages ) \
    || fail "the task-private Chrome launcher did not delegate to the real tool"
  assert_grep 'started=1' "$record" \
    "the task-private Chrome launcher did not mark a bridge-starting action"
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$record" 2>/dev/null)
  else
    mode=$(stat -c %a "$record" 2>/dev/null)
  fi
  [ "$mode" = 600 ] \
    || fail "the launcher's startup marking widened the task binding record from 0600 to 0$mode"
  pass "spawn records and exports one non-default chrome-devtools bridge session per task"
}

test_missing_chrome_devtools_tool_does_not_block_the_launch() {
  local rec id out status record session textlog chromeless tasktmp
  id=profile-chrome-missing-z21
  rm -rf "/tmp/fm-$id"
  rec=$(make_spawn_case profile-chrome-missing claude "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/chrome-devtools-axi"
  chromeless="$CASE_DIR/path-without-chrome"
  mirror_path_without "$chromeless" chrome-devtools-axi "$FAKEBIN_DIR"
  textlog="$CASE_DIR/text.log"

  out=$(FM_TEST_SPAWN_PATH="$chromeless" FM_TEST_TEXT_LOG="$textlog" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a missing chrome-devtools-axi must not block a ship launch"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude" "the launch did not complete without chrome-devtools-axi"
  assert_contains "$out" "chrome-devtools-axi is unavailable" "the absent browser tool was not reported"
  assert_contains "$out" "teardown will not reclaim" \
    "spawn implied teardown would still reclaim a bridge nothing can record the start of"
  assert_contains "$(cat "$LAUNCH_LOG")" "claude --dangerously-skip-permissions" \
    "no agent launch command was sent without chrome-devtools-axi"
  record="$HOME_DIR/state/$id.chrome-devtools-session"
  assert_present "$record" "spawn dropped the task-scoped Chrome binding when the tool was absent"
  session=$(sed -n 's/^session=//p' "$record")
  assert_grep "export CHROME_DEVTOOLS_AXI_SESSION=$session" "$textlog" \
    "spawn stopped scoping the task's Chrome session when the tool was absent"
  tasktmp=$(sed -n 's/^tasktmp=//p' "$HOME_DIR/state/$id.meta")
  [ -z "$(find "$tasktmp" -name chrome-devtools-axi -print -quit 2>/dev/null)" ] \
    || fail "spawn wrote a task-private Chrome launcher with no real tool behind it"
  ! grep -q 'export PATH=' "$textlog" \
    || fail "spawn prepended a launcher directory to the worker PATH with no real tool behind it"
  pass "an absent chrome-devtools-axi degrades to a warning and still scopes the task's bridge session"
}

test_world_writable_task_temp_root_never_reaches_the_worker_path() {
  local rec id out status record session textlog tasktmp
  id=profile-chrome-untrusted-z22
  tasktmp="/tmp/fm-$id"
  rm -rf "$tasktmp"
  mkdir -p "$tasktmp"
  chmod 777 "$tasktmp"
  rec=$(make_spawn_case profile-chrome-untrusted claude "$id")
  read_case_record "$rec"
  textlog="$CASE_DIR/text.log"

  out=$(FM_TEST_TEXT_LOG="$textlog" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a pre-created task temp root must not block a ship launch"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude" "the launch did not complete"
  record="$HOME_DIR/state/$id.chrome-devtools-session"
  assert_present "$record" "spawn dropped the task-scoped Chrome binding"
  session=$(sed -n 's/^session=//p' "$record")
  assert_grep "export CHROME_DEVTOOLS_AXI_SESSION=$session" "$textlog" \
    "spawn stopped scoping the task's Chrome session"
  ! grep -q "export PATH=$tasktmp" "$textlog" \
    || fail "spawn put a world-writable task temp directory first on the worker's PATH"
  [ -z "$(find "$tasktmp" -name chrome-devtools-axi -print -quit 2>/dev/null)" ] \
    || fail "spawn wrote its task-private launcher into a world-writable directory"
  rm -rf "$tasktmp"
  pass "a pre-created world-writable task temp root never becomes the worker's first PATH entry"
}

# The launcher directory goes first on the worker's PATH, so its name must not be
# reconstructible from anything an onlooker knows - the task id and its /tmp root
# are both visible in fleet output. Minting it twice under one root must not
# produce the same path.
test_task_private_launcher_directory_is_unpredictable() {
  local parent first second
  parent="$TMP_ROOT/launcher-unpredictable"
  rm -rf "$parent"
  mkdir -p "$parent"
  chmod 700 "$parent"

  first=$(fm_chrome_launcher_dir_create "$parent") \
    || fail "could not create a task-private Chrome launcher directory"
  second=$(fm_chrome_launcher_dir_create "$parent") \
    || fail "could not create a second task-private Chrome launcher directory"
  [ "$first" != "$second" ] \
    || fail "two launcher directories under one task temp root reused a single derivable name"
  case "$first" in
    "$parent"/?*) ;;
    *) fail "the launcher directory escaped its verified task temp root: $first" ;;
  esac
  fm_chrome_dir_is_task_private "$first" \
    || fail "the launcher directory was not created private to this user"

  chmod 777 "$parent"
  ! fm_chrome_launcher_dir_create "$parent" >/dev/null 2>&1 \
    || fail "a launcher directory was minted under a world-writable parent"
  chmod 700 "$parent"
  rm -rf "$parent"
  pass "the task-private Chrome launcher directory is minted unpredictably inside a verified private root"
}

# The pane-shell exports that scope a worker's browser calls are sent once, at
# spawn. Anything the worker runs whose environment did not survive - a nested
# shell, an rc file that re-exports CHROME_DEVTOOLS_AXI_PORT, a subprocess
# launched with a scrubbed env - would otherwise mark this task's binding started
# and then open the bridge on the captain's default session, orphaning it exactly
# as the incident did. The launcher is on that execution path whatever the
# environment, so it must carry the binding itself rather than merely record it.
test_task_private_launcher_forces_the_recorded_session() {
  local dir id state tool envlog bindir wrapper session record
  id=launcher-binding-z23
  dir="$TMP_ROOT/launcher-binding"
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/tool"
  chmod 700 "$dir"
  state="$dir/state"
  envlog="$dir/tool-env.log"
  tool="$dir/tool/chrome-devtools-axi"
  cat > "$tool" <<'SH'
#!/usr/bin/env bash
set -u
printf 'session=%s port=%s args=%s\n' \
  "${CHROME_DEVTOOLS_AXI_SESSION:-unset}" "${CHROME_DEVTOOLS_AXI_PORT:-unset}" "$*" \
  >> "$FM_FAKE_TOOL_ENV_LOG"
SH
  chmod +x "$tool"

  fm_chrome_binding_write "$state" "$id" \
    || fail "could not write the task binding for the launcher test"
  session=$FM_CHROME_TASK_SESSION
  record="$state/$id.chrome-devtools-session"
  bindir=$(fm_chrome_launcher_dir_create "$dir") \
    || fail "could not mint a task-private Chrome launcher directory"
  wrapper="$bindir/chrome-devtools-axi"
  fm_chrome_wrapper_write "$state" "$id" "$wrapper" "$tool" \
    || fail "could not write the task-private Chrome launcher"

  env -i "PATH=$PATH" "FM_FAKE_TOOL_ENV_LOG=$envlog" \
    CHROME_DEVTOOLS_AXI_SESSION=default CHROME_DEVTOOLS_AXI_PORT=9333 \
    "$wrapper" pages \
    || fail "the task-private Chrome launcher did not delegate to the real tool"
  assert_grep "session=$session port=unset args=pages" "$envlog" \
    "a bridge-starting call escaped the recorded task session or kept an inherited bridge port"
  assert_grep 'started=1' "$record" \
    "the launcher did not mark the binding for a bridge-starting call"

  env -i "PATH=$PATH" "FM_FAKE_TOOL_ENV_LOG=$envlog" \
    CHROME_DEVTOOLS_AXI_SESSION=default CHROME_DEVTOOLS_AXI_PORT=9333 \
    "$wrapper" stop \
    || fail "the task-private Chrome launcher did not delegate a stop to the real tool"
  assert_grep "session=$session port=unset args=stop" "$envlog" \
    "a worker stop escaped the recorded task session and could close the captain's bridge"

  sed 's/^session=.*/session=captain-shared/' "$record" > "$record.forged"
  mv "$record.forged" "$record"
  ! fm_chrome_wrapper_write "$state" "$id" "$wrapper" "$tool" >/dev/null 2>&1 \
    || fail "the launcher was written to force a session the task binding does not record"
  rm -rf "$dir"
  pass "the task-private Chrome launcher forces the recorded session and drops an inherited bridge port"
}

# A worker that opens a bridge and then shuts it down itself has left nothing to
# reclaim. Teardown's conditional disclosure - "this task recorded a start and the
# tool now says the session is gone, which a session-blind dispatcher would also
# say" - exists to flag a host that cannot scope bridges, so it must not fire for
# every browser-using task that cleaned up after itself. The marker is only
# cleared by a stop the tool reported succeeded; a failed stop stays eligible.
test_launcher_stop_retires_the_marker_only_when_the_tool_agrees() {
  local dir id state tool bindir wrapper record mode
  id=launcher-selfstop-z24
  dir="$TMP_ROOT/launcher-selfstop"
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/tool"
  chmod 700 "$dir"
  state="$dir/state"
  tool="$dir/tool/chrome-devtools-axi"
  cat > "$tool" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" != stop ] || exit "${FM_FAKE_TOOL_STOP_STATUS:-0}"
exit 0
SH
  chmod +x "$tool"

  fm_chrome_binding_write "$state" "$id" \
    || fail "could not write the task binding for the launcher self-stop test"
  record="$state/$id.chrome-devtools-session"
  bindir=$(fm_chrome_launcher_dir_create "$dir") \
    || fail "could not mint a task-private Chrome launcher directory"
  wrapper="$bindir/chrome-devtools-axi"
  fm_chrome_wrapper_write "$state" "$id" "$wrapper" "$tool" \
    || fail "could not write the task-private Chrome launcher"

  "$wrapper" open https://example.invalid \
    || fail "the task-private Chrome launcher did not delegate a bridge-starting call"
  assert_grep 'started=1' "$record" \
    "the launcher did not mark the binding for a bridge-starting call"

  FM_FAKE_TOOL_STOP_STATUS=7 "$wrapper" stop \
    && fail "the launcher hid a failed stop from the worker"
  assert_grep 'started=1' "$record" \
    "a stop the tool reported failed retired the marker and made the task ineligible for cleanup"

  ( umask 022; "$wrapper" stop ) || fail "the launcher did not delegate a successful stop"
  assert_grep 'started=0' "$record" \
    "a bridge the worker stopped itself still reads as a recorded start teardown must explain"

  "$wrapper" || fail "the launcher did not delegate a bare invocation"
  assert_grep 'started=0' "$record" \
    "a bare status invocation - what an agent harness runs at session start - marked the task as having opened a bridge"
  "$wrapper" --version || fail "the launcher did not delegate a version query"
  assert_grep 'started=0' "$record" \
    "a version query marked the task as having opened a bridge"
  "$wrapper" navigate https://example.invalid \
    || fail "the launcher did not delegate a bridge-capable command"
  assert_grep 'started=1' "$record" \
    "a bridge-capable command was exempted from marking the task binding"

  ( umask 022; "$wrapper" stop ) \
    || fail "the launcher did not delegate the stop that clears the marker for the flag-prefix check"
  assert_grep 'started=0' "$record" \
    "the launcher left the marker set before the flag-prefix check could start from a clean binding"
  "$wrapper" -h || fail "the launcher did not delegate a lone help query"
  assert_grep 'started=0' "$record" \
    "a lone help query marked the task as having opened a bridge"
  "$wrapper" -v open https://example.invalid \
    || fail "the launcher did not delegate a bridge-capable command behind a leading flag"
  assert_grep 'started=1' "$record" \
    "a bridge-capable command behind a leading -v escaped marking, so teardown would make no stop call and orphan that bridge"

  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$record" 2>/dev/null)
  else
    mode=$(stat -c %a "$record" 2>/dev/null)
  fi
  [ "$mode" = 600 ] \
    || fail "retiring the marker after a self-stop widened the task binding record to 0$mode"
  rm -rf "$dir"
  pass "a worker's own successful stop retires the startup marker and a failed one does not"
}

# A worker can have a bridge-capable command in flight while it issues its own
# stop - the tool call that opens a second bridge lands between the stop being
# handed over and the launcher retiring the marker. Clearing the marker then
# describes a bridge the stop never covered: that fresh bridge stays live while
# both teardown passes see started=0 and skip it, which is exactly the orphan
# this binding exists to prevent. Cleanup's reset already declines on a record
# somebody else replaced, and the launcher's must decline the same way.
test_launcher_stop_keeps_a_marker_written_during_the_stop() {
  local dir id state tool bindir wrapper record
  id=launcher-stoprace-z25
  dir="$TMP_ROOT/launcher-stoprace"
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/tool"
  chmod 700 "$dir"
  state="$dir/state"
  tool="$dir/tool/chrome-devtools-axi"
  # Stopping takes real time, and this tool spends it the way the incident did:
  # the worker opens another bridge through its own launcher while the stop is
  # still in flight. Driving that second bridge through the real launcher marks
  # the binding through the real marking path, so the interleaving is the
  # product's own and the ordering is fixed rather than raced.
  cat > "$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = stop ]; then
  if [ -n "${FM_FAKE_TOOL_CONCURRENT_LAUNCHER:-}" ]; then
    concurrent=$FM_FAKE_TOOL_CONCURRENT_LAUNCHER
    FM_FAKE_TOOL_CONCURRENT_LAUNCHER= "$concurrent" navigate https://example.invalid || exit 1
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$tool"

  fm_chrome_binding_write "$state" "$id" \
    || fail "could not write the task binding for the launcher stop-race test"
  record="$state/$id.chrome-devtools-session"
  bindir=$(fm_chrome_launcher_dir_create "$dir") \
    || fail "could not mint a task-private Chrome launcher directory"
  wrapper="$bindir/chrome-devtools-axi"
  fm_chrome_wrapper_write "$state" "$id" "$wrapper" "$tool" \
    || fail "could not write the task-private Chrome launcher"

  "$wrapper" open https://example.invalid \
    || fail "the task-private Chrome launcher did not delegate a bridge-starting call"
  assert_grep 'started=1' "$record" \
    "the launcher did not mark the binding for a bridge-starting call"

  FM_FAKE_TOOL_CONCURRENT_LAUNCHER="$wrapper" "$wrapper" stop \
    || fail "the launcher did not delegate a successful stop"
  assert_grep 'started=1' "$record" \
    "a stop retired a startup marker written by another invocation while it ran, so the bridge that mark describes would be skipped by teardown and orphaned"

  # The declined reset is the worker's only warning that its own stop did not
  # settle the binding, and teardown must still find a record it can read.
  ( umask 022; "$wrapper" stop ) \
    || fail "the launcher did not delegate a stop once no other invocation was writing the binding"
  assert_grep 'started=0' "$record" \
    "an uncontended self-stop failed to retire the startup marker"
  rm -rf "$dir"
  pass "a startup marker written during a self-stop survives that stop's reset"
}

# A worker's browser command marks the binding before the tool has opened
# anything: the mark says a bridge exists, but the bridge is still coming up
# while the command runs. A stop issued in that window - the incident's shape,
# with one call still connecting while another shuts a session down - covers
# nothing that call opened, so retiring the marker on it leaves that bridge live
# while both teardown passes read started=0 and skip it. The launcher must
# decline the reset for as long as any of its own calls is still in flight, and
# must resume retiring it once none is.
# Mutation proof: dropping the launcher's in-flight registration, or letting its
# record_stamp answer for a record that has one, makes the mid-call assertion
# red; never retiring the registration when the call returns makes the final
# assertion red.
test_launcher_stop_keeps_a_marker_whose_browser_call_is_still_running() {
  local dir id state tool bindir wrapper record waited bg
  id=launcher-inflight-z26
  dir="$TMP_ROOT/launcher-inflight"
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/tool"
  chmod 700 "$dir"
  state="$dir/state"
  tool="$dir/tool/chrome-devtools-axi"
  # Opening a bridge takes real time. This tool spends it: navigate announces
  # that it is connecting and stays there until the test releases it, so the
  # stop below provably runs while that call is still in flight rather than
  # racing it.
  cat > "$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = navigate ]; then
  : > "$FM_FAKE_TOOL_CONNECTING"
  waited=0
  while [ ! -e "$FM_FAKE_TOOL_GATE" ] && [ "$waited" -lt 400 ]; do
    sleep 0.05
    waited=$(( waited + 1 ))
  done
fi
exit 0
SH
  chmod +x "$tool"

  fm_chrome_binding_write "$state" "$id" \
    || fail "could not write the task binding for the launcher in-flight test"
  record="$state/$id.chrome-devtools-session"
  bindir=$(fm_chrome_launcher_dir_create "$dir") \
    || fail "could not mint a task-private Chrome launcher directory"
  wrapper="$bindir/chrome-devtools-axi"
  fm_chrome_wrapper_write "$state" "$id" "$wrapper" "$tool" \
    || fail "could not write the task-private Chrome launcher"

  FM_FAKE_TOOL_CONNECTING="$dir/connecting" FM_FAKE_TOOL_GATE="$dir/gate" \
    "$wrapper" open https://example.invalid \
    || fail "the task-private Chrome launcher did not delegate a bridge-starting call"
  assert_grep 'started=1' "$record" \
    "the launcher did not mark the binding for a bridge-starting call"

  FM_FAKE_TOOL_CONNECTING="$dir/connecting" FM_FAKE_TOOL_GATE="$dir/gate" \
    "$wrapper" navigate https://example.invalid &
  bg=$!
  waited=0
  while [ ! -e "$dir/connecting" ] && [ "$waited" -lt 400 ]; do
    sleep 0.05
    waited=$(( waited + 1 ))
  done
  [ -e "$dir/connecting" ] \
    || fail "the launcher never handed the second browser call to the tool"

  ( umask 022; "$wrapper" stop ) \
    || fail "the launcher did not delegate a successful stop"
  assert_grep 'started=1' "$record" \
    "a stop retired the startup marker of a browser call whose bridge was still coming up, so teardown would make no stop call and orphan that bridge"

  : > "$dir/gate"
  wait "$bg" || fail "the in-flight browser call did not complete"

  # The registration is the launcher's own, so it must be retired when that call
  # returns; otherwise no self-stop would ever settle the binding again.
  ( umask 022; "$wrapper" stop ) \
    || fail "the launcher did not delegate a stop once no browser call was in flight"
  assert_grep 'started=0' "$record" \
    "a self-stop with no browser call in flight failed to retire the startup marker"
  rm -rf "$dir"
  pass "a startup marker whose browser call is still running survives that task's own stop"
}

# A send that comes back 2 means the backend typed the line into the composer and
# could neither submit it nor clear it (bin/backends/zellij.sh, bin/backends/cmux.sh),
# so whatever is left there gets prefixed onto the next send. Appending the launch
# command would then submit the two concatenated: the agent never starts and the
# task is left unscoped. The TRACEPARENT send eight lines later already refuses on
# exactly this status, and the bridge-scoping send must refuse identically.
test_unsubmitted_bridge_scoping_input_refuses_the_launch() {
  local rec id out status
  id=profile-chrome-stuck-z25
  rm -rf "/tmp/fm-$id"
  rec=$(make_spawn_case profile-chrome-stuck claude "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CHROME_SEND_STATUS=2 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn continued after the bridge-scoping line was left unsubmitted in the composer"
  assert_contains "$out" "refusing to append the launch command" \
    "spawn did not report why it refused to launch onto an uncleared composer"
  ! grep -q 'claude --dangerously-skip-permissions' "$LAUNCH_LOG" \
    || fail "spawn appended the launch command onto an unsubmitted bridge-scoping line"
  pass "a bridge-scoping line left unsubmitted in the composer refuses the launch"
}

test_task_scoped_chrome_bridge_binding_is_exported_before_launch
test_task_private_launcher_forces_the_recorded_session
test_unsubmitted_bridge_scoping_input_refuses_the_launch
test_launcher_stop_retires_the_marker_only_when_the_tool_agrees
test_launcher_stop_keeps_a_marker_written_during_the_stop
test_launcher_stop_keeps_a_marker_whose_browser_call_is_still_running
test_missing_chrome_devtools_tool_does_not_block_the_launch
test_world_writable_task_temp_root_never_reaches_the_worker_path
test_task_private_launcher_directory_is_unpredictable
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
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
