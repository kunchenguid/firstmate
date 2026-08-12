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
  fm_fake_exit0 "$fakebin" treehouse pi opencode claude codex omp
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

# drive_omp_ext <ext-path> <mode>: load the generated OMP extension in a plain
# Node host and fire one lifecycle handler or one terminal event sequence.
drive_omp_ext() {
  EXT_PATH="$1" MODE="$2" STATE_DIR="${3:-}" TASK_ID="${4:-}" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, unlinkSync } from "node:fs";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const fire = async (name, event = {}) => {
  const handler = handlers[name];
  if (!handler) throw new Error("missing OMP handler " + name);
  await handler(event, {});
};
const busyState = () => readFileSync(
  process.env.STATE_DIR + "/" + process.env.TASK_ID + ".busy-state", "utf8");
const markerPresent = (path) => {
  try { readFileSync(path, "utf8"); return true; } catch { return false; }
};
const removeMarker = (path) => {
  try { unlinkSync(path); } catch {}
};
switch (process.env.MODE) {
  case "agent-start": await fire("agent_start"); break;
  case "agent-end": await fire("agent_end"); break;
  case "agent-end-continuation":
    await fire("agent_start");
    await fire("agent_end", { willContinue: true });
    if (!busyState().includes("state=busy")) {
      throw new Error("willContinue agent_end settled the active run");
    }
    break;
  case "timestamped-agent-end-continuation":
    await fire("agent_end", {
      willContinue: true,
      last_assistant_message: { timestamp: Number(process.env.EVENT_TIMESTAMP) },
    });
    break;
  case "session-stop": await fire("session_stop"); break;
  case "session-shutdown": await fire("session_shutdown"); break;
  case "timestamped-agent-end":
    await fire("agent_end", { last_assistant_message: { timestamp: Number(process.env.EVENT_TIMESTAMP) } });
    break;
  case "timestamped-session-shutdown":
    await fire("session_shutdown", { last_assistant_message: { timestamp: Number(process.env.EVENT_TIMESTAMP) } });
    break;
  case "explicit-session-shutdown":
    await fire("session_shutdown", {
      run_token: process.env.EVENT_TOKEN,
      last_assistant_message: { timestamp: Number(process.env.EVENT_TIMESTAMP) },
    });
    break;
  case "session-stop-agent-end-shutdown":
    await fire("session_stop");
    await fire("agent_end");
    await fire("session_shutdown");
    break;
  case "late-session-stop":
    await fire("agent_start");
    await new Promise((resolve) => setTimeout(resolve, 2));
    const priorRunTimestamp = Date.now();
    await fire("session_stop", { last_assistant_message: { timestamp: priorRunTimestamp } });
    await new Promise((resolve) => setTimeout(resolve, 2));
    await fire("agent_start");
    await fire("session_stop", { last_assistant_message: { timestamp: priorRunTimestamp } });
    if (readFileSync(process.env.STATE_DIR + "/busy-omp-2.omp-session-stop", "utf8").trim() !== "pending") {
      throw new Error("late prior-run session_stop settled the current run");
    }
    await new Promise((resolve) => setTimeout(resolve, 2));
    await fire("session_stop", { last_assistant_message: { timestamp: Date.now() } });
    break;
  case "repeat-session-shutdown":
    await fire("agent_start");
    await fire("session_stop");
    await fire("agent_start");
    await fire("session_shutdown");
    break;
  case "persistent-run-correlation": {
    const runPath = process.env.STATE_DIR + "/" + process.env.TASK_ID + ".omp-session-run";
    const stopPath = process.env.STATE_DIR + "/" + process.env.TASK_ID + ".omp-session-stop";
    const turnEndPath = process.env.STATE_DIR + "/" + process.env.TASK_ID + ".turn-ended";
    await fire("agent_start");
    const firstToken = readFileSync(runPath, "utf8").trim();
    await fire("session_stop");
    await fire("agent_start");
    const secondToken = readFileSync(runPath, "utf8").trim();
    if (!secondToken || secondToken === firstToken) {
      throw new Error("the second run did not receive a distinct token");
    }
    removeMarker(turnEndPath);
    await fire("agent_end");
    if (busyState().includes("state=busy") || !markerPresent(turnEndPath)) {
      throw new Error("tokenless agent_end did not settle the unique active run");
    }
    await fire("agent_start");
    await fire("session_stop", { run_token: firstToken });
    if (!busyState().includes("state=busy") || readFileSync(stopPath, "utf8").trim() !== "pending") {
      throw new Error("an explicit stale token settled the current run");
    }
    await fire("session_stop");
    await fire("agent_start");
    await fire("agent_start");
    await fire("agent_end");
    if (!busyState().includes("state=busy") || readFileSync(stopPath, "utf8").trim() !== "pending") {
      throw new Error("an ambiguous tokenless terminal event settled an active run");
    }
    break;
  }
  case "overlapping-terminal-events": {
    const turnEndPath = process.env.STATE_DIR + "/" + process.env.TASK_ID + ".turn-ended";
    await fire("agent_start");
    const firstToken = readFileSync(
      process.env.STATE_DIR + "/" + process.env.TASK_ID + ".omp-session-run", "utf8").trim();
    await fire("agent_start");
    removeMarker(turnEndPath);
    await fire("agent_end", { last_assistant_message: { timestamp: Date.now() } });
    if (!busyState().includes("state=busy") || markerPresent(turnEndPath)) {
      throw new Error("a timestamped tokenless terminal event settled overlapping runs");
    }
    await fire("session_stop", {
      run_token: firstToken,
      last_assistant_message: { timestamp: Date.now() },
    });
    if (!busyState().includes("state=busy") || markerPresent(turnEndPath)) {
      throw new Error("an explicit terminal token cleared busy while another run remained active");
    }
    await fire("agent_end", { last_assistant_message: { timestamp: Date.now() } });
    if (busyState().includes("state=busy") || !markerPresent(turnEndPath)) {
      throw new Error("the remaining unique run did not settle after an explicit sibling token");
    }
    break;
  }
  case "explicit-current-then-tokenless-older": {
    const runPath = process.env.STATE_DIR + "/" + process.env.TASK_ID + ".omp-session-run";
    const turnEndPath = process.env.STATE_DIR + "/" + process.env.TASK_ID + ".turn-ended";
    await fire("agent_start");
    const firstToken = readFileSync(runPath, "utf8").trim();
    await fire("agent_start");
    const secondToken = readFileSync(runPath, "utf8").trim();
    removeMarker(turnEndPath);
    await fire("session_stop", { run_token: secondToken });
    if (!busyState().includes("state=busy") || readFileSync(runPath, "utf8").trim() !== firstToken) {
      throw new Error("settling the current run did not advance to the surviving run");
    }
    await fire("agent_end");
    if (busyState().includes("state=busy") || !markerPresent(turnEndPath)) {
      throw new Error("a tokenless event did not settle the surviving run after pointer advance");
    }
    break;
  }
  case "settle-older-then-reload": {
    const runPath = process.env.STATE_DIR + "/" + process.env.TASK_ID + ".omp-session-run";
    await fire("agent_start");
    const olderToken = readFileSync(runPath, "utf8").trim();
    await fire("agent_start");
    const currentToken = readFileSync(runPath, "utf8").trim();
    await fire("session_stop", {
      run_token: olderToken,
      last_assistant_message: { timestamp: Date.now() },
    });
    if (!busyState().includes("state=busy") || readFileSync(runPath, "utf8").trim() !== currentToken) {
      throw new Error("settling the older run changed the active persisted pointer");
    }
    break;
  }
  case "settle-current-then-reload": {
    const runPath = process.env.STATE_DIR + "/" + process.env.TASK_ID + ".omp-session-run";
    await fire("agent_start");
    const olderToken = readFileSync(runPath, "utf8").trim();
    await fire("agent_start");
    const currentToken = readFileSync(runPath, "utf8").trim();
    await fire("session_stop", {
      run_token: currentToken,
      last_assistant_message: { timestamp: Date.now() },
    });
    if (!busyState().includes("state=busy") || readFileSync(runPath, "utf8").trim() !== olderToken) {
      throw new Error("settling the current run did not advance the active persisted pointer");
    }
    break;
  }
  case "overlapping-persisted-runs": {
    await fire("agent_start");
    await fire("agent_start");
    if (!busyState().includes("state=busy")) {
      throw new Error("overlapping persisted runs did not remain busy");
    }
    break;
  }
  case "ambiguous-session-shutdown":
    await fire("agent_start");
    await fire("agent_start");
    await fire("session_shutdown");
    break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
EOF
}

test_omp_extension_semantic_lifecycle() {
  local rec id=busy-omp-1 out state ext record gen run_token marker
  rec=$(make_spawn_case omp-lifecycle omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"

  out=$(classify omp "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" session-stop-agent-end-shutdown) || fail "OMP terminal lifecycle drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "session_stop must classify 'idle omp-ext', got '$out'"
  record=$(fm_busy_record_read "$state" "$id")
  [ "$record" = "idle omp-ext session-stop 3" ] \
    || fail "session_stop/agent_end/shutdown must settle exactly once, got '$record'"
  [ -f "$state/$id.turn-ended" ] || fail "session_stop no longer publishes the turn-end notification marker"
  gen=$(cat "$state/$id.busy-gen")
  run_token=$(cat "$state/$id.omp-session-run")
  marker=$(cat "$state/$id.omp-session-stop")
  case "$run_token" in
    "$gen".*) ;;
    *) fail "agent_start must publish a run token bound to the current busy generation" ;;
  esac
  [ "$marker" = "$run_token" ] || fail "session_stop must publish the current run token"

  out=$(drive_omp_ext "$ext" agent-start) || fail "second agent_start drive failed: $out"
  new_run_token=$(cat "$state/$id.omp-session-run")
  [ "$new_run_token" != "$run_token" ] || fail "each agent_start must rotate the OMP run token"
  marker=$(cat "$state/$id.omp-session-stop" 2>/dev/null || true)
  [ "$marker" = pending ] || fail "a fresh agent_start must invalidate prior terminal evidence atomically, got '$marker'"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "a fresh run must reopen busy, got '$out'"

  out=$(drive_omp_ext "$ext" session-shutdown) || fail "session_shutdown drive failed: $out"
  marker=$(cat "$state/$id.omp-session-stop" 2>/dev/null || true)
  [ "$marker" = pending ] || fail "a fallback shutdown must not restore terminal evidence for the fresh run"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "session_shutdown must settle the worker idle, got '$out'"
  pass "omp extension settles on observed session_stop with idempotent lifecycle fallbacks"
}

test_omp_extension_rejects_late_prior_run_stop() {
  local rec id=busy-omp-2 out state ext marker run_token
  rec=$(make_spawn_case omp-late-stop omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" late-session-stop "$state") || fail "late session_stop drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  marker=$(cat "$state/$id.omp-session-stop")
  [ "$marker" = "$run_token" ] || fail "the current run must publish only its own terminal evidence"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "the current run must settle after a late prior stop, got '$out'"
  pass "omp extension rejects a late prior-run stop before settling the replacement"
}

test_omp_session_shutdown_requires_one_active_run() {
  local rec id=busy-omp-shutdown out state ext marker
  rec=$(make_spawn_case omp-shutdown omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"

  out=$(drive_omp_ext "$ext" repeat-session-shutdown "$state" "$id") \
    || fail "repeated-run session_shutdown drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] \
    || fail "a tokenless shutdown with one active current run must settle idle, got '$out'"
  marker=$(cat "$state/$id.omp-session-stop")
  [ "$marker" = pending ] \
    || fail "the fallback shutdown must not publish terminal evidence"

  out=$(drive_omp_ext "$ext" ambiguous-session-shutdown "$state" "$id") \
    || fail "ambiguous session_shutdown drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] \
    || fail "an ambiguous tokenless shutdown must leave the active runs busy, got '$out'"
  marker=$(cat "$state/$id.omp-session-stop")
  [ "$marker" = pending ] \
    || fail "an ambiguous shutdown must not publish terminal evidence"
  pass "omp session_shutdown settles one active current run and rejects ambiguous history"
}

test_omp_extension_persistent_run_correlation() {
  local rec id=busy-omp-persistent out state ext
  rec=$(make_spawn_case omp-persistent omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" persistent-run-correlation "$state" "$id") \
    || fail "persistent OMP run-correlation drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] \
    || fail "ambiguous active runs must remain busy after tokenless agent_end, got '$out'"
  pass "omp extension correlates repeated tokenless terminal events to one active run"
}

test_omp_extension_rejects_overlapping_timestamped_runs() {
  local rec id=busy-omp-overlap out state ext
  rec=$(make_spawn_case omp-overlap omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" overlapping-terminal-events "$state" "$id") \
    || fail "overlapping OMP terminal-event drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] \
    || fail "the remaining unique run must settle after overlap is resolved, got '$out'"
  [ -e "$state/$id.turn-ended" ] \
    || fail "the final unique terminal event must publish turn-end evidence"
  pass "omp terminal correlation rejects overlap before settling the remaining run"
}

test_omp_extension_recovers_stale_current_pointer() {
  local rec id=busy-omp-pointer out state ext
  rec=$(make_spawn_case omp-pointer omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" explicit-current-then-tokenless-older "$state" "$id") \
    || fail "stale current-pointer drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] \
    || fail "the surviving run must settle after the current run is explicitly settled, got '$out'"
  [ -e "$state/$id.turn-ended" ] \
    || fail "the surviving run must publish turn-end evidence after pointer advance"
  pass "omp terminal correlation advances the current run after an explicit sibling settles"
}

test_omp_extension_scopes_evidence_per_run() {
  local rec id=busy-omp-evidence out state ext evidence_dir older_token current_token
  local older_evidence current_evidence
  rec=$(make_spawn_case omp-evidence omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  evidence_dir="$state/$id.omp-session-evidence"
  out=$(drive_omp_ext "$ext" settle-older-then-reload "$state" "$id") \
    || fail "older-run settlement drive failed: $out"
  current_token=$(cat "$state/$id.omp-session-run")
  older_token=$(find "$evidence_dir" -maxdepth 1 -type f -print | sort | head -n 1 | xargs -n 1 basename)
  [ "$older_token" != "$current_token" ] || fail "sibling settlement did not leave separate run evidence"
  older_evidence=$(cat "$evidence_dir/$older_token")
  current_evidence=$(cat "$evidence_dir/$current_token")
  [ "$(printf '%s\n' "$older_evidence" | awk '{ print $1 }')" = "$older_token" ] \
    || fail "settled evidence is not keyed by its own run token"
  [ "$(printf '%s\n' "$older_evidence" | awk '{ print $4 }')" -gt 0 ] \
    || fail "settled sibling evidence did not retain stop evidence"
  [ "$(printf '%s\n' "$current_evidence" | awk '{ print $1 }')" = "$current_token" ] \
    || fail "surviving evidence was overwritten by the settled sibling"
  [ "$(printf '%s\n' "$current_evidence" | awk '{ print $4 }')" = 0 ] \
    || fail "surviving run was incorrectly marked stopped"

  printf '%s\n' "$older_token" > "$state/$id.omp-session-run"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") \
    || fail "pointer-only stale evidence reload drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "a pointer to settled evidence must not settle the pending run, got '$out'"
  printf '%s\n' "$current_token" > "$state/$id.omp-session-run"

  printf '%s\n' "$older_evidence" > "$evidence_dir/$current_token"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") \
    || fail "stale evidence reload drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "mismatched per-run evidence must not settle the current run, got '$out'"
  printf '%s\n' "$current_evidence" > "$evidence_dir/$current_token"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") \
    || fail "valid surviving-run reload drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "reload did not recover the surviving run, got '$out'"

  out=$(drive_omp_ext "$ext" agent-start "$state" "$id") \
    || fail "fresh run after reload drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "fresh run did not reopen busy, got '$out'"
  pass "omp persists independent evidence for settled and surviving runs"
}

test_omp_extension_rejects_settled_sibling_after_reload() {
  local rec id=busy-omp-sibling-stale out state ext evidence_dir older_token current_token
  rec=$(make_spawn_case omp-sibling-stale omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  evidence_dir="$state/$id.omp-session-evidence"
  out=$(drive_omp_ext "$ext" settle-current-then-reload "$state" "$id") \
    || fail "current-run settlement drive failed: $out"
  current_token=$(cat "$state/$id.omp-session-run")
  older_token=$(find "$evidence_dir" -maxdepth 1 -type f -print | sort | tail -n 1 | xargs -n 1 basename)
  [ "$older_token" != "$current_token" ] || fail "current-run settlement did not preserve the older pointer"
  out=$(EVENT_TOKEN="$older_token" drive_omp_ext "$ext" explicit-session-shutdown "$state" "$id") \
    || fail "settled sibling reload drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "a settled sibling token must not settle the surviving run, got '$out'"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") \
    || fail "surviving-run reload drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "the surviving run did not settle after stale-token denial, got '$out'"
  pass "omp rejects settled sibling tokens after reload and settles the survivor"
}

test_omp_extension_rejects_overlapping_runs_after_reload() {
  local rec id=busy-omp-reload-overlap out state ext evidence_dir first_token second_token
  rec=$(make_spawn_case omp-reload-overlap omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  evidence_dir="$state/$id.omp-session-evidence"
  out=$(drive_omp_ext "$ext" overlapping-persisted-runs "$state" "$id") \
    || fail "overlapping persisted-run drive failed: $out"
  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") \
    || fail "ambiguous reload terminal drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "ambiguous persisted runs must remain busy, got '$out'"
  [ ! -e "$state/$id.turn-ended" ] || fail "ambiguous persisted runs must not publish turn-end evidence"

  first_token=$(find "$evidence_dir" -maxdepth 1 -type f -print | sort | head -n 1 | xargs -n 1 basename)
  second_token=$(cat "$state/$id.omp-session-run")
  [ "$first_token" != "$second_token" ] || fail "overlap setup did not produce two distinct persisted runs"
  out=$(EVENT_TOKEN="$first_token" drive_omp_ext "$ext" explicit-session-shutdown "$state" "$id") \
    || fail "explicit older persisted-run drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "settling one persisted run must leave its sibling busy, got '$out'"
  [ "$(cat "$state/$id.omp-session-run")" = "$second_token" ] \
    || fail "settling the older persisted run changed the surviving pointer"

  out=$(EVENT_TOKEN="$second_token" drive_omp_ext "$ext" explicit-session-shutdown "$state" "$id") \
    || fail "explicit surviving persisted-run drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "explicitly settling both persisted runs must clear busy, got '$out'"
  [ -e "$state/$id.turn-ended" ] || fail "explicitly settling both persisted runs must publish turn-end evidence"
  pass "omp reload rejects ambiguous pending runs until explicit tokens settle both"
}

test_omp_extension_reloads_and_reconciles_persisted_run() {
  local rec id out state ext run_token started_at record_before record_after
  local fresh_token fresh_started_at stale_token
  rec=$(make_spawn_case omp-reload omp busy-omp-reload)
  read_case_record "$rec"
  id=busy-omp-reload
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"

  out=$(drive_omp_ext "$ext" agent-start) || fail "persisted-run agent_start drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  started_at=$(printf '%s\n' "$run_token" | awk -F. '{ print $(NF - 1) }')
  rm -f "$state/$id.turn-ended"
  out=$(EVENT_TIMESTAMP=$((started_at + 1)) drive_omp_ext "$ext" timestamped-agent-end-continuation "$state" "$id") \
    || fail "timestamped reload continuation drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "a correlated continuation must keep the persisted run busy, got '$out'"
  out=$(EVENT_TIMESTAMP=$((started_at + 1)) drive_omp_ext "$ext" timestamped-agent-end "$state" "$id") \
    || fail "timestamped reload agent_end drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "a reloaded extension must settle its uniquely persisted run, got '$out'"
  [ -f "$state/$id.turn-ended" ] || fail "a reloaded timestamped terminal event must publish turn-end evidence"
  record_before=$(fm_busy_record_read "$state" "$id")
  out=$(EVENT_TIMESTAMP=$((started_at + 1)) drive_omp_ext "$ext" timestamped-agent-end "$state" "$id") \
    || fail "duplicate reload agent_end drive failed: $out"
  record_after=$(fm_busy_record_read "$state" "$id")
  [ "$record_after" = "$record_before" ] || fail "a duplicate terminal event after reload rewrote the busy record"

  out=$(drive_omp_ext "$ext" agent-start) || fail "fresh persisted-run agent_start drive failed: $out"
  fresh_token=$(cat "$state/$id.omp-session-run")
  fresh_started_at=$(printf '%s\n' "$fresh_token" | awk -F. '{ print $(NF - 1) }')
  rm -f "$state/$id.turn-ended"
  out=$(EVENT_TIMESTAMP=$((fresh_started_at - 1)) drive_omp_ext "$ext" timestamped-session-shutdown "$state" "$id") \
    || fail "stale timestamp reload shutdown drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "a timestamp before the persisted run lifetime must not settle it, got '$out'"
  [ ! -e "$state/$id.turn-ended" ] || fail "a stale timestamp must not publish turn-end evidence"

  stale_token="${fresh_token}.stale"
  out=$(EVENT_TIMESTAMP=$((fresh_started_at + 1)) EVENT_TOKEN="$stale_token" \
    drive_omp_ext "$ext" explicit-session-shutdown "$state" "$id") \
    || fail "stale-token reload shutdown drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "an explicit stale token must not settle the persisted run, got '$out'"
  printf '%s\n%s\n' "$fresh_token" "$stale_token" > "$state/$id.omp-session-run"
  out=$(EVENT_TIMESTAMP=$((fresh_started_at + 1)) drive_omp_ext "$ext" timestamped-session-shutdown "$state" "$id") \
    || fail "ambiguous persisted-run shutdown drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "multiple persisted pending runs must remain busy, got '$out'"
  printf '%s\n' "$fresh_token" > "$state/$id.omp-session-run"
  printf '%s\n' conflicting-token > "$state/$id.omp-session-stop"
  out=$(EVENT_TIMESTAMP=$((fresh_started_at + 1)) drive_omp_ext "$ext" timestamped-session-shutdown "$state" "$id") \
    || fail "conflicting stop-evidence shutdown drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "conflicting persisted stop evidence must remain busy, got '$out'"
  printf '%s\n' pending > "$state/$id.omp-session-stop"
  out=$(EVENT_TIMESTAMP=$((fresh_started_at + 1)) \
    drive_omp_ext "$ext" timestamped-agent-end-continuation "$state" "$id") \
    || fail "fresh correlated continuation drive failed: $out"
  out=$(EVENT_TIMESTAMP=$((fresh_started_at + 1)) drive_omp_ext "$ext" timestamped-session-shutdown "$state" "$id") \
    || fail "fresh timestamped reload shutdown drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "a fresh persisted run must settle after reload, got '$out'"
  pass "omp extension reconciles persisted runs across reloads with timestamp and ambiguity guards"
}

test_omp_extension_rejects_unproven_timestamp_after_reload() {
  local rec id=busy-omp-unproven-timestamp out state ext run_token started_at
  rec=$(make_spawn_case omp-unproven-timestamp omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "unproven timestamp agent_start drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  started_at=$(printf '%s\n' "$run_token" | awk -F. '{ print $(NF - 1) }')
  rm -f "$state/$id.turn-ended"
  out=$(EVENT_TIMESTAMP=$((started_at + 1)) drive_omp_ext "$ext" timestamped-agent-end "$state" "$id") \
    || fail "unproven timestamp terminal drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "an in-range but unproven reload timestamp settled the run, got '$out'"
  [ ! -e "$state/$id.turn-ended" ] || fail "an unproven reload timestamp published turn-end evidence"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") \
    || fail "uncorrelated tokenless terminal drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "a tokenless terminal should still settle the unique recovered run, got '$out'"
  pass "omp rejects in-range but unproven timestamp-only reload settlement"
}

test_omp_extension_adopts_pending_run_before_new_start() {
  local rec id=busy-omp-reload-new-start out state ext first_token second_token
  rec=$(make_spawn_case omp-reload-new-start omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp new-start recovery spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "new-start first agent_start drive failed: $out"
  first_token=$(cat "$state/$id.omp-session-run")
  out=$(drive_omp_ext "$ext" agent-start) || fail "new-start reloaded agent_start drive failed: $out"
  second_token=$(cat "$state/$id.omp-session-run")
  [ "$first_token" != "$second_token" ] || fail "new-start recovery did not rotate a fresh run"
  out=$(EVENT_TOKEN="$second_token" drive_omp_ext "$ext" explicit-session-shutdown "$state" "$id") \
    || fail "new-start explicit current settlement failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "settling a fresh run must preserve the reloaded sibling, got '$out'"
  [ "$(cat "$state/$id.omp-session-run")" = "$first_token" ] \
    || fail "settling a fresh run discarded the reloaded sibling pointer"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") \
    || fail "new-start surviving run settlement failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "the reloaded sibling did not settle after the fresh run, got '$out'"
  pass "omp reload adopts pending runs before rotating a fresh run"
}

test_omp_extension_recovers_partial_persistence() {
  local rec id=busy-omp-partial out state ext run_token evidence_dir first_token second_token
  rec=$(make_spawn_case omp-partial omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "partial marker agent_start drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  evidence_dir="$state/$id.omp-session-evidence"
  rm -rf "$evidence_dir"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") || fail "missing evidence recovery drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "a run marker without evidence was not recovered, got '$out'"
  [ -f "$evidence_dir/$run_token" ] || fail "recovery did not materialize missing run evidence"

  rec=$(make_spawn_case omp-partial-stop omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp stop-marker spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "stop-marker agent_start drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  printf '%s\n' "$run_token" > "$state/$id.omp-session-stop"
  rm -rf "$state/$id.omp-session-evidence"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") || fail "stop-marker recovery drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "a stop marker before evidence was not recovered, got '$out'"

  rec=$(make_spawn_case omp-partial-pointer omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp pointer-recovery spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "pointer-recovery first agent_start drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  out=$(drive_omp_ext "$ext" session-stop) || fail "pointer-recovery first session_stop drive failed: $out"
  first_token="$run_token"
  out=$(drive_omp_ext "$ext" agent-start) || fail "pointer-recovery second agent_start drive failed: $out"
  second_token=$(cat "$state/$id.omp-session-run")
  [ "$first_token" != "$second_token" ] || fail "pointer-recovery setup did not create a new run"
  printf '%s\n' "$first_token" > "$state/$id.omp-session-stop"
  rm -f "$state/$id.omp-session-evidence/$second_token"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") || fail "pointer-before-evidence recovery drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "a new run pointer with stale stop evidence was not recovered, got '$out'"
  [ "$(cat "$state/$id.omp-session-stop")" = pending ] \
    || fail "pointer recovery did not repair the stale stop marker"

  rec=$(make_spawn_case omp-partial-evidence-first omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp evidence-first recovery spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "evidence-first agent_start drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  rm -f "$state/$id.omp-session-run" "$state/$id.omp-session-stop"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") || fail "evidence-first recovery drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "a pending evidence record without run markers was not recovered, got '$out'"
  [ -f "$state/$id.omp-session-evidence/$run_token" ] \
    || fail "evidence-first recovery lost the durable run record"

  rec=$(make_spawn_case omp-partial-stop-publish omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp publication-recovery spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "publication agent_start drive failed: $out"
  out=$(drive_omp_ext "$ext" session-stop) || fail "publication session_stop drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  rm -f "$state/$id.turn-ended"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --current-gen \
    --run-token "$run_token" --source omp-ext --event crash-replay >/dev/null \
    || fail "could not recreate busy state before publication recovery"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") || fail "busy publication recovery drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "stopped evidence did not recover idle publication, got '$out'"
  [ -f "$state/$id.turn-ended" ] || fail "stopped evidence did not recover turn-end publication"

  rec=$(make_spawn_case omp-partial-turnend omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp turn-end-recovery spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "turn-end agent_start drive failed: $out"
  out=$(drive_omp_ext "$ext" session-stop) || fail "turn-end session_stop drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") || fail "idle turn-end recovery drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "idle publication recovery changed busy state, got '$out'"
  [ -f "$state/$id.turn-ended" ] || fail "idle publication recovery did not restore turn-end evidence"
  pass "omp extension recovers partial run, stop, idle, and turn-end persistence"
}

test_omp_extension_ignores_only_own_evidence_temps() {
  local rec id=busy-omp-evidence-temp out state ext run_token evidence_dir
  rec=$(make_spawn_case omp-evidence-temp omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp evidence-temp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "evidence-temp agent_start drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  evidence_dir="$state/$id.omp-session-evidence"
  printf '%s\n' "$run_token 1 1 0" > "$evidence_dir/$run_token.123.1.tmp"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") || fail "owned evidence temp recovery drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "the extension-owned evidence temp blocked recovery, got '$out'"
  [ ! -e "$evidence_dir/$run_token.123.1.tmp" ] || fail "the extension-owned evidence temp was not cleaned"

  rec=$(make_spawn_case omp-foreign-evidence-temp omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp foreign-temp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  out=$(drive_omp_ext "$ext" agent-start) || fail "foreign-temp agent_start drive failed: $out"
  evidence_dir="$state/$id.omp-session-evidence"
  printf '%s\n' malformed > "$evidence_dir/foreign.123.1.tmp"
  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") || fail "foreign evidence temp drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "a foreign evidence temp was accepted, got '$out'"
  [ -e "$evidence_dir/foreign.123.1.tmp" ] || fail "a foreign evidence temp was silently removed"
  pass "omp reload ignores only extension-owned evidence temporary files"
}

test_omp_extension_rejects_foreign_and_out_of_order_persisted_timestamps() {
  local rec id=busy-omp-timestamps out state ext run_token started_at
  rec=$(make_spawn_case omp-timestamps omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"

  out=$(drive_omp_ext "$ext" agent-start) || fail "timestamp evidence agent_start drive failed: $out"
  run_token=$(cat "$state/$id.omp-session-run")
  started_at=$(printf '%s\n' "$run_token" | awk -F. '{ print $(NF - 1) }')
  rm -f "$state/$id.turn-ended"
  out=$(EVENT_TIMESTAMP=$((started_at + 5)) \
    drive_omp_ext "$ext" timestamped-agent-end-continuation "$state" "$id") \
    || fail "timestamp evidence continuation drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] || fail "a continuing timestamp must keep the persisted run busy, got '$out'"

  out=$(EVENT_TIMESTAMP=$((started_at + 1)) \
    drive_omp_ext "$ext" timestamped-agent-end "$state" "$id") \
    || fail "out-of-order timestamp drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] \
    || fail "an out-of-order timestamp must not settle the persisted run, got '$out'"
  [ ! -e "$state/$id.turn-ended" ] \
    || fail "an out-of-order timestamp must not publish turn-end evidence"

  out=$(EVENT_TIMESTAMP=$((started_at + 86400000)) \
    drive_omp_ext "$ext" timestamped-session-shutdown "$state" "$id") \
    || fail "foreign future timestamp drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] \
    || fail "a foreign future timestamp must not settle the persisted run, got '$out'"

  out=$(EVENT_TIMESTAMP=$((started_at - 1)) \
    drive_omp_ext "$ext" timestamped-session-shutdown "$state" "$id") \
    || fail "prior-run timestamp drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] \
    || fail "a prior-run timestamp must not settle the persisted run, got '$out'"

  out=$(EVENT_TIMESTAMP=$((started_at + 5)) \
    drive_omp_ext "$ext" timestamped-agent-end "$state" "$id") \
    || fail "valid timestamp drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] || fail "a valid persisted timestamp must settle the unique run, got '$out'"
  [ -e "$state/$id.turn-ended" ] || fail "a valid persisted timestamp must publish turn-end evidence"
  pass "omp reload correlation rejects foreign and out-of-order timestamps"
}

test_omp_agent_end_continuation_stays_busy() {
  local rec id=busy-omp-continuation out state ext
  rec=$(make_spawn_case omp-continuation omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  rm -f "$state/$id.turn-ended"

  out=$(drive_omp_ext "$ext" agent-end-continuation "$state" "$id") \
    || fail "continuing agent_end drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy omp-ext" ] \
    || fail "willContinue=true must keep semantic busy active, got '$out'"
  [ ! -e "$state/$id.turn-ended" ] \
    || fail "willContinue=true must not publish a turn-end notification"

  out=$(drive_omp_ext "$ext" agent-end "$state" "$id") \
    || fail "terminal agent_end drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "idle omp-ext" ] \
    || fail "terminal agent_end must settle semantic busy, got '$out'"
  [ -e "$state/$id.turn-ended" ] \
    || fail "terminal agent_end must publish the turn-end notification"
  pass "omp agent_end ignores automatic continuation and settles only terminal turns"
}

test_omp_extension_stale_incarnation_rejected() {
  local rec id=busy-omp-2 out state ext
  rec=$(make_spawn_case omp-stale omp "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_omp_ext "$ext" session-stop) || fail "stale session_stop drive failed: $out"
  out=$(classify omp "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  pass "omp extension events from a superseded incarnation are rejected as stale"
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
test_omp_extension_semantic_lifecycle
test_omp_extension_rejects_late_prior_run_stop
test_omp_session_shutdown_requires_one_active_run
test_omp_extension_persistent_run_correlation
test_omp_extension_rejects_overlapping_timestamped_runs
test_omp_extension_recovers_stale_current_pointer
test_omp_extension_scopes_evidence_per_run
test_omp_extension_rejects_settled_sibling_after_reload
test_omp_extension_rejects_overlapping_runs_after_reload
test_omp_extension_reloads_and_reconciles_persisted_run
test_omp_extension_rejects_unproven_timestamp_after_reload
test_omp_extension_adopts_pending_run_before_new_start
test_omp_extension_recovers_partial_persistence
test_omp_extension_ignores_only_own_evidence_temps
test_omp_extension_rejects_foreign_and_out_of_order_persisted_timestamps
test_omp_agent_end_continuation_stays_busy
test_omp_extension_stale_incarnation_rejected
test_kimi_and_grok_install_no_unverified_wiring
test_opencode_plugin_semantic_lifecycle
test_claude_hooks_semantic_lifecycle
test_claude_hooks_stale_incarnation_harmless
test_codex_unverified_until_a_semantic_source_exists

echo "all fm-busy-adapter-wiring tests passed"
