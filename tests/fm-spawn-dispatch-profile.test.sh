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
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" pi-signed
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

enable_antigravity_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"pi","model":"antigravity/gemini-3.6-flash","effort":"high"}}],"default":{"harness":"pi","model":"antigravity/gemini-3.6-flash","effort":"high"}}' \
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
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_TREEHOUSE_LOG="$launchlog.treehouse" \
    FM_ANTIGRAVITY_PREFLIGHT_BIN="${PREFLIGHT_BIN:-}" \
    FM_ANTIGRAVITY_PREFLIGHT_TIMEOUT_SECONDS="${PREFLIGHT_TIMEOUT:-30}" \
    FM_PREFLIGHT_LOG="${PREFLIGHT_LOG:-}" FM_PREFLIGHT_RESULT="${PREFLIGHT_RESULT:-ok}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

make_preflight_checker() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_PREFLIGHT_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_PREFLIGHT_LOG"
case "${FM_PREFLIGHT_RESULT:-ok}" in
  ok) printf '%s\n' 'OK: active re***@example.invalid is usable (rotated: false)'; exit 0 ;;
  exhausted) printf '%s\n' 'EXHAUSTED: all configured accounts are exhausted or unavailable'; exit 1 ;;
  secret-error) printf '%s\n' 'ERROR: refresh_token=super-secret-value leaked@example.invalid'; exit 2 ;;
  timeout) sleep 5; exit 0 ;;
  signal-kill) kill -9 $$ ;;
  *) exit 23 ;;
esac
SH
  chmod +x "$path"
}

make_forked_preflight_checker() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_PREFLIGHT_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_PREFLIGHT_LOG"
( sleep 10 >/dev/null 2>&1 & )
printf '%s\n' 'OK: active re***@example.invalid is usable'
exit 0
SH
  chmod +x "$path"
}

make_timeout_without_perl() {
  local fakebin=$1 perl_marker=$2 native_timeout
  native_timeout=$(command -v timeout || command -v gtimeout) || fail "native timeout command is unavailable"
  cat > "$fakebin/timeout" <<SH
#!/usr/bin/env bash
set -u
shift
exec '$native_timeout' "\$@"
SH
  chmod +x "$fakebin/timeout"
  cat > "$fakebin/perl" <<SH
#!/usr/bin/env bash
printf '%s\\n' called > '$perl_marker'
exit 127
SH
  chmod +x "$fakebin/perl"
}

make_incompatible_timeout_with_gtimeout() {
  local fakebin=$1 timeout_marker=$2 gtimeout_marker=$3 perl_marker=$4 native_timeout
  native_timeout=$(command -v timeout || command -v gtimeout) || fail "native timeout command is unavailable"
  cat > "$fakebin/timeout" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --help) printf '%s\\n' 'portable timeout'; exit 0 ;;
esac
printf '%s\\n' called > '$timeout_marker'
exit 127
SH
  chmod +x "$fakebin/timeout"
  cat > "$fakebin/gtimeout" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --help) printf '%s\\n' '--kill-after=DURATION'; exit 0 ;;
esac
printf '%s\\n' called > '$gtimeout_marker'
exec '$native_timeout' "\$@"
SH
  chmod +x "$fakebin/gtimeout"
  cat > "$fakebin/perl" <<SH
#!/usr/bin/env bash
printf '%s\\n' called > '$perl_marker'
exit 127
SH
  chmod +x "$fakebin/perl"
}

make_incompatible_timeouts() {
  local fakebin=$1 timeout_marker=$2 gtimeout_marker=$3 perl_marker=$4
  cat > "$fakebin/timeout" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --help) printf '%s\\n' 'portable timeout'; exit 0 ;;
esac
printf '%s\\n' called > '$timeout_marker'
exit 127
SH
  chmod +x "$fakebin/timeout"
  cat > "$fakebin/gtimeout" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --help) printf '%s\\n' 'portable gtimeout'; exit 0 ;;
esac
printf '%s\\n' called > '$gtimeout_marker'
exit 127
SH
  chmod +x "$fakebin/gtimeout"
  cat > "$fakebin/perl" <<SH
#!/usr/bin/env bash
printf '%s\\n' called > '$perl_marker'
exit 127
SH
  chmod +x "$fakebin/perl"
}

make_large_preflight_checker() {
  local path=$1 result=${2:-ok}
  cat > "$path" <<SH
#!/usr/bin/env bash
set -u
[ -z "\${FM_PREFLIGHT_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FM_PREFLIGHT_LOG"
python3 -c 'print("X" * 50000)'
case "$result" in
  ok) exit 0 ;;
  exhausted) exit 1 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$path"
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
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
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
  assert_contains "$launch" "FM_PI_HARNESS=pi pi --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level"
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

test_antigravity_preflight_exit_zero_preserves_profile() {
  local rec id out status
  id=preflight-ok-z17
  rec=$(make_spawn_case preflight-ok pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=ok
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 0 "$status" "usable Antigravity quota should permit the spawn"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi antigravity/gemini-3.6-flash high
  assert_grep "check" "$PREFLIGHT_LOG" "preflight checker was not invoked with check"
  pass "exit 0 keeps the requested Antigravity model and effort"
}

test_antigravity_preflight_without_perl_uses_native_timeout() {
  local rec id out status perl_marker
  id=preflight-no-perl-z17a
  rec=$(make_spawn_case preflight-no-perl pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=ok
  perl_marker="$CASE_DIR/perl-called"
  make_preflight_checker "$PREFLIGHT_BIN"
  make_timeout_without_perl "$FAKEBIN_DIR" "$perl_marker"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 0 "$status" "native timeout should permit Antigravity launch without Perl"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi antigravity/gemini-3.6-flash high
  assert_absent "$perl_marker" "Antigravity preflight invoked Perl despite native timeout availability"
  pass "native timeout path removes Perl as a required Antigravity dependency"
}

test_antigravity_preflight_prefers_compatible_gtimeout() {
  local rec id out status timeout_marker gtimeout_marker perl_marker
  id=preflight-gtimeout-z17b
  rec=$(make_spawn_case preflight-gtimeout pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_RESULT=ok
  timeout_marker="$CASE_DIR/timeout-called"
  gtimeout_marker="$CASE_DIR/gtimeout-called"
  perl_marker="$CASE_DIR/perl-called"
  make_preflight_checker "$PREFLIGHT_BIN"
  make_incompatible_timeout_with_gtimeout "$FAKEBIN_DIR" "$timeout_marker" "$gtimeout_marker" "$perl_marker"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 0 "$status" "compatible gtimeout should replace incompatible timeout"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi antigravity/gemini-3.6-flash high
  assert_absent "$timeout_marker" "incompatible timeout was selected despite compatible gtimeout"
  assert_present "$gtimeout_marker" "compatible gtimeout was not selected"
  assert_absent "$perl_marker" "gtimeout fallback invoked Perl"
  pass "compatible gtimeout is selected when timeout lacks kill-after"
}

test_antigravity_preflight_refuses_without_compatible_timeout() {
  local rec id out status timeout_marker gtimeout_marker perl_marker
  id=preflight-no-compatible-timeout-z17c
  rec=$(make_spawn_case preflight-no-compatible-timeout pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_RESULT=ok
  timeout_marker="$CASE_DIR/timeout-called"
  gtimeout_marker="$CASE_DIR/gtimeout-called"
  perl_marker="$CASE_DIR/perl-called"
  make_preflight_checker "$PREFLIGHT_BIN"
  make_incompatible_timeouts "$FAKEBIN_DIR" "$timeout_marker" "$gtimeout_marker" "$perl_marker"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 1 "$status" "preflight should refuse without a compatible timeout"
  assert_contains "$out" "requires timeout or gtimeout with --kill-after" \
    "incompatible timeout refusal was not concrete"
  assert_absent "$HOME_DIR/state/$id.meta" "incompatible timeout wrote task metadata"
  assert_absent "$timeout_marker" "incompatible timeout was invoked"
  assert_absent "$gtimeout_marker" "incompatible gtimeout was invoked"
  assert_absent "$perl_marker" "incompatible timer fallback invoked Perl"
  pass "preflight refuses before metadata when no timer can clean descendants"
}

test_antigravity_preflight_configured_profile_covers_scouts() {
  local rec id out status
  id=preflight-profile-scout-z17b
  rec=$(make_spawn_case preflight-profile-scout pi "$id")
  read_case_record "$rec"
  enable_antigravity_dispatch_profile "$HOME_DIR"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=ok
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness pi --model antigravity/gemini-3.6-flash --effort high --scout)
  status=$?
  expect_code 0 "$status" "configured Antigravity scout profile should permit the spawn"
  assert_grep "kind=scout" "$HOME_DIR/state/$id.meta" "configured Antigravity scout did not record kind=scout"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi antigravity/gemini-3.6-flash high
  assert_grep "check" "$PREFLIGHT_LOG" "configured Antigravity scout did not invoke preflight"
  pass "configured Antigravity profiles use the shared scout boundary"
}

test_antigravity_preflight_all_unusable_falls_back_before_metadata() {
  local rec id out status launch
  id=preflight-exhausted-z18
  rec=$(make_spawn_case preflight-exhausted pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=exhausted
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort xhigh)
  status=$?
  expect_code 0 "$status" "exhausted Antigravity accounts should fall back to Luna high"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi cockpit/gpt-5.6-luna high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cockpit/gpt-5.6-luna' --thinking 'high'" \
    "launch command did not receive the Luna high fallback profile"
  assert_grep "check" "$PREFLIGHT_LOG" "exhausted accounts test did not run the quota checker"
  pass "exit 1 falls back to Luna high before endpoint and metadata publication"
}

test_antigravity_preflight_raw_launch_uses_fallback() {
  local rec id out status launch
  id=preflight-raw-fallback-z18b
  rec=$(make_spawn_case preflight-raw-fallback pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=exhausted
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    "custom-agent --flag" --model antigravity/gemini-3.6-flash --effort xhigh)
  status=$?
  expect_code 0 "$status" "raw launch should use the documented Luna fallback"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent cockpit/gpt-5.6-luna high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "custom-agent --flag --model 'cockpit/gpt-5.6-luna' --effort 'high'" \
    "raw launch did not receive the Luna fallback"
  pass "exit 1 applies the Luna fallback to raw launch commands"
}

test_antigravity_preflight_error_is_secret_safe_and_refuses() {
  local rec id out status
  id=preflight-error-z19
  rec=$(make_spawn_case preflight-error pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=secret-error
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 1 "$status" "checker error exit code must refuse Antigravity launch"
  assert_contains "$out" "unrecognized result (exit 2)" "preflight error refusal was not concrete"
  assert_not_contains "$out" "super-secret-value" "preflight error leaked secret diagnostic text"
  assert_absent "$HOME_DIR/state/$id.meta" "checker error wrote task metadata"
  pass "checker error exit code refuses without leaking checker stdout"
}

test_antigravity_preflight_missing_and_non_executable_refuse() {
  local rec id out status
  id=preflight-missing-z20
  rec=$(make_spawn_case preflight-missing pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/missing-checker"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 1 "$status" "missing checker must refuse Antigravity launch"
  assert_contains "$out" "missing or not executable" "missing checker refusal was not concrete"
  assert_absent "$HOME_DIR/state/$id.meta" "missing checker wrote task metadata"

  touch "$PREFLIGHT_BIN"
  chmod -x "$PREFLIGHT_BIN"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 1 "$status" "non-executable checker must refuse Antigravity launch"
  assert_contains "$out" "missing or not executable" "non-executable refusal was not concrete"
  assert_absent "$HOME_DIR/state/$id.meta" "non-executable checker wrote task metadata"
  pass "missing or non-executable checker refuses before endpoint creation"
}

test_antigravity_preflight_timeout_refuses() {
  local rec id out status
  id=preflight-timeout-z21
  rec=$(make_spawn_case preflight-timeout pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=timeout
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(PREFLIGHT_TIMEOUT=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 1 "$status" "preflight timeout must refuse Antigravity launch"
  assert_contains "$out" "timed out" "timeout refusal was not concrete"
  assert_absent "$HOME_DIR/state/$id.meta" "timeout wrote task metadata"
  pass "preflight timeout refuses before endpoint creation"
}

test_antigravity_preflight_skips_non_antigravity_models() {
  local rec id out status
  id=preflight-luna-z23
  rec=$(make_spawn_case preflight-luna pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/missing-checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=ok

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cockpit/gpt-5.6-luna --effort high)
  status=$?
  expect_code 0 "$status" "Luna must not require Antigravity preflight"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi cockpit/gpt-5.6-luna high
  assert_absent "$PREFLIGHT_LOG" "Luna launch unexpectedly invoked Antigravity preflight"
  pass "Luna and other non-Antigravity models bypass the checker"
}

test_antigravity_preflight_applies_to_configured_secondmate_model() {
  local rec id sm out status
  id=preflight-secondmate-z24
  rec=$(make_spawn_case preflight-secondmate codex "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  mkdir -p "$sm/state" "$sm/config" "$sm/projects"
  printf '%s\n' 'pi antigravity/gemini-3.6-flash medium' > "$HOME_DIR/config/secondmate-harness"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=exhausted
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate Antigravity model should use the shared preflight boundary"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi cockpit/gpt-5.6-luna high
  assert_grep "check" "$PREFLIGHT_LOG" "secondmate did not invoke the quota checker"
  pass "secondmate config models use the same preflight and accurate fallback metadata"
}

test_antigravity_preflight_forked_checker_does_not_hang() {
  local rec id out status
  id=preflight-forked-z25
  rec=$(make_spawn_case preflight-forked pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  make_forked_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 0 "$status" "forked checker should return promptly and permit spawn"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi antigravity/gemini-3.6-flash high
  assert_grep "check" "$PREFLIGHT_LOG" "forked checker was not invoked"
  pass "forked checker process does not hang the preflight"
}

test_antigravity_preflight_invalid_limits_refuse() {
  local rec id out status
  id=preflight-invalid-limits-z26
  rec=$(make_spawn_case preflight-invalid-limits pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=ok
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(PREFLIGHT_TIMEOUT=invalid \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 1 "$status" "non-integer timeout must refuse spawn"
  assert_contains "$out" "timeout is not a positive integer" "invalid timeout refusal missing diagnostic"
  assert_absent "$HOME_DIR/state/$id.meta" "invalid timeout written metadata"

  out=$(FM_ANTIGRAVITY_PREFLIGHT_OUTPUT_BYTES=0 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 1 "$status" "zero output limit must refuse spawn"
  assert_contains "$out" "output limit must be positive" "invalid output limit refusal missing diagnostic"
  assert_absent "$HOME_DIR/state/$id.meta" "invalid output limit written metadata"
  pass "invalid timeout and output limit settings refuse before endpoint creation"
}

test_antigravity_preflight_uses_default_checker_path() {
  local rec id out status agent_dir checker_path
  id=preflight-default-path-z27
  rec=$(make_spawn_case preflight-default-path pi "$id")
  read_case_record "$rec"
  agent_dir="$CASE_DIR/pi-agent"
  checker_path="$agent_dir/extensions/antigravity-account-switcher/bin/antigravity-account-check.js"
  mkdir -p "$(dirname "$checker_path")"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=ok
  make_preflight_checker "$checker_path"

  out=$(PI_CODING_AGENT_DIR="$agent_dir" PREFLIGHT_BIN="" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 0 "$status" "default checker path under PI_CODING_AGENT_DIR should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi antigravity/gemini-3.6-flash high
  assert_grep "check" "$PREFLIGHT_LOG" "default checker path was not invoked"
  pass "default checker path under PI_CODING_AGENT_DIR is resolved and executed"
}

test_antigravity_preflight_uses_secondary_fallback_checker_path() {
  local rec id out status agent_dir secondary_checker_path
  id=preflight-secondary-path-z33
  rec=$(make_spawn_case preflight-secondary-path pi "$id")
  read_case_record "$rec"
  agent_dir="$CASE_DIR/pi-agent"
  secondary_checker_path="$agent_dir/extensions/pi-antigravity-account-switcher/bin/antigravity-account-check.js"
  mkdir -p "$(dirname "$secondary_checker_path")"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=ok
  make_preflight_checker "$secondary_checker_path"

  out=$(PI_CODING_AGENT_DIR="$agent_dir" PREFLIGHT_BIN="" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 0 "$status" "secondary checker path under PI_CODING_AGENT_DIR should succeed when primary is missing"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi antigravity/gemini-3.6-flash high
  assert_grep "check" "$PREFLIGHT_LOG" "secondary checker path was not invoked"
  pass "secondary checker path under PI_CODING_AGENT_DIR is resolved and executed when primary path is missing"
}

test_antigravity_preflight_embedded_raw_launch_model_uses_fallback() {
  local rec id out status launch
  id=preflight-raw-embedded-z28
  rec=$(make_spawn_case preflight-raw-embedded pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=exhausted
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    "custom-agent --model=antigravity/gemini-3.6-flash --effort xhigh")
  status=$?
  expect_code 0 "$status" "raw launch with embedded antigravity model flag should trigger preflight fallback"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent cockpit/gpt-5.6-luna high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model='cockpit/gpt-5.6-luna'" \
    "embedded raw launch model did not receive Luna fallback"
  assert_grep "check" "$PREFLIGHT_LOG" "embedded raw launch model did not invoke checker"
  pass "raw launch commands with embedded model flag trigger preflight and Luna fallback"
}

test_antigravity_preflight_large_output_does_not_fail() {
  local rec id out status
  id=preflight-large-out-z29
  rec=$(make_spawn_case preflight-large-out pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  make_large_preflight_checker "$PREFLIGHT_BIN" ok

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 0 "$status" "checker writing large output with exit 0 should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi antigravity/gemini-3.6-flash high
  pass "checker writing >8KB output with exit 0 does not receive SIGPIPE or fail"
}

test_antigravity_preflight_space_in_home_path_succeeds() {
  local rec id out status home_space
  id=preflight-space-z30
  rec=$(make_spawn_case preflight-space pi "$id")
  read_case_record "$rec"
  home_space="$CASE_DIR/home with spaces"
  mkdir -p "$home_space/data/$id" "$home_space/projects" "$home_space/state" "$home_space/config"
  printf '%s\n' pi > "$home_space/config/crew-harness"
  touch "$home_space/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home_space/data/$id/brief.md"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=ok
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$home_space" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 0 "$status" "preflight with space in home path should succeed"
  assert_meta_profile "$home_space/state/$id.meta" pi antigravity/gemini-3.6-flash high
  pass "state path containing spaces is handled safely"
}

test_antigravity_preflight_quoted_embedded_raw_launch_model_uses_fallback() {
  local rec id out status launch
  id=preflight-raw-quoted-z31
  rec=$(make_spawn_case preflight-raw-quoted pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=exhausted
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    "custom-agent --model 'antigravity/gemini-3.6-flash' --effort xhigh")
  status=$?
  expect_code 0 "$status" "raw launch with single-quoted antigravity model should trigger fallback and replace flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent cockpit/gpt-5.6-luna high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "custom-agent --model 'cockpit/gpt-5.6-luna' --effort 'high'" \
    "quoted raw launch model and effort were not cleanly replaced"
  assert_not_contains "$launch" "antigravity" \
    "quoted raw launch model still contains old antigravity string"
  assert_not_contains "$launch" "xhigh" \
    "quoted raw launch effort still contains old xhigh string"
  pass "single-quoted raw launch model and effort flags are parsed and cleanly replaced on fallback"
}

test_resume_reuses_recorded_worktree_and_profile() {
  local rec id out status old_head meta
  id=resume-existing-z33
  rec=$(make_spawn_case resume-existing pi "$id")
  read_case_record "$rec"
  printf 'committed before resume\n' > "$WT_DIR/resume-committed.txt"
  git -C "$WT_DIR" add resume-committed.txt
  git -C "$WT_DIR" -c user.name='Firstmate Test' -c user.email='firstmate@example.invalid' commit -qm 'resume fixture commit'
  old_head=$(git -C "$WT_DIR" rev-parse HEAD)
  printf 'uncommitted before resume\n' > "$WT_DIR/resume-uncommitted.txt"
  meta="$HOME_DIR/state/$id.meta"
  {
    printf 'worktree=%s\n' "$WT_DIR"
    printf 'project=%s\n' "$PROJ_DIR"
    printf 'harness=pi\n'
    printf 'kind=ship\n'
    printf 'model=antigravity/gemini-3.6-flash\n'
    printf 'effort=high\n'
  } > "$meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --resume --model cockpit/gpt-5.6-luna --effort xhigh)
  status=$?
  expect_code 0 "$status" "resume should relaunch from the recorded worktree"
  assert_contains "$out" "spawned $id harness=pi" "resume did not report the recorded harness"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$old_head" ] \
    || fail "resume changed the recorded branch head"
  assert_present "$WT_DIR/resume-uncommitted.txt" "resume discarded an uncommitted change"
  assert_grep "worktree=$WT_DIR" "$meta" "resume metadata lost the recorded worktree"
  assert_grep "model=cockpit/gpt-5.6-luna" "$meta" "resume metadata lost the actual resumed model"
  assert_grep "effort=xhigh" "$meta" "resume metadata lost the actual resumed effort"
  assert_grep "thinking=xhigh" "$meta" "resume metadata lost the actual resumed thinking level"
  assert_grep "resume=1" "$meta" "resume metadata did not record same-branch recovery"
  assert_grep "branch=wt-resume-existing" "$meta" "resume metadata did not record the resumed branch"
  assert_absent "$LAUNCH_LOG.treehouse" "resume allocated a replacement treehouse worktree"
  pass "--resume preserves commits and uncommitted changes while recording the actual profile"
}

test_antigravity_preflight_signal_killed_checker_refuses() {
  local rec id out status
  id=preflight-sigkill-z32
  rec=$(make_spawn_case preflight-sigkill pi "$id")
  read_case_record "$rec"
  PREFLIGHT_BIN="$CASE_DIR/checker"
  PREFLIGHT_LOG="$CASE_DIR/checker.log"
  PREFLIGHT_RESULT=signal-kill
  make_preflight_checker "$PREFLIGHT_BIN"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model antigravity/gemini-3.6-flash --effort high)
  status=$?
  expect_code 1 "$status" "signal-killed checker must refuse Antigravity launch"
  assert_contains "$out" "unrecognized result (exit 255)" "signal-killed refusal did not report exit 255"
  assert_absent "$HOME_DIR/state/$id.meta" "signal-killed checker wrote task metadata"
  pass "checker killed by signal refuses spawn and reports unrecognized result"
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
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
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
test_antigravity_preflight_exit_zero_preserves_profile
test_antigravity_preflight_without_perl_uses_native_timeout
test_antigravity_preflight_prefers_compatible_gtimeout
test_antigravity_preflight_refuses_without_compatible_timeout
test_antigravity_preflight_configured_profile_covers_scouts
test_antigravity_preflight_all_unusable_falls_back_before_metadata
test_antigravity_preflight_raw_launch_uses_fallback
test_antigravity_preflight_error_is_secret_safe_and_refuses
test_antigravity_preflight_missing_and_non_executable_refuse
test_antigravity_preflight_timeout_refuses
test_antigravity_preflight_skips_non_antigravity_models
test_antigravity_preflight_applies_to_configured_secondmate_model
test_antigravity_preflight_forked_checker_does_not_hang
test_antigravity_preflight_invalid_limits_refuse
test_antigravity_preflight_uses_default_checker_path
test_antigravity_preflight_uses_secondary_fallback_checker_path
test_antigravity_preflight_embedded_raw_launch_model_uses_fallback
test_antigravity_preflight_large_output_does_not_fail
test_antigravity_preflight_space_in_home_path_succeeds
test_resume_reuses_recorded_worktree_and_profile
test_antigravity_preflight_quoted_embedded_raw_launch_model_uses_fallback
test_antigravity_preflight_signal_killed_checker_refuses

echo "# all fm-spawn-dispatch-profile tests passed"
