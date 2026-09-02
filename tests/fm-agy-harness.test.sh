#!/usr/bin/env bash
# Behavior tests for the agy (Antigravity CLI) crewmate/scout adapter: harness
# detection, launch shape, the fullyIdle turn-end rule, busy-signature
# registration, the lifecycle tables, and teardown cleanup.
#
# The turn-end cases are the reason this suite exists. agy pushes a long command
# into the background after about ten seconds, ENDS THE TURN saying it will
# wait, then wakes itself and ends a second turn once the work lands. Only the
# second carries fullyIdle=true. The payload fixtures below are the real
# captured Stop payloads from that measurement (docs/verification/agy.md),
# including the one that arrived with workspacePaths ALREADY POPULATED while the
# command was still running. Without that exact case a hook keyed on the
# workspace alone would pass every other assertion here and still report a
# validation run finished 81 seconds early.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

# agy publishes its own marker, and bin/fm-harness.sh checks markers before
# ancestry. Drop every foreign marker so an ancestry assertion cannot be
# satisfied by whichever harness happens to be running this suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS ANTIGRAVITY_AGENT

# --- captured Stop payloads -------------------------------------------------

# The turn that ended while ./slow.sh was STILL RUNNING in the background.
# workspacePaths is populated; only fullyIdle separates it from a real turn end.
AGY_STOP_WAITING='{"artifactDirectoryPath":"/brain/0839a3af","conversationId":"0839a3af","error":"","executionNum":0,"fullyIdle":false,"modelName":"gemini-3.7-flash-high","terminationReason":"NO_TOOL_CALL","transcriptPath":"/brain/0839a3af/logs/transcript_full.jsonl","workspacePaths":["__WS__"]}'
# The genuine turn end, 81 seconds later in the same conversation.
AGY_STOP_DONE='{"artifactDirectoryPath":"/brain/0839a3af","conversationId":"0839a3af","error":"","executionNum":0,"fullyIdle":true,"modelName":"gemini-3.7-flash-high","terminationReason":"NO_TOOL_CALL","transcriptPath":"/brain/0839a3af/logs/transcript_full.jsonl","workspacePaths":["__WS__"]}'
# The Stop that fires while agy is blocked on its workspace-trust dialog: no
# workspace at all, so a workspace-keyed hook is inert here for a second reason.
AGY_STOP_TRUST='{"conversationId":"0839a3af","error":"","executionNum":0,"fullyIdle":false,"modelName":"gemini-3.7-flash-high","terminationReason":"NO_TOOL_CALL","workspacePaths":[]}'
# protojson omits default values, so a false fullyIdle can arrive as an ABSENT
# key rather than an explicit false. Both must be treated as "not a turn end".
AGY_STOP_ABSENT='{"conversationId":"0839a3af","error":"","executionNum":0,"terminationReason":"NO_TOOL_CALL","workspacePaths":["__WS__"]}'

agy_payload() {  # <template> <workspace>
  printf '%s' "${1//__WS__/$2}"
}

# --- spawn scaffolding ------------------------------------------------------

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin agy_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  agy_home="$case_dir/agyconfig"
  id="agy-$name-x1"
  mkdir -p "$agy_home"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$agy_home|$id"
}

run_agy_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 agy_home=$5 id=$6
  shift 6
  FM_AGY_CONFIG_HOME="$agy_home" FM_FAKE_LAUNCH_LOG="${FM_FAKE_LAUNCH_LOG:-}" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" agy "$@"
}

# --- detection --------------------------------------------------------------

# agy sets ANTIGRAVITY_AGENT=1 on its child/tool processes. The marker must also
# OUTRANK an inherited CLAUDECODE, because agy is not known to clear one and an
# agy crewmate launched from a claude primary can carry both.
test_marker_detection_and_precedence() {
  local out
  out=$(ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT=1 reported '$out', expected agy"
  out=$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = agy ] || fail "agy marker lost to an inherited CLAUDECODE, reported '$out'"
  out=$(CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "the agy marker arm changed claude detection, reported '$out'"
  pass "agy is detected by its marker, ahead of an inherited claude marker"
}

# Ancestry is what guarantees identity when the marker is absent, so it is
# exercised through a REAL running process rather than a string.
test_ancestry_detection() {
  local dir out
  dir="$TMP_ROOT/detect"
  fm_test_named_interpreter "$dir" agy >/dev/null \
    || fail "no construction on this host yields a running process named 'agy'"
  out=$("$dir/agy" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = agy ] || fail "fm-harness.sh under process 'agy' reported '$out', expected agy"
  pass "agy is detected through its process ancestry"
}

# The match must be ANCHORED. `agy` is a substring of ordinary words, so a glob
# would claim a stranger's pane as a live agent. Every name below genuinely
# CONTAINS the substring - a negative case that does not would pass against a
# glob too and prove nothing.
test_ancestry_is_anchored() {
  local dir bin out
  dir="$TMP_ROOT/detect-neg"
  for bin in magyar stagy voyagy agylike notagy agy-bin; do
    fm_test_named_interpreter "$dir" "$bin" >/dev/null \
      || fail "no construction on this host yields a running process named '$bin'"
    out=$("$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != agy ] || fail "fm-harness.sh misdetected unrelated process '$bin' as agy"
  done
  pass "agy detection does not claim unrelated agy-containing commands"
}

# The same anchoring must hold in the tmux liveness classifier, which is a
# SEPARATE table from harness detection and is consulted for crewmates too.
test_tmux_process_classification() {
  local out
  # Load the tmux backend the way bin/fm-backend.sh does, so the classifier is
  # exercised through its real dependency set rather than a hand-built one.
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "the tmux backend adapter could not be loaded"
  out=$(fm_backend_tmux_classify_process_name /Users/x/.local/bin/agy)
  [ "$out" = agent ] || fail "tmux classifier reported '$out' for agy, expected agent"
  # magyar genuinely contains the substring `agy`, so this negative fails
  # against a *agy* glob and actually pins the anchoring.
  out=$(fm_backend_tmux_classify_process_name /usr/bin/magyar)
  [ "$out" != agent ] || fail "tmux classifier misclassified 'magyar' as an agent"
  pass "the tmux classifier recognizes agy and stays anchored"
}

# --- launch shape -----------------------------------------------------------

# agy REJECTS a positional prompt ("Error: unexpected argument") and reads one
# only from -p/--print, -i/--prompt-interactive, or stdin.
test_launch_shape() {
  local rec case_dir home proj wt fakebin agy_home id out launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin agy_home id <<EOF
$rec
EOF
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$agy_home" "$id" \
    --mode no-mistakes --yolo off) || fail "agy spawn failed: $out"
  launch=$(cat "$case_dir/launch.log" 2>/dev/null || true)
  [ -n "$launch" ] || fail "no agy launch command was delivered to the pane"
  case "$launch" in
    *' -i '*) : ;;
    *) fail "agy launch did not pass the brief through -i: $launch" ;;
  esac
  case "$launch" in
    *--dangerously-skip-permissions*) : ;;
    *) fail "agy launch did not request autonomy: $launch" ;;
  esac
  # The brief must reach -i as that flag's VALUE, never as a bare positional.
  case "$launch" in
    *'-i "'*) : ;;
    *) fail "agy launch did not attach the brief to -i as its value: $launch" ;;
  esac
  pass "agy launches with -i and skip-permissions, never a positional prompt"
}

# agy 1.1.24 rejects xhigh outright ("invalid --effort \"xhigh\""), so an
# unsupported level must be OMITTED rather than passed through and refused at
# launch. A supported level must still reach the command.
test_effort_is_clamped_to_supported_levels() {
  local rec case_dir home proj wt fakebin agy_home id out launch
  rec=$(make_spawn_case effort)
  IFS='|' read -r case_dir home proj wt fakebin agy_home id <<EOF
$rec
EOF
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$agy_home" "$id" \
    --mode no-mistakes --yolo off --effort xhigh) || fail "agy spawn failed: $out"
  launch=$(cat "$case_dir/launch.log" 2>/dev/null || true)
  case "$launch" in
    *--effort*) fail "agy launch passed an effort level agy rejects: $launch" ;;
  esac

  rec=$(make_spawn_case effort-ok)
  IFS='|' read -r case_dir home proj wt fakebin agy_home id <<EOF
$rec
EOF
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$agy_home" "$id" \
    --mode no-mistakes --yolo off --effort high) || fail "agy spawn failed: $out"
  launch=$(cat "$case_dir/launch.log" 2>/dev/null || true)
  case "$launch" in
    *"--effort 'high'"*) : ;;
    *) fail "agy launch dropped a supported effort level: $launch" ;;
  esac
  pass "agy effort is clamped to the levels agy accepts"
}

# agy is a crewmate/scout adapter only; a secondmate needs a primary supervision
# protocol it does not have.
test_secondmate_is_refused() {
  local rec case_dir home proj wt fakebin agy_home id out
  rec=$(make_spawn_case secondmate)
  IFS='|' read -r case_dir home proj wt fakebin agy_home id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$agy_home" "$id" --secondmate 2>&1) \
    && fail "agy was accepted for a secondmate spawn"
  case "$out" in
    *"crewmate/scout adapter only"*) : ;;
    *) fail "agy secondmate refusal did not name the reason: $out" ;;
  esac
  pass "agy refuses a secondmate spawn and says why"
}

# --- the fullyIdle turn-end rule -------------------------------------------

# Drive the INSTALLED hook, not a copy of its logic, so the assertion covers
# what agy actually executes.
agy_fire_hook() {  # <hook> <payload> -> stdout of the hook
  local hook=$1 payload=$2
  printf '%s' "$payload" | bash "$hook"
}

test_turnend_requires_fully_idle() {
  local rec case_dir home proj wt fakebin agy_home id out hook turnend
  rec=$(make_spawn_case turnend)
  IFS='|' read -r case_dir home proj wt fakebin agy_home id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$agy_home" "$id" \
    --mode no-mistakes --yolo off) || fail "agy spawn failed: $out"
  hook="$agy_home/plugins/fm-turn-end/fm-turn-end.sh"
  turnend="$home/state/$id.turn-ended"
  assert_present "$hook" "agy turn-end hook was not installed"
  assert_present "$agy_home/plugins/fm-turn-end/hooks.json" "agy hooks.json was not installed"
  assert_present "$agy_home/plugins/fm-turn-end/plugin.json" "agy plugin.json was not installed"
  rm -f "$turnend"

  # A turn that ended while backgrounded work is still running is NOT a turn
  # end, even though its workspace resolves and its token is valid.
  agy_fire_hook "$hook" "$(agy_payload "$AGY_STOP_WAITING" "$wt")" >/dev/null
  assert_absent "$turnend" "a fullyIdle=false Stop was treated as a turn end"

  # protojson omits defaults, so an ABSENT fullyIdle must behave the same way.
  agy_fire_hook "$hook" "$(agy_payload "$AGY_STOP_ABSENT" "$wt")" >/dev/null
  assert_absent "$turnend" "a Stop with no fullyIdle key was treated as a turn end"

  # Blocked on the workspace-trust dialog: no workspace, still not a turn end.
  agy_fire_hook "$hook" "$AGY_STOP_TRUST" >/dev/null
  assert_absent "$turnend" "a workspace-less Stop was treated as a turn end"

  # Only this one counts.
  agy_fire_hook "$hook" "$(agy_payload "$AGY_STOP_DONE" "$wt")" >/dev/null
  assert_present "$turnend" "a fullyIdle=true Stop did not signal the turn end"
  pass "only a fullyIdle=true Stop counts as an agy turn end"
}

# The hook is global, so it must be a no-op for every agy session that is not a
# firstmate task - and it must never let a foreign workspace redirect the touch.
test_turnend_requires_registered_token() {
  local rec case_dir home proj wt fakebin agy_home id out hook turnend token evil evil_target
  rec=$(make_spawn_case token)
  IFS='|' read -r case_dir home proj wt fakebin agy_home id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$agy_home" "$id" \
    --mode no-mistakes --yolo off) || fail "agy spawn failed: $out"
  hook="$agy_home/plugins/fm-turn-end/fm-turn-end.sh"
  turnend="$home/state/$id.turn-ended"
  token=$(sed -n 's/^token=//p' "$wt/.fm-agy-turnend")
  [ -n "$token" ] || fail "agy pointer did not contain a token"
  assert_no_grep "$turnend" "$wt/.fm-agy-turnend" "agy pointer exposed the turn-end path"
  assert_present "$agy_home/fm-turn-end.d/$token" "agy registry entry was not written"
  rm -f "$turnend"

  # A stranger's workspace with no pointer at all.
  evil="$case_dir/evil"
  mkdir -p "$evil"
  agy_fire_hook "$hook" "$(agy_payload "$AGY_STOP_DONE" "$evil")" >/dev/null
  assert_absent "$turnend" "the hook fired for a workspace with no firstmate pointer"

  # A pointer naming a target directly instead of a registered token.
  evil_target="$case_dir/evil.turn-ended"
  printf '%s\n' "$evil_target" > "$evil/.fm-agy-turnend"
  agy_fire_hook "$hook" "$(agy_payload "$AGY_STOP_DONE" "$evil")" >/dev/null
  assert_absent "$evil_target" "the hook honoured a pointer that was not a registry token"

  # A pointer carrying an unregistered token.
  printf 'token=fm.zzzzzzzzzzzz\n' > "$evil/.fm-agy-turnend"
  agy_fire_hook "$hook" "$(agy_payload "$AGY_STOP_DONE" "$evil")" >/dev/null
  assert_absent "$turnend" "the hook honoured an unregistered token"

  # The real pointer still works, so the negatives above are not vacuous.
  agy_fire_hook "$hook" "$(agy_payload "$AGY_STOP_DONE" "$wt")" >/dev/null
  assert_present "$turnend" "the registered token did not signal the turn end"
  pass "the agy global hook requires a firstmate registry token"
}

# agy reads the hook's verdict from stdout and only the literal decision
# "continue" blocks the stop, so the hook must never emit that word - a hook
# that accidentally blocked the stop would wedge every agy session on the host.
test_turnend_never_blocks_the_stop() {
  local rec case_dir home proj wt fakebin agy_home id out hook stdout payload
  rec=$(make_spawn_case verdict)
  IFS='|' read -r case_dir home proj wt fakebin agy_home id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$agy_home" "$id" \
    --mode no-mistakes --yolo off) || fail "agy spawn failed: $out"
  hook="$agy_home/plugins/fm-turn-end/fm-turn-end.sh"
  for payload in "$(agy_payload "$AGY_STOP_DONE" "$wt")" \
                 "$(agy_payload "$AGY_STOP_WAITING" "$wt")" \
                 "$AGY_STOP_TRUST" \
                 'not json at all' \
                 ''; do
    stdout=$(agy_fire_hook "$hook" "$payload") \
      || fail "the agy hook exited nonzero on a payload it must tolerate"
    case "$stdout" in
      *continue*) fail "the agy hook told agy to continue, which would wedge the session" ;;
    esac
    [ -n "$stdout" ] || fail "the agy hook produced no stdout for agy to parse"
  done
  pass "the agy hook always lets the stop proceed, on every payload shape"
}

test_teardown_retires_the_hook_wiring() {
  local rec case_dir home proj wt fakebin agy_home id out token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin agy_home id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$agy_home" "$id" \
    --mode no-mistakes --yolo off) || fail "agy spawn failed: $out"
  token=$(sed -n 's/^token=//p' "$wt/.fm-agy-turnend")
  out=$(FM_AGY_CONFIG_HOME="$agy_home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1) || fail "agy teardown failed: $out"
  assert_absent "$agy_home/fm-turn-end.d/$token" "agy registry token survived teardown"
  assert_absent "$home/state/$id.agy-turnend-token" "agy state token survived teardown"
  pass "teardown retires the agy per-task turn-end wiring"
}

# --- busy signature and worker state ---------------------------------------

test_busy_signature_is_registered_and_distinct() {
  local h
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  printf '%s\0' 'esc to cancel   accept-edits · Gemini 3.7 Flash · high' \
    | fm_busy_lines_match agy || fail "agy's busy footer was not recognized"
  printf '%s\0' '? for shortcuts   accept-edits · Gemini 3.7 Flash · high' \
    | fm_busy_lines_match agy && fail "agy's idle footer was classified busy"
  # No other adapter may claim agy's footer, and agy may claim no other's. This
  # is what keeps one adapter's signature from silently classifying another.
  for h in claude codex opencode pi pi-signed grok kimi cursor; do
    printf '%s\0' 'esc to cancel' | fm_busy_lines_match "$h" \
      && fail "harness '$h' claimed agy's busy footer"
  done
  printf '%s\0' 'Ctrl+c:cancel' | fm_busy_lines_match agy && fail "agy claimed grok's busy footer"
  printf '%s\0' 'esc to interrupt' | fm_busy_lines_match agy && fail "agy claimed claude's busy footer"
  printf '%s\0' 'ctrl+c to stop' | fm_busy_lines_match agy && fail "agy claimed cursor's busy footer"
  pass "agy's busy signature is registered and collides with no other adapter"
}

# agy's rendered footer reads IDLE for the whole time it waits on backgrounded
# work, so it can never be a worker-state source. The recorded verdict must be
# unknown with an explicit reason - never idle, which would report a working
# agent as finished.
test_worker_state_is_unknown_never_idle() {
  local state verdict sources
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  state="$TMP_ROOT/busy-state"
  mkdir -p "$state"
  verdict=$(fm_busy_classify tmux fake-target agy agy-task "$state" '? for shortcuts')
  [ "$verdict" = "unknown agy-unverified" ] \
    || fail "an agy task with no record classified '$verdict', expected 'unknown agy-unverified'"
  # Even with agy's own busy footer on screen the recorded verdict stays
  # unknown: the footer is a delivery signal, not worker state.
  verdict=$(fm_busy_classify tmux fake-target agy agy-task "$state" 'esc to cancel')
  [ "${verdict%% *}" != idle ] || fail "an agy task was classified idle from rendered text"
  [ "$verdict" = "unknown agy-unverified" ] \
    || fail "agy classified '$verdict' from a rendered footer, expected 'unknown agy-unverified'"
  # And no busy-record source is trusted for agy, so nothing can seed a busy
  # record that its fullyIdle-gated hook could never settle.
  sources=$(fm_busy_sources_for_harness agy)
  case "$sources" in
    *agy*) fail "agy trusts a busy-record source it has no writer to clear: $sources" ;;
  esac
  pass "agy worker state is unknown with a reason, never idle"
}

# --- lifecycle tables -------------------------------------------------------

test_lifecycle_values() {
  local out
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_harness_supported agy || fail "agy is not a supported control-plane harness"
  out=$(fm_control_harness_family agy-1.1.24) || fail "a recorded agy harness had no family"
  [ "$out" = agy ] || fail "agy family resolved to '$out'"
  out=$(fm_control_interrupt_key agy)
  [ "$out" = Escape ] || fail "agy interrupt key is '$out', expected Escape"
  out=$(fm_control_interrupt_repeat agy)
  [ "$out" = 1 ] || fail "agy interrupt repeat is '$out', expected 1"
  out=$(fm_control_interrupt_clear_key agy)
  [ -z "$out" ] || fail "agy asked for a composer clear key '$out'; its composer is empty after Escape"
  out=$(fm_control_exit_command agy)
  [ "$out" = /exit ] || fail "agy exit command is '$out', expected /exit"
  fm_control_harness_supports_kind agy crewmate || fail "agy was refused for a crewmate"
  fm_control_harness_supports_kind agy scout || fail "agy was refused for a scout"
  fm_control_harness_supports_kind agy secondmate \
    && fail "agy was accepted for a secondmate by the control plane"
  pass "agy's lifecycle table matches its verified mechanics"
}

test_wiring_paths_cover_every_artifact() {
  local out
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  out=$(fm_control_harness_wiring_paths agy /wt /state task1)
  case "$out" in
    *"/wt/.fm-agy-turnend"*) : ;;
    *) fail "agy wiring paths omitted the worktree pointer: $out" ;;
  esac
  case "$out" in
    *"/state/task1.agy-turnend-token"*) : ;;
    *) fail "agy wiring paths omitted the state token: $out" ;;
  esac
  out=$(fm_control_harness_turnend_token_path agy /state task1)
  [ "$out" = "/state/task1.agy-turnend-token" ] || fail "agy token path is '$out'"
  # A token that is not a registry name must resolve to nothing rather than to
  # an attacker-chosen path.
  out=$(FM_AGY_CONFIG_HOME=/cfg fm_control_harness_turnend_auth_path agy '../../etc/passwd')
  [ -z "$out" ] || fail "agy auth path accepted a traversing token: $out"
  out=$(FM_AGY_CONFIG_HOME=/cfg fm_control_harness_turnend_auth_path agy fm.abcdefghijkl)
  [ "$out" = "/cfg/fm-turn-end.d/fm.abcdefghijkl" ] || fail "agy auth path is '$out'"
  pass "agy's wiring and registry paths are complete and refuse a bad token"
}

test_marker_detection_and_precedence
test_ancestry_detection
test_ancestry_is_anchored
test_tmux_process_classification
test_launch_shape
test_effort_is_clamped_to_supported_levels
test_secondmate_is_refused
test_turnend_requires_fully_idle
test_turnend_requires_registered_token
test_turnend_never_blocks_the_stop
test_teardown_retires_the_hook_wiring
test_busy_signature_is_registered_and_distinct
test_worker_state_is_unknown_never_idle
test_lifecycle_values
test_wiring_paths_cover_every_artifact

echo "all fm-agy-harness tests passed"
