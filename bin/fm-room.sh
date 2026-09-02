#!/usr/bin/env bash
# fm-room.sh - own one localhost Agent Room used for adversarial planning gap reviews.
#
# setup clones the pinned Agent Room source into state/tools/agent-room/ and
# verifies its commit without running the upstream installer.
# start <review-id> creates a review-scoped server, room, observer URL, and
# join command under state/rooms/<review-id>/.
# join-cmd <review-id> <seat-name> prints the exact environment and command for
# one seat to join its review room.
# transcript <review-id> exports the raw Agent Room state and verbatim room
# transcript into data/<review-id>/.
# stop <review-id> terminates only the review-owned server after checking its
# pid, process start time, and review marker; status lists known review rooms.
#
# Agent Room is intentionally localhost-only and unauthenticated. Its source is
# MIT licensed and is treated as untrusted code at the pinned commit; setup does
# not run install.sh or write either ~/.codex or ~/.claude.
#
# Usage:
#   fm-room.sh setup
#   fm-room.sh start <review-id>
#   fm-room.sh join-cmd <review-id> <seat-name>
#   fm-room.sh transcript <review-id>
#   fm-room.sh stop <review-id>
#   fm-room.sh status
set -u
umask 077

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TOOLS="$STATE/tools/agent-room"
ROOMS="$STATE/rooms"
REPOSITORY_URL="https://github.com/steviebuilds/agent-room.git"
PINNED_COMMIT="ae600ecb4790a4fdc526020fd6946e8f57e2b1b4"
HOST=127.0.0.1

fail() {
  printf 'fm-room: %s\n' "$*" >&2
  exit 1
}

case "$FM_HOME" in
  /*) ;;
  *) FM_HOME="$PWD/$FM_HOME" ;;
esac
[ -d "$FM_HOME" ] || fail "FM_HOME is not an existing directory: $FM_HOME"
FM_HOME=$(cd -P "$FM_HOME" && pwd) || fail "could not resolve FM_HOME"
case "$STATE" in
  /*) ;;
  *) STATE="$PWD/$STATE" ;;
esac
case "$DATA" in
  /*) ;;
  *) DATA="$PWD/$DATA" ;;
esac

canonical_path() {
  local path=$1 suffix='' base resolved
  while [ ! -e "$path" ] && [ ! -L "$path" ]; do
    base=$(basename "$path")
    suffix="/$base$suffix"
    path=$(dirname "$path")
  done
  [ -d "$path" ] || fail "path is not rooted in an existing directory: $path"
  resolved=$(cd -P "$path" && pwd) || fail "could not resolve path: $path"
  printf '%s%s\n' "$resolved" "$suffix"
}

STATE=$(canonical_path "$STATE")
DATA=$(canonical_path "$DATA")
TOOLS="$STATE/tools/agent-room"
ROOMS="$STATE/rooms"

trusted_dir_tree() {
  local path=$1 current part
  case "$path" in
    /*) current=/; path=${path#/} ;;
    *) current=$PWD ;;
  esac
  local IFS=/
  read -r -a parts <<<"$path"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    current="${current%/}/$part"
    [ ! -L "$current" ] || fail "refusing symlinked directory component: $current"
    if [ -e "$current" ]; then
      [ -d "$current" ] || fail "directory component is not a directory: $current"
    elif ! mkdir "$current" 2>/dev/null; then
      [ ! -L "$current" ] && [ -d "$current" ] \
        || fail "could not create directory: $current"
    fi
  done
}

file_links() {
  stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null
}

file_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}

safe_existing_file() {
  local path=$1 links
  [ ! -L "$path" ] || fail "refusing symlinked file: $path"
  if [ -e "$path" ]; then
    [ -f "$path" ] || fail "expected a regular file: $path"
    links=$(file_links "$path") || fail "could not inspect file links: $path"
    [ "$links" = 1 ] || fail "refusing multiply-linked file: $path"
  fi
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

valid_review_id() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_seat_name() {
  [ -n "$1" ] && [ "${#1}" -le 80 ] && case "$1" in *$'\n'*) return 1 ;; esac
}

review_dir() {
  valid_review_id "$1" || fail "invalid review id: $1"
  printf '%s/%s\n' "$ROOMS" "$1"
}

runtime() {
  local selected=${FM_ROOM_RUNTIME:-}
  if [ -n "$selected" ]; then
    command -v "$selected" >/dev/null 2>&1 || fail "runtime is not installed: $selected"
    printf '%s\n' "$(command -v "$selected")"
    return 0
  fi
  if command -v bun >/dev/null 2>&1; then
    command -v bun
  elif command -v node >/dev/null 2>&1; then
    command -v node
  else
    fail "Agent Room requires Bun or Node.js 20+"
  fi
}

runtime_check() {
  local js=$1 major
  case "$(basename "$js")" in
    bun) return 0 ;;
  esac
  major=$("$js" -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null) || fail "could not read Node.js version"
  case "$major" in ''|*[!0-9]*) fail "could not read Node.js version" ;; esac
  [ "$major" -ge 20 ] || fail "Agent Room requires Node.js 20+; found $major"
}

room_script() {
  [ -f "$TOOLS/scripts/agent_room.mjs" ] || fail "Agent Room is not set up; run fm-room.sh setup"
  [ ! -L "$TOOLS/scripts/agent_room.mjs" ] || fail "Agent Room script is a symlink"
  printf '%s\n' "$TOOLS/scripts/agent_room.mjs"
}

expected_repository_url() {
  if [ "${FM_ROOM_TESTING:-0}" = 1 ]; then
    printf '%s\n' "${FM_ROOM_REPO_URL:-$REPOSITORY_URL}"
  else
    printf '%s\n' "$REPOSITORY_URL"
  fi
}

expected_commit() {
  if [ "${FM_ROOM_TESTING:-0}" = 1 ]; then
    printf '%s\n' "${FM_ROOM_PIN_OVERRIDE:-$PINNED_COMMIT}"
  else
    printf '%s\n' "$PINNED_COMMIT"
  fi
}

verify_tool() {
  local expected actual
  [ -d "$TOOLS" ] || fail "Agent Room checkout is missing: $TOOLS"
  [ ! -L "$TOOLS" ] || fail "Agent Room checkout is a symlink: $TOOLS"
  trusted_dir_tree "$STATE/tools"
  expected=$(expected_commit)
  actual=$(git -C "$TOOLS" rev-parse HEAD 2>/dev/null) || fail "Agent Room checkout is not a git repository"
  [ "$actual" = "$expected" ] || fail "Agent Room checkout is not at the pinned commit $expected (found $actual)"
  [ -f "$TOOLS/scripts/agent_room.mjs" ] || fail "pinned Agent Room checkout has no scripts/agent_room.mjs"
}

setup() {
  local expected actual temporary repository
  trusted_dir_tree "$STATE/tools"
  chmod 700 "$STATE/tools" || fail "could not secure Agent Room tools directory"
  if [ -e "$TOOLS" ] || [ -L "$TOOLS" ]; then
    verify_tool
    printf 'Agent Room setup verified at %s (%s).\n' "$TOOLS" "$(expected_commit)"
    return 0
  fi
  expected=$(expected_commit)
  repository=$(expected_repository_url)
  temporary="$TOOLS.tmp.$$"
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] \
    || fail "temporary Agent Room checkout already exists: $temporary"
  trap 'rm -rf "$temporary"' EXIT HUP INT TERM
  git clone --quiet "$repository" "$temporary" || fail "could not clone Agent Room"
  git -C "$temporary" checkout --quiet "$expected" || fail "Agent Room clone does not contain pinned commit $expected"
  actual=$(git -C "$temporary" rev-parse HEAD 2>/dev/null) || fail "could not read cloned Agent Room commit"
  [ "$actual" = "$expected" ] || fail "Agent Room checkout is not at the pinned commit $expected (found $actual)"
  [ -f "$temporary/scripts/agent_room.mjs" ] || fail "pinned Agent Room checkout has no scripts/agent_room.mjs"
  mv "$temporary" "$TOOLS" || fail "could not install the verified Agent Room checkout"
  trap - EXIT HUP INT TERM
  printf 'Agent Room setup verified at %s (%s).\n' "$TOOLS" "$expected"
}

meta_get() {
  local dir=$1 key=$2
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$dir/meta" 2>/dev/null
}

meta_set() {
  local dir=$1 key=$2 value=$3 temporary
  trusted_dir_tree "$dir"
  safe_existing_file "$dir/meta"
  temporary="$dir/meta.tmp.$$"
  safe_existing_file "$temporary"
  if [ -f "$dir/meta" ] && grep -q "^${key}=" "$dir/meta"; then
    awk -F= -v key="$key" -v value="$value" '$1 == key { print key "=" value; found=1; next } { print } END { if (!found) print key "=" value }' "$dir/meta" >"$temporary"
  else
    cat "$dir/meta" 2>/dev/null >"$temporary" || :
    printf '%s=%s\n' "$key" "$value" >>"$temporary"
  fi
  chmod 600 "$temporary" || fail "could not secure Agent Room metadata"
  mv "$temporary" "$dir/meta"
}

pid_is_number() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

pid_alive() {
  pid_is_number "$1" && kill -0 "$1" 2>/dev/null
}

pid_start_time() {
  LC_ALL=C COLUMNS=200 ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//'
}

pid_command() {
  LC_ALL=C COLUMNS=200 ps -p "$1" -o command= 2>/dev/null | sed 's/^[[:space:]]*//'
}

pid_belongs_to_review() {
  local dir=$1 pid=$2 expected_start expected_command current_start current_command marker
  expected_start=$(meta_get "$dir" pid_start)
  expected_command=$(meta_get "$dir" pid_command)
  marker="serve --fm-room-review=$(basename "$dir")"
  pid_alive "$pid" || return 1
  current_start=$(pid_start_time "$pid")
  current_command=$(pid_command "$pid")
  [ -n "$expected_start" ] && [ "$current_start" = "$expected_start" ] || return 1
  [ -n "$expected_command" ] && [ "$current_command" = "$expected_command" ] || return 1
  case "$current_command" in
    *"$marker"*) return 0 ;;
    *) return 1 ;;
  esac
}

port_is_free() {
  local runner=$1 port=$2
  "$runner" -e '
    const net = require("node:net");
    const server = net.createServer();
    server.once("error", () => process.exit(1));
    server.listen(Number(process.argv[1]), "127.0.0.1", () => server.close(() => process.exit(0)));
  ' "$port" >/dev/null 2>&1
}

choose_port() {
  local runner=$1
  if [ -n "${FM_ROOM_PORT:-}" ]; then
    case "$FM_ROOM_PORT" in ''|*[!0-9]*) fail "FM_ROOM_PORT must be a numeric TCP port" ;; esac
    [ "$FM_ROOM_PORT" -ge 1 ] && [ "$FM_ROOM_PORT" -le 65535 ] || fail "FM_ROOM_PORT is outside 1-65535"
    printf '%s\n' "$FM_ROOM_PORT"
    return 0
  fi
  "$runner" -e '
    const net = require("node:net");
    const server = net.createServer();
    server.once("error", () => process.exit(1));
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      process.stdout.write(String(address.port) + "\n");
      server.close(() => process.exit(0));
    });
  '
}

health() {
  local base=$1 runner
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 1 "$base/api/health" >/dev/null 2>&1
    return $?
  fi
  runner=$(runtime) || return 1
  runtime_check "$runner" || return 1
  "$runner" -e 'fetch(process.argv[1]).then((response) => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))' "$base/api/health" >/dev/null 2>&1
}

wait_for_server() {
  local base=$1 dir=$2 attempt=0 pid
  while [ "$attempt" -lt 80 ]; do
    if [ -f "$dir/server.pid" ]; then
      pid=$(cat "$dir/server.pid" 2>/dev/null || true)
      if health "$base" && pid_belongs_to_review "$dir" "$pid"; then
        return 0
      fi
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

shell_quote() {
  printf '%q' "$1"
}

join_command() {
  local dir=$1 seat=$2 code port js js_runner
  code=$(meta_get "$dir" room_code)
  port=$(meta_get "$dir" port)
  js=$(room_script)
  js_runner=$(runtime)
  runtime_check "$js_runner"
  printf 'AGENT_ROOM_HOST=%q AGENT_ROOM_PORT=%q AGENT_ROOM_HOME=%q %q %q join %q --name %q\n' \
    "$HOST" "$port" "$dir" "$js_runner" "$js" "$code" "$seat"
}

START_LOCK=
START_LOCK_CANDIDATE=
START_LOCK_START=
START_DIR=
START_SERVER_PID=
START_ROLLBACK=0

release_start_lock() {
  local owner owner_start
  [ -n "$START_LOCK" ] || return 0
  [ ! -L "$START_LOCK" ] || { START_LOCK=; START_LOCK_CANDIDATE=; START_LOCK_START=; return 0; }
  owner=$(sed -n '1p' "$START_LOCK" 2>/dev/null || true)
  owner_start=$(sed -n '2p' "$START_LOCK" 2>/dev/null || true)
  if [ "$owner" = "$$" ] && [ "$owner_start" = "$START_LOCK_START" ]; then
    rm -f "$START_LOCK"
  fi
  [ -z "$START_LOCK_CANDIDATE" ] || rm -f "$START_LOCK_CANDIDATE"
  START_LOCK=
  START_LOCK_CANDIDATE=
  START_LOCK_START=
}

start_cleanup() {
  local rc=$?
  if [ "$START_ROLLBACK" = 1 ] && [ -n "$START_SERVER_PID" ]; then
    if pid_belongs_to_review "$START_DIR" "$START_SERVER_PID"; then
      kill -TERM "$START_SERVER_PID" 2>/dev/null || true
      local attempt=0
      while pid_alive "$START_SERVER_PID" && [ "$attempt" -lt 80 ]; do
        sleep 0.1
        attempt=$((attempt + 1))
      done
      if pid_alive "$START_SERVER_PID"; then
        printf 'fm-room: could not confirm rollback of server %s; retaining pid metadata\n' "$START_SERVER_PID" >&2
      else
        rm -f "$START_DIR/server.pid"
      fi
    fi
  fi
  release_start_lock
  trap - EXIT HUP INT TERM
  return "$rc"
}

acquire_start_lock() {
  local dir=$1 lock="$1/.start.lock" candidate owner owner_start stale_lock attempt
  for attempt in 1 2; do
    candidate="$lock.$$"
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
      || fail "could not create start lock for review $(basename "$dir")"
    owner_start=$(pid_start_time "$$")
    (set -C; printf '%s\n%s\n' "$$" "$owner_start" >"$candidate") 2>/dev/null \
      || fail "could not create start lock for review $(basename "$dir")"
    if ln "$candidate" "$lock" 2>/dev/null; then
      rm -f "$candidate"
      START_LOCK=$lock
      START_LOCK_START=$owner_start
      return 0
    fi
    rm -f "$candidate"
    [ ! -L "$lock" ] || fail "refusing symlinked start lock: $lock"
    owner=$(sed -n '1p' "$lock" 2>/dev/null || true)
    owner_start=$(sed -n '2p' "$lock" 2>/dev/null || true)
    if pid_is_number "$owner" && pid_alive "$owner" \
      && [ -n "$owner_start" ] && [ "$(pid_start_time "$owner")" = "$owner_start" ]; then
      fail "start already in progress for review $(basename "$dir")"
    fi
    stale_lock="$lock.stale.$$"
    [ ! -e "$stale_lock" ] && [ ! -L "$stale_lock" ] \
      || fail "could not recover stale start lock for review $(basename "$dir")"
    [ -f "$lock" ] || fail "refusing unsafe start lock: $lock"
    local lock_links lock_candidate="$lock.$owner"
    lock_links=$(file_links "$lock") || fail "could not inspect start lock: $lock"
    if [ "$lock_links" != 1 ]; then
      [ -f "$lock_candidate" ] && [ "$(file_identity "$lock")" = "$(file_identity "$lock_candidate")" ] \
        || fail "refusing multiply-linked start lock: $lock"
    fi
    mv "$lock" "$stale_lock" 2>/dev/null \
      || fail "start already in progress for review $(basename "$dir")"
    rm -f "$stale_lock"
    [ "$lock_links" = 1 ] || rm -f "$lock_candidate"
  done
  fail "start already in progress for review $(basename "$dir")"
}

start() {
  local id=$1 dir port js js_runner base pid pid_start command_line url code output
  dir=$(review_dir "$id")
  [ ! -L "$dir" ] || fail "review directory is a symlink: $dir"
  setup >/dev/null
  verify_tool
  js=$(room_script)
  js_runner=$(runtime)
  runtime_check "$js_runner"
  trusted_dir_tree "$ROOMS"
  chmod 700 "$ROOMS" || fail "could not secure Agent Room rooms directory"
  trusted_dir_tree "$dir"
  acquire_start_lock "$dir"
  START_DIR=$dir
  START_ROLLBACK=1
  trap start_cleanup EXIT HUP INT TERM
  if [ -f "$dir/server.pid" ]; then
    pid=$(cat "$dir/server.pid" 2>/dev/null || true)
    if [ -n "$(meta_get "$dir" room_code)" ] && [ -n "$(meta_get "$dir" observer_url)" ] \
      && pid_belongs_to_review "$dir" "$pid" && health "http://$HOST:$(meta_get "$dir" port)"; then
      printf 'Agent Room is already running for review %s.\n' "$id"
      printf 'Observer URL: %s\n' "$(meta_get "$dir" observer_url)"
      printf 'Join command: %s\n' "$(join_command "$dir" Lead)"
      return 0
    fi
    fail "refusing to start with a stale or foreign pid file for review $id"
  fi
  port=$(choose_port "$js_runner")
  if ! port_is_free "$js_runner" "$port"; then
    fail "port $port is already bound by another process; refusing to start"
  fi
  trusted_dir_tree "$dir"
  safe_existing_file "$dir/server.log"
  safe_existing_file "$dir/server.pid"
  safe_existing_file "$dir/rooms.json"
  chmod 700 "$dir" || fail "could not secure Agent Room review directory"
  base="http://$HOST:$port"
  AGENT_ROOM_HOST="$HOST" AGENT_ROOM_PORT="$port" AGENT_ROOM_HOME="$dir" \
    nohup "$js_runner" "$js" serve "--fm-room-review=$id" >"$dir/server.log" 2>&1 &
  pid=$!
  START_SERVER_PID=$pid
  pid_start=$(pid_start_time "$pid")
  [ -n "$pid_start" ] || fail "could not record Agent Room server start time"
  command_line=$(pid_command "$pid")
  safe_existing_file "$dir/meta"
  cat >"$dir/meta" <<EOF
review_id=$id
port=$port
pid_start=$pid_start
pid_command=$command_line
status=starting
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "$dir/meta" || fail "could not secure Agent Room metadata"
  if ! wait_for_server "$base" "$dir"; then
    if pid_belongs_to_review "$dir" "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
    fail "Agent Room server did not become healthy; see $dir/server.log"
  fi
  output=$(AGENT_ROOM_HOST="$HOST" AGENT_ROOM_PORT="$port" AGENT_ROOM_HOME="$dir" \
    FM_ROOM_CREATE_BODY="{\"title\":\"Planning gap review $id\",\"objective\":\"Find adversarial gaps before implementation for review $id.\",\"name\":\"Lead\"}" \
    "$js_runner" "$js" create --title "Planning gap review $id" \
      --objective "Find adversarial gaps before implementation for review $id." --name Lead 2>&1) \
    || fail "could not create Agent Room: $output"
  url=$(printf '%s\n' "$output" | grep -Eo 'http://127\.0\.0\.1:[0-9]+/rooms/[A-Za-z0-9-]+' | tail -1)
  [ -n "$url" ] || fail "Agent Room did not return an observer URL: $output"
  code=${url##*/}
  meta_set "$dir" room_code "$code"
  meta_set "$dir" observer_url "$url"
  meta_set "$dir" status active
  printf 'Agent Room started for review %s.\n' "$id"
  printf 'Observer URL: %s\n' "$url"
  printf 'Join command: %s\n' "$(join_command "$dir" Lead)"
  printf 'Warning: Agent Room rooms have no auth; any same-user process can read or post.\n'
  START_ROLLBACK=0
  trap - EXIT HUP INT TERM
  release_start_lock
}

transcript() {
  local id=$1 dir output state code runner
  dir=$(review_dir "$id")
  [ ! -L "$dir" ] || fail "review directory is a symlink: $dir"
  trusted_dir_tree "$dir"
  [ -f "$dir/meta" ] || fail "review does not exist: $id"
  state="$dir/rooms.json"
  [ -f "$state" ] || fail "Agent Room state is missing for review $id"
  safe_existing_file "$dir/meta"
  safe_existing_file "$state"
  code=$(meta_get "$dir" room_code)
  [ -n "$code" ] || fail "room code is missing for review $id"
  output="$DATA/$id"
  case "$DATA/" in
    "$STATE/"*) fail "transcript output must be outside room state: $output" ;;
  esac
  trusted_dir_tree "$output"
  safe_existing_file "$output/room.json"
  safe_existing_file "$output/transcript.txt"
  chmod 700 "$output" || fail "could not secure transcript directory"
  cp "$state" "$output/room.json" || fail "could not export raw room JSON"
  runner=$(runtime)
  runtime_check "$runner"
  FM_ROOM_STATE="$state" FM_ROOM_CODE="$code" FM_ROOM_TRANSCRIPT="$output/transcript.txt" \
    "$runner" - <<'NODE' || fail "could not export Agent Room transcript"
import fs from "node:fs";
const state = JSON.parse(fs.readFileSync(process.env.FM_ROOM_STATE, "utf8"));
const room = state.rooms?.[process.env.FM_ROOM_CODE];
if (!room) throw new Error(`room ${process.env.FM_ROOM_CODE} is missing`);
const messages = Array.isArray(room.messages) ? room.messages : [];
let text = messages.length
  ? messages.map((message) => `#${message.id} [${message.kind}] ${message.sender}: ${message.content}`).join("\n\n")
  : "No new messages. Continue listening unless a stop condition has been met.";
if (room.summary) text += `\n\nSummary: ${room.summary}`;
fs.writeFileSync(process.env.FM_ROOM_TRANSCRIPT, text);
NODE
  safe_existing_file "$output/transcript.txt"
  chmod 600 "$output/room.json" "$output/transcript.txt" \
    || fail "could not secure transcript files"
  printf 'Transcript exported to %s (raw JSON: %s).\n' "$output/transcript.txt" "$output/room.json"
}

stop() {
  local id=$1 dir pid attempt
  dir=$(review_dir "$id")
  [ ! -L "$dir" ] || fail "review directory is a symlink: $dir"
  [ -d "$dir" ] || fail "review does not exist: $id"
  if [ ! -e "$dir/server.pid" ] && [ ! -L "$dir/server.pid" ]; then
    [ -f "$dir/meta" ] && meta_set "$dir" status stopped
    printf 'Agent Room is already stopped for review %s.\n' "$id"
    return 0
  fi
  [ -f "$dir/server.pid" ] || fail "stale or missing pid file for review $id"
  [ ! -L "$dir/server.pid" ] || fail "refusing symlink pid file for review $id"
  pid=$(cat "$dir/server.pid" 2>/dev/null || true)
  pid_is_number "$pid" || fail "stale pid file for review $id"
  if ! pid_alive "$pid"; then
    safe_existing_file "$dir/server.pid"
    rm -f "$dir/server.pid"
    meta_set "$dir" status stopped
    printf 'Agent Room recovered stale metadata for review %s.\n' "$id"
    return 0
  fi
  pid_belongs_to_review "$dir" "$pid" || fail "refusing foreign pid for review $id"
  kill -TERM "$pid" 2>/dev/null || fail "could not stop review server $pid"
  attempt=0
  while pid_alive "$pid" && [ "$attempt" -lt 80 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  pid_alive "$pid" && fail "review server $pid did not stop cleanly"
  rm -f "$dir/server.pid"
  meta_set "$dir" status stopped
  printf 'Agent Room stopped for review %s.\n' "$id"
}

status() {
  local dir id state pid
  [ -d "$ROOMS" ] || { printf 'No Agent Room reviews.\n'; return 0; }
  for dir in "$ROOMS"/*; do
    [ -d "$dir" ] || continue
    [ ! -L "$dir" ] || fail "refusing symlinked review directory: $dir"
    trusted_dir_tree "$dir"
    id=$(basename "$dir")
    state=$(meta_get "$dir" status)
    pid=$(cat "$dir/server.pid" 2>/dev/null || true)
    if [ -n "$pid" ] && pid_belongs_to_review "$dir" "$pid"; then
      state=running
    elif [ -n "$pid" ] && ! pid_alive "$pid"; then
      safe_existing_file "$dir/server.pid"
      rm -f "$dir/server.pid"
      meta_set "$dir" status stopped
      state=stopped
    elif [ -z "$state" ] || [ "$state" = active ]; then
      state=unknown
    fi
    printf '%s status=%s room=%s port=%s\n' "$id" "${state:-unknown}" \
      "$(meta_get "$dir" room_code)" "$(meta_get "$dir" port)"
  done
}

command=${1:-}
case "$command" in
  setup)
    [ "$#" -eq 1 ] || fail "setup takes no arguments"
    setup
    ;;
  start)
    [ "$#" -eq 2 ] || fail "start requires <review-id>"
    start "$2"
    ;;
  join-cmd)
    [ "$#" -eq 3 ] || fail "join-cmd requires <review-id> <seat-name>"
    valid_seat_name "$3" || fail "invalid seat name"
    dir=$(review_dir "$2")
    [ ! -L "$dir" ] || fail "review directory is a symlink: $dir"
    [ -d "$dir" ] || fail "review does not exist: $2"
    trusted_dir_tree "$dir"
    [ -f "$dir/meta" ] || fail "review does not exist: $2"
    safe_existing_file "$dir/meta"
    join_command "$dir" "$3"
    ;;
  transcript)
    [ "$#" -eq 2 ] || fail "transcript requires <review-id>"
    transcript "$2"
    ;;
  stop)
    [ "$#" -eq 2 ] || fail "stop requires <review-id>"
    stop "$2"
    ;;
  status)
    [ "$#" -eq 1 ] || fail "status takes no arguments"
    status
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
