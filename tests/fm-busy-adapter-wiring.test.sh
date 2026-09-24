#!/usr/bin/env bash
# Behavior tests for the per-adapter semantic busy-state wiring that
# bin/fm-spawn.sh installs under the contract owned by bin/fm-busy-lib.sh.
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated
# git worktree, then drive the generated adapter artifact (the Pi extension,
# the OpenCode plugin) in a plain Node host, so the artifact, the real
# bin/fm-busy-event.sh writer, and the real classifier are exercised together
# with no live harness session.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi opencode claude codex gemini)
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

# drive_pi_ext <ext-path> <mode>: load the generated Pi extension in a plain
# Node host and fire one lifecycle handler. Modes: agent-start, settle-idle,
# settle-continuing, turn-end.
drive_pi_ext() {
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; }, events: { on: (name, fn) => { handlers[name] = fn; } } });
const ctx = { isIdle: () => process.env.MODE !== "settle-continuing" };
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({}, ctx); break;
  case "settle-idle": await handlers["agent_settled"]({}, ctx); break;
  case "settle-continuing": await handlers["agent_settled"]({}, ctx); break;
  case "settle-then-start":
    await handlers["agent_settled"]({}, ctx);
    await handlers["agent_start"]({}, ctx);
    break;
  case "turn-end": await handlers["turn_end"]({}, ctx); break;
  case "progress": await handlers["codex-native:progress"]({ type: "commandExecution", phase: "completed" }); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (["turn-end", "progress"].includes(process.env.MODE)) {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_pi_extension_semantic_lifecycle() {
  local rec id=busy-pi-1 out state ext
  rec=$(make_spawn_case pi-lifecycle pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"

  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_pi_ext "$ext" progress) || fail "native progress drive failed: $out"
  [ -f "$state/$id.progress" ] || fail "native progress did not write its separate marker"
  [ ! -e "$state/$id.turn-ended" ] || fail "native progress fabricated a completed turn"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "native progress changed semantic state: $out"
  out=$(drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "agent_settled drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "agent_settled with isIdle must classify 'idle pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "agent_start must classify 'busy pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" settle-continuing) || fail "continuing settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a settle while another run continues must stay busy, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "final settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "the final settle must classify idle, got '$out'"
  pass "pi extension reports agent_start busy, settles idle only via ctx.isIdle(), and keeps turn_end a notification"
}

test_pi_extension_serializes_settle_before_next_start() {
  local rec id=busy-pi-order out state ext
  rec=$(make_spawn_case pi-order pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  out=$(drive_pi_ext "$ext" settle-then-start) || fail "settle/start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a fresh agent_start after agent_settled must win, got '$out'"
  pass "pi extension awaits agent_settled before the next agent_start without a test delay"
}

test_pi_extension_stale_incarnation_rejected() {
  local rec id=busy-pi-2 out state ext
  rec=$(make_spawn_case pi-stale pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  # A re-arm (a rewired incarnation) supersedes the gen embedded in the old
  # extension file: its late events must be rejected and never change state.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_pi_ext "$ext" settle-idle) || fail "stale settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  out=$(drive_pi_ext "$ext" progress) || fail "stale progress drive failed: $out"
  [ ! -e "$state/$id.progress" ] || fail "stale native progress refreshed the new incarnation"
  pass "pi extension events from a superseded incarnation are rejected as stale"
}

# drive_oc_plugin <plugin-path> <events-json-lines...>: load the generated
# OpenCode plugin in a plain Node host and feed it one event per argument, in
# order, through the same hooks.event entry OpenCode calls.
drive_oc_plugin() {
  local plugin=$1
  shift
  PLUGIN_PATH="$plugin" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmBusyState({});
for (const arg of process.argv.slice(2)) {
  await hooks.event({ event: JSON.parse(arg) });
}
EOF
}

oc_status() {  # <sessionID> <type>
  printf '{"type":"session.status","properties":{"sessionID":"%s","status":{"type":"%s"}}}' "$1" "$2"
}

oc_idle() {  # <sessionID>
  printf '{"type":"session.idle","properties":{"sessionID":"%s"}}' "$1"
}

test_opencode_plugin_semantic_lifecycle() {
  local rec id=busy-oc-1 out state plugin
  rec=$(make_spawn_case oc-lifecycle opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode spawn did not write the busy-state plugin"

  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)") || fail "busy drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "session busy must classify 'busy opencode-plugin', got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_status ses_child busy)" \
    "$(oc_status ses_child idle)") || fail "child-session drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "a child session's idle must not clear the worker, got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main retry)" \
    "$(oc_status ses_main idle)") || fail "retry/idle drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "the latched session's idle must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_idle ses_main)") || fail "session.idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "session.idle no longer touches the notification marker"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "session.idle for the latched session must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses2 busy)" \
    "$(oc_idle ses_other)") || fail "other-session idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "the marker touch must stay a notification for every session.idle"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "another session's idle must not clear the latched busy, got '$out'"
  pass "opencode plugin classifies from session.status, scoped to the latched worker session"
}

run_claude_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_claude_hooks_semantic_lifecycle() {
  local rec id=busy-cl-1 out state settings
  rec=$(make_spawn_case claude-lifecycle claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "claude hook settings are not valid JSON"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "claude hook settings lack $ev"
  done

  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  run_claude_hook "$settings" Stop || fail "Stop hook command failed"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "Stop must classify 'idle claude-hook', got '$out'"

  run_claude_hook "$settings" UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "UserPromptSubmit must classify 'busy claude-hook', got '$out'"

  run_claude_hook "$settings" StopFailure || fail "StopFailure hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "StopFailure must classify idle so an API error cannot strand busy, got '$out'"

  run_claude_hook "$settings" UserPromptSubmit
  run_claude_hook "$settings" SessionEnd || fail "SessionEnd hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  pass "claude hooks open on UserPromptSubmit and close on Stop, StopFailure, and SessionEnd"
}

test_claude_hooks_stale_incarnation_harmless() {
  local rec id=busy-cl-2 out state settings
  rec=$(make_spawn_case claude-stale claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_claude_hook "$settings" UserPromptSubmit \
    || fail "a stale-gen hook must still exit 0 so Claude's lifecycle is never broken"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "claude hook events from a superseded incarnation are rejected without breaking the hook"
}

test_codex_unverified_until_a_semantic_source_exists() {
  local rec id=busy-cx-1 out state
  rec=$(make_spawn_case codex-unverified codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "codex spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "codex must not arm a busy contract with no verified semantic source"
  assert_absent "$WT_DIR/.codex/hooks.json" "codex must not install unverified busy hooks"
  assert_contains "$out" 'spawned '"$id"' harness=codex' "codex spawn did not complete normally"
  out=$(classify codex "$id" "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must classify 'unknown codex-unverified', got '$out'"
  out=$(fm_busy_classify tmux fake:w codex "$id" "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "unknown codex-unverified" ] || fail "codex must not fall back to footer text, got '$out'"
  pass "codex classifies unknown until a semantic source is verified, never idle or footer-matched"
}

# Gemini's hooks are PROJECT hooks in the worktree's own .gemini/settings.json,
# and gemini's hook contract requires each command to print a JSON object on
# stdout and nothing else, so these drive the real command and check both the
# classification and that stdout stays parseable JSON.
run_gemini_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_gemini_hooks_semantic_lifecycle() {
  local rec id=busy-gm-1 out state settings
  rec=$(make_spawn_case gemini-lifecycle gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$state/$id.gemini-settings.json"
  assert_present "$settings" "gemini spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "gemini hook settings are not valid JSON"
  for ev in BeforeAgent AfterAgent SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "gemini hook settings lack $ev"
  done
  # The worktree's own .gemini/settings.json is the PROJECT's committed file;
  # firstmate must never write it, or a project's configuration is clobbered.
  assert_absent "$WT_DIR/.gemini/settings.json" \
    "gemini spawn must not write the project's own .gemini/settings.json"

  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(run_gemini_hook "$settings" AfterAgent) || fail "AfterAgent hook command failed"
  printf '%s' "$out" | jq -e . >/dev/null \
    || fail "AfterAgent must print only a JSON object on stdout, got '$out'"
  [ -f "$state/$id.turn-ended" ] || fail "AfterAgent no longer touches the notification marker"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "AfterAgent must classify 'idle gemini-hook', got '$out'"

  out=$(run_gemini_hook "$settings" BeforeAgent) || fail "BeforeAgent hook command failed"
  printf '%s' "$out" | jq -e . >/dev/null \
    || fail "BeforeAgent must print only a JSON object on stdout, got '$out'"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy gemini-hook" ] || fail "BeforeAgent must classify 'busy gemini-hook', got '$out'"

  # SessionEnd fires TWICE for one /quit on gemini-cli 0.58.0, so the second
  # delivery must be a harmless no-op rather than a state change or a failure.
  run_gemini_hook "$settings" SessionEnd >/dev/null || fail "SessionEnd hook command failed"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  run_gemini_hook "$settings" SessionEnd >/dev/null || fail "a repeated SessionEnd must still exit 0"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "a repeated SessionEnd must stay idle, got '$out'"
  pass "gemini hooks open on BeforeAgent and close on AfterAgent and a repeated SessionEnd"
}

test_gemini_hooks_stale_incarnation_harmless() {
  local rec id=busy-gm-2 out state settings
  rec=$(make_spawn_case gemini-stale gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$state/$id.gemini-settings.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_gemini_hook "$settings" BeforeAgent >/dev/null \
    || fail "a stale-gen hook must still exit 0 so gemini's lifecycle is never broken"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "gemini hook events from a superseded incarnation are rejected without breaking the hook"
}

test_raw_gemini_launch_has_no_semantic_wiring() {
  local rec id=busy-gm-raw out state
  rec=$(make_spawn_case gemini-raw gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" 'gemini --debug')
  expect_code 0 $? "raw gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "raw gemini launch must not arm a busy generation"
  assert_absent "$state/$id.gemini-settings.json" "raw gemini launch must not write hook settings"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "raw gemini launch must classify unknown, got '$out'"
  pass "raw gemini launch remains unwired and classifies unknown"
}

test_gemini_is_refused_as_a_secondmate() {
  local rec id=busy-gm-3 out
  rec=$(make_spawn_case gemini-secondmate gemini "$id")
  read_case_record "$rec"
  # A secondmate spawn carries no delivery contract, so this one deliberately
  # bypasses run_spawn's ship-only --mode/--yolo arguments.
  out=$(GROK_HOME="$HOME_DIR/grok-home" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --secondmate "$id" gemini) && {
    fail "a gemini secondmate must be refused, it has no primary supervision protocol: $out"
  }
  assert_contains "$out" 'crewmate/scout adapter only' \
    "refusing a gemini secondmate must name the crewmate/scout boundary: $out"
  pass "gemini is refused as a secondmate because it has no primary supervision protocol"
}

test_kimi_and_grok_install_no_unverified_wiring() {
  local state out
  state="$TMP_ROOT/gates/state"
  mkdir -p "$state"
  [ -z "$(fm_busy_sources_for_harness kimi)" ] \
    || fail "standalone kimi must trust no semantic source until it is verified"
  [ -z "$(fm_busy_sources_for_harness grok)" ] \
    || fail "grok must trust no semantic source while its structured path is unverified"
  out=$(fm_busy_classify tmux fake:w kimi gate-k "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must classify unknown, not from its spinner, got '$out'"
  out=$(fm_busy_classify tmux fake:w grok gate-g "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok must classify through its isolated fallback, got '$out'"
  pass "kimi and grok install no unverified semantic wiring and classify through their own gates"
}

# A --secondmate launch used to skip the busy arm entirely, so a tmux-backed
# mate's active-turn gate could never see busy. These cases run the real
# spawn, drive the generated wiring, and check the stall gate against that
# record. Parent turn-ended markers stay off this path.
seed_secondmate_home() { # <home> <id> [home Stop guard]
  local home=$1 id=$2 guard=${3:-$ROOT/bin/fm-turnend-guard.sh}
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$guard" "$home/bin/fm-turnend-guard.sh"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  fm_git_init_commit "$home"
}

spawn_secondmate_harness() { # <case-dir> <id> <harness> [extra fake tools...]
  local case_dir=$1 id=$2 harness=$3 primary sm fakebin
  shift 3
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  mkdir -p "$case_dir"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" "$harness" "$@")
  fm_test_spawn_home "$primary" "$harness"
  seed_secondmate_home "$sm" "$id" "${SECONDMATE_HOME_GUARD:-}"
  : > "$case_dir/launch.log"
  FM_BACKEND=tmux FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$primary" "$sm" "$fakebin" "$id" "$sm" "$harness" --secondmate
}

secondmate_stall_watch() { # <primary> <id> <out> [seconds]
  local primary=$1 id=$2 out=$3 seconds=${4:-4} state window fakebin
  state="$primary/state"
  window=$(grep '^window=' "$state/$id.meta" | cut -d= -f2-)
  # A previous quiet checkpoint leaves a downtime marker. The next watcher
  # would exit on that recovery wake before this observation finishes.
  rm -f "$state/.watcher-down"
  fakebin="$primary/watch-fake-$id"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows)
    # The watcher asks for session:window. The liveness inventory asks for the
    # window name alone, and a full target there reads as a missing endpoint.
    format=
    prev=
    for arg in "\$@"; do
      if [ "\$prev" = -F ]; then format=\$arg; fi
      prev=\$arg
    done
    case "\$format" in
      '#{window_name}') printf '%s\n' '${window#*:}' ;;
      *) printf '%s\n' '$window' ;;
    esac
    ;;
  capture-pane) printf 'working\n' ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  PATH="$fakebin:$PATH" FM_HOME="$primary" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_BACKEND=tmux \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$seconds" \
    > "$out" 2>"$out.err" || true
}

test_secondmate_claude_spawn_arms_busy_for_the_stall_gate() {
  local case_dir id=sm-claude primary sm state settings out
  case_dir="$TMP_ROOT/sm-claude"
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  out=$(spawn_secondmate_harness "$case_dir" "$id" claude) \
    || fail "claude secondmate spawn failed: $out"
  state="$primary/state"
  settings="$sm/.claude/settings.local.json"
  assert_present "$state/$id.busy-state" "claude secondmate spawn did not arm the busy contract"
  assert_present "$settings" "claude secondmate spawn did not write hook settings"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seeded secondmate must classify busy fm-spawn, got '$out'"
  out=$(fm_busy_classify tmux "firstmate:fm-$id" claude "$id" "$state" 'working on the charter')
  [ "$out" = "busy fm-spawn" ] || fail "a non-empty tail without a record used to stay unknown; got '$out'"

  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 10 ))" \
    > "$sm/state/.wake-queue"
  secondmate_stall_watch "$primary" "$id" "$case_dir/watch-busy.out"
  grep -F 'secondmate wake-loop stalled' "$case_dir/watch-busy.out" >/dev/null \
    && fail "a secondmate inside an armed turn was escalated as a stalled wake loop: $(cat "$case_dir/watch-busy.out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a secondmate inside an armed turn published a durable stall notification"

  rm -f "$state/$id.turn-ended"
  fire_secondmate_stop "$sm" parallel || fail "secondmate Stop was blocked with nothing to supervise"
  [ ! -e "$state/$id.turn-ended" ] || fail "a secondmate Stop touched the parent's turn-ended marker"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "secondmate Stop must classify idle claude-hook, got '$out'"

  assert_present "$state/.secondmate-wake-progress-$id" \
    "the stall gate never observed the frozen queue while the mate was busy"
  # The busy checkpoint writes the progress marker on its first poll and then
  # leaves it alone. A poll that lands at the end of that window would still
  # be inside the one-second threshold when the idle checkpoint starts, so
  # wait out the threshold before asking the same frozen row to surface.
  sleep 2
  secondmate_stall_watch "$primary" "$id" "$case_dir/watch-idle.out" 8
  grep -F "check: secondmate wake-loop stalled: mate=$id row=7" "$case_dir/watch-idle.out" >/dev/null \
    || fail "the same frozen queue stayed hidden after the secondmate turn ended: $(cat "$case_dir/watch-idle.out")"
  pass "a claude secondmate spawn arms the busy contract the stall gate can see, and Stop does not wake the parent"
}

run_secondmate_stop_guard() { # <sm-home>
  printf '{"stop_hook_active":false,"session_id":"sm-guard"}' \
    | CLAUDECODE=1 FM_ROOT_OVERRIDE="$1" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
      bash "$ROOT/bin/fm-turnend-guard.sh" --claude >/dev/null 2>&1
}

run_secondmate_local_stop_hooks() { # <sm-home>
  local cmd
  jq -r '.hooks.Stop[]?.hooks[]?.command' "$1/.claude/settings.local.json" \
    | while IFS= read -r cmd; do sh -c "$cmd" </dev/null; done
}

# Claude runs the home's settings.local.json Stop hooks beside its tracked Stop
# guard, in parallel, so their order is not fixed. Fire one Stop event in the
# given order and return the guard's status.
fire_secondmate_stop() { # <sm-home> <guard-first|guard-last|parallel>
  local sm=$1 status
  case "$2" in
    guard-first)
      run_secondmate_stop_guard "$sm"; status=$?
      run_secondmate_local_stop_hooks "$sm"
      ;;
    guard-last)
      run_secondmate_local_stop_hooks "$sm"
      run_secondmate_stop_guard "$sm"; status=$?
      ;;
    parallel)
      run_secondmate_local_stop_hooks "$sm" &
      run_secondmate_stop_guard "$sm"; status=$?
      wait
      ;;
  esac
  return "$status"
}

# The mate home's tracked Stop guard can block a Stop into a continuation that
# fires no UserPromptSubmit. It is the mate's only Stop writer, so a blocked
# Stop records busy and an allowed Stop records idle for the same gen, whatever
# order Claude runs the Stop hooks in.
test_secondmate_claude_stop_guard_owns_the_stop_verdict() {
  local case_dir id=sm-claude-guard primary sm state settings out status order gen
  case_dir="$TMP_ROOT/sm-claude-guard"
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  out=$(spawn_secondmate_harness "$case_dir" "$id" claude) \
    || fail "claude secondmate spawn failed: $out"
  state="$primary/state"
  settings="$sm/.claude/settings.local.json"
  gen=$(cat "$state/$id.busy-gen")
  git -C "$sm" status --porcelain | grep -F '.fm-busy-stop' >/dev/null \
    && fail "the secondmate Stop pointer is not excluded from the home's git status"

  : > "$sm/state/child.meta"
  for order in guard-first guard-last parallel; do
    run_claude_hook "$settings" UserPromptSubmit || fail "secondmate UserPromptSubmit hook failed"
    fire_secondmate_stop "$sm" "$order"; status=$?
    expect_code 2 "$status" "the secondmate guard must block a blind Stop with a task in flight ($order)"
    out=$(classify claude "$id" "$state")
    [ "$out" = "busy claude-hook" ] \
      || fail "a blocked Stop must leave the continuation busy ($order), got '$out'"
    grep -F "gen=$gen " "$state/$id.busy-state" >/dev/null \
      || fail "a blocked Stop must write the spawn's gen ($order): $(cat "$state/$id.busy-state")"
  done
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 10 ))" \
    > "$sm/state/.wake-queue"
  secondmate_stall_watch "$primary" "$id" "$case_dir/watch-blocked.out"
  grep -F 'secondmate wake-loop stalled' "$case_dir/watch-blocked.out" >/dev/null \
    && fail "a secondmate inside a guard-forced continuation was escalated as stalled: $(cat "$case_dir/watch-blocked.out")"

  rm -f "$sm/state/child.meta"
  for order in guard-first guard-last parallel; do
    run_claude_hook "$settings" UserPromptSubmit || fail "secondmate UserPromptSubmit hook failed"
    fire_secondmate_stop "$sm" "$order"; status=$?
    expect_code 0 "$status" "the secondmate guard must allow a Stop with nothing to supervise ($order)"
    out=$(classify claude "$id" "$state")
    [ "$out" = "idle claude-hook" ] || fail "an allowed Stop must record idle ($order), got '$out'"
  done
  sleep 2
  secondmate_stall_watch "$primary" "$id" "$case_dir/watch-allowed.out" 8
  grep -F "check: secondmate wake-loop stalled: mate=$id row=7" "$case_dir/watch-allowed.out" >/dev/null \
    || fail "the frozen queue stayed hidden after an allowed Stop: $(cat "$case_dir/watch-allowed.out")"

  # An allowed Stop hands the home to the asyncRewake auto-arm. Claude 2.1.278
  # fires UserPromptSubmit for that wake (docs/verification/runtime-backends.md),
  # so the mate's own hook must reopen busy for the spawn's gen.
  run_claude_hook "$settings" UserPromptSubmit || fail "secondmate rewake UserPromptSubmit hook failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "a rewake turn after an allowed Stop must classify busy, got '$out'"
  grep -F "gen=$gen " "$state/$id.busy-state" >/dev/null \
    || fail "a rewake turn must write the spawn's gen: $(cat "$state/$id.busy-state")"
  pass "a claude secondmate's Stop guard records busy on a blocked Stop and idle on an allowed one, in any hook order, and a rewake turn reopens busy"
}

# A leased home can lag the parent. Its older Stop guard never reads
# .fm-busy-stop, so the launch keeps the ordinary Stop idle hook, or an idle
# mate would read busy until SessionEnd.
test_secondmate_claude_older_home_guard_keeps_the_stop_idle_hook() {
  local case_dir id=sm-claude-old primary sm state settings out old_guard
  case_dir="$TMP_ROOT/sm-claude-old"
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  old_guard="$case_dir/old-guard.sh"
  mkdir -p "$case_dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$old_guard"
  out=$(SECONDMATE_HOME_GUARD="$old_guard" spawn_secondmate_harness "$case_dir" "$id" claude) \
    || fail "claude secondmate spawn failed: $out"
  state="$primary/state"
  settings="$sm/.claude/settings.local.json"

  run_claude_hook "$settings" UserPromptSubmit || fail "secondmate UserPromptSubmit hook failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "UserPromptSubmit must open busy, got '$out'"
  rm -f "$state/$id.turn-ended"
  run_claude_hook "$settings" Stop || fail "secondmate Stop hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] \
    || fail "an older home guard cannot close the turn, so the Stop hook must record idle, got '$out'"
  [ ! -e "$state/$id.turn-ended" ] || fail "a secondmate Stop touched the parent's turn-ended marker"
  pass "a claude secondmate whose home guard predates .fm-busy-stop keeps the Stop idle hook"
}

test_secondmate_pi_extension_reports_busy_without_a_parent_turnend() {
  local case_dir id=sm-pi primary state ext launch out
  case_dir="$TMP_ROOT/sm-pi"
  primary="$case_dir/primary"
  out=$(spawn_secondmate_harness "$case_dir" "$id" pi) \
    || fail "pi secondmate spawn failed: $out"
  state="$primary/state"
  ext="$state/$id.pi-ext.ts"
  launch=$(cat "$case_dir/launch.log")
  assert_present "$ext" "pi secondmate spawn did not write the busy extension"
  assert_contains "$launch" "$ext" "pi secondmate launch did not load the busy extension"
  assert_contains "$launch" "fm-primary-turnend-guard.ts" "pi secondmate launch dropped its turn-end extension"
  assert_contains "$launch" "fm-primary-pi-watch.ts" "pi secondmate launch dropped its watch extension"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "pi secondmate seed must be busy fm-spawn, got '$out'"
  rm -f "$state/$id.turn-ended"
  out=$(drive_pi_ext "$ext" turn-end) || fail "pi secondmate turn_end drive failed: $out"
  [ ! -e "$state/$id.turn-ended" ] || fail "pi secondmate turn_end touched the parent's turn-ended marker"
  out=$(drive_pi_ext "$ext" settle-idle) || fail "pi secondmate settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "pi secondmate settle must classify idle pi-ext, got '$out'"
  pass "a pi secondmate loads the busy extension beside its primary extensions and does not emit a parent turn-end"
}

test_secondmate_omp_extension_reports_busy_without_a_parent_turnend() {
  local case_dir id=sm-omp primary state ext launch out
  case_dir="$TMP_ROOT/sm-omp"
  primary="$case_dir/primary"
  out=$(spawn_secondmate_harness "$case_dir" "$id" omp) \
    || fail "omp secondmate spawn failed: $out"
  state="$primary/state"
  ext="$state/$id.omp-ext.ts"
  launch=$(cat "$case_dir/launch.log")
  assert_present "$ext" "omp secondmate spawn did not write the busy extension"
  assert_contains "$launch" "$ext" "omp secondmate launch did not name the busy extension"
  assert_contains "$launch" "--cwd" "omp secondmate launch dropped its cwd pin"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "omp secondmate seed must be busy fm-spawn, got '$out'"
  rm -f "$state/$id.turn-ended"
  out=$(drive_pi_ext "$ext" turn-end) || fail "omp secondmate turn_end drive failed: $out"
  [ ! -e "$state/$id.turn-ended" ] || fail "omp secondmate turn_end touched the parent's turn-ended marker"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "omp secondmate turn_end must stay a notification, got '$out'"
  # drive_pi_ext has no agent_end mode. Fire the omp handler through node.
  EXT_PATH="$ext" node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
await handlers["agent_end"]({ willContinue: false }, {});
EOF
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "omp secondmate agent_end must classify idle omp-ext, got '$out'"
  pass "an omp secondmate names only the out-of-home busy extension and does not emit a parent turn-end"
}

test_secondmate_opencode_plugin_closes_without_a_parent_turnend() {
  local case_dir id=sm-oc primary sm state plugin out
  case_dir="$TMP_ROOT/sm-oc"
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  out=$(spawn_secondmate_harness "$case_dir" "$id" opencode) \
    || fail "opencode secondmate spawn failed: $out"
  state="$primary/state"
  plugin="$sm/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode secondmate spawn did not write the busy plugin"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "opencode secondmate seed must be busy fm-spawn, got '$out'"
  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)" "$(oc_idle ses_main)") \
    || fail "opencode secondmate idle drive failed: $out"
  [ ! -e "$state/$id.turn-ended" ] || fail "opencode secondmate session.idle touched the parent's turn-ended marker"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "opencode secondmate idle must classify idle, got '$out'"
  pass "an opencode secondmate plugin closes the parent busy record without a parent turn-end"
}

test_secondmate_codex_and_grok_do_not_arm_a_parent_turnend() {
  local case_dir id state launch out sm
  case_dir="$TMP_ROOT/sm-codex"
  id='sm-codex'
  out=$(spawn_secondmate_harness "$case_dir" "$id" codex) \
    || fail "codex secondmate spawn failed: $out"
  state="$case_dir/primary/state"
  launch=$(cat "$case_dir/launch.log")
  assert_absent "$state/$id.busy-gen" "codex secondmate must not arm a busy contract with no verified source"
  assert_not_contains "$launch" "turn-ended" "codex secondmate launch referenced a parent turn-ended signal"
  assert_not_contains "$launch" "notify=" "codex secondmate launch included the parent turn-end notify hook"
  out=$(classify codex "$id" "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex secondmate must stay unknown, got '$out'"

  case_dir="$TMP_ROOT/sm-grok"
  id='sm-grok'
  sm="$case_dir/sm"
  out=$(GROK_HOME="$case_dir/grok-home" spawn_secondmate_harness "$case_dir" "$id" grok) \
    || fail "grok secondmate spawn failed: $out"
  state="$case_dir/primary/state"
  assert_absent "$state/$id.busy-gen" "grok secondmate must keep its rendered-tail fallback instead of an armed record"
  assert_absent "$sm/.fm-grok-turnend" "grok secondmate spawn installed a parent turn-end pointer"
  assert_absent "$state/$id.grok-turnend-token" "grok secondmate spawn installed a parent turn-end token"
  out=$(fm_busy_classify tmux "firstmate:fm-$id" grok "$id" "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok secondmate must still classify from its tail, got '$out'"
  pass "codex and grok secondmates stay on their existing verdicts and do not emit a parent turn-end"
}

test_secondmate_claude_spawn_arms_busy_for_the_stall_gate
test_secondmate_claude_stop_guard_owns_the_stop_verdict
test_secondmate_claude_older_home_guard_keeps_the_stop_idle_hook
test_secondmate_pi_extension_reports_busy_without_a_parent_turnend
test_secondmate_omp_extension_reports_busy_without_a_parent_turnend
test_secondmate_opencode_plugin_closes_without_a_parent_turnend
test_secondmate_codex_and_grok_do_not_arm_a_parent_turnend
test_pi_extension_semantic_lifecycle
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_stale_incarnation_rejected
test_kimi_and_grok_install_no_unverified_wiring
test_opencode_plugin_semantic_lifecycle
test_claude_hooks_semantic_lifecycle
test_claude_hooks_stale_incarnation_harmless
test_gemini_hooks_semantic_lifecycle
test_gemini_hooks_stale_incarnation_harmless
test_raw_gemini_launch_has_no_semantic_wiring
test_gemini_is_refused_as_a_secondmate
test_codex_unverified_until_a_semantic_source_exists

echo "all fm-busy-adapter-wiring tests passed"
