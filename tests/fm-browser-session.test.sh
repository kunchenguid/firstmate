#!/usr/bin/env bash
# Public-interface regressions for task-owned chrome-devtools-axi lifecycle.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BROWSER="$ROOT/bin/fm-browser-session.sh"
WRAPPER="$ROOT/bin/browser-axi/chrome-devtools-axi"
TMP_ROOT=$(fm_test_tmproot fm-browser-session)
TEST_HOME="$TMP_ROOT/user-home"
FAKEBIN="$TMP_ROOT/fakebin"
REAL_PS=$(command -v ps)
PIDS=
START_PID=
START_PORT=
START_HELPER=

cleanup() {
  local pid
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_HOME" "$FAKEBIN"

cat > "$FAKEBIN/chrome-devtools-axi-real" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = test-bridge ] || {
  printf 'unexpected real cli call: %s\n' "$*" >> "${FM_FAKE_BROWSER_STOP_LOG:?}"
  exit 2
}
shift
exec node "${FM_FAKE_BRIDGE_JS:?}" "$@"
SH
chmod +x "$FAKEBIN/chrome-devtools-axi-real"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  echo "can't find session: ghost" >&2
  exit 1
fi
exit 1
SH
chmod +x "$FAKEBIN/tmux"

cat > "$FAKEBIN/ps" <<SH
#!/usr/bin/env bash
if [ "\$*" = '-axo pid=,ppid=,command=' ]; then
  case "\${FM_FAKE_PS_MODE:-empty}" in
    busy)
      cat <<'EOF'
  100     1 node /tmp/chrome-devtools-axi-bridge.js
  101   100 /tmp/chrome-for-testing/chrome-headless-shell --headless=new --user-data-dir=/tmp/owned
  102   101 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper --type=renderer
  103   102 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper --type=utility
  200     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --user-data-dir=/tmp/unrelated
  201   200 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper --type=renderer
EOF
      ;;
    real) exec "$REAL_PS" "\$@" ;;
  esac
  exit 0
fi
exec "$REAL_PS" "\$@"
SH
chmod +x "$FAKEBIN/ps"

BRIDGE_JS="$TMP_ROOT/chrome-devtools-axi-bridge.js"
cat > "$BRIDGE_JS" <<'JS'
const {spawn} = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const session = process.argv[2];
const portFile = process.argv[3];
const mode = process.argv[4] || "graceful";
const stopLog = process.env.FM_FAKE_BROWSER_STOP_LOG;
process.on("SIGTERM", () => {
  fs.appendFileSync(stopLog, `${process.env.CHROME_DEVTOOLS_AXI_SESSION}\n`);
  if (mode !== "hang") process.exit(0);
});
process.on("exit", () => {
  try { process.kill(-process.pid, "SIGTERM"); } catch {}
});
if (mode === "hang" || mode === "stubborn-helper") {
  const helper = spawn(process.execPath, ["-e", `
    const fs = require("node:fs");
    process.on("SIGTERM", () => {});
    fs.writeFileSync(process.argv[1], "ready");
    setInterval(() => {}, 1000);
  `, `${portFile}.helper.ready`], {stdio: "ignore"});
  helper.unref();
  fs.writeFileSync(`${portFile}.helper`, String(helper.pid));
}
const server = http.createServer((request, response) => {
  if (request.url !== "/health") {
    response.writeHead(404).end();
    return;
  }
  response.writeHead(200, {"content-type": "application/json"});
  response.end(JSON.stringify({status: "ok", session}));
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
JS
LAUNCHER_JS="$TMP_ROOT/detached-launcher.cjs"
cat > "$LAUNCHER_JS" <<'JS'
const {spawn} = require("node:child_process");
const fs = require("node:fs");
const [wrapper, pidFile, real, bridge, stopLog, owner, session, portFile, mode] = process.argv.slice(2);
const child = spawn(wrapper, ["test-bridge", session, portFile, mode], {
  detached: true,
  stdio: "ignore",
  env: {
    ...process.env,
    CHROME_DEVTOOLS_AXI_SESSION: owner,
    FM_CHROME_DEVTOOLS_AXI_REAL: real,
    FM_FAKE_BRIDGE_JS: bridge,
    FM_FAKE_BROWSER_STOP_LOG: stopLog,
  },
});
fs.writeFileSync(pidFile, String(child.pid));
child.unref();
JS
STOP_LOG="$TMP_ROOT/stops.log"
: > "$STOP_LOG"

browser_name() {
  HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" "$BROWSER" name "$1" "$2"
}

start_session() {
  local session=$1 owner_session=${2:-$1} mode=${3:-graceful} dir port_file pid_file attempt
  dir="$TEST_HOME/.chrome-devtools-axi/sessions/$session"
  mkdir -p "$dir"
  port_file="$TMP_ROOT/port.${BASHPID:-$$}.$RANDOM"
  pid_file="$port_file.pid"
  node "$LAUNCHER_JS" "$WRAPPER" "$pid_file" "$FAKEBIN/chrome-devtools-axi-real" \
    "$BRIDGE_JS" "$STOP_LOG" "$owner_session" "$session" "$port_file" "$mode"
  START_PID=$(cat "$pid_file")
  PIDS="$PIDS $START_PID"
  attempt=0
  while [ "$attempt" -lt 30 ] && [ ! -s "$port_file" ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -s "$port_file" ] || fail "fake bridge did not publish its health port"
  START_PORT=$(cat "$port_file")
  START_HELPER=
  if [ "$mode" = hang ] || [ "$mode" = stubborn-helper ]; then
    [ -s "$port_file.helper" ] || fail "hanging fake bridge did not publish its helper pid"
    attempt=0
    while [ "$attempt" -lt 30 ] && [ ! -s "$port_file.helper.ready" ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    [ -s "$port_file.helper.ready" ] || fail "fake bridge helper did not become signal-ready"
    START_HELPER=$(cat "$port_file.helper")
    PIDS="$PIDS $START_HELPER"
  fi
  printf '{"pid":%s,"port":%s}\n' "$START_PID" "$START_PORT" > "$dir/bridge.pid"
}

write_meta() {
  local home=$1 id=$2 session=$3 backend=${4:-} status_start=${5:-0} spawn_gen="test-$2"
  mkdir -p "$home/state"
  {
    printf 'window=ghost:one\n'
    printf 'harness=claude\n'
    printf 'kind=ship\n'
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'browser_session=%s\n' "$session"
    printf 'browser_status_gen=%s\n' "$spawn_gen"
    printf 'browser_status_start=%s\n' "$status_start"
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
  } > "$home/state/$id.meta"
}

assert_alive() {
  kill -0 "$1" 2>/dev/null || fail "$2"
}

assert_dead() {
  local attempt=0
  while [ "$attempt" -lt 30 ] && kill -0 "$1" 2>/dev/null; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if kill -0 "$1" 2>/dev/null; then
    fail "$2"
  fi
}

test_home_scoped_names_and_exact_cleanup() {
  local home_a home_b id session_a session_b pid_a pid_b out status
  home_a="$TMP_ROOT/home-a"
  home_b="$TMP_ROOT/home-b"
  id=browser-owner-a1
  mkdir -p "$home_a" "$home_b"
  session_a=$(browser_name "$home_a" "$id")
  session_b=$(browser_name "$home_b" "$id")
  [ "$session_a" != "$session_b" ] || fail "equal task ids in separate homes shared a browser session"
  case "$session_a:$session_b" in
    fm-[0-9a-f][0-9a-f]*:fm-[0-9a-f][0-9a-f]*) ;;
    *) fail "derived browser session names are malformed" ;;
  esac

  start_session "$session_a"; pid_a=$START_PID
  start_session "$session_b"; pid_b=$START_PID
  write_meta "$home_a" "$id" "$session_a"
  write_meta "$home_b" "$id" "$session_b"

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" cleanup "$home_a" "$home_a/state/$id.meta" 2>&1)
  status=$?
  expect_code 0 "$status" "exact task browser cleanup should succeed: $out"
  assert_dead "$pid_a" "cleanup left the selected task bridge alive"
  assert_alive "$pid_b" "cleanup touched the equal-id browser in another home"
  [ "$(cat "$STOP_LOG")" = "$session_a" ] || fail "cleanup stopped anything except the recorded exact session"
  pass "session identities are home-scoped and exact cleanup preserves neighboring sessions"
}

test_live_non_bridge_pid_is_never_signaled() {
  local home id session pid out status before
  home="$TMP_ROOT/non-bridge-home"
  id=browser-pid-guard-a1
  mkdir -p "$home"
  session=$(browser_name "$home" "$id")
  sleep 30 &
  pid=$!
  PIDS="$PIDS $pid"
  mkdir -p "$TEST_HOME/.chrome-devtools-axi/sessions/$session"
  printf '{"pid":%s,"port":65534}\n' "$pid" > "$TEST_HOME/.chrome-devtools-axi/sessions/$session/bridge.pid"
  write_meta "$home" "$id" "$session"
  before=$(wc -l < "$STOP_LOG" | tr -d ' ')

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" cleanup "$home" "$home/state/$id.meta" 2>&1)
  status=$?
  expect_code 1 "$status" "cleanup must refuse a live PID that is not the recorded tool's bridge"
  assert_contains "$out" "not chrome-devtools-axi's bridge" "PID ownership refusal was not explicit"
  assert_alive "$pid" "cleanup signaled an unrelated process from a stale PID file"
  [ "$(wc -l < "$STOP_LOG" | tr -d ' ')" = "$before" ] || fail "cleanup called stop for an unsafe PID"
  pass "PID reuse cannot turn exact browser cleanup into an unrelated signal"
}

test_live_bridge_for_another_session_is_never_signaled() {
  local home id session foreign_session foreign_pid foreign_port out status before
  home="$TMP_ROOT/reused-bridge-home"
  id=browser-reused-bridge-a1
  foreign_session=fm-1111111111111111111111111111111111111111
  mkdir -p "$home"
  session=$(browser_name "$home" "$id")
  start_session "$session" "$foreign_session"
  foreign_pid=$START_PID
  foreign_port=$START_PORT
  mkdir -p "$TEST_HOME/.chrome-devtools-axi/sessions/$session"
  printf '{"pid":%s,"port":%s}\n' "$foreign_pid" "$foreign_port" \
    > "$TEST_HOME/.chrome-devtools-axi/sessions/$session/bridge.pid"
  write_meta "$home" "$id" "$session"
  before=$(wc -l < "$STOP_LOG" | tr -d ' ')

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" cleanup "$home" "$home/state/$id.meta" 2>&1)
  status=$?
  expect_code 1 "$status" "cleanup must refuse a bridge serving another session"
  assert_contains "$out" "did not accept its identity-bound shutdown request" "session-identity refusal was not explicit"
  assert_alive "$foreign_pid" "cleanup signaled another session's live bridge"
  [ "$(wc -l < "$STOP_LOG" | tr -d ' ')" = "$before" ] || fail "cleanup called stop for another session's bridge"
  pass "identity changes after health cannot cross the shutdown boundary"
}

test_worker_stop_uses_identity_bound_shutdown() {
  local home id session pid out status before
  home="$TMP_ROOT/worker-stop-home"
  id=browser-worker-stop-a1
  mkdir -p "$home"
  session=$(browser_name "$home" "$id")
  start_session "$session"
  pid=$START_PID
  before=$(wc -l < "$STOP_LOG" | tr -d ' ')

  out=$(HOME="$TEST_HOME" CHROME_DEVTOOLS_AXI_SESSION="$session" \
    FM_CHROME_DEVTOOLS_AXI_REAL="$FAKEBIN/chrome-devtools-axi-real" \
    FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" "$WRAPPER" stop 2>&1)
  status=$?
  expect_code 0 "$status" "worker stop should use the task bridge's shutdown endpoint: $out"
  assert_dead "$pid" "worker stop left its exact task bridge alive"
  [ "$(wc -l < "$STOP_LOG" | tr -d ' ')" = "$((before + 1))" ] || fail "worker stop invoked the PID-directed real CLI"
  pass "worker stop uses the same identity-bound shutdown endpoint"
}

test_hanging_shutdown_escalates_only_exact_process_group() {
  local home target_id neighbor_id target_session neighbor_session target_pid helper_pid neighbor_pid out status
  home="$TMP_ROOT/hanging-shutdown-home"
  target_id=browser-hanging-a1
  neighbor_id=browser-hanging-neighbor-a1
  mkdir -p "$home"
  target_session=$(browser_name "$home" "$target_id")
  neighbor_session=$(browser_name "$home" "$neighbor_id")
  start_session "$target_session" "$target_session" hang
  target_pid=$START_PID
  helper_pid=$START_HELPER
  start_session "$neighbor_session"
  neighbor_pid=$START_PID
  write_meta "$home" "$target_id" "$target_session"
  write_meta "$home" "$neighbor_id" "$neighbor_session"

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" cleanup "$home" "$home/state/$target_id.meta" 2>&1)
  status=$?
  expect_code 0 "$status" "hanging task browser cleanup should escalate successfully: $out"
  assert_dead "$target_pid" "escalation left the hanging bridge alive"
  assert_dead "$helper_pid" "escalation left a helper in the exact browser process group alive"
  assert_alive "$neighbor_pid" "escalation touched an unrelated active browser process group"
  pass "hanging shutdown escalates only the identity-bound process group"
}

test_graceful_shutdown_reaps_sigterm_resistant_helpers() {
  local home target_id neighbor_id target_session neighbor_session target_pid helper_pid neighbor_pid out status
  home="$TMP_ROOT/graceful-stubborn-home"
  target_id=browser-graceful-stubborn-a1
  neighbor_id=browser-graceful-neighbor-a1
  mkdir -p "$home"
  target_session=$(browser_name "$home" "$target_id")
  neighbor_session=$(browser_name "$home" "$neighbor_id")
  start_session "$target_session" "$target_session" stubborn-helper
  target_pid=$START_PID
  helper_pid=$START_HELPER
  start_session "$neighbor_session"
  neighbor_pid=$START_PID
  write_meta "$home" "$target_id" "$target_session"
  write_meta "$home" "$neighbor_id" "$neighbor_session"

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" cleanup "$home" "$home/state/$target_id.meta" 2>&1)
  status=$?
  expect_code 0 "$status" "graceful browser cleanup should reap a resistant helper: $out"
  assert_dead "$target_pid" "graceful shutdown left the bridge alive"
  assert_dead "$helper_pid" "watchdog died before reaping a SIGTERM-resistant helper"
  assert_alive "$neighbor_pid" "graceful escalation touched an unrelated active process group"
  pass "graceful shutdown keeps exact-group escalation alive for resistant helpers"
}

test_terminal_sweep_closes_only_terminal_owner() {
  local home terminal_id active_id terminal_session active_session terminal_pid restarted_pid active_pid out signature
  home="$TMP_ROOT/terminal-home"
  terminal_id=browser-terminal-a1
  active_id=browser-active-a1
  mkdir -p "$home"
  terminal_session=$(browser_name "$home" "$terminal_id")
  active_session=$(browser_name "$home" "$active_id")
  start_session "$terminal_session"; terminal_pid=$START_PID
  start_session "$active_session"; active_pid=$START_PID
  write_meta "$home" "$terminal_id" "$terminal_session"
  write_meta "$home" "$active_id" "$active_session"
  printf 'done: implementation committed\n' > "$home/state/$terminal_id.status"
  printf 'working: browser check in progress\n' > "$home/state/$active_id.status"

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" sweep "$home" "$home/state")
  [ -z "$out" ] || fail "successful terminal cleanup should stay silent: $out"
  assert_dead "$terminal_pid" "terminal sweep left the terminal task browser alive"
  assert_alive "$active_pid" "terminal sweep touched the active task browser"

  # A later browser command can start a fresh bridge under the same assignment.
  # Terminal recovery must bind dedupe to the bridge incarnation, not suppress
  # cleanup forever merely because the status line did not change.
  start_session "$terminal_session"; restarted_pid=$START_PID
  signature=$(printf '%s' 'done: implementation committed' | cksum | awk -v pid="$restarted_pid" '{print $1 ":" $2 ":" pid}')
  printf '%s\n' "$signature" > "$home/state/.$terminal_id.browser-terminal-cleaned"
  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" sweep "$home" "$home/state")
  [ -z "$out" ] || fail "restarted terminal cleanup should stay silent: $out"
  assert_dead "$restarted_pid" "terminal sweep ignored a later bridge incarnation"
  assert_alive "$active_pid" "terminal resweep touched the active task browser"
  pass "terminal recovery cannot be suppressed by a reused-PID cleanup marker"
}

test_terminal_sweep_ignores_status_before_current_spawn() {
  local home id session pid old_bytes out
  home="$TMP_ROOT/relaunch-status-home"
  id=browser-relaunch-active-a1
  mkdir -p "$home/state"
  session=$(browser_name "$home" "$id")
  printf 'done: previous worker finished\n' > "$home/state/$id.status"
  old_bytes=$(wc -c < "$home/state/$id.status" | tr -d '[:space:]')
  start_session "$session"; pid=$START_PID
  write_meta "$home" "$id" "$session" '' "$old_bytes"

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" sweep "$home" "$home/state")
  [ -z "$out" ] || fail "stale pre-spawn terminal status should stay silent: $out"
  assert_alive "$pid" "stale terminal status closed the active replacement browser"

  printf 'done: replacement worker finished\n' >> "$home/state/$id.status"
  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    "$BROWSER" sweep "$home" "$home/state")
  [ -z "$out" ] || fail "current-spawn terminal cleanup should stay silent: $out"
  assert_dead "$pid" "current-spawn terminal status did not close its browser"
  pass "terminal cleanup authority begins at the current spawn generation"
}

test_idle_detection_warns_uncertain_and_closes_orphan() {
  local home id session pid session_dir out
  home="$TMP_ROOT/idle-home"
  id=browser-idle-a1
  mkdir -p "$home"
  session=$(browser_name "$home" "$id")
  start_session "$session"; pid=$START_PID
  write_meta "$home" "$id" "$session" unsupported
  printf 'working: waiting for browser evidence\n' > "$home/state/$id.status"
  session_dir="$TEST_HOME/.chrome-devtools-axi/sessions/$session"
  touch -t 200001010000 "$session_dir"/*

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    FM_BROWSER_IDLE_TIMEOUT_SECS=1 "$BROWSER" sweep "$home" "$home/state")
  assert_contains "$out" "task=$id" "idle session warning omitted its owner"
  assert_contains "$out" "owner=unverified" "uncertain owner did not take the preserving warning path"
  assert_alive "$pid" "idle detection killed a session whose owner was not authoritatively gone"

  # The verified tmux adapter now reports the exact recorded endpoint missing.
  write_meta "$home" "$id" "$session"
  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_BROWSER_STOP_LOG="$STOP_LOG" \
    FM_BROWSER_IDLE_TIMEOUT_SECS=1 "$BROWSER" sweep "$home" "$home/state")
  [ -z "$out" ] || fail "successful orphan cleanup should stay silent: $out"
  assert_dead "$pid" "idle orphan sweep left a browser whose worker endpoint was authoritatively missing"
  pass "idle sessions are detected after the bound and only proven orphans are closed"
}

test_owned_process_counts_and_capacity_warning_rearm() {
  local home out
  home="$TMP_ROOT/capacity-home"
  mkdir -p "$home/state"

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_PS_MODE=busy "$BROWSER" count)
  [ "$out" = 'roots=1 helpers=2' ] || fail "owned process graph count was wrong or included unrelated Chrome: $out"

  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_PS_MODE=busy \
    FM_BROWSER_ROOT_WARN=1 FM_BROWSER_HELPER_WARN=2 "$BROWSER" sweep "$home" "$home/state")
  assert_contains "$out" "browser capacity roots=1/1 helpers=2/2" "capacity threshold did not warn at its configured boundary"
  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_PS_MODE=busy \
    FM_BROWSER_ROOT_WARN=1 FM_BROWSER_HELPER_WARN=2 "$BROWSER" sweep "$home" "$home/state")
  [ -z "$out" ] || fail "unchanged capacity pressure warned more than once: $out"

  HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_PS_MODE=empty \
    FM_BROWSER_ROOT_WARN=1 FM_BROWSER_HELPER_WARN=2 "$BROWSER" sweep "$home" "$home/state" >/dev/null
  out=$(HOME="$TEST_HOME" PATH="$FAKEBIN:$PATH" FM_FAKE_PS_MODE=busy \
    FM_BROWSER_ROOT_WARN=1 FM_BROWSER_HELPER_WARN=2 "$BROWSER" sweep "$home" "$home/state")
  assert_contains "$out" "browser capacity" "capacity warning did not rearm after pressure cleared"
  pass "capacity warnings count only owned trees, deduplicate, and rearm after recovery"
}

test_home_scoped_names_and_exact_cleanup
test_live_non_bridge_pid_is_never_signaled
test_live_bridge_for_another_session_is_never_signaled
test_worker_stop_uses_identity_bound_shutdown
test_hanging_shutdown_escalates_only_exact_process_group
test_graceful_shutdown_reaps_sigterm_resistant_helpers
test_terminal_sweep_closes_only_terminal_owner
test_terminal_sweep_ignores_status_before_current_spawn
test_idle_detection_warns_uncertain_and_closes_orphan
test_owned_process_counts_and_capacity_warning_rearm
