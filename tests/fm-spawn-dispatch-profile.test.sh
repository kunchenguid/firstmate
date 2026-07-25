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
  *"#{pane_current_command}"*)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ] \
       && [ -f "$FM_FAKE_LAUNCH_LOG.kimi-busy" ]; then
      printf '%s\n' kimi
    else
      printf '%s\n' zsh
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_EXISTING_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_EXISTING_WINDOW"
    [ ! -f "${FM_FAKE_LAUNCH_LOG:-}.window" ] || cat "$FM_FAKE_LAUNCH_LOG.window"
    exit 0
    ;;
  capture-pane)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ] \
       && [ -f "$FM_FAKE_LAUNCH_LOG.kimi-busy" ]; then
      printf '%s\n' '🌑 · Kimi prompt bootstrap'
    fi
    exit 0
    ;;
  new-window)
    prev=
    for a in "$@"; do
      if [ "$prev" = "-n" ] && [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
        printf '%s\n' "$a" > "$FM_FAKE_LAUNCH_LOG.window"
      fi
      prev=$a
    done
    exit 0
    ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
      case " $* " in
        *" Enter "*)
          control=$(sed -n "s/.*fm-kimi-bootstrap\\.sh' marker '\\([^']*\\)'.*/\\1/p" \
            "$FM_FAKE_LAUNCH_LOG" | tail -1)
          if [ -n "$control" ] && [ -d "$control" ]; then
            sleep 60 &
            bootstrap=$!
            printf 'bootstrap=%s\n' "$bootstrap" > "$control/live"
            printf '%s\n' "$bootstrap" > "$FM_FAKE_LAUNCH_LOG.kimi-pids"
            : > "$FM_FAKE_LAUNCH_LOG.kimi-busy"
          fi
          ;;
      esac
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
  cat > "$fakebin/kimi" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *" -p "*)
    [ -z "${FM_FAKE_KIMI_BOOTSTRAP_DELAY:-}" ] || sleep "$FM_FAKE_KIMI_BOOTSTRAP_DELAY"
    if [ -n "${FM_FAKE_KIMI_PREFLIGHT_LOG:-}" ]; then
      printf 'effort=%s args=%s\n' "${KIMI_MODEL_THINKING_EFFORT:-default}" "$*" \
        > "$FM_FAKE_KIMI_PREFLIGHT_LOG"
    fi
    if [ "${FM_FAKE_KIMI_PREFLIGHT_FAIL:-0}" = 1 ]; then
      echo "config.invalid: Kimi profile preflight rejected" >&2
      exit 1
    fi
    printf '%s\n' '{"role":"assistant","content":"KIMI_PREFLIGHT_OK"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"preflight-session"}'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
exit 99
SH
  chmod +x "$fakebin/treehouse" "$fakebin/kimi" "$fakebin/python3"
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
  : > "$launchlog.preflight"
  : > "$launchlog.treehouse"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    KIMI_CODE_BIN="$fakebin/kimi" KIMI_CODE_HOME="$home/kimi-code" \
    FM_FAKE_KIMI_PREFLIGHT_LOG="$launchlog.preflight" \
    FM_FAKE_TREEHOUSE_LOG="$launchlog.treehouse" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
  local status=$? pid
  if [ -f "$launchlog.kimi-pids" ]; then
    while IFS= read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$launchlog.kimi-pids"
    rm -f "$launchlog.kimi-pids" "$launchlog.kimi-busy"
  fi
  return "$status"
}

write_kimi_config() {  # <home>
  local home=$1
  mkdir -p "$home/kimi-code"
  cat > "$home/kimi-code/config.toml" <<'EOF'
default_model = "kimi-code/kimi-for-coding"

[models."kimi-code/kimi-for-coding"]
provider = "managed:kimi-code"
model = "kimi-for-coding"
max_context_size = 262144

[models."kimi-code/k3"]
provider = "managed:kimi-code"
model = "k3"
max_context_size = 262144
support_efforts = [ "low", "high", "max" ]

[models."kimi-code/k3-256k"]
provider = "managed:kimi-code"
model = "k3-256k"
max_context_size = 262144
support_efforts = [ "low", "high", "max" ]
EOF
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
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
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_kimi_bootstraps_prompt_then_resumes_with_model_and_effort() {
  local rec id out status launch
  id=profile-kimi-z8b
  rec=$(make_spawn_case profile-kimi kimi "$id")
  read_case_record "$rec"
  write_kimi_config "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model kimi-code/k3 --effort high)
  status=$?
  expect_code 0 "$status" "kimi spawn with k3 high effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" kimi kimi-code/k3 high
  assert_contains "$(cat "$LAUNCH_LOG.preflight")" \
    "effort=high args=--model kimi-code/k3 -p Reply with exactly KIMI_PREFLIGHT_OK. --output-format stream-json" \
    "kimi profile preflight did not use the requested model and effort"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$ROOT/bin/fm-kimi-bootstrap.sh' marker" \
    "kimi launch did not start the live-process marker"
  assert_contains "$launch" "/bin/bash -c 'printf \"bootstrap=%s\\n\" \"\$\$\" > \"\$1\"; shift; exec \"\$@\"'" \
    "kimi launch did not exec prompt mode into the pane foreground"
  assert_contains "$launch" "env KIMI_CODE_HOME='$HOME_DIR/kimi-code' KIMI_MODEL_THINKING_EFFORT='high' '$FAKEBIN_DIR/kimi' --model 'kimi-code/k3' -p" \
    "kimi launch did not seed the brief through prompt mode with the requested model and effort"
  assert_contains "$launch" "'$ROOT/bin/fm-kimi-bootstrap.sh' finish \"\$KIMI_STATUS\" '$FAKEBIN_DIR/kimi'" \
    "kimi launch did not finish the captured bootstrap result"
  assert_not_contains "$launch" '🌑 · Kimi prompt bootstrap' \
    "kimi launch command text can impersonate the emitted busy marker"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "kimi launch lost the canonical launch-brief envelope"
  pass "kimi seeds the launch brief with -p, then resumes that session with model and effort"
}

test_kimi_preflight_follows_local_validation() {
  local rec id out status
  id=profile-kimi-local-validation-z8i
  rec=$(make_spawn_case profile-kimi-local-validation kimi "$id")
  read_case_record "$rec"
  write_kimi_config "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$CASE_DIR/missing-project" --model kimi-code/k3 --effort high)
  status=$?
  expect_code 1 "$status" "kimi spawn with a missing project should fail"
  [ ! -s "$LAUNCH_LOG.preflight" ] || fail "kimi preflight ran before project validation"

  out=$(FM_FAKE_EXISTING_WINDOW="fm-$id" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --model kimi-code/k3 --effort high)
  status=$?
  expect_code 1 "$status" "kimi spawn with an existing endpoint should fail"
  assert_contains "$out" "already exists" "kimi duplicate endpoint refusal was not surfaced"
  [ ! -s "$LAUNCH_LOG.preflight" ] || fail "kimi preflight ran before duplicate endpoint validation"
  assert_absent "$HOME_DIR/state/$id.meta" "locally rejected kimi spawn should not write meta"
  pass "kimi preflight runs only after local spawn validation"
}

test_kimi_control_validation_precedes_preflight() {
  local rec id out status
  id=profile-kimi-control-validation-z8j
  rec=$(make_spawn_case profile-kimi-control-validation kimi "$id")
  read_case_record "$rec"
  write_kimi_config "$HOME_DIR"
  chmod 2775 "$HOME_DIR/state"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model kimi-code/k3 --effort high)
  status=$?
  expect_code 1 "$status" "kimi spawn with group-writable special-bit state should fail"
  assert_contains "$out" "state directory is writable by another user" \
    "kimi special-bit state refusal was not surfaced"
  [ ! -s "$LAUNCH_LOG.preflight" ] || fail "kimi preflight ran before secure-control validation"
  assert_grep "return --force $WT_DIR" "$LAUNCH_LOG.treehouse" \
    "kimi control-validation abort did not return the leased worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "rejected kimi control setup should not write meta"
  pass "kimi control validation handles special bits before preflight"
}

test_kimi_records_and_omits_effort_for_non_k3_model() {
  local rec id out status launch preflight
  id=profile-kimi-nosupport-z8c
  rec=$(make_spawn_case profile-kimi-nosupport kimi "$id")
  read_case_record "$rec"
  write_kimi_config "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model kimi-code/kimi-for-coding --effort low)
  status=$?
  expect_code 0 "$status" "kimi spawn should record and omit effort for a non-K3 model"
  assert_meta_profile "$HOME_DIR/state/$id.meta" kimi kimi-code/kimi-for-coding low
  preflight=$(cat "$LAUNCH_LOG.preflight")
  assert_contains "$preflight" "effort=default args=--model kimi-code/kimi-for-coding" \
    "kimi non-K3 preflight should omit the effort environment"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "KIMI_MODEL_THINKING_EFFORT=" \
    "kimi non-K3 launch should omit the effort environment"
  pass "kimi records and omits effort for models without verified effort support"
}

test_kimi_rejects_unsupported_effort_value() {
  local rec id out status
  id=profile-kimi-medium-z8d
  rec=$(make_spawn_case profile-kimi-medium kimi "$id")
  read_case_record "$rec"
  write_kimi_config "$HOME_DIR"

  out=$(FM_FAKE_KIMI_PREFLIGHT_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model kimi-code/k3 --effort medium)
  status=$?
  expect_code 1 "$status" "kimi spawn should reject medium effort"
  assert_contains "$out" "config.invalid: Kimi profile preflight rejected" \
    "kimi unsupported effort rejection did not surface Kimi's preflight error"
  assert_absent "$HOME_DIR/state/$id.meta" "kimi rejected medium effort should not write meta"
  assert_grep "return --force $WT_DIR" "$LAUNCH_LOG.treehouse" \
    "kimi preflight abort did not return the leased worktree"
  [ -z "$(find "$HOME_DIR/state" -maxdepth 1 -name '.kimi-bootstrap-*' -print -quit)" ] \
    || fail "kimi preflight abort left secure-control state behind"
  pass "kimi rejects unsupported effort values before spawning"
}

test_kimi_bootstrap_launcher_owns_marker_and_secure_capture() {
  local control output pid marker status mode
  control="$TMP_ROOT/kimi-launcher-control"
  output="$TMP_ROOT/kimi-launcher-output"
  mkdir -m 700 "$control"
  for name in capture live; do
    : > "$control/$name"
    chmod 600 "$control/$name"
  done

  sleep 60 &
  pid=$!
  printf 'bootstrap=%s\n' "$pid" > "$control/live"
  "$ROOT/bin/fm-kimi-bootstrap.sh" marker "$control" > "$output" 2>&1 &
  marker=$!
  for _ in $(seq 1 50); do
    grep -q 'Kimi prompt bootstrap' "$output" 2>/dev/null && break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null || fail "kimi bootstrap pid was not live with its busy marker"
  kill -0 "$marker" 2>/dev/null || fail "kimi marker did not follow the live bootstrap pid"
  mode=$(if stat -f '%Lp' "$control/capture" >/dev/null 2>&1; then stat -f '%Lp' "$control/capture"; else stat -c '%a' "$control/capture"; fi)
  [ "$mode" = 600 ] || fail "kimi bootstrap capture mode was $mode, expected 600"
  [ ! -L "$control/capture" ] || fail "kimi bootstrap capture was a symlink"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  wait "$marker"
  printf '%s\n' 'bootstrap failure detail' > "$control/capture"
  output=$("$ROOT/bin/fm-kimi-bootstrap.sh" finish 7 \
    "$FAKEBIN_DIR/kimi" "$control" --model kimi-code/k3 2>&1)
  status=$?
  expect_code 7 "$status" "kimi bootstrap finisher should preserve prompt-mode failure status"
  assert_contains "$output" "bootstrap failure detail" \
    "kimi bootstrap finisher discarded captured failure output"
  assert_absent "$control" "kimi bootstrap finisher did not remove its secure control directory"
  pass "kimi bootstrap marker and failure capture follow the live process lifecycle"
}

test_kimi_default_model_requires_real_section() {
  local rec id out status
  id=profile-kimi-missing-default-z8e
  rec=$(make_spawn_case profile-kimi-missing-default kimi "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/kimi-code"
  printf '%s\n' 'default_model = "missing/model"' > "$HOME_DIR/kimi-code/config.toml"

  out=$(FM_FAKE_KIMI_PREFLIGHT_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "kimi spawn should reject a default_model without a model section"
  assert_contains "$out" "config.invalid: Kimi profile preflight rejected" \
    "kimi missing default model section rejection did not surface Kimi's preflight error"
  assert_absent "$HOME_DIR/state/$id.meta" "kimi missing default model section should not write meta"
  pass "kimi requires the default model to have a real model section"
}

test_kimi_accepts_literal_config_and_omits_default_effort() {
  local rec id out status
  id=profile-kimi-literal-config-z8g
  rec=$(make_spawn_case profile-kimi-structured-config kimi "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/kimi-code"
  cat > "$HOME_DIR/kimi-code/config.toml" <<'EOF'
default_model = 'custom/kimi'

[models.'custom/kimi']
support_efforts = [
  'low',
  'high', # 'max' is intentionally disabled
]
EOF

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --effort high)
  status=$?
  expect_code 0 "$status" "kimi spawn should accept literal-string TOML"
  assert_meta_profile "$HOME_DIR/state/$id.meta" kimi default high
  assert_contains "$(cat "$LAUNCH_LOG.preflight")" "effort=default args=-p" \
    "kimi default-model preflight should omit the unverified effort environment"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "KIMI_MODEL_THINKING_EFFORT=" \
    "kimi default-model launch should omit the unverified effort environment"
  pass "kimi records and omits effort when the resolved default model is unknown"
}

test_kimi_rejects_duplicate_toml_declarations() {
  local rec id out status
  id=profile-kimi-duplicate-config-z8h
  rec=$(make_spawn_case profile-kimi-duplicate-config kimi "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/kimi-code"
  cat > "$HOME_DIR/kimi-code/config.toml" <<'EOF'
default_model = "custom/kimi"

[models."custom/kimi"]
support_efforts = ["low", "high"]
support_efforts = ["low", "high", "max"]
EOF

  out=$(FM_FAKE_KIMI_PREFLIGHT_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --effort max)
  status=$?
  expect_code 1 "$status" "kimi spawn should reject duplicate TOML declarations"
  assert_contains "$out" "config.invalid: Kimi profile preflight rejected" \
    "kimi duplicate declaration rejection did not surface Kimi's preflight error"
  assert_absent "$HOME_DIR/state/$id.meta" "kimi duplicate TOML declaration should not write meta"
  pass "kimi rejects duplicate TOML declarations before writing metadata"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
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

test_kimi_secondmate_launch_is_refused() {
  local rec id id_pos sm out status
  id=profile-kimi-secondmate-z17
  id_pos=profile-kimi-secondmate-pos-z18
  rec=$(make_spawn_case profile-kimi-secondmate codex "$id" "$id_pos")
  read_case_record "$rec"
  write_kimi_config "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$sm" --secondmate --harness kimi)
  status=$?
  expect_code 1 "$status" "kimi secondmate spawn should be refused"
  assert_contains "$out" "kimi is verified for crewmate/scout spawns only" \
    "kimi secondmate refusal did not explain the scope boundary"
  assert_absent "$HOME_DIR/state/$id.meta" "refused kimi secondmate launch should not write meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_pos" kimi --secondmate)
  status=$?
  expect_code 1 "$status" "positional kimi secondmate spawn should be refused"
  assert_contains "$out" "kimi is verified for crewmate/scout spawns only" \
    "positional kimi secondmate refusal did not explain the scope boundary"
  assert_absent "$HOME_DIR/state/$id_pos.meta" "refused positional kimi secondmate launch should not write meta"
  pass "kimi is refused for secondmate primary launches"
}

test_no_profile_keeps_claude_profile_defaults
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
test_kimi_bootstraps_prompt_then_resumes_with_model_and_effort
test_kimi_preflight_follows_local_validation
test_kimi_control_validation_precedes_preflight
test_kimi_bootstrap_launcher_owns_marker_and_secure_capture
test_kimi_records_and_omits_effort_for_non_k3_model
test_kimi_rejects_unsupported_effort_value
test_kimi_default_model_requires_real_section
test_kimi_accepts_literal_config_and_omits_default_effort
test_kimi_rejects_duplicate_toml_declarations
test_batch_forwards_shared_profile_flags
test_active_dispatch_profile_does_not_block_secondmate_launch
test_kimi_secondmate_launch_is_refused

echo "# all fm-spawn-dispatch-profile tests passed"
