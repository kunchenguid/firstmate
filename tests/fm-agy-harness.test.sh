#!/usr/bin/env bash
# Behavior tests for the verified agy (Antigravity CLI) crewmate/scout adapter:
# harness detection, launch shape and model pin, the secondmate refusal, the
# claude-model refusal, and the guarded global Stop hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
AGY_HOOK="$ROOT/bin/fm-agy-turnend-hook.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
JQ_BIN=$(command -v jq) || fail "test needs jq"

trap 'rm -rf "$TMP_ROOT"' EXIT

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
  capture-pane)
    # FM_FAKE_TRUST_STATE models a live trust dialog: it is shown while the
    # dialog file exists, and the first Enter sent after it has actually been
    # displayed accepts it, the way agy's preselected Yes does. Timing-free, so
    # the dialog cannot be "cleared" by a keystroke sent before it appeared.
    if [ -n "${FM_FAKE_TRUST_STATE:-}" ] && [ -e "$FM_FAKE_TRUST_STATE/dialog" ]; then
      : > "$FM_FAKE_TRUST_STATE/shown"
      printf 'Do you trust the contents of this project?\n'
      exit 0
    fi
    if [ -n "${FM_FAKE_PANE_TEXT:-}" ]; then
      printf '%s\n' "$FM_FAKE_PANE_TEXT"
    else
      printf '? for shortcuts                                          Gemini 3.1 Pro · high\n'
    fi
    exit 0
    ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      if [ "$arg" = Enter ]; then
        printf 'Enter\n' >> "${FM_FAKE_KEYS_LOG:-/dev/null}"
        if [ -n "${FM_FAKE_TRUST_STATE:-}" ] && [ -e "$FM_FAKE_TRUST_STATE/shown" ]; then
          rm -f "$FM_FAKE_TRUST_STATE/dialog"
        fi
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" agy treehouse gh-axi gh
  ln -s "$JQ_BIN" "$fakebin/jq"
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
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/.gemini/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_agy_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  run_spawn_arg3 "$home" "$proj" "$wt" "$fakebin" "$id" agy "$@"
}

run_spawn_arg3() {  # <home> <proj> <wt> <fakebin> <id> <arg3> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 arg3=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_AGY_TRUST_POLLS="${FM_AGY_TRUST_POLLS:-0}" \
    FM_AGY_TRUST_POLL_INTERVAL="${FM_AGY_TRUST_POLL_INTERVAL:-0}" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    HOME="$home" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$arg3" "$@" 2>&1
}

# --- detection --------------------------------------------------------------

test_detects_agy_process_ancestor() {
  local dir out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/agy"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT \
    -u CURSOR_INVOKED_AS \
    "$dir/agy" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = agy ] || fail "fm-harness.sh under process agy reported '$out', expected agy"
  pass "agy is detected through an agy process ancestor"
}

test_detection_does_not_claim_agy_substrings() {
  local dir out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in magy agy-bin notagy; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != agy ] || fail "fm-harness.sh misdetected unrelated process '$bin' as agy"
  done
  pass "agy detection does not claim unrelated agy-containing commands"
}

# --- spawn ------------------------------------------------------------------

test_spawn_launch_shape_pins_gemini_and_omits_effort() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "agy spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" '--dangerously-skip-permissions' "agy launch omitted autonomy"
  assert_contains "$launch" "--model 'gemini-3.1-pro-high'" "agy launch did not pin gemini-3.1-pro-high"
  assert_contains "$launch" '--prompt-interactive' "agy launch omitted --prompt-interactive"
  assert_contains "$launch" 'encode launch-brief' "agy launch did not deliver the brief"
  assert_not_contains "$launch" '--effort' "agy launch passed --effort, which conflicts with *-high model ids"
  assert_grep 'harness=agy' "$home/state/$id.meta" "agy harness was not recorded in meta"
  assert_grep 'model=gemini-3.1-pro-high' "$home/state/$id.meta" "agy default model was not recorded"
  # The prompt must come AFTER the flags; --prompt-interactive --model swallows --model as the prompt.
  case "$launch" in
    *'--prompt-interactive'*'--model'*)
      fail "agy launch placed --prompt-interactive before --model, which consumes --model as the prompt"
      ;;
  esac
  pass "agy spawn pins gemini-3.1-pro-high, skips --effort, and keeps --prompt-interactive last"
}

test_spawn_omits_requested_effort_and_keeps_model_pin() {
  local rec case_dir home proj wt fakebin id launch
  rec=$(make_spawn_case effort)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort low >/dev/null \
    || fail "agy spawn with effort low failed"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "--model 'gemini-3.1-pro-high'" "agy effort spawn dropped the model pin"
  assert_not_contains "$launch" '--effort' "agy spawn forwarded --effort low, which conflicts with gemini-3.1-pro-high"
  assert_grep 'effort=low' "$home/state/$id.meta" "requested effort was not recorded in meta"
  pass "agy records requested effort in meta and omits it from the launch"
}

test_spawn_refuses_claude_model() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case claude-model)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --model claude-sonnet-4-6)
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn accepted a claude model"
  assert_contains "$out" "claude" "agy claude-model refusal did not name the blocked model family"
  assert_absent "$home/state/$id.meta" "refused agy spawn still published task metadata"
  pass "agy spawn refuses claude-* models"
}

test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="agy-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/.gemini/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" HOME="$home" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" agy --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "agy was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" "agy secondmate refusal did not explain the boundary"
  pass "agy is refused as a secondmate harness"
}

test_spawn_clears_inherited_foreign_harness_markers() {
  local rec case_dir home proj wt fakebin id launch out status
  rec=$(make_spawn_case inherited-markers)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true GROK_AGENT=1 FM_PI_HARNESS=pi-signed \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "agy spawn from a marked backend should succeed: $out"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" '-u CLAUDECODE' "agy launch did not clear an inherited CLAUDECODE"
  pass "agy launch clears foreign harness markers"
}

test_raw_launch_command_named_agy_spawns() {
  # The raw-launch escape hatch names the harness from the command's first
  # word, so `agy ...` takes the agy branch without ever going through the
  # generated template - and so without the hook installer that only the
  # template block runs. This hatch is the adapter-verification path, so it has
  # to work unaided: nothing here pre-creates the turn-end registry the skipped
  # installer would have made, and the mint must still land rather than abort a
  # spawn whose window and worktree already exist.
  local rec case_dir home proj wt fakebin id raw launch out status
  rec=$(make_spawn_case raw-launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  raw="agy --dangerously-skip-permissions --prompt-interactive 'probe'"
  out=$(run_spawn_arg3 "$home" "$proj" "$wt" "$fakebin" "$id" "$raw" \
    --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "raw agy launch command should spawn: $out"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "$raw" "raw agy launch command was not sent to the pane"
  assert_present "$wt/.fm-agy-turnend" "raw agy launch did not write the turn-end pointer"
  assert_present "$home/state/$id.agy-turnend-token" \
    "raw agy launch did not record the turn-end token"
  pass "a raw launch command whose first word is agy spawns unaided"
}

# --- turn-end hook ----------------------------------------------------------

test_hook_install_is_surgical_and_gated() {
  local home config hook registry
  home="$TMP_ROOT/hook-home"
  config="$home/.gemini/config/hooks.json"
  hook="$home/.gemini/config/fm-agy-turn-end.sh"
  registry="$home/.gemini/config/fm-agy-turn-end.d"
  mkdir -p "$home/.gemini/config"
  printf '%s\n' '{"captain-hook":{"Stop":[{"type":"command","command":"true"}]}}' > "$config"

  HOME="$home" "$AGY_HOOK" install || fail "agy hook install failed"
  assert_present "$hook" "install did not write the hook script"
  assert_present "$registry" "install did not create the token registry"
  "$PYTHON_BIN" - "$config" <<'PY' || fail "installed hooks.json is not valid JSON with both keys"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "captain-hook" in data, data
assert "fm-agy-turn-end" in data, data
PY
  HOME="$home" "$AGY_HOOK" install || fail "second agy hook install failed"
  # The key exists once.
  "$PYTHON_BIN" - "$config" <<'PY' || fail "idempotent install duplicated the Firstmate hook key"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert list(data.keys()).count("fm-agy-turn-end") == 1
PY

  HOME="$home" "$AGY_HOOK" remove || fail "agy hook removal failed"
  "$PYTHON_BIN" - "$config" <<'PY' || fail "removal dropped the captain hook or left the Firstmate key"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "captain-hook" in data, data
assert "fm-agy-turn-end" not in data, data
PY
  assert_absent "$hook" "removal left the Firstmate hook script"
  pass "agy hook install is surgical and removal keeps foreign hooks"
}

test_hook_install_never_names_a_missing_command() {
  local home config registry status
  home="$TMP_ROOT/hook-order"
  config="$home/.gemini/config/hooks.json"
  registry="$home/.gemini/config/fm-agy-turn-end.d"
  mkdir -p "$home/.gemini/config"
  # The registry path is occupied, so the hook script cannot be written.
  printf 'occupied\n' > "$registry"

  HOME="$home" "$AGY_HOOK" install >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "install should refuse when the registry path is not a directory"
  assert_absent "$config" \
    "a failed install left hooks.json naming a Stop command that was never written"
  pass "agy hook install writes no config when the hook script cannot be written"
}

test_hook_install_refuses_a_foreign_hook_path() {
  local home config hook registry status before
  home="$TMP_ROOT/hook-foreign"
  config="$home/.gemini/config/hooks.json"
  hook="$home/.gemini/config/fm-agy-turn-end.sh"
  registry="$home/.gemini/config/fm-agy-turn-end.d"
  mkdir -p "$home/.gemini/config"
  printf '%s\n' '{"captain-hook":{"Stop":[{"type":"command","command":"true"}]}}' > "$config"
  before=$(cat "$config")
  printf '#!/usr/bin/env bash\necho captain script\n' > "$hook"

  HOME="$home" "$AGY_HOOK" install >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "install should refuse to overwrite a foreign hook script"
  [ "$(cat "$config")" = "$before" ] || fail "a refused install still edited hooks.json"
  assert_grep 'echo captain script' "$hook" "a refused install overwrote the foreign hook script"

  rm -f "$hook"
  ln -s "$TMP_ROOT/elsewhere" "$registry"
  HOME="$home" "$AGY_HOOK" install >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "install should refuse a symlinked token registry"
  assert_absent "$TMP_ROOT/elsewhere" "a refused install created the symlink target directory"
  pass "agy hook install refuses a foreign hook script or symlinked registry"
}

test_hook_remove_deregisters_a_foreign_hook_script() {
  local home config hook status
  home="$TMP_ROOT/hook-remove-foreign"
  config="$home/.gemini/config/hooks.json"
  hook="$home/.gemini/config/fm-agy-turn-end.sh"
  mkdir -p "$home/.gemini/config"
  HOME="$home" "$AGY_HOOK" install >/dev/null 2>&1 || fail "install for the removal test failed"
  # Something else replaced the hook script Firstmate registered.
  printf '#!/usr/bin/env bash\necho not ours\n' > "$hook"

  HOME="$home" "$AGY_HOOK" remove >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "remove should still report the unrecognized hook script"
  "$PYTHON_BIN" - "$config" <<'PY' || fail "remove left agy executing an unrecognized Stop command"
import json, os, sys
path = sys.argv[1]
if os.path.exists(path):
    assert "fm-agy-turn-end" not in json.load(open(path, encoding="utf-8")), "key survived"
PY
  assert_present "$hook" "remove deleted a hook script it does not recognize"
  pass "agy hook removal de-registers the Stop key even when the hook script is foreign"
}

test_hook_script_touches_only_a_matching_pointer() {
  local home hook wt token target payload
  home="$TMP_ROOT/hook-fire"
  mkdir -p "$home/.gemini/config/fm-agy-turn-end.d"
  HOME="$home" "$AGY_HOOK" install || fail "hook install for fire test failed"
  hook="$home/.gemini/config/fm-agy-turn-end.sh"
  wt="$home/wt"
  mkdir -p "$wt"
  token="fm.abcdefghijkl"
  target="$home/state/agy-fire.turn-ended"
  mkdir -p "$home/state"
  printf '%s\n' "$target" > "$home/.gemini/config/fm-agy-turn-end.d/$token"
  printf 'token=%s\n' "$token" > "$wt/.fm-agy-turnend"
  payload=$(printf '%s' "{\"workspacePaths\":[\"$wt\"]}")
  HOME="$home" "$hook" <<<"$payload"
  assert_present "$target" "matching pointer did not touch the turn-end marker"

  rm -f "$target"
  payload=$(printf '%s' '{"workspacePaths":["/tmp/not-a-firstmate-worktree"]}')
  HOME="$home" "$hook" <<<"$payload"
  assert_absent "$target" "a workspace without a pointer still touched the turn-end marker"
  pass "agy Stop hook is gated by the worktree pointer and registry token"
}

test_spawn_writes_turnend_pointer() {
  local rec case_dir home proj wt fakebin id
  rec=$(make_spawn_case turnend)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "agy spawn for turnend pointer failed"
  assert_present "$wt/.fm-agy-turnend" "agy spawn did not write the turn-end pointer"
  assert_present "$home/state/$id.agy-turnend-token" "agy spawn did not record the turn-end token"
  assert_present "$home/.gemini/config/hooks.json" "agy spawn did not install the global Stop hook"
  pass "agy spawn installs the gated global Stop hook and per-task pointer"
}

test_hook_script_reads_a_pretty_printed_payload() {
  local home hook wt token target payload
  home="$TMP_ROOT/hook-multiline"
  mkdir -p "$home/.gemini/config/fm-agy-turn-end.d"
  HOME="$home" "$AGY_HOOK" install || fail "hook install for multiline test failed"
  hook="$home/.gemini/config/fm-agy-turn-end.sh"
  wt="$home/wt"
  mkdir -p "$wt" "$home/state"
  token="fm.abcdefghijkl"
  target="$home/state/agy-multiline.turn-ended"
  printf '%s\n' "$target" > "$home/.gemini/config/fm-agy-turn-end.d/$token"
  printf 'token=%s\n' "$token" > "$wt/.fm-agy-turnend"
  # agy is free to pretty-print the Stop payload; a first-line-only read sees
  # `{` and the wake is lost silently.
  payload=$(printf '{\n  "workspacePaths": [\n    "%s"\n  ]\n}\n' "$wt")
  HOME="$home" "$hook" <<<"$payload"
  assert_present "$target" "a pretty-printed Stop payload did not touch the turn-end marker"
  pass "agy Stop hook reads a multi-line Stop payload, not just its first line"
}

test_hook_script_scans_every_workspace_path() {
  local home hook wt token target payload
  home="$TMP_ROOT/hook-multiroot"
  mkdir -p "$home/.gemini/config/fm-agy-turn-end.d"
  HOME="$home" "$AGY_HOOK" install || fail "hook install for multiroot test failed"
  hook="$home/.gemini/config/fm-agy-turn-end.sh"
  wt="$home/wt"
  mkdir -p "$wt" "$home/state"
  token="fm.abcdefghijkl"
  target="$home/state/agy-multiroot.turn-ended"
  printf '%s\n' "$target" > "$home/.gemini/config/fm-agy-turn-end.d/$token"
  printf 'token=%s\n' "$token" > "$wt/.fm-agy-turnend"
  # workspacePaths is an array; reading only [0] loses the wake whenever the
  # task worktree is not the first root agy reports.
  payload=$(printf '%s' "{\"workspacePaths\":[\"/tmp/not-a-firstmate-worktree\",\"$wt\"]}")
  HOME="$home" "$hook" <<<"$payload"
  assert_present "$target" "a later-index worktree did not touch the turn-end marker"

  rm -f "$target"
  payload=$(printf '%s' '{"workspacePaths":["/tmp/not-a-firstmate-worktree","/tmp/also-not-one"]}')
  HOME="$home" "$hook" <<<"$payload"
  assert_absent "$target" "a multi-root payload with no pointer still touched the turn-end marker"
  pass "agy Stop hook scans every workspace path, not only the first"
}

test_spawn_fails_when_the_trust_dialog_never_clears() {
  local rec case_dir home proj wt fakebin id out status base_enters stuck_enters
  rec=$(make_spawn_case trust-ready)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_AGY_TRUST_POLLS=3 FM_AGY_TRUST_POLL_INTERVAL=0 \
    FM_FAKE_KEYS_LOG="$home/keys.log" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "agy spawn against a ready pane failed"
  base_enters=$(grep -c '^Enter$' "$home/keys.log")

  rec=$(make_spawn_case trust-stuck)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(FM_AGY_TRUST_POLLS=3 FM_AGY_TRUST_POLL_INTERVAL=0 \
    FM_FAKE_PANE_TEXT='Do you trust the contents of this project?' \
    FM_FAKE_KEYS_LOG="$home/keys.log" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn reported success while its trust dialog was still up: $out"
  assert_contains "$out" "trust dialog" "stuck-trust refusal did not name the trust dialog"
  assert_grep 'failed:' "$home/state/$id.status" "stuck-trust spawn did not record a failure status"
  # Exactly one accept Enter across three polls: a second one would submit an
  # empty prompt to the composer the moment the dialog does clear.
  stuck_enters=$(grep -c '^Enter$' "$home/keys.log")
  [ "$stuck_enters" -eq "$((base_enters + 1))" ] \
    || fail "agy spawn sent $((stuck_enters - base_enters)) accept Enters across 3 trust polls, expected 1"
  pass "agy spawn fails when its trust dialog is still up, having sent exactly one accept"
}

test_spawn_accepts_a_trust_dialog_that_appears_on_the_last_poll() {
  local rec case_dir home proj wt fakebin id out status trust base_enters late_enters
  rec=$(make_spawn_case trust-late-base)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_AGY_TRUST_POLLS=1 FM_AGY_TRUST_POLL_INTERVAL=0 \
    FM_FAKE_KEYS_LOG="$home/keys.log" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "agy spawn against a ready pane failed"
  base_enters=$(grep -c '^Enter$' "$home/keys.log")

  # A cold agy start can reach the dialog only on the last budgeted poll. The
  # accept lands, so the brief does reach the agent; declaring failure there
  # would strand a working crewmate behind a failed spawn.
  rec=$(make_spawn_case trust-late)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  trust="$case_dir/trust"
  mkdir -p "$trust"
  : > "$trust/dialog"
  out=$(FM_AGY_TRUST_POLLS=1 FM_AGY_TRUST_POLL_INTERVAL=0 \
    FM_FAKE_TRUST_STATE="$trust" FM_FAKE_KEYS_LOG="$home/keys.log" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "agy spawn failed on a trust dialog its own accept cleared: $out"
  assert_contains "$out" "spawned $id harness=agy" "late-dialog agy spawn did not report success"
  assert_grep 'harness=agy' "$home/state/$id.meta" "late-dialog agy spawn published no task metadata"
  late_enters=$(grep -c '^Enter$' "$home/keys.log")
  [ "$late_enters" -eq "$((base_enters + 1))" ] \
    || fail "late-dialog agy spawn sent $((late_enters - base_enters)) accept Enters, expected 1"
  pass "agy spawn re-checks a trust dialog it accepted on the last poll"
}

test_teardown_removes_agy_pointer_and_registry_token() {
  local rec case_dir home proj wt fakebin id token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "agy spawn for teardown failed"
  token=$(sed -n 's/^token=//p' "$wt/.fm-agy-turnend")
  [ -n "$token" ] || fail "agy spawn wrote no turn-end token"
  assert_present "$home/.gemini/config/fm-agy-turn-end.d/$token" "agy spawn minted no registry entry"

  HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "agy teardown failed"
  assert_absent "$home/.gemini/config/fm-agy-turn-end.d/$token" \
    "agy registry entry survived teardown, leaking one home-config file per task"
  assert_absent "$home/state/$id.agy-turnend-token" "agy turn-end token state survived teardown"
  assert_absent "$wt/.fm-agy-turnend" "agy turn-end pointer survived teardown"
  pass "fm-teardown: agy registry entry, state token, and worktree pointer are all retired"
}

test_detects_agy_process_ancestor
test_detection_does_not_claim_agy_substrings
test_spawn_launch_shape_pins_gemini_and_omits_effort
test_spawn_omits_requested_effort_and_keeps_model_pin
test_spawn_refuses_claude_model
test_spawn_refuses_secondmate
test_spawn_clears_inherited_foreign_harness_markers
test_raw_launch_command_named_agy_spawns
test_hook_install_is_surgical_and_gated
test_hook_install_never_names_a_missing_command
test_hook_install_refuses_a_foreign_hook_path
test_hook_remove_deregisters_a_foreign_hook_script
test_hook_script_touches_only_a_matching_pointer
test_hook_script_reads_a_pretty_printed_payload
test_hook_script_scans_every_workspace_path
test_spawn_writes_turnend_pointer
test_spawn_fails_when_the_trust_dialog_never_clears
test_spawn_accepts_a_trust_dialog_that_appears_on_the_last_poll
test_teardown_removes_agy_pointer_and_registry_token
