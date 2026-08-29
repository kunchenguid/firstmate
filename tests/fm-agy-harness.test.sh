#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI (agy) crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HARNESS_SH="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

assert_equals() {
  local expected=$1 actual=$2 msg=$3
  [ "$actual" = "$expected" ] || fail "$msg (expected: '$expected', got: '$actual')"
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
    if [ -n "${FM_FAKE_CAPTURE_KEYS:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_CAPTURE_KEYS"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_agy_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --harness agy --mode no-mistakes --yolo off "$@" 2>&1
}

test_agy_harness_detection() {
  local out fakebin ps_dir
  out=$(ANTIGRAVITY_AGENT=1 "$HARNESS_SH")
  assert_equals "agy" "$out" "ANTIGRAVITY_AGENT=1 did not detect agy"

  out=$(ANTIGRAVITY_LS_VERSION=cli-1.1.22 "$HARNESS_SH")
  assert_equals "agy" "$out" "ANTIGRAVITY_LS_VERSION did not detect agy"

  out=$(ANTIGRAVITY_SOURCE_METADATA="test" "$HARNESS_SH")
  assert_equals "agy" "$out" "ANTIGRAVITY_SOURCE_METADATA did not detect agy"

  out=$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 "$HARNESS_SH")
  assert_equals "agy" "$out" "ANTIGRAVITY_AGENT did not outrank inherited CLAUDECODE"

  ps_dir="$TMP_ROOT/ps-test"
  fakebin=$(fm_fakebin "$ps_dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/home/blake/.local/bin/agy'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS_SH")
  assert_equals "agy" "$out" "process ancestry agy was not detected"

  pass "fm-harness detects agy from environment markers and ancestry"
}

test_agy_launch_model_and_effort_rules() {
  local rec case_dir home proj wt fakebin id keys_log out status

  # Case 1: default model and default effort
  rec=$(make_spawn_case default-model)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  keys_log="$case_dir/keys.log"
  FM_FAKE_CAPTURE_KEYS="$keys_log"
  export FM_FAKE_CAPTURE_KEYS

  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "default agy spawn should succeed"
  assert_grep "--model 'gemini-3.7-flash-high'" "$keys_log" "default model was not gemini-3.7-flash-high"
  assert_grep "--dangerously-skip-permissions" "$keys_log" "--dangerously-skip-permissions was missing"
  assert_grep "--prompt-interactive=" "$keys_log" "--prompt-interactive= was missing or unattached"
  assert_no_grep "--effort" "$keys_log" "default model with embedded effort should not receive --effort flag"

  # Case 2: base gemini model with explicit effort low
  rec=$(make_spawn_case base-gemini-effort)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  keys_log="$case_dir/keys.log"
  FM_FAKE_CAPTURE_KEYS="$keys_log"
  export FM_FAKE_CAPTURE_KEYS

  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --model gemini-3.7-flash --effort low)
  status=$?
  expect_code 0 "$status" "gemini base model with effort should succeed"
  assert_grep "--model 'gemini-3.7-flash'" "$keys_log" "explicit model was not passed"
  assert_grep "--effort 'low'" "$keys_log" "base gemini model did not receive effort low"

  # Case 3: base gemini model with xhigh (capped to high)
  rec=$(make_spawn_case xhigh-cap)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  keys_log="$case_dir/keys.log"
  FM_FAKE_CAPTURE_KEYS="$keys_log"
  export FM_FAKE_CAPTURE_KEYS

  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --model gemini-3.7-flash --effort xhigh)
  status=$?
  expect_code 0 "$status" "gemini xhigh spawn should succeed"
  assert_grep "--effort 'high'" "$keys_log" "xhigh was not capped to high"

  # Case 4: non-gemini model omits effort flag
  rec=$(make_spawn_case claude-model)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  keys_log="$case_dir/keys.log"
  FM_FAKE_CAPTURE_KEYS="$keys_log"
  export FM_FAKE_CAPTURE_KEYS

  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --model claude-sonnet-4-6 --effort high)
  status=$?
  expect_code 0 "$status" "claude model spawn should succeed"
  assert_grep "--model 'claude-sonnet-4-6'" "$keys_log" "claude model was not passed"
  assert_no_grep "--effort" "$keys_log" "non-gemini model should not receive --effort flag"

  pass "agy launch composition enforces model and effort rules"
}

test_agy_secondmate_refusal() {
  local rec case_dir home proj wt fakebin id out status=0
  rec=$(make_spawn_case secondmate-refusal)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$home/subhome" --harness agy --secondmate 2>&1) || status=$?
  expect_code 1 "$status" "spawn --secondmate with agy should fail"
  assert_contains "$out" "error: agy is a verified crewmate/scout adapter only and cannot run a secondmate" "secondmate error message mismatch"

  if fm_control_harness_supports_kind agy secondmate; then
    fail "fm_control_harness_supports_kind should return false for agy secondmate"
  fi
  if ! fm_control_harness_supports_kind agy ship; then
    fail "fm_control_harness_supports_kind should return true for agy ship"
  fi

  pass "agy refuses --secondmate launch"
}

test_agy_spawn_hooks_and_teardown() {
  local rec case_dir home proj wt fakebin id out status hooks_json keys_log
  rec=$(make_spawn_case hook-wiring)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  keys_log="$case_dir/keys.log"
  FM_FAKE_CAPTURE_KEYS="$keys_log"
  export FM_FAKE_CAPTURE_KEYS

  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "agy spawn should succeed"
  assert_contains "$out" "spawned $id harness=agy" "spawn output did not report agy success"

  hooks_json="$wt/.agents/hooks.json"
  assert_present "$hooks_json" ".agents/hooks.json was not created in worktree"
  assert_grep "PreInvocation" "$hooks_json" "PreInvocation hook was not in hooks.json"
  assert_grep "Stop" "$hooks_json" "Stop hook was not in hooks.json"
  assert_grep "agy-hook" "$hooks_json" "agy-hook source was not in hook command"

  if ! git -C "$wt" check-ignore -q .agents/hooks.json; then
    fail ".agents/hooks.json was not git-ignored via exclude_path"
  fi

  assert_present "$home/state/$id.busy-gen" "busy-gen sidecar was not minted"
  assert_present "$home/state/$id.busy-state" "busy-state was not seeded"
  assert_grep "busy" "$home/state/$id.busy-state" "initial state was not busy"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "agy teardown failed"

  assert_absent "$hooks_json" ".agents/hooks.json survived teardown"
  assert_absent "$home/state/$id.busy-gen" "busy-gen survived teardown"
  assert_absent "$home/state/$id.busy-state" "busy-state survived teardown"

  pass "agy spawn wires hooks and teardown cleans them up"
}

test_agy_control_and_composer() {
  local key repeat exit_cmd
  key=$(fm_control_interrupt_key agy)
  assert_equals "C-c" "$key" "agy interrupt key should be C-c"

  repeat=$(fm_control_interrupt_repeat agy)
  assert_equals "1" "$repeat" "agy interrupt repeat should be 1"

  exit_cmd=$(fm_control_exit_command agy)
  assert_equals "/exit" "$exit_cmd" "agy exit command should be /exit"

  if ! printf '%s\n' 'esc to cancel' | fm_busy_lines_match agy; then
    fail "fm_busy_lines_match agy did not match 'esc to cancel'"
  fi

  pass "agy control plane and delivery busy token verified"
}

test_agy_harness_detection
test_agy_launch_model_and_effort_rules
test_agy_secondmate_refusal
test_agy_spawn_hooks_and_teardown
test_agy_control_and_composer
