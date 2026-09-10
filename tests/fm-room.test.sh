#!/usr/bin/env bash
# Behavior tests for bin/fm-room.sh's pinned Agent Room lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOM="$ROOT/bin/fm-room.sh"
TMP_ROOT=$(fm_test_tmproot fm-room)

make_fixture_repo() {
  local repo=$1 sha
  mkdir -p "$repo/scripts"
  git -C "$repo" init -q
  cat >"$repo/install.sh" <<'SH'
#!/usr/bin/env bash
printf 'install.sh was executed\n' >"${FM_ROOM_INSTALL_MARKER:?}"
SH
  chmod +x "$repo/install.sh"
  cat >"$repo/scripts/agent_room.mjs" <<'NODE'
#!/usr/bin/env node
import http from "node:http";
import fs from "node:fs";
import process from "node:process";
const host = process.env.AGENT_ROOM_HOST || "127.0.0.1";
const port = Number(process.env.AGENT_ROOM_PORT || 7331);
const home = process.env.AGENT_ROOM_HOME;
const statePath = `${home}/rooms.json`;
const pidPath = `${home}/server.pid`;
const load = () => fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, "utf8")) : { rooms: {} };
const save = state => { fs.mkdirSync(home, { recursive: true }); fs.writeFileSync(statePath, JSON.stringify(state, null, 2)); };
const send = (res, status, value) => { const body = JSON.stringify(value); res.writeHead(status, { "content-type": "application/json" }); res.end(body); };
const read = req => new Promise((resolve, reject) => { let body = ""; req.on("data", chunk => { body += chunk; }); req.on("end", () => { try { resolve(body ? JSON.parse(body) : {}); } catch (error) { reject(error); } }); });
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${host}:${port}`);
  if (req.method === "GET" && url.pathname === "/api/health") { send(res, 200, { ok: true, version: "fixture" }); return; }
  if (req.method === "POST" && url.pathname === "/api/rooms") {
    if (process.env.FM_ROOM_CREATE_DELAY) await new Promise(resolve => setTimeout(resolve, Number(process.env.FM_ROOM_CREATE_DELAY)));
    if (process.env.FM_ROOM_CREATE_FAIL === "1") { send(res, 500, { error: "fixture create failure" }); return; }
    const body = await read(req); const state = load(); const room = { code: "AM-TEST", title: body.title, objective: body.objective, status: "open", next_message_id: 2, participants: [], messages: [{ id: 1, kind: "agent", sender: body.name || "Lead", content: "gap\nwith counterexample", created_at: "2026-09-02T00:00:00Z" }] };
    state.rooms[room.code] = room; save(state); send(res, 201, { ...room, viewer_url: `http://${host}:${port}/rooms/${room.code}`, invitation: `Use the agent-room skill to join room: http://${host}:${port}/rooms/${room.code}` }); return;
  }
  const roomMatch = url.pathname.match(/^\/api\/rooms\/([^/]+)(?:\/(join|messages))?$/);
  if (roomMatch) {
    const state = load(); const room = state.rooms[roomMatch[1]];
    if (!room) { send(res, 404, { error: "missing" }); return; }
    if (req.method === "GET" && !roomMatch[2]) { send(res, 200, room); return; }
    if (req.method === "POST" && roomMatch[2] === "join") {
      const body = await read(req); room.participants = room.participants || [];
      const name = String(body.name || "Agent").trim().slice(0, 80) || "Agent";
      if (!room.participants.some(person => person.name.toLowerCase() === name.toLowerCase())) room.participants.push({ name, last_read_id: room.next_message_id - 1 });
      save(state); send(res, 200, room); return;
    }
    if (req.method === "POST" && roomMatch[2] === "messages") {
      const body = await read(req); const name = String(body.name || "Agent").trim().slice(0, 80) || "Agent";
      const content = String(body.content || "").trim();
      if (!content) { send(res, 400, { error: "Content is required" }); return; }
      if (!room.participants.some(person => person.name.toLowerCase() === name.toLowerCase())) room.participants.push({ name, last_read_id: room.next_message_id - 1 });
      if (process.env.FM_ROOM_MESSAGE_DELAY) await new Promise(resolve => setTimeout(resolve, Number(process.env.FM_ROOM_MESSAGE_DELAY)));
      const message = { id: room.next_message_id++, kind: "agent", sender: name, content: content.slice(0, 20000), created_at: "2026-09-02T00:00:01Z" };
      room.messages.push(message);
      save(state); send(res, 201, { message }); return;
    }
    if (req.method === "GET" && roomMatch[2] === "messages") {
      const name = url.searchParams.get("name"); const participant = (room.participants || []).find(person => person.name === name);
      const after = participant ? participant.last_read_id : Number(url.searchParams.get("after") || 0);
      const messages = room.messages.filter(message => message.id > after && message.sender !== name);
      if (participant) { participant.last_read_id = room.next_message_id - 1; save(state); }
      send(res, 200, { messages }); return;
    }
  }
  send(res, 404, { error: "not found" });
});
if (process.argv[2] === "serve") {
  fs.mkdirSync(home, { recursive: true });
  server.listen(port, host, () => {
    fs.writeFileSync(pidPath, String(process.pid));
    if (process.env.FM_ROOM_TEST_PID_FILE) fs.writeFileSync(process.env.FM_ROOM_TEST_PID_FILE, String(process.pid));
  });
  const close = () => {
    const finish = () => server.close(() => { try { if (fs.readFileSync(pidPath, "utf8").trim() === String(process.pid)) fs.unlinkSync(pidPath); } catch {} process.exit(0); });
    if (process.env.FM_ROOM_TERM_DELAY) setTimeout(finish, Number(process.env.FM_ROOM_TERM_DELAY)); else finish();
  };
  process.on("SIGTERM", close); process.on("SIGINT", close);
} else if (process.argv[2] === "create") {
  const body = JSON.parse(process.env.FM_ROOM_CREATE_BODY);
  fetch(`http://${host}:${port}/api/rooms`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }).then(response => response.json()).then(room => console.log(room.invitation));
}
NODE
  chmod +x "$repo/scripts/agent_room.mjs"
  git -C "$repo" add .
  git -C "$repo" -c user.name='fm-room tests' -c user.email='tests@example.invalid' commit -qm fixture
  sha=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$sha"
}

setup_fixture() {
  local home=$1 repo=$2 pin=$3
  export FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_REPO_URL="$repo" FM_ROOM_PIN_OVERRIDE="$pin"
  "$ROOM" setup >/dev/null || fail "fixture Agent Room setup failed"
}

start_fixture() {
  local home=$1 review=$2
  FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start "$review"
}

stop_fixture() {
  local home=$1 review=$2
  FM_HOME="$home" "$ROOM" stop "$review" >/dev/null 2>&1 || true
}

fixture_repo_and_home() {
  local name=$1 repo pin home
  repo="$TMP_ROOT/$name/repo"
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home"
  pin=$(make_fixture_repo "$repo")
  printf '%s\n%s\n%s\n' "$repo" "$home" "$pin"
}

test_setup_verifies_pin_and_never_installs() {
  local repo home pin marker out
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home setup)
  marker="$home/install-marker"
  out=$(FM_ROOM_INSTALL_MARKER="$marker" FM_HOME="$home" FM_ROOM_TESTING=1 \
    FM_ROOM_REPO_URL="$repo" FM_ROOM_PIN_OVERRIDE="$pin" "$ROOM" setup 2>&1) \
    || fail "setup failed: $out"
  [ "$(git -C "$home/state/tools/agent-room" rev-parse HEAD)" = "$pin" ] \
    || fail "setup did not check out the pinned commit"
  [ ! -e "$marker" ] || fail "setup executed the untrusted install.sh"
  pass "setup verifies the pinned commit without running install.sh"
}

test_setup_refuses_pin_drift() {
  local repo home pin out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home drift)
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_REPO_URL="$repo" \
    FM_ROOM_PIN_OVERRIDE=0000000000000000000000000000000000000000 "$ROOM" setup 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "setup accepted a commit different from its pin"
  assert_contains "$out" "pinned commit" "pin drift refusal did not name the pinned commit"
  pass "setup refuses a commit that does not match the pin"
}

test_port_in_use_is_refused() {
  local repo home pin port py out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home port)
  setup_fixture "$home" "$repo" "$pin"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
  py="$home/hold-port.py"
  cat >"$py" <<PY
import socket, time
s=socket.socket(); s.bind(("127.0.0.1", $port)); s.listen(); time.sleep(30)
PY
  python3 "$py" &
  local holder=$!
  sleep 0.1
  mkdir -p "$home/fakebin"
  cat >"$home/fakebin/python3" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$home/fakebin/python3"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_PORT="$port" "$ROOM" start port-review 2>&1) || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "${rc:-0}" -ne 0 ] || fail "start accepted a port already bound by another process"
  assert_contains "$out" "already bound" "port refusal did not identify the bound port"
  pass "start refuses a port already bound by another process"
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

test_room_state_is_private_under_open_umask() {
  local repo home pin out old_umask
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home private-mode)
  setup_fixture "$home" "$repo" "$pin"
  old_umask=$(umask)
  umask 000
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start private-mode-review 2>&1) || fail "private-mode start failed: $out"
  umask "$old_umask"
  [ "$(file_mode "$home/state/rooms")" = 700 ] || fail "rooms directory was not private"
  [ "$(file_mode "$home/state/rooms/private-mode-review")" = 700 ] \
    || fail "review directory was not private"
  stop_fixture "$home" private-mode-review
  pass "room state directories stay private under an open caller umask"
}

test_concurrent_start_is_serialized() {
  local repo home pin out_one out_two rc_one rc_two
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home concurrent)
  setup_fixture "$home" "$repo" "$pin"
  FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node FM_ROOM_CREATE_DELAY=1000 \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start concurrent-review >"$home/one.out" 2>&1 &
  local one=$!
  FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node FM_ROOM_CREATE_DELAY=1000 \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start concurrent-review >"$home/two.out" 2>&1 &
  local two=$!
  wait "$one" || rc_one=$?
  wait "$two" || rc_two=$?
  out_one=$(cat "$home/one.out")
  out_two=$(cat "$home/two.out")
  [ "${rc_one:-0}" -eq 0 ] || [ "${rc_two:-0}" -eq 0 ] \
    || fail "concurrent starts both failed"
  [ "${rc_one:-0}" -ne 0 ] || [ "${rc_two:-0}" -ne 0 ] \
    || fail "concurrent starts both claimed the review"
  assert_contains "$out_one$out_two" "start already in progress" \
    "concurrent start refusal did not identify the review lock"
  stop_fixture "$home" concurrent-review
  pass "concurrent starts serialize one review transition"
}

test_failed_create_rolls_back_server() {
  local repo home pin out rc pid
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home rollback)
  setup_fixture "$home" "$repo" "$pin"
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node FM_ROOM_CREATE_FAIL=1 \
    FM_ROOM_TERM_DELAY=200 FM_ROOM_TEST_PID_FILE="$home/original.pid" \
    "$ROOM" start rollback-review 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "start accepted a fixture create failure"
  [ ! -f "$home/state/rooms/rollback-review/server.pid" ] \
    || fail "failed room creation stranded a server pid"
  pid=$(cat "$home/original.pid")
  ! kill -0 "$pid" 2>/dev/null || fail "rollback returned before the original server exited"
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start rollback-review 2>&1) || fail "retry after create failure failed: $out"
  stop_fixture "$home" rollback-review
  pass "failed room creation rolls back before a retry"
}

test_start_prints_observer_join_and_warning() {
  local repo home pin out
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home start-output)
  setup_fixture "$home" "$repo" "$pin"
  out=$(start_fixture "$home" start-output-review)
  assert_contains "$out" "Observer URL: http://127.0.0.1:" "start did not print a localhost observer URL"
  assert_contains "$out" "Join command:" "start did not print a join command"
  assert_contains "$out" "no auth" "start did not print the no-auth warning"
  stop_fixture "$home" start-output-review
  pass "start prints the observer URL, join command, and no-auth warning"
}

test_pid_identity_ps_is_locale_and_width_stable() {
  local repo home pin fakebin log out
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home ps-locale)
  setup_fixture "$home" "$repo" "$pin"
  fakebin="$home/fakebin"
  log="$home/ps.log"
  mkdir -p "$fakebin"
  cat >"$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${LC_ALL-<unset>}" "${COLUMNS-<unset>}" >>"$FAKE_PS_LOG"
case " $* " in
  *' lstart= '*) printf 'Mon Jul 28 20:00:00 2026\n' ;;
  *) printf '/usr/bin/node fixture/scripts/agent_room.mjs serve --fm-room-review=ps-locale-review\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" FAKE_PS_LOG="$log" LC_ALL=fr_FR.UTF-8 COLUMNS=7 \
    FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start ps-locale-review 2>&1) || fail "locale probe start failed: $out"
  out=$(PATH="$fakebin:$PATH" FAKE_PS_LOG="$log" LC_ALL=fr_FR.UTF-8 COLUMNS=7 \
    FM_HOME="$home" "$ROOM" stop ps-locale-review 2>&1) \
    || fail "locale probe stop failed: $out"
  while IFS='|' read -r locale columns; do
    [ "$locale" = C ] && [ "$columns" = 200 ] \
      || fail "PID ps probe was not stabilized (saw ${locale:-<unset>}|${columns:-<unset>})"
  done <"$log"
  pass "PID ownership ps probes stabilize locale and output width"
}

test_transcript_path_comparison_is_canonical() {
  local repo home pin alias out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home canonical-transcript)
  setup_fixture "$home" "$repo" "$pin"
  start_fixture "$home" canonical-transcript-review >/dev/null
  mkdir -p "$home/alias"
  alias="$home/alias/../state"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$alias" "$ROOM" transcript canonical-transcript-review 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "non-canonical state spelling bypassed transcript boundary"
  assert_contains "$out" "outside room state" \
    "canonical transcript boundary refusal did not identify the output boundary"
  stop_fixture "$home" canonical-transcript-review
  pass "transcript state separation uses canonical paths"
}

test_transcript_cannot_write_inside_state() {
  local repo home pin out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home transcript-state)
  setup_fixture "$home" "$repo" "$pin"
  start_fixture "$home" transcript-state-review >/dev/null
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/state" "$ROOM" transcript transcript-state-review 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "transcript export wrote into room state"
  assert_contains "$out" "outside room state" \
    "state-polluting transcript refusal did not identify the output boundary"
  stop_fixture "$home" transcript-state-review
  pass "transcript export refuses a state-polluting destination"
}

test_join_cmd_refuses_symlinked_review() {
  local repo home pin outside out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home join-link)
  setup_fixture "$home" "$repo" "$pin"
  outside="$home/outside-review"
  mkdir -p "$outside" "$home/state/rooms"
  cat >"$outside/meta" <<EOF
room_code=AM-TEST
port=7331
EOF
  ln -s "$outside" "$home/state/rooms/join-link-review"
  out=$(FM_HOME="$home" "$ROOM" join-cmd join-link-review Lead 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "join-cmd followed a symlinked review directory"
  assert_contains "$out" "symlink" "join-cmd symlink refusal did not identify the unsafe path"
  pass "join-cmd refuses symlinked review directories"
}

test_state_ancestor_symlink_is_refused() {
  local repo home pin outside out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home state-link)
  setup_fixture "$home" "$repo" "$pin"
  outside="$home/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$home/state/rooms"
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start state-link-review 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "start followed a symlinked rooms ancestor"
  assert_contains "$out" "symlink" "ancestor symlink refusal did not identify the unsafe path"
  pass "start refuses symlinked state ancestors"
}

test_preexisting_output_links_are_refused() {
  local repo home pin room_dir outside out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home output-link)
  setup_fixture "$home" "$repo" "$pin"
  room_dir="$home/state/rooms/output-link-review"
  outside="$home/outside.log"
  mkdir -p "$room_dir"
  : >"$outside"
  ln -s "$outside" "$room_dir/server.log"
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start output-link-review 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "start followed a pre-existing server log symlink"
  assert_contains "$out" "symlink" "pre-existing output link refusal did not identify the unsafe path"
  rm "$room_dir/server.log"
  : >"$home/outside-hardlink.log"
  ln "$home/outside-hardlink.log" "$room_dir/server.log"
  rc=
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start output-link-review 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "start accepted a multiply-linked server log"
  assert_contains "$out" "multiply-linked" "hardlink refusal did not identify the unsafe path"
  pass "start refuses pre-existing symlink and hardlink outputs"
}

test_status_recovers_crashed_room() {
  local repo home pin pid out
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home status-crash)
  setup_fixture "$home" "$repo" "$pin"
  start_fixture "$home" status-crash-review >/dev/null
  pid=$(cat "$home/state/rooms/status-crash-review/server.pid")
  kill -KILL "$pid" 2>/dev/null || fail "could not crash fixture room"
  out=$(FM_HOME="$home" "$ROOM" status 2>&1) || fail "status failed to recover crashed room: $out"
  assert_contains "$out" "status=stopped" "status did not reconcile the crashed room"
  [ ! -e "$home/state/rooms/status-crash-review/server.pid" ] \
    || fail "status retained crashed room pid metadata"
  pass "status recovers a crashed room before stop"
}

test_empty_start_lock_is_recovered() {
  local repo home pin out
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home empty-lock)
  setup_fixture "$home" "$repo" "$pin"
  mkdir -p "$home/state/rooms/empty-lock-review"
  : >"$home/state/rooms/empty-lock-review/.start.lock"
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start empty-lock-review 2>&1) || fail "start did not recover an incomplete lock: $out"
  stop_fixture "$home" empty-lock-review
  pass "start recovers an incomplete crashed lock publication"
}

test_hardlinked_crashed_start_lock_is_recovered() {
  local repo home pin dir candidate out
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home hardlinked-lock)
  setup_fixture "$home" "$repo" "$pin"
  dir="$home/state/rooms/hardlinked-lock-review"
  mkdir -p "$dir"
  candidate="$dir/.start.lock.999999"
  printf '999999\nold-start\n' >"$candidate"
  ln "$candidate" "$dir/.start.lock"
  out=$(FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start hardlinked-lock-review 2>&1) \
    || fail "start did not recover a hardlinked crashed lock: $out"
  [ ! -e "$dir/.start.lock" ] || fail "recovered lock remained after start"
  [ ! -e "$candidate" ] || fail "recovered lock candidate remained after start"
  stop_fixture "$home" hardlinked-lock-review
  pass "start recovers a hardlinked crashed lock publication"
}

test_status_refuses_symlinked_review_before_cleanup() {
  local repo home pin outside out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home status-link)
  setup_fixture "$home" "$repo" "$pin"
  outside="$home/outside-review"
  mkdir -p "$outside" "$home/state/rooms"
  printf 'review_id=status-link-review\nstatus=active\n' >"$outside/meta"
  printf '999999\n' >"$outside/server.pid"
  ln -s "$outside" "$home/state/rooms/status-link-review"
  out=$(FM_HOME="$home" "$ROOM" status 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "status followed a symlinked review directory"
  assert_contains "$out" "symlink" "status symlink refusal did not identify the unsafe path"
  [ -f "$outside/server.pid" ] || fail "status deleted a symlink-target pid file"
  pass "status validates review paths before stale cleanup"
}

test_chmod_failure_is_fatal() {
  local repo home pin out rc
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home chmod-failure)
  setup_fixture "$home" "$repo" "$pin"
  mkdir -p "$home/fakebin"
  cat >"$home/fakebin/chmod" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/chmod"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_TESTING=1 FM_ROOM_RUNTIME=node \
    FM_ROOM_CREATE_BODY='{"title":"gap review","objective":"find gaps","name":"Lead"}' \
    "$ROOM" start chmod-failure-review 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "start continued after chmod failure"
  assert_contains "$out" "secure" "chmod failure did not fail closed"
  pass "permission hardening fails closed"
}

test_stop_is_idempotent_after_clean_stop() {
  local repo home pin out
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home repeat-stop)
  setup_fixture "$home" "$repo" "$pin"
  start_fixture "$home" repeat-stop-review >/dev/null
  FM_HOME="$home" "$ROOM" stop repeat-stop-review >/dev/null \
    || fail "first stop failed"
  out=$(FM_HOME="$home" "$ROOM" stop repeat-stop-review 2>&1) \
    || fail "repeated stop was not idempotent: $out"
  pass "stop is idempotent after a clean stop"
}

test_stop_refuses_foreign_pid() {
  local repo home pin out rc pid
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home pid)
  setup_fixture "$home" "$repo" "$pin"
  start_fixture "$home" pid-review >/dev/null
  pid=$(cat "$home/state/rooms/pid-review/server.pid")
  printf '%s\n' "$$" >"$home/state/rooms/pid-review/server.pid"
  out=$(FM_HOME="$home" "$ROOM" stop pid-review 2>&1) || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "stop accepted a foreign pid"
  assert_contains "$out" "foreign" "foreign pid refusal did not name ownership"
  printf '%s\n' "$pid" >"$home/state/rooms/pid-review/server.pid"
  stop_fixture "$home" pid-review
  printf '%s\n' 999999 >"$home/state/rooms/pid-review/server.pid"
  rc=
  out=$(FM_HOME="$home" "$ROOM" stop pid-review 2>&1) \
    || fail "stop did not recover a dead pid: $out"
  [ ! -e "$home/state/rooms/pid-review/server.pid" ] \
    || fail "stale pid metadata was not removed after recovery"
  assert_contains "$out" "recovered" "stale pid recovery did not identify the transition"
  pass "stop refuses foreign pids and recovers dead pid metadata"
}

test_transcript_export_shape() {
  local repo home pin out
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home transcript)
  setup_fixture "$home" "$repo" "$pin"
  start_fixture "$home" transcript-review >/dev/null
  out=$(FM_HOME="$home" "$ROOM" transcript transcript-review 2>&1) \
    || fail "transcript export failed: $out"
  [ -f "$home/data/transcript-review/room.json" ] || fail "raw room json was not exported"
  [ -f "$home/data/transcript-review/transcript.txt" ] || fail "transcript was not exported"
  jq -e '.rooms["AM-TEST"].messages[0].content == "gap\nwith counterexample"' \
    "$home/data/transcript-review/room.json" >/dev/null \
    || fail "raw room json was not preserved"
  assert_grep 'gap' "$home/data/transcript-review/transcript.txt" \
    "transcript did not contain the room message"
  stop_fixture "$home" transcript-review
  pass "transcript exports raw room JSON and message text"
}

make_handoff_stubs() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] || exit 0
    printf '%s\n' "${1:-}" >> "${FM_HANDOFF_SEND_LOG:?}"
    if [ -n "${FM_ACK_RECORD:-}" ] && [ -f "$FM_ACK_RECORD" ]; then
      mv "$FM_ACK_RECORD" "${FM_ACK_RECORD%/*}/handled/"
    fi
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf 'claude\n'; exit 0 ;;
        *pane_tty*) printf '/dev/ttys001\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-receiver\n' ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · validating (running)\n'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
}

test_handoff_publishes_and_custodies_one_packet() {
  local repo home pin dir out rec body messages retry conflict_rc handled_retry
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home handoff)
  setup_fixture "$home" "$repo" "$pin"
  make_handoff_stubs "$home"
  fm_write_meta "$home/state/receiver.meta" "window=sess:fm-receiver" "kind=ship" "harness=claude"
  start_fixture "$home" handoff-review >/dev/null
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-review "  Publisher  " receiver packet-1 $'  actionable packet \n' 2>&1) \
    || fail "handoff did not publish and enqueue: $out"
  assert_contains "$out" "packet #2" "handoff did not report the room packet identity"
  [ -f "$home/state/receiver.inbox/001.msg" ] || fail "handoff did not create the durable recipient record"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/receiver.inbox/001.msg")
  assert_contains "$body" "AM-TEST" "recipient record omitted the room identity"
  assert_contains "$body" "packet 2" "recipient record omitted the packet identity"
  assert_contains "$body" "packet-1" "recipient record omitted the stable handoff key"
  messages=$(jq -r '.rooms["AM-TEST"].messages | length' "$home/state/rooms/handoff-review/rooms.json")
  [ "$messages" = 2 ] || fail "handoff should publish exactly one room packet, got $messages"
  jq -e '.rooms["AM-TEST"].messages[1].content | startswith("fm-room-handoff.v1 key=packet-1 recipient=receiver")' \
    "$home/state/rooms/handoff-review/rooms.json" >/dev/null \
    || fail "room packet did not retain its handoff identity"
  retry=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-review "  Publisher  " receiver packet-1 $'  actionable packet \n' 2>&1) \
    || fail "an identical handoff retry failed: $retry"
  assert_contains "$retry" "packet #2" "an identical retry did not reuse the room packet"
  messages=$(jq -r '.rooms["AM-TEST"].messages | length' "$home/state/rooms/handoff-review/rooms.json")
  [ "$messages" = 2 ] || fail "an identical retry published a duplicate room packet"
  [ "$(find "$home/state/receiver.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "an identical retry created a duplicate recipient record"
  conflict_rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-review Publisher receiver packet-1 "changed packet" 2>&1) || conflict_rc=$?
  [ "$conflict_rc" -ne 0 ] || fail "a changed payload reused an existing handoff key"
  assert_contains "$out" "different room packet" "changed payload did not fail as a loud key conflict"
  fm_write_meta "$home/state/secondmate.meta" "window=sess:fm-secondmate" "kind=secondmate" "mode=secondmate"
  conflict_rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-review Publisher secondmate packet-2 "remote packet" 2>&1) || conflict_rc=$?
  [ "$conflict_rc" -ne 0 ] || fail "a secondmate recipient was accepted by room handoff"
  assert_contains "$out" "local ordinary task recipients" "secondmate rejection was not explicit"
  rec="$home/state/receiver.inbox/001.msg"
  mv "$rec" "$home/state/receiver.inbox/handled/"
  [ -f "$home/state/receiver.inbox/handled/001.msg" ] || fail "the consumed handoff record was not retained in handled/"
  handled_retry=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-review "  Publisher  " receiver packet-1 $'  actionable packet \n' 2>&1) \
    || fail "a handled handoff retry failed: $handled_retry"
  assert_contains "$handled_retry" "packet #2" "a handled retry did not reuse the room packet"
  [ "$(find "$home/state/receiver.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 0 ] \
    || fail "a handled retry created a new recipient record"
  stop_fixture "$home" handoff-review
  pass "handoff retries idempotently, rejects changed payloads, and preserves consumed custody"
}

test_handoff_rejects_sender_newline_before_publication() {
  local repo home pin out rc messages
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home handoff-sender-newline)
  setup_fixture "$home" "$repo" "$pin"
  make_handoff_stubs "$home"
  fm_write_meta "$home/state/receiver.meta" "window=sess:fm-receiver" "kind=ship" "harness=claude"
  start_fixture "$home" handoff-sender-newline-review >/dev/null
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-sender-newline-review $'Publisher\nExtra' receiver packet-newline "payload" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an embedded sender newline was accepted"
  assert_contains "$out" "could not be normalized" "embedded sender newline was not rejected before serialization"
  messages=$(jq -r '.rooms["AM-TEST"].messages | length' "$home/state/rooms/handoff-sender-newline-review/rooms.json")
  [ "$messages" = 1 ] || fail "embedded sender newline changed room state"
  [ ! -e "$home/state/receiver.inbox/001.msg" ] || fail "embedded sender newline created durable custody"
  stop_fixture "$home" handoff-sender-newline-review
  pass "embedded sender newlines fail before line serialization"
}

test_handoff_wait_and_watcher_distinguish_consumed_from_missing() {
  local repo home pin port dir out rec packet wait_result watch_pid i=0
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home handoff-controls)
  setup_fixture "$home" "$repo" "$pin"
  make_handoff_stubs "$home"
  fm_write_meta "$home/state/receiver.meta" "window=sess:fm-receiver" "kind=ship" "harness=claude"
  printf '%s\n' 'captain-held: awaiting manual QA approval' > "$home/state/receiver.status"
  start_fixture "$home" handoff-controls-review >/dev/null
  port=$(awk -F= '$1 == "port" { print $2; exit }' "$home/state/rooms/handoff-controls-review/meta")
  curl -fsS -X POST "http://127.0.0.1:$port/api/rooms/AM-TEST/join" \
    -H 'content-type: application/json' -d '{"name":"Receiver"}' >/dev/null \
    || fail "receiver could not join the room before the explicit wait control"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-controls-review Publisher receiver packet-1 "actionable packet" 2>&1) \
    || fail "handoff controls setup failed: $out"
  wait_result=$(curl -fsS "http://127.0.0.1:$port/api/rooms/AM-TEST/messages?name=Receiver&wait=0") \
    || fail "explicit wait control could not read the published packet"
  packet=$(printf '%s' "$wait_result" | jq -r '.messages[0].id')
  [ "$packet" = 2 ] || fail "explicit wait control did not consume packet 2: $wait_result"
  [ "$(cat "$home/state/receiver.status")" = 'captain-held: awaiting manual QA approval' ] \
    || fail "room handoff changed the explicit approval/QA hold"
  rec="$home/state/receiver.inbox/001.msg"
  mv "$rec" "$home/state/receiver.inbox/handled/" \
    || fail "consumed handoff could not acknowledge its durable record"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-controls-review Publisher receiver packet-2 "unconsumed packet" 2>&1) \
    || fail "second handoff did not enqueue for the missing-consumer control: $out"
  rec="$home/state/receiver.inbox/002.msg"
  [ -f "$rec" ] || fail "missing-consumer control did not leave an unhandled record"
  touch -t 202001010000 "$rec"
  : > "$home/state/.wake-queue"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_SEND_LOG="$home/send.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=1 \
    "$ROOT/bin/fm-watch.sh" >"$home/watch.out" 2>&1 &
  watch_pid=$!
  while [ "$i" -lt 100 ] && ! grep -qF 'unread firstmate instruction' "$home/state/.wake-queue" 2>/dev/null; do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(grep -cF 'unread firstmate instruction' "$home/state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || { kill "$watch_pid" 2>/dev/null || true; fail "missing consumer did not reach the existing watcher escalation:"$'\n'"$(cat "$home/state/.wake-queue" 2>/dev/null)"; }
  [ -f "$rec" ] || fail "watcher escalation removed the unconsumed handoff record"
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  stop_fixture "$home" handoff-controls-review
  pass "an explicit room read plus handled acknowledgement stays quiet, while a missing consumer reaches watcher escalation"
}

test_handoff_rejects_oversize_before_publication() {
  local repo home pin out rc messages oversized
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home handoff-oversize)
  setup_fixture "$home" "$repo" "$pin"
  make_handoff_stubs "$home"
  fm_write_meta "$home/state/receiver.meta" "window=sess:fm-receiver" "kind=ship" "harness=claude"
  start_fixture "$home" handoff-oversize-review >/dev/null
  oversized=$(printf '%20001s' '' | tr ' ' x)
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-oversize-review Publisher receiver packet-oversize "$oversized" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an over-limit handoff was published"
  assert_contains "$out" "could not be normalized" "over-limit handoff did not fail before publication"
  messages=$(jq -r '.rooms["AM-TEST"].messages | length' "$home/state/rooms/handoff-oversize-review/rooms.json")
  [ "$messages" = 1 ] || fail "over-limit handoff changed room state"
  [ ! -e "$home/state/receiver.inbox/001.msg" ] || fail "over-limit handoff created durable custody"
  stop_fixture "$home" handoff-oversize-review
  pass "over-limit handoffs fail before publication"
}

test_handoff_serializes_concurrent_publication() {
  local repo home pin first second first_pid first_rc second_rc messages i=0
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home handoff-concurrent)
  setup_fixture "$home" "$repo" "$pin"
  make_handoff_stubs "$home"
  fm_write_meta "$home/state/receiver.meta" "window=sess:fm-receiver" "kind=ship" "harness=claude"
  FM_ROOM_MESSAGE_DELAY=200 start_fixture "$home" handoff-concurrent-review >/dev/null
  first="$home/first.out"; second="$home/second.out"
  (PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-concurrent-review Publisher receiver packet-concurrent "concurrent packet" \
    >"$first" 2>&1; printf '%s\n' "$?" > "$home/first.rc") &
  first_pid=$!
  while [ "$i" -lt 100 ] && [ ! -e "$home/state/rooms/handoff-concurrent-review/.start.lock" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -e "$home/state/rooms/handoff-concurrent-review/.start.lock" ] \
    || fail "concurrent publication did not acquire the room lock"
  second_rc=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-concurrent-review Publisher receiver packet-concurrent "concurrent packet" \
    >"$second" 2>&1 || second_rc=$?
  wait "$first_pid" || true
  first_rc=$(cat "$home/first.rc")
  [ "$first_rc" = 0 ] || fail "the first concurrent handoff failed: $(cat "$first")"
  [ "$second_rc" -ne 0 ] || fail "concurrent publication did not refuse the locked retry"
  messages=$(jq -r '.rooms["AM-TEST"].messages | length' "$home/state/rooms/handoff-concurrent-review/rooms.json")
  [ "$messages" = 2 ] || fail "concurrent publication created duplicate packets"
  [ "$(find "$home/state/receiver.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "concurrent publication created duplicate custody"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-concurrent-review Publisher receiver packet-concurrent "concurrent packet" 2>&1) \
    || fail "retry after concurrent lock refusal failed: $out"
  stop_fixture "$home" handoff-concurrent-review
  pass "concurrent handoffs serialize before keyed publication"
}

test_handoff_retries_after_api_timeout() {
  local repo home pin out rc retry messages i=0
  { read -r repo; read -r home; read -r pin; } < <(fixture_repo_and_home handoff-timeout)
  setup_fixture "$home" "$repo" "$pin"
  make_handoff_stubs "$home"
  fm_write_meta "$home/state/receiver.meta" "window=sess:fm-receiver" "kind=ship" "harness=claude"
  FM_ROOM_MESSAGE_DELAY=300 start_fixture "$home" handoff-timeout-review >/dev/null
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_ROOM_API_TIMEOUT_MS=100 FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-timeout-review Publisher receiver packet-timeout "timeout packet" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a timed-out room publication was reported successful"
  while [ "$i" -lt 100 ]; do
    messages=$(jq -r '.rooms["AM-TEST"].messages | length' "$home/state/rooms/handoff-timeout-review/rooms.json" 2>/dev/null || true)
    [ "$messages" = 2 ] && break
    sleep 0.01
    i=$((i + 1))
  done
  [ "$messages" = 2 ] || fail "the timed-out publication did not settle in the room fixture"
  retry=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOM_RUNTIME=node \
    FM_ROOM_API_TIMEOUT_MS=1000 FM_HANDOFF_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOM" handoff handoff-timeout-review Publisher receiver packet-timeout "timeout packet" 2>&1) \
    || fail "retry after timed-out publication failed: $retry"
  assert_contains "$retry" "packet #2" "timed-out retry did not reuse the settled packet"
  [ -f "$home/state/receiver.inbox/001.msg" ] || fail "timed-out retry did not create durable custody"
  stop_fixture "$home" handoff-timeout-review
  pass "a bounded API timeout leaves a stable-key retry path"
}

test_setup_verifies_pin_and_never_installs
test_setup_refuses_pin_drift
test_port_in_use_is_refused
test_room_state_is_private_under_open_umask
test_concurrent_start_is_serialized
test_failed_create_rolls_back_server
test_start_prints_observer_join_and_warning
test_pid_identity_ps_is_locale_and_width_stable
test_transcript_cannot_write_inside_state
test_transcript_path_comparison_is_canonical
test_join_cmd_refuses_symlinked_review
test_state_ancestor_symlink_is_refused
test_preexisting_output_links_are_refused
test_status_recovers_crashed_room
test_empty_start_lock_is_recovered
test_hardlinked_crashed_start_lock_is_recovered
test_status_refuses_symlinked_review_before_cleanup
test_chmod_failure_is_fatal
test_stop_is_idempotent_after_clean_stop
test_stop_refuses_foreign_pid
test_transcript_export_shape
test_handoff_publishes_and_custodies_one_packet
test_handoff_rejects_sender_newline_before_publication
test_handoff_wait_and_watcher_distinguish_consumed_from_missing
test_handoff_rejects_oversize_before_publication
test_handoff_serializes_concurrent_publication
test_handoff_retries_after_api_timeout
printf 'All fm-room tests passed.\n'
