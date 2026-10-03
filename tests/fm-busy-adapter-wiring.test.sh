#!/usr/bin/env bash
# Behavior tests for the per-adapter semantic busy-state wiring that
# bin/fm-spawn.sh installs under the contract owned by bin/fm-busy-lib.sh.
#
# These tests run the REAL fm-spawn against a fake Herdr pane and an isolated
# git worktree, then drive the generated adapter artifact (the Pi extension,
# generated Pi lifecycle handlers) in a plain Node host, so the artifact, the real
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
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi codex)
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
  CODEX_HOME="$home/codex-home" TRAE_HOME="$home/traex-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode review-PR --yolo off
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify herdr fake:w "$1" "$2" "$3"
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

test_codex_task_bound_native_process_wiring() {
  local rec id=busy-cx-1 out state marker transcript
  rec=$(make_spawn_case codex-native codex "$id")
  read_case_record "$rec"
  export FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "codex spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_present "$state/$id.busy-gen" "codex must mint a launch generation"
  local launch
  launch=$(grep 'FIRSTMATE_BUSY_GENERATION=' "$FM_FAKE_LAUNCH_LOG")
  unset FM_FAKE_LAUNCH_LOG
  cat > "$FAKEBIN_DIR/codex" <<'PY'
#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FM_ARGV_LOG'], 'w') as stream:
    json.dump({'args': sys.argv[1:], 'home': os.environ.get('CODEX_HOME')}, stream)
PY
  chmod +x "$FAKEBIN_DIR/codex"
  FM_ARGV_LOG="$CASE_DIR/argv.json" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" || fail "managed Codex launch is not executable"
  python3 - "$CASE_DIR/argv.json" "$state/$id.busy-gen" "$HOME_DIR/codex-home" <<'PY' || fail "launch binding marker or vendor home differs from the reader"
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
gen = pathlib.Path(sys.argv[2]).read_text().strip()
assert record['args'][-1].splitlines()[-1] == 'FIRSTMATE_BUSY_GENERATION=' + gen
assert 'FIRSTMATE_OP: v1 launch-brief:' in record['args'][-1]
assert record['home'] == sys.argv[3]
PY
  assert_absent "$WT_DIR/.codex/hooks.json" "codex must not install unverified busy hooks"
  assert_contains "$out" 'spawned '"$id"' harness=codex' "codex spawn did not complete normally"

  marker="$state/forbidden-transcript-read"
  transcript="$state/vendor-transcript.jsonl"
  truncate -s $((64 * 1024 * 1024)) "$transcript"
  printf '{"path":"%s"}\n' "$transcript" > "$state/$id.busy-session"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_agent_state() { printf '%s' "$FAKE_PROCESS_STATE"; }
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' "$FAKE_NATIVE_STATE"; }
  # shellcheck disable=SC2329 # forbidden-read tripwire for the retired path
  python3() { printf 'opened\n' > "$marker"; return 97; }

  FAKE_PROCESS_STATE=alive FAKE_NATIVE_STATE=busy
  out=$(classify codex "$id" "$state")
  [ "$out" = "busy herdr-native" ] || fail "codex native working state was not busy: $out"
  FAKE_NATIVE_STATE=idle
  out=$(classify codex "$id" "$state")
  [ "$out" = "idle herdr-native" ] || fail "codex native idle state was not idle: $out"
  FAKE_NATIVE_STATE=unknown
  out=$(fm_busy_classify herdr fake:w codex "$id" "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "idle herdr-native-live" ] || fail "codex live process with unknown native status was not idle: $out"
  FAKE_PROCESS_STATE=dead
  out=$(classify codex "$id" "$state")
  [ "$out" = "dead endpoint-gone" ] || fail "codex exited process was not dead: $out"
  FAKE_PROCESS_STATE=unreadable
  out=$(classify codex "$id" "$state")
  [ "$out" = "unknown herdr-process-unverified" ] || fail "codex unverified process did not stay unknown: $out"
  [ ! -e "$marker" ] || fail "codex native/process classification opened the forbidden 64 MiB transcript"
  unset -f fm_backend_agent_state fm_backend_busy_state python3
  unset FAKE_PROCESS_STATE FAKE_NATIVE_STATE
  pass "codex spawn uses native Herdr status plus exact process liveness without reading its vendor transcript"
}

test_pi_extension_semantic_lifecycle
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_stale_incarnation_rejected
test_codex_task_bound_native_process_wiring

echo "all fm-busy-adapter-wiring tests passed"
