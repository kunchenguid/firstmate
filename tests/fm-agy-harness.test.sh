#!/usr/bin/env bash
# Behavior tests for the agy (Google Antigravity CLI) crewmate adapter:
# harness detection, spawn launch shape, workspace pre-trust, per-task hook
# wiring, the secondmate refusal, control-plane tables, busy-source trust,
# and relaunch/teardown wiring paths.
#
# The live-harness half (trust dialog, hook firing, interrupt, exit/resume)
# is recorded in docs/verification/antigravity.md; these cases pin the
# harness-independent logic with real processes and no agy binary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
AGY_RUNTIME_TASK_TMPS=()
JQ_BIN=$(command -v jq) || fail "test needs jq"
JQ_BIN_DIR=$(dirname "$JQ_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$JQ_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_agy_harness() {
  local tmp
  for tmp in "${AGY_RUNTIME_TASK_TMPS[@]:-}"; do
    [ -n "$tmp" ] && rm -rf "$tmp"
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup_agy_harness EXIT

# --- detection --------------------------------------------------------------

# The ancestry cases need a real process whose name the walk can find, so they
# execute bash through a renamed SYMLINK: both macOS and Linux derive the
# process comm from the exec path's last component, and unlike the copied-bash
# fleet pattern a symlink keeps the real binary in place, so macOS launch
# constraints (which SIGKILL a relocated /bin/bash) are satisfied. With no
# runnable symlinked bash, the ancestry cases skip loudly rather than passing
# vacuously. The command substitution in the probe is load-bearing: a bare
# `-c <cmd>` lets the shell exec the probe in place, REPLACING the agy-named
# process the walk is supposed to find; real agy keeps its TUI process alive
# and runs tools as children, so forcing the fork reproduces that shape.
AGY_RUNNER_SRC=$(command -v bash)
AGY_RUNNER_KIND=bash
_agy_runner_dir="$TMP_ROOT/runner-probe"
mkdir -p "$_agy_runner_dir"
ln -s "$AGY_RUNNER_SRC" "$_agy_runner_dir/probe-bash"
"$_agy_runner_dir/probe-bash" -c 'exit 0' 2>/dev/null || AGY_RUNNER_KIND=

make_named_runner() {  # <dir> <name>
  ln -sf "$AGY_RUNNER_SRC" "$1/$2"
}

probe_harness_under() {  # <renamed-binary>
  "$1" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\""
}

test_env_marker_detects_agy() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
    ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT=1 detected '$out', expected agy"
  pass "agy is detected through its verified ANTIGRAVITY_AGENT child marker"
}

test_foreign_markers_outrank_agy_ancestry() {
  # The documented precedence hazard: a retained foreign marker wins over
  # ancestry, which is why the agy launch template clears them.
  local dir out
  if [ -z "$AGY_RUNNER_KIND" ]; then
    echo "skip: no copyable interpreter for process-ancestry cases"
    return 0
  fi
  dir="$TMP_ROOT/marker-precedence"
  mkdir -p "$dir"
  make_named_runner "$dir" agy
  out=$( (unset ANTIGRAVITY_AGENT PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS
    export CLAUDECODE=1
    probe_harness_under "$dir/agy") )
  [ "$out" = claude ] || fail "retained CLAUDECODE under an agy process detected '$out', expected claude (the precedence hazard the launch template clears)"
  pass "a retained foreign marker outranks agy ancestry, matching the documented hazard"
}

test_detects_agy_process_ancestor() {
  local dir out
  if [ -z "$AGY_RUNNER_KIND" ]; then
    echo "skip: no copyable interpreter for process-ancestry cases"
    return 0
  fi
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  make_named_runner "$dir" agy
  out=$( (unset CLAUDECODE PI_CODING_AGENT GROK_AGENT ANTIGRAVITY_AGENT FM_PI_HARNESS
    probe_harness_under "$dir/agy") )
  [ "$out" = agy ] || fail "fm-harness.sh under process 'agy' reported '$out', expected agy"
  pass "agy is detected through an exact agy process ancestor"
}

test_detection_is_anchored() {
  local dir bin out
  if [ -z "$AGY_RUNNER_KIND" ]; then
    echo "skip: no copyable interpreter for process-ancestry cases"
    return 0
  fi
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in magy agy-nightly xagy agyx antigravity; do
    make_named_runner "$dir" "$bin"
    out=$( (unset CLAUDECODE PI_CODING_AGENT GROK_AGENT ANTIGRAVITY_AGENT FM_PI_HARNESS
      probe_harness_under "$dir/$bin") )
    [ "$out" != agy ] || fail "fm-harness.sh misdetected unrelated process '$bin' as agy"
  done
  pass "agy detection does not claim unrelated agy-containing commands"
}

test_tmux_liveness_classifier_is_anchored() {
  local name
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_backend_tmux_classify_process_name agy)" = agent ] \
    || fail "tmux liveness did not classify 'agy' as an agent"
  for name in magy agy-nightly xagy; do
    [ "$(fm_backend_tmux_classify_process_name "$name")" = other ] \
      || fail "tmux liveness misclassified '$name' as an agent"
  done
  pass "tmux agent liveness classifies exactly 'agy' as an agent"
}

# --- control-plane tables ---------------------------------------------------

test_control_tables_for_agy() {
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_harness_supported agy || fail "agy is not control-plane supported"
  [ "$(fm_control_harness_family agy)" = agy ] || fail "agy family mismatch"
  fm_control_harness_family agy-nightly >/dev/null 2>&1 \
    && fail "agy family claimed an unrelated agy-prefixed value"
  fm_control_harness_supports_kind agy ship || fail "agy should support ship"
  fm_control_harness_supports_kind agy scout || fail "agy should support scout"
  fm_control_harness_supports_kind agy secondmate \
    && fail "agy must not support secondmate"
  [ "$(fm_control_interrupt_key agy)" = Escape ] || fail "agy interrupt key mismatch"
  [ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "agy interrupt repeat mismatch"
  [ -z "$(fm_control_interrupt_clear_key agy)" ] || fail "agy needs no composer clear after interrupt"
  [ "$(fm_control_interrupt_ack_source agy)" = none ] || fail "agy interrupt ack source mismatch"
  [ "$(fm_control_exit_command agy)" = /exit ] || fail "agy exit command mismatch"
  local paths
  paths=$(fm_control_harness_wiring_paths agy /wt /state task-1)
  [ "$paths" = "/wt/.agent/hooks.json" ] \
    || fail "agy wiring paths mismatch: $paths"
  [ -z "$(fm_control_harness_turnend_token_path agy /state task-1)" ] \
    || fail "agy mints no global turn-end token"
  pass "control-plane tables carry agy's verified mechanics"
}

# --- busy-source trust ------------------------------------------------------

test_busy_sources_for_agy() {
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  local sources
  sources=$(fm_busy_sources_for_harness agy)
  [ "$sources" = "agy-hook fm-spawn fm-interrupt fm-recovery" ] \
    || fail "agy trusted sources mismatch: $sources"
  fm_busy_source_trusted agy agy-hook || fail "agy-hook not trusted for agy"
  fm_busy_source_trusted agy claude-hook \
    && fail "claude-hook must not classify an agy task"
  fm_busy_source_trusted claude agy-hook \
    && fail "agy-hook must not classify a claude task"
  pass "busy-source trust scopes agy-hook to agy tasks only"
}

test_busy_record_roundtrip_for_agy() {
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  local state="$TMP_ROOT/busy-state" id=agy-busy-x1 gen out
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id") || fail "arm failed"
  out=$(fm_busy_classify tmux fm:1 agy "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seeded record classified '$out', expected 'busy fm-spawn'"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy \
    --gen "$gen" --source agy-hook --event pre-invocation || fail "busy apply refused"
  out=$(fm_busy_classify tmux fm:1 agy "$id" "$state")
  [ "$out" = "busy agy-hook" ] || fail "pre-invocation classified '$out', expected 'busy agy-hook'"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle \
    --gen "$gen" --source agy-hook --event stop || fail "idle apply refused"
  out=$(fm_busy_classify tmux fm:1 agy "$id" "$state")
  [ "$out" = "idle agy-hook" ] || fail "stop classified '$out', expected 'idle agy-hook'"
  # A stale-generation event must be refused, never regress the record.
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy \
    --gen not-the-gen --source agy-hook --event pre-invocation 2>/dev/null \
    && fail "stale-gen event was accepted"
  out=$(fm_busy_classify tmux fm:1 agy "$id" "$state")
  [ "$out" = "idle agy-hook" ] || fail "stale-gen event changed the record to '$out'"
  pass "agy busy events round-trip through the shared record with gen safety"
}

test_busy_unwired_agy_task_is_unknown() {
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  local state="$TMP_ROOT/busy-missing" out
  mkdir -p "$state"
  out=$(fm_busy_classify tmux fm:1 agy agy-none-x1 "$state")
  [ "$out" = "unknown missing" ] || fail "unwired agy task classified '$out', expected 'unknown missing'"
  pass "an unwired agy task classifies unknown, never idle"
}

# --- spawn ------------------------------------------------------------------

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
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" agy
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for agy\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  AGY_RUNTIME_TASK_TMPS+=("/tmp/fm-$id")
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness agy "$@" 2>&1
}

test_agy_launch_shape_and_hook_wiring() {
  local id rec out rc launch settings hooks gen meta
  id="agy-success-z1-$$"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --mode no-mistakes --yolo off --model gemini-3.6-flash --effort high)
  rc=$?
  expect_code 0 "$rc" "verified agy spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS" \
    "agy launch did not clear foreign harness markers"
  assert_contains "$launch" "'$FAKEBIN_DIR/agy' --dangerously-skip-permissions" \
    "agy launch did not use the absolute binary with the verified autonomy flag"
  assert_contains "$launch" "--model 'gemini-3.6-flash' --effort 'high' -i " \
    "agy launch did not carry model, effort, and the -i prompt shape"
  assert_contains "$launch" "encode launch-brief" "agy brief does not ride the launch command"

  settings="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  assert_present "$settings" "agy pre-trust did not create settings.json"
  jq -e --arg wt "$WT_DIR" '(.trustedWorkspaces // []) | index($wt) != null' \
    "$settings" >/dev/null || fail "worktree path missing from trustedWorkspaces"

  hooks="$WT_DIR/.agent/hooks.json"
  assert_present "$hooks" "agy spawn did not write the per-task hook file"
  jq -e . "$hooks" >/dev/null || fail "agy hook file is not valid JSON"
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_grep "gen '$gen' --source agy-hook --event pre-invocation" "$hooks" \
    "hook file lost the gen-bound PreInvocation busy event"
  assert_grep "gen '$gen' --source agy-hook --event stop" "$hooks" \
    "hook file lost the gen-bound Stop idle event"
  assert_grep "$id.turn-ended" "$hooks" "hook file lost the turn-ended touch"
  jq -e '."fm-busy-state" | has("PreInvocation") and has("Stop") and (has("PreToolUse") | not)' \
    "$hooks" >/dev/null || fail "hook file must register exactly the flat no-decision events (a PreToolUse without a decision would deny tool calls)"
  local cmd
  for cmd in "$(jq -r '."fm-busy-state".PreInvocation[0].command' "$hooks")" \
             "$(jq -r '."fm-busy-state".Stop[0].command' "$hooks")"; do
    case "$cmd" in
      *"printf '{}'") : ;;
      *) fail "hook command does not end with a JSON object on stdout: $cmd" ;;
    esac
  done
  assert_grep '.agent/hooks.json' "$(git -C "$WT_DIR" rev-parse --git-path info/exclude)" \
    "hook file was not git-excluded"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=gemini-3.6-flash' "$meta" "agy meta lost the requested model"
  assert_grep 'effort=high' "$meta" "agy meta lost the requested effort"
  assert_grep "busy_gen=$gen" "$meta" "agy meta lost the busy generation"
  assert_grep 'state=busy source=fm-spawn' "$HOME_DIR/state/$id.busy-state" \
    "agy spawn did not seed the launch-brief busy record"
  pass "fm-spawn: agy launches with verified flags, pre-trust, and gen-bound hook wiring"
}

test_agy_effort_ceiling_is_high() {
  local id rec out rc launch meta
  id="agy-effort-z2-$$"
  rec=$(make_spawn_case effort-ceiling "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --mode no-mistakes --yolo off --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "agy spawn with xhigh effort should still launch: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--effort" \
    "agy launch passed an effort above the verified low|medium|high ceiling"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "agy meta did not retain the requested effort axis"
  pass "fm-spawn: agy omits effort values above high instead of passing a launch-fatal flag"
}

test_agy_pretrust_preserves_existing_settings() {
  local id rec out rc settings
  id="agy-pretrust-z3-$$"
  rec=$(make_spawn_case pretrust-merge "$id")
  read_spawn_record "$rec"
  settings="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  mkdir -p "$(dirname "$settings")"
  printf '{"trustedWorkspaces":["/existing/workspace"],"userSettings":{"keep":"me"}}\n' > "$settings"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --mode no-mistakes --yolo off)
  rc=$?
  expect_code 0 "$rc" "agy spawn with existing settings should succeed: $out"
  jq -e --arg wt "$WT_DIR" '
    ((.trustedWorkspaces // []) | index($wt) != null)
    and ((.trustedWorkspaces // []) | index("/existing/workspace") != null)
    and (.userSettings.keep == "me")' "$settings" >/dev/null \
    || fail "pre-trust did not preserve foreign settings content: $(cat "$settings")"
  pass "fm-spawn: agy pre-trust appends surgically and preserves foreign settings"
}

test_agy_pretrust_refuses_malformed_settings() {
  local id rec out rc settings
  id="agy-malformed-z4-$$"
  rec=$(make_spawn_case pretrust-malformed "$id")
  read_spawn_record "$rec"
  settings="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  mkdir -p "$(dirname "$settings")"
  printf 'not json {' > "$settings"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --mode no-mistakes --yolo off)
  rc=$?
  [ "$rc" -ne 0 ] || fail "agy spawn should refuse on malformed settings.json"
  assert_contains "$out" "not valid JSON" "refusal did not name the malformed settings"
  [ "$(cat "$settings")" = 'not json {' ] || fail "refusal modified the malformed settings file"
  assert_absent "$HOME_DIR/state/$id.busy-gen" \
    "a refused agy spawn left an armed busy generation with no writer"
  assert_absent "$WT_DIR/.agent/hooks.json" "a refused agy spawn left hook wiring behind"
  pass "fm-spawn: agy refuses on malformed settings and arms nothing"
}

test_agy_refuses_tracked_hook_path() {
  local id rec out rc
  id="agy-tracked-z5-$$"
  rec=$(make_spawn_case tracked-hooks "$id")
  read_spawn_record "$rec"
  mkdir -p "$PROJ_DIR/.agent"
  printf '{"project-owned":{}}\n' > "$PROJ_DIR/.agent/hooks.json"
  git -C "$PROJ_DIR" add .agent/hooks.json
  git -C "$PROJ_DIR" -c user.email=t@t -c user.name=t commit -qm 'project hooks'
  # Land the tracked file on the bare origin so the spawn's worktree freshen
  # materializes it exactly as a real project clone would.
  git -C "$PROJ_DIR" push -q origin HEAD
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --mode no-mistakes --yolo off)
  rc=$?
  [ "$rc" -ne 0 ] || fail "agy spawn should refuse when the project tracks .agent/hooks.json"
  assert_contains "$out" "tracks .agent/hooks.json" "refusal did not name the tracked hook path"
  [ "$(cat "$WT_DIR/.agent/hooks.json")" = '{"project-owned":{}}' ] \
    || fail "refusal overwrote the project's tracked hook file"
  pass "fm-spawn: agy refuses rather than overwrite a project-tracked .agent/hooks.json"
}

test_agy_secondmate_is_refused() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="agy-secondmate-z6"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" agy --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "agy was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" \
    "agy secondmate refusal did not explain the boundary"
  pass "fm-spawn: agy refuses --secondmate loudly"
}

test_env_marker_detects_agy
test_foreign_markers_outrank_agy_ancestry
test_detects_agy_process_ancestor
test_detection_is_anchored
test_tmux_liveness_classifier_is_anchored
test_control_tables_for_agy
test_busy_sources_for_agy
test_busy_record_roundtrip_for_agy
test_busy_unwired_agy_task_is_unknown
test_agy_launch_shape_and_hook_wiring
test_agy_effort_ceiling_is_high
test_agy_pretrust_preserves_existing_settings
test_agy_pretrust_refuses_malformed_settings
test_agy_refuses_tracked_hook_path
test_agy_secondmate_is_refused
