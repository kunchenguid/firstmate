#!/usr/bin/env bash
# tests/t3-fake-lib.sh - shared fixture helpers for the t3code backend suites:
# start and stop tests/t3-fake-server.mjs, point it at a case directory, edit
# that case's world, mint credentials it accepts, and read its request log.
# Sourced after tests/lib.sh.

T3_FAKE_SERVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/t3-fake-server.mjs"
T3_FAKE_PID=

# t3_fake_start <server-dir> [VAR=value...]: start a server with the extra
# environment given. Sets T3_FAKE_URL and T3_FAKE_CASE_FILE; call
# t3_fake_case before the first request.
t3_fake_start() {
  local dir=$1
  shift
  mkdir -p "$dir"
  T3_FAKE_CASE_FILE="$dir/case"
  [ -f "$T3_FAKE_CASE_FILE" ] || printf '%s' "$dir" > "$T3_FAKE_CASE_FILE"
  rm -f "$dir/port"
  env -u T3CODE_TELEMETRY_ENABLED "$@" node "$T3_FAKE_SERVER" --case-file "$T3_FAKE_CASE_FILE" \
    --port-file "$dir/port" --parent-pid "$$" >"$dir/server.out" 2>&1 &
  T3_FAKE_PID=$!
  for _ in $(seq 1 100); do
    [ -s "$dir/port" ] && break
    sleep 0.05
  done
  [ -s "$dir/port" ] || fail "fake T3 server did not start: $(cat "$dir/server.out" 2>/dev/null)"
  T3_FAKE_URL="http://127.0.0.1:$(cat "$dir/port")"
}

t3_fake_stop() {
  [ -n "$T3_FAKE_PID" ] || return 0
  kill "$T3_FAKE_PID" 2>/dev/null || true
  wait "$T3_FAKE_PID" 2>/dev/null || true
  T3_FAKE_PID=
}

# t3_fake_case <dir> [world-json]: make <dir> the server's current case, with
# a fresh world (default `{}`) and an empty request log. Sets T3_FAKE_WORLD
# and T3_FAKE_LOG.
t3_fake_case() {
  local world=${2:-}
  [ -n "$world" ] || world='{}'
  mkdir -p "$1"
  T3_FAKE_WORLD="$1/world.json"
  T3_FAKE_LOG="$1/requests.jsonl"
  printf '%s\n' "$world" > "$T3_FAKE_WORLD"
  : > "$T3_FAKE_LOG"
  printf '%s' "$1" > "$T3_FAKE_CASE_FILE"
}

# t3_fake_set <js>: run <js> against the current world as `w` and save it.
t3_fake_set() {
  node -e '
const fs = require("fs");
const file = process.argv[1];
let w = JSON.parse(fs.readFileSync(file, "utf8"));
eval(process.argv[2]);
fs.writeFileSync(file, JSON.stringify(w));
' "$T3_FAKE_WORLD" "$1"
}

# t3_fake_t3_cli <dir>: a fake `t3` CLI whose pairing create prints the code
# the fake server accepts and logs its arguments to <dir>/t3-cli.log.
t3_fake_t3_cli() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/t3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/t3-cli.log'
printf '{"credential":"PAIR-OK","expiresAt":"later"}\n'
SH
  chmod +x "$dir/t3"
  printf '%s\n' "$dir/t3"
}

# t3_fake_credential <file> [env-id] [expires-at-ms] [mode] [origin]: a
# credential the current world accepts, written without the sign-in flow.
t3_fake_credential() {
  local file=$1 env=${2:-env-fake-1} expires=${3:-} mode=${4:-600} origin=${5:-$T3_FAKE_URL} token
  [ -n "$expires" ] || expires=$(( ($(date +%s) + 30 * 86400) * 1000 ))
  token="tok-test-$RANDOM$RANDOM"
  FM_T3_FAKE_TOKEN=$token t3_fake_set 'w.tokens = [...(w.tokens || []), process.env.FM_T3_FAKE_TOKEN]'
  mkdir -p "$(dirname "$file")"
  rm -f "$file"
  printf '{"version":1,"origin":"%s","access_token":"%s","issued_at":0,"expires_at":%s,"access":"full-access","environment_id":"%s","server_version":"0.0.46-nightly.fake"}\n' \
    "$origin" "$token" "$expires" "$env" > "$file"
  chmod "$mode" "$file"
}

# t3_fake_calls <tool>: the logged arguments of every call to <tool>, one JSON
# object per line.
t3_fake_calls() {
  node -e '
const tool = process.argv[1];
for (const line of require("fs").readFileSync(process.argv[2], "utf8").split("\n")) {
  if (!line) continue;
  const e = JSON.parse(line);
  if (e.tool === tool && !e.dropped) console.log(JSON.stringify(e.arguments ?? {}));
}
' "$1" "$T3_FAKE_LOG"
}

# t3_fake_mutations: the mutating tool calls in order, space-separated (reads,
# the gate, and dropped calls excluded).
t3_fake_mutations() {
  node -e '
const writes = new Set(["t3_project_create", "t3_thread_launch", "t3_thread_send", "t3_thread_interrupt", "t3_thread_organize"]);
const out = [];
for (const line of require("fs").readFileSync(process.argv[1], "utf8").split("\n")) {
  if (!line) continue;
  const e = JSON.parse(line);
  if (writes.has(e.tool)) out.push(e.dropped ? e.tool + "!" : e.tool);
}
process.stdout.write(out.join(" "));
' "$T3_FAKE_LOG"
}
