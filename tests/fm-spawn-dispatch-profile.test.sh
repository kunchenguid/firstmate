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
TEARDOWN="$ROOT/bin/fm-teardown.sh"
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
  capture-pane) printf '%s\n' "${FM_FAKE_TMUX_CAPTURE:-}"; exit 0 ;;
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
  fm_fake_exit0 "$fakebin" treehouse pi-signed no-mistakes gh-axi gh tasks-axi
  write_reviewer_quota_fixture "$fakebin" known known 100
  printf '%s\n' "$fakebin"
}

write_reviewer_quota_fixture() {
  local fakebin=$1 claude_status=$2 codex_status=$3 percent_remaining=$4
  cat > "$fakebin/quota-axi" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"$claude_status","effectivePercentRemaining":$percent_remaining}]}},{"provider":"codex","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"$codex_status","effectivePercentRemaining":$percent_remaining}]}}]}
JSON
EOF
  chmod +x "$fakebin/quota-axi"
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

test_routing_source_recorded_only_when_declared() {
  local rec id out status
  id=profile-routing-source-z29
  rec=$(make_spawn_case routing-source codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort medium --routing-source fallback)
  status=$?
  expect_code 0 "$status" "spawn with --routing-source fallback should succeed"
  assert_grep "routing_source=fallback" "$HOME_DIR/state/$id.meta" "meta missing routing_source=fallback"

  id=profile-routing-source-z30
  rec=$(make_spawn_case routing-source-absent codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort medium)
  status=$?
  expect_code 0 "$status" "spawn without --routing-source should succeed"
  assert_no_grep "routing_source=" "$HOME_DIR/state/$id.meta" "undeclared routing source must stay absent (unknown provenance fails closed)"

  id=profile-routing-source-z31
  rec=$(make_spawn_case routing-source-invalid codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --routing-source vibes)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an unrecognized --routing-source"
  assert_contains "$out" "--routing-source must be one of captain, profile, fallback" "invalid routing source refusal did not name the contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "invalid routing source reached launch submission"
  assert_absent "$HOME_DIR/state/$id.meta" "invalid routing source published task metadata"
  pass "--routing-source records provenance in meta, stays absent when undeclared, and refuses unknown values"
}

test_recorded_default_axes_respawn_as_unset() {
  local rec id out status launch expected ledger
  id=profile-default-sentinel-z32
  rec=$(make_spawn_case default-sentinel claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model default --effort default --routing-source fallback)
  status=$?
  expect_code 0 "$status" "a relaunch re-passing the meta's recorded tuple should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "recorded default axes did not launch identically to unset axes"$'\n'"expected: $expected"$'\n'"actual:   $launch"

  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  jq -es 'map(select(.eventType=="attempt-intake")) | length==1 and .[0].intake.tuple.model==null and .[0].intake.tuple.effort=="default"' "$ledger" >/dev/null \
    || fail "the recorded default tuple entered the routing ledger under a second spelling instead of one unset model axis"
  pass "a tuple recorded as model=default/effort=default respawns verbatim, launches as unset axes, and enters the ledger once"
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
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id.meta" "explicit resolved attestation did not land in meta"
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
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id.meta" "positional resolved attestation did not land in meta"
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag" --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id.meta" "raw-command resolved attestation did not land in meta"
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

test_cursor_agent_threads_model_variant_and_records_effort() {
  local rec id out status launch
  id=profile-cursor-agent-z7b
  rec=$(make_spawn_case profile-cursor-agent cursor-agent "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.6-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor-agent spawn with a model-variant effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor-agent cursor-grok-4.6-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent --trust --force --model 'cursor-grok-4.6-high' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "cursor-agent launch did not preserve the model variant and typed brief"
  assert_not_contains "$launch" "--effort" \
    "cursor-agent launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" \
    "cursor-agent launch must not borrow another harness's effort flag"
  pass "cursor-agent receives the model variant while metadata preserves the selected effort axis"
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
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id1.meta" "batch did not forward attestation to first task meta"
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id2.meta" "batch did not forward attestation to second task meta"
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

test_telemetry_precedes_submission_and_metadata_is_opaque() {
  local rec id out status meta ledger attempt terminal refusal_rec refusal_id
  id=profile-telemetry-z20
  rec=$(make_spawn_case profile-telemetry pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  expect_code 0 "$status" "telemetry-backed spawn should succeed"
  meta="$HOME_DIR/state/$id.meta"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  grep -Eq '^telemetry_attempt=mra_' "$meta" || fail "spawn meta missing opaque telemetry attempt id"
  grep -Eq '^telemetry_task_root=mrt_' "$meta" || fail "spawn meta missing opaque telemetry task root"
  [ "$(grep -c '^telemetry_' "$meta")" -eq 2 ] || fail "spawn metadata contains telemetry fields beyond the two opaque ids"
  jq -e 'select(.eventType=="attempt-intake" and .intake.tuple.harness=="pi" and .intake.tuple.model=="gpt-5" and .intake.tuple.effort=="high" and .intake.taskClass=="bounded-implementation-proven-root-fix" and .intake.exploration.kind=="deliberate" and (.intake.exploration.machineCondition.loadAverage1m|type)=="number" and (.intake.exploration.machineCondition.logicalCpuCount|type)=="number")' "$ledger" >/dev/null || fail "spawn did not durably record the exploration tuple and observed machine condition before submission"
  ! grep -F -- "$PROJ_DIR" "$ledger" >/dev/null || fail "spawn telemetry exposed the project path instead of its opaque reference"

  attempt=$(sed -n 's/^telemetry_attempt=//p' "$meta")
  terminal='{"classification":"accepted","refusalQuality":"not-applicable","endedAt":"2026-08-02T00:01:00Z","wallSeconds":60,"firstPassAccepted":true,"correctionCount":0,"interventionCount":0,"evidence":{"tests":"pass","reviewer":"not-run","oracle":"not-run","refs":[{"kind":"test","id":"spawn-teardown-e2e"}]},"outcomeLink":{"kind":"commit","id":"0123456789abcdef"},"usage":{"inputTokens":null,"outputTokens":null,"cost":null,"currency":null},"primaryFailureClass":"none","flags":{"tool":false,"transport":false,"environment":false,"externalWait":false,"scopeChange":false,"quota":false},"reclassification":{"fromTaskClass":null,"toTaskClass":null,"reasonCodes":["none"],"escalated":false}}'
  # shellcheck disable=SC2016 # Literal dollar spend is a captured harness fixture.
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TMUX_CAPTURE='↑109k ↓2.9k R383k CH87.9% $0.728 (sub) 38.5%/272k (auto)' PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force --terminal-payload "$terminal" >/dev/null 2>&1 \
    || fail "telemetry-backed spawn could not complete through real teardown"
  jq -es --arg attempt "$attempt" '
    map(select(.attemptId==$attempt)) |
    length==2 and .[0].eventType=="attempt-intake" and
    .[1].eventType=="attempt-terminal" and
    .[1].terminal.classification=="accepted" and
    .[1].terminal.evidence.refs[0].id=="spawn-teardown-e2e" and
    .[1].terminal.usage.cost==null and .[1].terminal.usage.currency==null
  ' "$ledger" >/dev/null || fail "spawn and teardown did not seal one end-to-end attempt with cost left absent"
  assert_absent "$meta" "real teardown left the completed task metadata behind"

  refusal_id=profile-telemetry-refusal-z21
  refusal_rec=$(make_spawn_case profile-telemetry-refusal codex "$refusal_id")
  read_case_record "$refusal_rec"
  ln -s "$CASE_DIR/unsafe-ledger-target" "$HOME_DIR/data/routing-outcomes.jsonl"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$refusal_id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn proceeded after telemetry refusal"
  assert_contains "$out" "model telemetry intake refused; no model launch was submitted" "spawn refusal did not name the telemetry boundary"
  [ ! -s "$LAUNCH_LOG" ] || fail "telemetry refusal reached launch submission"
  assert_absent "$HOME_DIR/state/$refusal_id.meta" "telemetry refusal published task metadata"
  pass "spawn records only opaque telemetry ids and refuses telemetry failures before launch submission"
}

test_exploration_requires_an_explicit_rotated_model_and_effort() {
  local rec id id2 out status
  id=profile-exploration-missing-model-z24
  rec=$(make_spawn_case profile-exploration-missing-model pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --effort xhigh --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "exploration accepted a tuple with no explicit rotated model"
  assert_contains "$out" "--exploration requires explicit --model and --effort values" "missing-model exploration refusal did not name the tuple contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing-model exploration reached launch submission"
  assert_absent "$HOME_DIR/data/routing-outcomes.jsonl" "missing-model exploration recorded an attempt"

  id=profile-exploration-missing-effort-z25
  rec=$(make_spawn_case profile-exploration-missing-effort pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5.6-sol --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "exploration accepted a tuple with no explicit rotated effort"
  assert_contains "$out" "--exploration requires explicit --model and --effort values" "missing-effort exploration refusal did not name the tuple contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing-effort exploration reached launch submission"
  assert_absent "$HOME_DIR/data/routing-outcomes.jsonl" "missing-effort exploration recorded an attempt"

  id=profile-exploration-default-effort-z26
  rec=$(make_spawn_case profile-exploration-default-effort pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5.6-sol --effort default --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "exploration accepted the unset-effort sentinel as a rotated effort"
  assert_contains "$out" "--exploration requires explicit --model and --effort values" "default-effort exploration refusal did not name the tuple contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "default-effort exploration reached launch submission"
  assert_absent "$HOME_DIR/data/routing-outcomes.jsonl" "default-effort exploration recorded an attempt"

  id=profile-exploration-default-model-z27
  rec=$(make_spawn_case profile-exploration-default-model pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model default --effort high --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "exploration accepted the unset-model sentinel as a rotated model"
  assert_contains "$out" "--exploration requires explicit --model and --effort values" "default-model exploration refusal did not name the tuple contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "default-model exploration reached launch submission"
  assert_absent "$HOME_DIR/data/routing-outcomes.jsonl" "default-model exploration recorded an attempt"

  id=profile-exploration-batch-default-model-z28
  id2=profile-exploration-batch-default-model-z29
  rec=$(make_spawn_case profile-exploration-batch-default-model pi "$id" "$id2")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id=$PROJ_DIR" "$id2=$PROJ_DIR" \
    --model default --effort high --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "batch exploration accepted the unset-model sentinel as a rotated model"
  assert_not_contains "$out" "batch: FAILED to spawn" "batch exploration dispatched pairs the parent should have refused up front"
  assert_absent "$HOME_DIR/state/$id.meta" "refused batch exploration published task metadata"
  assert_absent "$HOME_DIR/state/$id2.meta" "refused batch exploration published second-pair metadata"
  pass "deliberate exploration requires an explicit rotated model and effort before intake or submission, on single and batch dispatch"
}

test_no_mistakes_spawn_requires_one_quota_eligible_reviewer() {
  local rec operator_home exhausted_id uncertain_id override_id out status
  exhausted_id=profile-reviewers-exhausted-z26
  uncertain_id=profile-reviewers-uncertain-z27
  override_id=profile-reviewers-override-z28
  rec=$(make_spawn_case profile-reviewer-quota codex "$exhausted_id" "$uncertain_id" "$override_id")
  read_case_record "$rec"
  operator_home="$CASE_DIR/operator-home"
  mkdir -p "$operator_home/.no-mistakes"
  printf '%s\n' 'agent: [claude, codex]' > "$operator_home/.no-mistakes/config.yaml"

  write_reviewer_quota_fixture "$FAKEBIN_DIR" known known 0
  out=$(HOME="$operator_home" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$exhausted_id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "no-mistakes spawn started with every configured reviewer exhausted"
  assert_contains "$out" "claude=exhausted" "reviewer-quota refusal did not report Claude's result"
  assert_contains "$out" "codex=exhausted" "reviewer-quota refusal did not report Codex's result"
  assert_contains "$out" "--allow-no-mistakes-without-reviewer-quota" "reviewer-quota refusal did not name the captain-authorized override"
  [ ! -s "$LAUNCH_LOG" ] || fail "reviewer-quota refusal reached launch submission"
  assert_absent "$HOME_DIR/state/$exhausted_id.meta" "reviewer-quota refusal published task metadata"

  write_reviewer_quota_fixture "$FAKEBIN_DIR" known unknown 0
  out=$(HOME="$operator_home" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$uncertain_id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "unmeasurable reviewer quota must remain eligible"
  assert_contains "$out" "codex=unmeasurable" "eligible uncertainty was not disclosed"

  write_reviewer_quota_fixture "$FAKEBIN_DIR" known known 0
  out=$(HOME="$operator_home" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$override_id" "$PROJ_DIR" --allow-no-mistakes-without-reviewer-quota)
  status=$?
  expect_code 0 "$status" "captain-authorized reviewer-quota override should allow the spawn"
  assert_contains "$out" "captain-authorized reviewer-quota override" "override did not disclose the exhausted reviewer results"
  pass "no-mistakes spawn requires one quota-eligible reviewer unless explicitly overridden"
}

test_linked_telemetry_identifiers_chain_one_task_root() {
  local rec first_id retry_id out status ledger attempt root
  first_id=profile-telemetry-root-z22
  retry_id=profile-telemetry-retry-z23
  rec=$(make_spawn_case profile-telemetry-link codex "$first_id" "$retry_id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$first_id" "$PROJ_DIR" --model gpt-5 --effort medium)
  status=$?
  expect_code 0 "$status" "first linked-telemetry spawn should succeed"
  attempt=$(sed -n 's/^telemetry_attempt=//p' "$HOME_DIR/state/$first_id.meta")
  root=$(sed -n 's/^telemetry_task_root=//p' "$HOME_DIR/state/$first_id.meta")

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$retry_id" "$PROJ_DIR" \
    --model gpt-5.6-sol --effort xhigh --telemetry-task-root "$root" --telemetry-parent "$attempt")
  status=$?
  expect_code 0 "$status" "linked retry spawn should succeed"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  [ "$(sed -n 's/^telemetry_task_root=//p' "$HOME_DIR/state/$retry_id.meta")" = "$root" ] || fail "linked retry left its task root"
  jq -e --arg r "$root" --arg p "$attempt" 'select(.eventType=="attempt-intake" and .intake.taskRootId==$r and .intake.parentAttemptId==$p and .intake.tuple.model=="gpt-5.6-sol" and .intake.tuple.effort=="xhigh")' "$ledger" >/dev/null || fail "linked retry did not record its escalated tuple under the prior root and parent"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$retry_id" "$PROJ_DIR" --telemetry-task-root ../../etc/passwd)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a non-opaque telemetry task root"
  assert_contains "$out" "--telemetry-task-root requires an opaque mrt UUID" "non-opaque root refusal did not name the identifier contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "non-opaque telemetry root reached launch submission"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$retry_id" "$PROJ_DIR" --telemetry-parent "$attempt")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a parent attempt without its task root"
  assert_contains "$out" "--telemetry-parent requires --telemetry-task-root" "orphan parent refusal did not name the missing root"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$first_id=$PROJ_DIR" "$retry_id=$PROJ_DIR" --telemetry-task-root "$root")
  status=$?
  [ "$status" -ne 0 ] || fail "batch dispatch accepted per-attempt telemetry identifiers"
  assert_contains "$out" "not supported by batch dispatch" "batch refusal did not name the per-attempt boundary"
  [ ! -s "$LAUNCH_LOG" ] || fail "batch telemetry refusal reached launch submission"
  pass "linked telemetry identifiers chain a retry under one task root and are refused when unsafe, orphaned, or batched"
}

# --- dispatch attestation backstop ------------------------------------------
#
# The explicit-harness guard above only proves *something* was passed. The
# measured failure it was built from (2026-08-15) was firstmate hand-picking an
# explicit harness for every dispatch while crew-dispatch.json sat on disk
# unread, so the guard stayed green while the rule was broken. The attestation
# backstop closes that gap: when profiles are active, an explicit harness must
# be accompanied by a declaration of HOW it was chosen - either --dispatch-resolved
# (firstmate consulted the profiles) or --dispatch-override-reason "<why>"
# (firstmate deliberately departed). A bare explicit harness is refused, because
# that is the silent hand-pick the guard exists to catch. The guard never reads
# crew-dispatch.json to verify the harness matches; it checks that resolution
# HAPPENED, not what it produced, and records the override reason in meta.

test_active_profile_refuses_explicit_harness_without_attestation() {
  local rec id resolved_id out status
  # The bare explicit harness is the silent hand-pick the guard exists to catch.
  id=profile-no-attestation-z30
  rec=$(make_spawn_case profile-no-attestation claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 1 "$status" "explicit harness without attestation should be refused when profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active" \
    "refusal did not name the active dispatch profile file"
  assert_contains "$out" "--dispatch-resolved" "refusal did not name the resolved attestation flag"
  assert_contains "$out" "--dispatch-override-reason" "refusal did not name the override attestation flag"
  assert_absent "$HOME_DIR/state/$id.meta" "refusal should happen before meta is written"

  # The same guard must NOT fire when the caller did the right thing: a resolved
  # attestation passes. This second direction is what makes the test die on a
  # predicate weakened to constant true (which would refuse both) and on a
  # predicate that refuses every explicit harness (which would refuse both),
  # not only on deletion/unreachability/weakening that lets the bare case through.
  resolved_id=profile-no-attestation-resolved-z30b
  rec=$(make_spawn_case profile-no-attestation-resolved claude "$resolved_id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$resolved_id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "explicit harness with --dispatch-resolved should pass the same guard"
  assert_contains "$out" "spawned $resolved_id harness=codex" "resolved attestation spawn did not pass"
  pass "active profile refuses a bare explicit harness that skipped profile consultation while passing a resolved one"
}

test_active_profile_requires_attestation_for_scout() {
  local rec id resolved_id out status
  # Scouts are in scope with crewmates: the guard keys on "not a secondmate", so a
  # predicate narrowed to the ship kind would let every scout skip consultation.
  id=profile-scout-no-attestation-z38
  rec=$(make_spawn_case profile-scout-no-attestation claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --scout)
  status=$?
  expect_code 1 "$status" "scout with an explicit harness but no attestation should be refused"
  assert_contains "$out" "--dispatch-resolved" "scout refusal did not name the resolved attestation flag"
  assert_contains "$out" "--dispatch-override-reason" "scout refusal did not name the override attestation flag"
  assert_absent "$HOME_DIR/state/$id.meta" "scout attestation refusal should happen before meta is written"

  resolved_id=profile-scout-resolved-z39
  rec=$(make_spawn_case profile-scout-resolved claude "$resolved_id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$resolved_id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --scout --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "scout with --dispatch-resolved should pass the same guard"
  assert_contains "$out" "spawned $resolved_id harness=codex" "resolved scout spawn did not pass"
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$resolved_id.meta" \
    "resolved scout attestation did not land in meta"
  pass "active profile requires and records the dispatch attestation on scout spawns too"
}

test_active_profile_refuses_multiline_override_reason() {
  local rec id out status
  # state/<id>.meta is one key=value per line and every reader takes the LAST match,
  # so a newline in the free-text reason would forge a later worktree= line and
  # point peek and teardown at another directory.
  id=profile-override-multiline-z40
  rec=$(make_spawn_case profile-override-multiline claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --dispatch-override-reason "codex quota out"$'\n'"worktree=/tmp/forged-by-reason")
  status=$?
  expect_code 1 "$status" "a multi-line override reason should be refused"
  assert_contains "$out" "--dispatch-override-reason must be a single line" \
    "refusal did not explain the single-line meta contract"
  assert_absent "$HOME_DIR/state/$id.meta" "multi-line reason should be refused before meta is written"
  pass "active profile refuses a multi-line override reason that would forge a meta key"
}

test_active_profile_allows_resolved_attestation_and_records_it() {
  local rec id out status meta
  id=profile-resolved-z31
  rec=$(make_spawn_case profile-resolved claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "explicit harness with --dispatch-resolved should pass"
  assert_contains "$out" "spawned $id harness=codex" "resolved attestation spawn did not report codex"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "dispatch=resolved" "$meta" "resolved attestation did not land dispatch=resolved in meta"
  pass "active profile allows a resolved attestation and records dispatch=resolved in meta"
}

test_active_profile_records_override_reason_in_meta() {
  local rec id out status meta
  id=profile-override-z32
  rec=$(make_spawn_case profile-override claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --model sonnet --effort high \
    --dispatch-override-reason "captain instruction: use claude for this task")
  status=$?
  expect_code 0 "$status" "explicit harness with --dispatch-override-reason should pass"
  assert_contains "$out" "spawned $id harness=claude" "override spawn did not report claude"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "dispatch=override" "$meta" "override attestation did not land dispatch=override in meta"
  assert_grep "dispatch_override_reason=captain instruction: use claude for this task" "$meta" \
    "override attestation did not land the reason text in meta"
  pass "active profile records a deliberate override and its reason in meta"
}

test_active_profile_refuses_both_attestations() {
  local rec id out status
  id=profile-both-attestations-z33
  rec=$(make_spawn_case profile-both-attestations claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --dispatch-resolved --dispatch-override-reason "captain instruction")
  status=$?
  expect_code 1 "$status" "passing both attestations should be refused as ambiguous"
  assert_contains "$out" "pass exactly one of --dispatch-resolved or --dispatch-override-reason" \
    "refusal did not name the mutual-exclusion contract"
  assert_absent "$HOME_DIR/state/$id.meta" "ambiguous-attestation refusal should happen before meta is written"
  pass "active profile refuses when both attestations are supplied"
}

test_active_profile_refuses_override_reason_without_explicit_harness() {
  local rec id out status
  id=profile-override-no-harness-z34
  rec=$(make_spawn_case profile-override-no-harness claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --dispatch-override-reason "captain instruction")
  status=$?
  expect_code 1 "$status" "override reason without an explicit harness should be refused"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "override-without-harness refusal did not reuse the explicit-harness backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "override-without-harness refusal should happen before meta is written"
  pass "active profile refuses an override reason that has no harness to override from"
}

test_no_profile_does_not_require_attestation() {
  local rec id out status meta
  id=profile-absent-no-attestation-z35
  rec=$(make_spawn_case profile-absent-no-attestation claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "absent profiles should not require attestation"
  assert_contains "$out" "spawned $id harness=claude" "no-profile spawn did not report claude"
  meta="$HOME_DIR/state/$id.meta"
  assert_no_grep "dispatch=" "$meta" "absent profiles should not record a dispatch attestation line"
  pass "absent crew-dispatch.json does not require or record an attestation"
}

test_active_profile_batch_forwards_resolved_attestation() {
  local rec id1 id2 out status
  id1=profile-batch-resolved-a-z36
  id2=profile-batch-resolved-b-z37
  rec=$(make_spawn_case profile-batch-resolved claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "batch with shared --dispatch-resolved should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id1.meta" "batch did not forward attestation to first task meta"
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id2.meta" "batch did not forward attestation to second task meta"
  pass "batch dispatch forwards shared --dispatch-resolved to every pair"
}

test_active_profile_batch_refuses_without_attestation() {
  local rec id1 id2 out status
  # The batch guard must refuse the whole invocation up front, before any pair is
  # re-execed: without it each pair would still fail its own guard, so the only
  # observable difference is that no pair is ever attempted.
  id1=profile-batch-no-attestation-a-z41
  id2=profile-batch-no-attestation-b-z42
  rec=$(make_spawn_case profile-batch-no-attestation claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 1 "$status" "batch with a shared harness but no attestation should be refused"
  assert_contains "$out" "--dispatch-resolved" "batch refusal did not name the resolved attestation flag"
  assert_not_contains "$out" "batch: FAILED to spawn" \
    "batch refused per pair instead of refusing the whole invocation before any spawn"
  assert_absent "$HOME_DIR/state/$id1.meta" "batch refusal should happen before the first pair spawns"
  assert_absent "$HOME_DIR/state/$id2.meta" "batch refusal should happen before the second pair spawns"
  [ ! -s "$LAUNCH_LOG" ] || fail "batch refusal still launched a harness"$'\n'"launch log: $(cat "$LAUNCH_LOG")"
  pass "batch dispatch refuses a shared harness with no attestation before any pair spawns"
}

test_routing_source_recorded_only_when_declared
test_recorded_default_axes_respawn_as_unset
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
test_active_profile_refuses_explicit_harness_without_attestation
test_active_profile_requires_attestation_for_scout
test_active_profile_refuses_multiline_override_reason
test_active_profile_allows_resolved_attestation_and_records_it
test_active_profile_records_override_reason_in_meta
test_active_profile_refuses_both_attestations
test_active_profile_refuses_override_reason_without_explicit_harness
test_no_profile_does_not_require_attestation
test_active_profile_batch_forwards_resolved_attestation
test_active_profile_batch_refuses_without_attestation
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_cursor_agent_threads_model_variant_and_records_effort
test_pi_threads_model_and_max_effort
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch
test_telemetry_precedes_submission_and_metadata_is_opaque
test_exploration_requires_an_explicit_rotated_model_and_effort
test_no_mistakes_spawn_requires_one_quota_eligible_reviewer
test_linked_telemetry_identifiers_chain_one_task_root

echo "# all fm-spawn-dispatch-profile tests passed"
