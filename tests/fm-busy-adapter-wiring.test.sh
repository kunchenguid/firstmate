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

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

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
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi prime-agent opencode claude codex
  cat > "$fakebin/prime-agent" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.8.1' ;;
  --help) printf '%s\n' 'Options: --daemon-socket <path>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/prime-agent"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  set -- "$@" --mode no-mistakes --yolo off
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
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
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
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
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

drive_prime_ext() {
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { copyFileSync } from "node:fs";
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";
const rootPath = process.env.EXT_PATH + ".root.ts";
const childPath = process.env.EXT_PATH + ".child.ts";
const replacementPath = process.env.EXT_PATH + ".replacement.ts";
copyFileSync(process.env.EXT_PATH, rootPath);
copyFileSync(process.env.EXT_PATH, childPath);
copyFileSync(process.env.EXT_PATH, replacementPath);
if (process.env.MODE === "overlapping-ends") {
  const realExecFile = childProcess.execFile;
  childProcess.execFile = (file, args, callback) => {
    const eventIndex = args.indexOf("--event");
    if (eventIndex >= 0 && args[eventIndex + 1] === "agent-end-other-active") {
      setTimeout(() => realExecFile(file, args, callback), 150);
      return;
    }
    return realExecFile(file, args, callback);
  };
  syncBuiltinESMExports();
}
const rootMod = await import(pathToFileURL(rootPath).href);
const childMod = await import(pathToFileURL(childPath).href);
const replacementMod = await import(pathToFileURL(replacementPath).href);
const createHandlers = (mod) => {
  const handlers = {};
  mod.default({ on: (name, fn) => { handlers[name] = fn; } });
  return handlers;
};
const root = createHandlers(rootMod);
const child = createHandlers(childMod);
const replacement = createHandlers(replacementMod);
const normalEnd = { messages: [] };
const retryEnd = { messages: [{ role: "assistant", stopReason: "error", errorMessage: "retryable" }] };
const manager = (rlmDepth, sessionId) => ({
  getHeader: () => ({ rlmDepth }),
  getSessionId: () => sessionId,
});
const rootManager = manager(0, "root");
const childManager = manager(1, "child");
const replacementManager = manager(0, "replacement");
const reloadRootManager = manager(0, "root");
const replacementChildManager = manager(1, "child");
const unrelatedManager = manager(1, "unrelated");
const context = (sessionManager, hasPendingMessages = false, isIdle = true) => ({
  sessionManager,
  hasPendingMessages: () => hasPendingMessages,
  isIdle: () => isIdle,
});
const rootSettled = context(rootManager);
const rootPending = context(rootManager, true);
const childSettled = context(childManager);
const replacementSettled = context(replacementManager);
const replacementActive = context(reloadRootManager, false, false);
const replacementChildActive = context(replacementChildManager, false, false);
const unrelatedIdle = context(unrelatedManager);
switch (process.env.MODE) {
  case "root-settled":
    await root["agent_start"]({}, rootSettled);
    await root["agent_end"](normalEnd, rootSettled);
    break;
  case "root-pending":
    await root["agent_start"]({}, rootPending);
    await root["agent_end"](normalEnd, rootPending);
    break;
  case "root-retry":
    await root["agent_start"]({}, rootSettled);
    await root["agent_end"](retryEnd, rootSettled);
    break;
  case "root-unproven":
    await root["agent_start"]({}, rootSettled);
    await root["agent_end"](normalEnd, { sessionManager: rootManager });
    break;
  case "child-end-root-active":
    await root["agent_start"]({}, rootSettled);
    await child["agent_start"]({}, childSettled);
    await child["agent_end"](normalEnd, childSettled);
    break;
  case "root-end-child-active":
    await root["agent_start"]({}, rootSettled);
    await child["agent_start"]({}, childSettled);
    await root["agent_end"](normalEnd, rootSettled);
    break;
  case "root-end-child-compaction":
    await root["agent_start"]({}, rootSettled);
    await child["agent_start"]({}, childSettled);
    await root["agent_end"](normalEnd, rootSettled);
    await root["session_before_compact"]({}, rootSettled);
    await root["session_compact"]({}, rootSettled);
    break;
  case "all-sessions-settled":
    await root["agent_start"]({}, rootSettled);
    await child["agent_start"]({}, childSettled);
    await root["agent_end"](normalEnd, rootSettled);
    await child["agent_end"](normalEnd, childSettled);
    break;
  case "child-retry-settled":
    await root["agent_start"]({}, rootSettled);
    await child["agent_start"]({}, childSettled);
    await child["agent_end"](retryEnd, childSettled);
    await child["agent_start"]({}, childSettled);
    await child["agent_end"](normalEnd, childSettled);
    await root["agent_end"](normalEnd, rootSettled);
    break;
  case "compaction-active":
    await root["agent_start"]({}, rootSettled);
    await root["agent_end"](normalEnd, rootSettled);
    await root["session_before_compact"]({}, rootSettled);
    await new Promise((resolve) => setTimeout(resolve, 350));
    await root["session_compact"]({}, rootSettled);
    break;
  case "compaction-continuation":
    await root["agent_start"]({}, rootSettled);
    await root["agent_end"](normalEnd, rootSettled);
    await root["session_before_compact"]({}, rootSettled);
    await root["session_compact"]({}, rootSettled);
    await root["agent_start"]({}, rootSettled);
    break;
  case "session-replacement":
    await root["agent_start"]({}, rootSettled);
    await root["session_shutdown"]({ reason: "new" }, rootSettled);
    await replacement["agent_start"]({}, replacementSettled);
    await replacement["agent_end"](normalEnd, replacementSettled);
    break;
  case "active-reload-shutdown":
    await root["agent_start"]({}, rootSettled);
    await root["session_shutdown"]({ reason: "reload" }, rootSettled);
    break;
  case "active-reload":
    await root["agent_start"]({}, rootSettled);
    await root["session_shutdown"]({ reason: "reload" }, rootSettled);
    await replacement["session_start"]({}, replacementActive);
    break;
  case "reload-unrelated-session":
    await root["agent_start"]({}, rootSettled);
    await root["session_shutdown"]({ reason: "reload" }, rootSettled);
    await replacement["session_start"]({}, unrelatedIdle);
    break;
  case "inactive-shutdown-during-reload":
    await root["agent_start"]({}, rootSettled);
    await root["session_shutdown"]({ reason: "reload" }, rootSettled);
    await child["session_shutdown"]({ reason: "new" }, childSettled);
    break;
  case "concurrent-active-reloads":
    await root["agent_start"]({}, rootSettled);
    await child["agent_start"]({}, childSettled);
    await root["session_shutdown"]({ reason: "reload" }, rootSettled);
    await child["session_shutdown"]({ reason: "reload" }, childSettled);
    await replacement["session_start"]({}, replacementActive);
    await replacement["session_start"]({}, replacementChildActive);
    await replacement["agent_end"](normalEnd, replacementActive);
    break;
  case "overlapping-ends":
    await root["agent_start"]({}, rootSettled);
    await child["agent_start"]({}, childSettled);
    await Promise.all([
      root["agent_end"](normalEnd, rootSettled),
      child["agent_end"](normalEnd, childSettled),
    ]);
    break;
  case "turn-end":
    await root["turn_end"]();
    await new Promise((resolve) => setTimeout(resolve, 200));
    break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
EOF
}

test_prime_extension_semantic_lifecycle() {
  local rec id=busy-prime-1 out state ext record before_turn_end
  rec=$(make_spawn_case prime-lifecycle prime-agent "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "prime-agent spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.prime-ext.ts"
  assert_present "$ext" "prime-agent spawn did not write the per-task extension"

  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "Prime seed after spawn must be 'busy fm-spawn', got '$out'"

  out=$(drive_prime_ext "$ext" root-settled) || fail "Prime settled root lifecycle drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime inactive root without a settled event must classify unknown, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime root-settled record is unreadable"
  case "$record" in "unknown prime-ext task-quiescence-unavailable "*) : ;; *) fail "Prime clean root end did not record unavailable quiescence: $record" ;; esac

  out=$(drive_prime_ext "$ext" root-pending) || fail "Prime pending root lifecycle drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime agent_end with queued messages must classify unknown, got '$out'"

  out=$(drive_prime_ext "$ext" root-retry) || fail "Prime retry root lifecycle drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime retry-hold agent_end must classify unknown, got '$out'"

  out=$(drive_prime_ext "$ext" root-unproven) || fail "Prime unproven root lifecycle drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime agent_end without terminal context must classify unknown, got '$out'"

  out=$(drive_prime_ext "$ext" child-end-root-active) || fail "Prime child-end aggregation drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "Prime child end while root remains active must stay busy, got '$out'"

  out=$(drive_prime_ext "$ext" root-end-child-active) || fail "Prime root-end aggregation drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "Prime root end while a child remains active must stay busy, got '$out'"

  out=$(drive_prime_ext "$ext" root-end-child-compaction) || fail "Prime active-child compaction drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "Prime compaction must preserve busy while a child remains active, got '$out'"

  out=$(drive_prime_ext "$ext" all-sessions-settled) || fail "Prime all-session quiescence drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime clean root and child ends without a settled event must stay unknown, got '$out'"

  out=$(drive_prime_ext "$ext" child-retry-settled) || fail "Prime child retry lifecycle drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime settled child retry must end at unknown quiescence, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime child-retry record is unreadable"
  case "$record" in "unknown prime-ext task-quiescence-unavailable "*) : ;; *) fail "Prime child retry left sticky unproven terminality: $record" ;; esac

  out=$(drive_prime_ext "$ext" compaction-active) || fail "Prime compaction lifecycle drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime compaction without continuation must stay unknown, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime compaction record is unreadable"
  case "$record" in "unknown prime-ext task-compaction-active "*) : ;; *) fail "Prime compaction lifecycle was not recorded explicitly: $record" ;; esac

  out=$(drive_prime_ext "$ext" compaction-continuation) || fail "Prime compaction continuation drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "Prime continuation start inside the quiescence window must stay busy, got '$out'"

  out=$(drive_prime_ext "$ext" session-replacement) || fail "Prime session replacement drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime replacement must remove the abandoned active session, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime session replacement record is unreadable"
  case "$record" in "unknown prime-ext task-quiescence-unavailable "*) : ;; *) fail "Prime replacement left stale lifecycle state: $record" ;; esac

  out=$(drive_prime_ext "$ext" active-reload-shutdown) || fail "Prime active reload shutdown drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "Prime active reload shutdown must preserve busy, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime active reload shutdown record is unreadable"
  case "$record" in "busy prime-ext session-reload-active "*) : ;; *) fail "Prime active reload shutdown lost its busy edge: $record" ;; esac

  out=$(drive_prime_ext "$ext" active-reload) || fail "Prime active reload replacement drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "Prime active reload replacement must remain busy, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime active reload replacement record is unreadable"
  case "$record" in "busy prime-ext session-start-active "*) : ;; *) fail "Prime active reload replacement did not seed busy: $record" ;; esac

  out=$(drive_prime_ext "$ext" reload-unrelated-session) || fail "Prime unrelated reload session drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "An unrelated session_start consumed Prime's active reload, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime unrelated reload session record is unreadable"
  case "$record" in "busy prime-ext session-reload-active "*) : ;; *) fail "Prime unrelated session consumed the reload identity: $record" ;; esac

  out=$(drive_prime_ext "$ext" inactive-shutdown-during-reload) || fail "Prime inactive shutdown during reload drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "An inactive shutdown must preserve another session's pending reload, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime inactive shutdown during reload record is unreadable"
  case "$record" in "busy prime-ext session-replaced-other-active "*) : ;; *) fail "Prime inactive shutdown lost the pending reload: $record" ;; esac

  out=$(drive_prime_ext "$ext" concurrent-active-reloads) || fail "Prime concurrent reload drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "busy prime-ext" ] || fail "Prime concurrent reloads must preserve the remaining active session, got '$out'"
  record=$(fm_busy_record_read "$state" "$id") || fail "Prime concurrent reload record is unreadable"
  case "$record" in "busy prime-ext agent-end-other-active "*) : ;; *) fail "Prime concurrent reloads collapsed per-session state: $record" ;; esac

  out=$(drive_prime_ext "$ext" overlapping-ends) || fail "Prime overlapping writer drive failed: $out"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "unknown prime-ext" ] || fail "Prime serialized publication allowed an older busy write to win, got '$out'"

  before_turn_end=$out
  rm -f "$state/$id.turn-ended"
  out=$(drive_prime_ext "$ext" turn-end) || fail "Prime turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "Prime turn_end no longer touches the notification marker"
  out=$(classify prime-agent "$id" "$state")
  [ "$out" = "$before_turn_end" ] || fail "Prime turn_end changed lifecycle state from '$before_turn_end' to '$out'"
  pass "Prime extension tracks compaction and per-session retries without inventing idle"
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

test_pi_extension_semantic_lifecycle
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_stale_incarnation_rejected
test_prime_extension_semantic_lifecycle
test_kimi_and_grok_install_no_unverified_wiring
test_opencode_plugin_semantic_lifecycle
test_claude_hooks_semantic_lifecycle
test_claude_hooks_stale_incarnation_harmless
test_codex_unverified_until_a_semantic_source_exists

echo "all fm-busy-adapter-wiring tests passed"
