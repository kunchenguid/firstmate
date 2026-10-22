#!/usr/bin/env bash
# tests/fm-backend-rex.test.sh - fake-rex-CLI unit tests for the Rex
# session-provider adapter (bin/backends/rex.sh) and its wiring in
# bin/fm-backend.sh. A small keyed fake `rex` on PATH answers each subcommand
# from response files under $FM_REX_FAKE and logs every call (argv joined by
# \x1f, prefixed with whether REX_* leaked into its environment) to
# $FM_REX_FAKE/log; jq is real. The real-binary smoke against a private Rex
# server lives in tests/fm-backend-rex-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the rex adapter)"; exit 0; }

unset TMUX TMUX_PANE HERDR_ENV CMUX_WORKSPACE_ID PASEO_AGENT_ID __CFBundleIdentifier \
  REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT REX_BIN_DIR FM_REX_SERVER 2>/dev/null || true

TMP_ROOT=$(fm_test_tmproot fm-backend-rex-tests)
export FM_BACKEND_REX_BUNDLE_BIN="$TMP_ROOT/no-bundled-rex"

SID=01a15f2e-b05a-7449-b8c9-b9eafcadf82a
BID=01a15f2e-c301-7b2b-a2fb-f59d5f593bd5
WID=01a15f2e-c30d-727c-a801-ee0958c2c74d
LSID=01a15f09-8f9c-701b-a80b-a9a85e4f5875
LBID=01a15f09-8f9c-7115-87f6-69c03274b041
T="$SID:$BID"
SERVER=unix:///tmp/fm-rex-fake.sock

# make_rex_fake: <dir> -> fakebin dir. Response files (all optional):
#   exit                 forces every non-meta call to exit with this code
#   status.json/.exit    `server status --json`
#   methods              `api list -q`
#   ls.json/.exit        `ls --json`
#   new.json             `new ... --json`
#   window-new.json      `window new ... --json` (also answers `window move`)
#   window-ls.json       `window ls -s S --json`; `window rename` only logs
#   events.jsonl         `events ...` prints these lines, then holds the
#                        stream open; events.exit makes it exit at once
#   api-call.json        `api call ...` (e.g. session.new_block); absent -> exit 1
#   inspect/<id>.json    `block inspect <id> --json`; absent -> exit 3
#   blocks/<sid>.json    `block ls -s <sid> --json`
#   call/<bid>.<m>.json  `block call -s S -b <bid> <m>`; absent -> exit 3
#   capture/<bid>.txt    `capture -b <bid>` (capture/<bid>.vt for --format vt)
#   session/<sid>.json   `session inspect <sid> --json`
#   <cmd>.exit           exit code for rename|close|send|send-key|kill
#   close-removes        makes `block close` delete inspect/<bid>.json
# Typed ids are filed with their `:` replaced by `_`.
make_rex_fake() { # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb" "$dir/fake/inspect" "$dir/fake/blocks" "$dir/fake/call" "$dir/fake/capture" "$dir/fake/session"
  cat >"$fb/rex" <<'SH'
#!/usr/bin/env bash
set -u
F="${FM_REX_FAKE:?}"
leak=clean
[ -z "${REX_BLOCK:-}${REX_SESSION:-}${REX_CLIENT:-}${REX_SERVER:-}" ] || leak=leaked
line=$leak
for a in "$@"; do line="$line"$'\x1f'"$a"; done
printf '%s\n' "$line" >>"$F/log"
key() { printf '%s' "${1//:/_}"; }
emit() { # <file> [missing-exit]
  if [ -f "$1" ]; then cat "$1"; [ -f "${1%.*}.exit" ] && exit "$(cat "${1%.*}.exit")"; exit 0; fi
  echo "Error: target not found" >&2
  exit "${2:-3}"
}
while [ $# -gt 0 ]; do
  case "$1" in
    -S|-C|--timeout) shift 2 ;;
    --autostart=*) shift ;;
    *) break ;;
  esac
done
cmd=${1:-}; shift || true
if [ "$cmd" = version ]; then echo "rex 0.0.1-fake"; echo "api: revision 4 (supports 0 to 4)"; exit 0; fi
[ -f "$F/exit" ] && { echo "Error: rex server is not running" >&2; exit "$(cat "$F/exit")"; }
opt() { local want=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "${2:-}"; return; }; shift; done; }
case "$cmd" in
  server)
    [ "${1:-}" = status ] || exit 0
    [ -f "$F/status.json" ] || printf '{"endpoint":"unix:///tmp/fm-rex-fake.sock","instance_id":"inst-1","api_revision":4}' >"$F/status.json"
    emit "$F/status.json" ;;
  api)
    if [ "${1:-}" = call ]; then emit "$F/api-call.json" 1; fi
    [ -f "$F/methods" ] || printf '%s\n' block.close session.new_window session.set_block_label com.superlogical.terminal.process com.superlogical.terminal.format >"$F/methods"; cat "$F/methods" ;;
  ls) [ -f "$F/ls.json" ] || printf '{"sessions":[]}' >"$F/ls.json"; emit "$F/ls.json" ;;
  new) emit "$F/new.json" 1 ;;
  window)
    case "${1:-}" in
      ls) emit "$F/window-ls.json" 1 ;;
      rename) exit 0 ;;
    esac
    emit "$F/window-new.json" 1 ;;
  events)
    [ -f "$F/events.exit" ] && exit "$(cat "$F/events.exit")"
    cat "$F/events.jsonl" 2>/dev/null
    exec sleep 30 ;;
  kill) exit "$(cat "$F/kill.exit" 2>/dev/null || echo 0)" ;;
  send) cat >>"$F/sent"; printf '\n' >>"$F/sent"; exit "$(cat "$F/send.exit" 2>/dev/null || echo 0)" ;;
  send-key) exit "$(cat "$F/send-key.exit" 2>/dev/null || echo 0)" ;;
  capture)
    b=$(key "$(opt -b "$@")")
    case " $* " in *" vt "*) [ -f "$F/capture/$b.vt" ] && { cat "$F/capture/$b.vt"; exit 0; } ;; esac
    emit "$F/capture/$b.txt" ;;
  session) emit "$F/session/$(key "${2:-}").json" ;;
  block)
    sub=${1:-}; shift || true
    case "$sub" in
      inspect) emit "$F/inspect/$(key "$1").json" ;;
      ls) b="$F/blocks/$(key "$(opt -s "$@")").json"; [ -f "$b" ] || printf '{"blocks":[]}' >"$b"; emit "$b" ;;
      call) emit "$F/call/$(key "$(opt -b "$@")").${5:-}.json" ;;
      rename) exit "$(cat "$F/rename.exit" 2>/dev/null || echo 0)" ;;
      close)
        [ -f "$F/close-removes" ] && rm -f "$F/inspect/$(key "${3:-}").json"
        exit "$(cat "$F/close.exit" 2>/dev/null || echo 0)" ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/rex"
  printf '%s\n' "$fb"
}

# new_case: a fresh fake + FM_HOME; exports what every adapter call needs.
new_case() { # <name>
  local dir="$TMP_ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir/home/state"
  make_rex_fake "$dir" >/dev/null
  CASE=$dir
  FAKE="$dir/fake"
  export FM_REX_FAKE=$FAKE FM_HOME="$dir/home" STATE="$dir/home/state" PATH="$dir/fakebin:$ORIG_PATH"
  export FM_REX_SERVER=$SERVER
  unset FM_BACKEND_REX_SERVER FM_BACKEND_REX_SERVER_INSTANCE
}

inspect_json() { # <bid> <sid> [label] [window]
  printf '{"session_id":"session:%s","block":{"block_id":"block:%s","label":"%s","window_id":"window:%s","placement":"placed"}}' \
    "$2" "$1" "${3:-shell}" "${4:-$WID}" >"$FAKE/inspect/block_$1.json"
}

process_json() { # <bid> <json>
  printf '%s' "$2" >"$FAKE/call/block_$1.process.json"
}

calls() { tr '\037' ' ' <"$FAKE/log"; }

ORIG_PATH=$PATH
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source rex || fail "could not source the rex adapter"
fm_backend_source tmux || fail "could not source the tmux adapter"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

# --- the call contract --------------------------------------------------------

test_every_call_pins_server_and_never_autostarts() {
  new_case pin
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  printf 'hello\n' >"$FAKE/capture/block_$BID.txt"
  REX_BLOCK=block:$LBID REX_SESSION=session:$LSID REX_SERVER=unix:///live.sock REX_CLIENT=c \
    fm_backend_rex_capture "$T" 5 fm-t1 >/dev/null || fail "capture failed"
  REX_BLOCK=block:$LBID fm_backend_rex_send_key "$T" Enter fm-t1 || fail "send-key failed"
  [ -s "$FAKE/log" ] || fail "no rex calls were made"
  while IFS= read -r line; do
    case "$line" in
      "clean"$'\037'"-S"$'\037'"$SERVER"$'\037'"--autostart=false"$'\037'*) ;;
      *) fail "a rex call did not start with a clean env, -S $SERVER, and --autostart=false: $(printf '%s' "$line" | tr '\037' ' ')" ;;
    esac
  done <"$FAKE/log"
  calls | grep -q -- "-b block:$BID" || fail "calls did not address the block by its full typed id"
  calls | grep -q -- "-s session:$SID" || fail "calls did not address the session by its full typed id"
  pass "rex: every call carries a clean env, the pinned -S server, --autostart=false, and full typed ids"
}

test_server_resolution_prefers_the_task_record() {
  local server
  new_case server
  printf '%s\n' "window=$T" "rex_server=unix:///recorded.sock" >"$STATE/t1.meta"
  server=$(fm_backend_rex_server "$T")
  [ "$server" = unix:///recorded.sock ] || fail "the recorded rex_server must win for its target, got '$server'"
  server=$(fm_backend_rex_server "$SID:$WID")
  [ "$server" = "$SERVER" ] || fail "an unrecorded target must fall back to FM_REX_SERVER, got '$server'"
  server=$(FM_BACKEND_REX_SERVER=unix:///pinned.sock fm_backend_rex_server "$T")
  [ "$server" = unix:///pinned.sock ] || fail "a spawn-pinned server must win, got '$server'"
  server=$(unset FM_REX_SERVER; fm_backend_rex_server)
  [ "$server" = unix:///tmp/fm-rex-fake.sock ] || fail "with nothing named, the running default server's endpoint must be used, got '$server'"
  printf '1' >"$FAKE/exit"
  if server=$(unset FM_REX_SERVER; fm_backend_rex_server); then
    fail "no running server must resolve to no server, got '$server'"
  fi
  pass "rex: server resolution - spawn pin, then the task record, then FM_REX_SERVER/REX_SERVER, then the running default"
}

# --- version gate -------------------------------------------------------------

test_version_gate() {
  local out
  new_case version
  fm_backend_rex_version_check || fail "API revision 4 with every method should pass"
  printf '{"endpoint":"x","instance_id":"i","api_revision":3}' >"$FAKE/status.json"
  out=$(fm_backend_rex_version_check 2>&1) && fail "API revision 3 must refuse"
  assert_contains "$out" "older than the verified floor 4" "the API floor refusal should name the floor"
  rm -f "$FAKE/status.json"
  printf 'block.close\n' >"$FAKE/methods"
  out=$(fm_backend_rex_version_check 2>&1) && fail "a missing API method must refuse"
  assert_contains "$out" "lacks the required API method" "a missing method should be named"
  printf '4' >"$FAKE/exit"
  out=$(fm_backend_rex_version_check 2>&1) && fail "an unreachable server must refuse"
  assert_contains "$out" "never starts the Rex server" "the unreachable refusal should say Firstmate never starts it"
  pass "rex: the version gate checks the server API floor and methods and refuses an unreachable server"
}

test_container_ensure_pins_server_and_instance() {
  new_case ensure
  fm_backend_rex_container_ensure || fail "container_ensure failed"
  [ "$FM_BACKEND_REX_SERVER" = "$SERVER" ] || fail "container_ensure did not pin the server"
  [ "$FM_BACKEND_REX_SERVER_INSTANCE" = inst-1 ] || fail "container_ensure did not record the server instance"
  unset FM_BACKEND_REX_SERVER FM_BACKEND_REX_SERVER_INSTANCE
  pass "rex: container_ensure pins the server and records its instance id"
}

# --- creation -----------------------------------------------------------------

window_new_json() {
  printf '{"window_id":"window:%s","block_ids":["block:%s"],"revision":2}' "$WID" "$BID" >"$FAKE/window-new.json"
}

test_create_task_creates_the_fm_local_session_with_the_task_as_first_tab() {
  local out
  new_case create-new
  printf '{"session_id":"session:%s","initial_windows":[{"window_id":"window:%s","block_ids":["block:%s"]}]}' "$SID" "$WID" "$BID" >"$FAKE/new.json"
  out=$(fm_backend_rex_create_task fm-t1 /work/proj) || fail "create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "create_task must print bare session/window/block uuids, got '$out'"
  calls | grep -q " new fm-local -c /work/proj --window Ship · t1 --keep-open --json" \
    || fail "the fm-local session should be created with the task as its first, kept-open tab: $(calls)"
  calls | grep -q " block close " && fail "the new session's first tab is the task tab and must not be closed"
  calls | grep -q " window new " && fail "a new fm-local session needs no second tab"
  calls | grep -q " block rename -s session:$SID block:$BID $(fm_backend_rex_scoped_name fm-t1)" \
    || fail "the block must be labeled with the home-scoped name"

  new_case create-existing
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$SID" >"$FAKE/ls.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj) || fail "create_task failed"
  calls | grep -q " window new -s session:$SID Ship · t1 -c /work/proj --focus=false --keep-open --json" \
    || fail "the task tab must be created with --focus=false --keep-open and the fallback sidebar label: $(calls)"
  new_case create-labeled
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$SID" >"$FAKE/ls.json"
  window_new_json
  fm_backend_rex_create_task fm-t1 /work/proj "" "" "P3 · Rex status" >/dev/null || fail "create_task with a tab label failed"
  calls | grep -q " window new -s session:$SID P3 · Rex status -c /work/proj " \
    || fail "an explicit tab label must be used as given: $(calls)"
  calls | grep -q " window move " && fail "an ordinary task tab is never reordered"
  pass "rex: a primary-home task opens in the fm-local session (created with the task as its first tab), unfocused and kept open"
}

test_create_task_adopts_a_unique_home_session_and_refuses_duplicates() {
  local out
  new_case create-adopt
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"},{"session_id":"session:%s","label":"other"}]}' "$SID" "$LSID" >"$FAKE/ls.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj) || fail "create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "unexpected ids '$out'"
  calls | grep -q -- "--autostart=false new " && fail "an existing unique fm-local session must be adopted, not duplicated"

  new_case create-ambiguous
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"},{"session_id":"session:%s","label":"fm-local"}]}' "$SID" "$LSID" >"$FAKE/ls.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj 2>&1) && fail "two fm-local sessions must refuse"
  assert_contains "$out" "refusing to guess" "the ambiguity refusal should explain itself"

  new_case create-dup
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$SID" >"$FAKE/ls.json"
  printf '{"blocks":[{"block_id":"block:%s","label":"%s"}]}' "$BID" "$(fm_backend_rex_scoped_name fm-t1)" >"$FAKE/blocks/session_$SID.json"
  out=$(fm_backend_rex_create_task fm-t1 /work/proj 2>&1) && fail "a live duplicate label must refuse"
  assert_contains "$out" "already exists" "the duplicate refusal should say so"

  new_case create-unreadable
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$SID" >"$FAKE/ls.json"
  printf '{"blocks":[]}' >"$FAKE/blocks/session_$SID.json"
  printf '1' >"$FAKE/blocks/session_$SID.exit"
  out=$(fm_backend_rex_create_task fm-t1 /work/proj 2>&1) && fail "an unreadable block inventory must refuse"
  assert_contains "$out" "could not read the Rex block inventory" "the unreadable refusal should say so"
  pass "rex: create_task adopts a unique home session, refuses two, and refuses a duplicate or unreadable inventory"
}

test_create_task_in_rex_never_uses_the_supervisor_session() {
  local out
  new_case create-launcher
  inspect_json "$LBID" "$LSID"
  process_json "$LBID" "{\"child\":{\"pid\":$$},\"foreground\":{\"pid\":$$,\"name\":\"bash\"},\"last_exit\":null}"
  printf '{"session_id":"session:%s","initial_windows":[{"window_id":"window:%s","block_ids":["block:%s"]}]}' "$SID" "$WID" "$BID" >"$FAKE/new.json"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID fm_backend_rex_create_task fm-t1 /work/proj) || fail "create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "the task tab should open in a new fm-local session, got '$out'"
  calls | grep -q " window new -s session:$LSID" && fail "a task tab must never open in the supervisor's own session"
  calls | grep -q " new fm-local " || fail "a proven launcher must still get the dedicated fm-local session: $(calls)"

  new_case create-launcher-recorded
  inspect_json "$LBID" "$LSID"
  process_json "$LBID" "{\"child\":{\"pid\":$$},\"foreground\":{\"pid\":$$,\"name\":\"bash\"},\"last_exit\":null}"
  printf '{"session_id":"session:%s","label":"captain-work","windows":[]}' "$LSID" >"$FAKE/session/session_$LSID.json"
  printf '{"session_id":"session:%s","initial_windows":[{"window_id":"window:%s","block_ids":["block:%s"]}]}' "$SID" "$WID" "$BID" >"$FAKE/new.json"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID fm_backend_rex_create_task fm-t1 /work/proj "" "$LSID") || fail "create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "a record naming the supervisor's session must not pull a reclaim into it, got '$out'"

  new_case create-launcher-labeled
  inspect_json "$LBID" "$LSID"
  process_json "$LBID" "{\"child\":{\"pid\":$$},\"foreground\":{\"pid\":$$,\"name\":\"bash\"},\"last_exit\":null}"
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$LSID" >"$FAKE/ls.json"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID fm_backend_rex_create_task fm-t1 /work/proj 2>&1) \
    && fail "a supervisor session labeled fm-local must refuse rather than receive worker tabs"
  assert_contains "$out" "supervisor's session" "the refusal should name the supervisor's session"
  pass "rex: inside a proven Rex pane, task tabs open in fm-local and never in the supervisor's own session"
}

# --- targets, I/O ------------------------------------------------------------

test_parse_target() {
  fm_backend_rex_parse_target "$T" || fail "a bare uuid pair should parse"
  [ "$FM_BACKEND_REX_SESSION_ID" = "session:$SID" ] && [ "$FM_BACKEND_REX_BLOCK_ID" = "block:$BID" ] \
    || fail "parse_target did not rebuild typed ids"
  fm_backend_rex_parse_target "session:$SID:block:$BID" && fail "typed ids are not a target"
  fm_backend_rex_parse_target "$SID" && fail "a target needs two halves"
  fm_backend_rex_parse_target "fm-x:$BID" && fail "a non-uuid half must refuse"
  pass "rex: targets are exactly <session-uuid>:<block-uuid>"
}

test_target_ready_checks_session_and_label() {
  new_case ready
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  fm_backend_rex_target_ready "$T" fm-t1 || fail "a matching block should be ready"
  fm_backend_rex_target_ready "$T" fm-t2 && fail "a block with another task's label must not be ready"
  inspect_json "$BID" "$LSID" "$(fm_backend_rex_scoped_name fm-t1)"
  fm_backend_rex_target_ready "$T" fm-t1 && fail "a block in another session must not be ready"
  rm -f "$FAKE/inspect/block_$BID.json"
  fm_backend_rex_target_ready "$T" fm-t1
  [ "$FM_BACKEND_REX_READY_RC" = 3 ] || fail "a missing block should report gone (3), got $FM_BACKEND_REX_READY_RC"
  printf '4' >"$FAKE/exit"
  fm_backend_rex_target_ready "$T" fm-t1
  [ "$FM_BACKEND_REX_READY_RC" = 4 ] || fail "an unreachable server should report 4, got $FM_BACKEND_REX_READY_RC"
  pass "rex: target_ready verifies session, label, and separates gone (3) from unreachable (4)"
}

test_capture_send_and_keys() {
  local out
  new_case io
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  printf 'one\r\ntwo\r\nthree\r\n' >"$FAKE/capture/block_$BID.txt"
  out=$(fm_backend_rex_capture "$T" 2 fm-t1)
  [ "$out" = "two"$'\n'"three" ] || fail "capture should be a carriage-return-free tail, got '$out'"
  fm_backend_rex_send_literal "$T" "-n option-shaped" fm-t1 || fail "send_literal failed"
  grep -qx -- "-n option-shaped" "$FAKE/sent" || fail "the literal should arrive on stdin unchanged"
  calls | grep -- " send " | grep -q "option-shaped" && fail "the literal must never ride argv"
  for key in Enter Escape C-c C-u Tab; do
    fm_backend_rex_send_key "$T" "$key" fm-t1 || fail "$key should be deliverable"
  done
  for key in enter escape ctrl+c ctrl+u tab; do
    calls | grep -q " send-key -s session:$SID -b block:$BID $key\$" || fail "missing normalized key $key"
  done
  out=$(fm_backend_rex_send_key "$T" F13 fm-t1 2>&1) && fail "an unknown key must refuse"
  assert_contains "$out" "unsupported rex key" "the key refusal should name the key"
  : >"$FAKE/log"
  fm_backend_rex_send_text_line "$T" "echo hi" fm-t1 || fail "send_text_line should report submitted"
  calls | grep -q " send-key .* enter$" || fail "send_text_line must submit with enter"
  printf '1' >"$FAKE/send.exit"
  fm_backend_rex_send_text_line "$T" "echo hi" fm-t1
  [ "$?" -eq 1 ] || fail "a failed type must report nothing pending (1)"
  pass "rex: capture tails without CR, text rides stdin, keys normalize, and unknown keys refuse"
}

test_composer_state_and_submit() {
  local out
  new_case composer
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  printf '\033[38;5;5m❯\033[0m \r\n' >"$FAKE/capture/block_$BID.vt"
  out=$(fm_backend_rex_composer_state "$T" fm-t1)
  [ "$out" = empty ] || fail "a bare styled prompt should read empty, got '$out'"
  printf '\033[38;5;5m❯\033[0m typed text\r\n' >"$FAKE/capture/block_$BID.vt"
  out=$(fm_backend_rex_composer_state "$T" fm-t1)
  [ "$out" = pending ] || fail "typed text should read pending, got '$out'"
  rm -f "$FAKE/inspect/block_$BID.json"
  out=$(fm_backend_rex_composer_state "$T" fm-t1)
  [ "$out" = unknown ] || fail "an unreadable composer should read unknown, got '$out'"
  out=$(fm_backend_rex_send_text_submit "$T" "hello" 2 0 0 fm-t1)
  [ "$out" = send-failed ] || fail "a submit to a gone block should report send-failed, got '$out'"
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  printf '\033[38;5;5m❯\033[0m \r\n' >"$FAKE/capture/block_$BID.vt"
  out=$(fm_backend_rex_send_text_submit "$T" "hello" 2 0 0 fm-t1)
  [ "$out" = empty ] || fail "a landed submit should report empty, got '$out'"
  out=$(fm_backend_composer_state rex "$T" fm-t1)
  [ "$out" = empty ] || fail "fm_backend_composer_state should route rex, got '$out'"
  pass "rex: the styled composer capture feeds the shared classifier and the shared submit core"
}

# --- liveness, absence, kill ---------------------------------------------------

test_agent_state_mapping() {
  local out
  new_case agent
  inspect_json "$BID" "$SID"
  process_json "$BID" '{"child":{"pid":1},"foreground":{"pid":999999,"name":"2.1.306","path":"/Users/me/.local/share/claude/versions/2.1.306","argv0":"claude"},"last_exit":null}'
  out=$(fm_backend_agent_state rex "$T")
  [ "$out" = alive ] || fail "a claude foreground should read alive, got '$out'"
  process_json "$BID" '{"child":{"pid":1},"foreground":{"pid":999999,"name":"zsh","path":"/bin/zsh","argv0":"-zsh"},"last_exit":null}'
  out=$(fm_backend_agent_state rex "$T")
  [ "$out" = dead ] || fail "a shell-only foreground should read dead, got '$out'"
  process_json "$BID" '{"child":{"pid":1},"foreground":{"pid":999999,"name":"sleep","path":"/bin/sleep","argv0":"sleep"},"last_exit":null}'
  out=$(fm_backend_agent_state rex "$T")
  [ "$out" = ambiguous ] || fail "a non-agent, non-shell foreground should read ambiguous, got '$out'"
  process_json "$BID" '{"child":{"pid":1},"foreground":{"pid":999999,"name":"zsh","path":"/bin/zsh","argv0":"-zsh"},"last_exit":{"exit_code":0}}'
  out=$(fm_backend_agent_state rex "$T")
  [ "$out" = dead ] || fail "a recorded last_exit should read dead, got '$out'"
  rm -f "$FAKE/inspect/block_$BID.json"
  out=$(fm_backend_agent_state rex "$T")
  [ "$out" = missing ] || fail "exit 3 on the full block id should read missing, got '$out'"
  printf '4' >"$FAKE/exit"
  out=$(fm_backend_agent_state rex "$T")
  [ "$out" = unreadable ] || fail "an unreachable server must read unreadable, never missing, got '$out'"
  out=$(fm_backend_agent_state rex "not-a-target")
  [ "$out" = unreadable ] || fail "a malformed target should read unreadable, got '$out'"
  pass "rex: agent_state maps agent/shell/other foregrounds, last_exit, exit 3, and exit 4"
}

test_absence_verdict() {
  local out
  new_case absence
  out=$(fm_control_endpoint_absence_verdict rex "$T")
  [ "${out%%$'\t'*}" = gone ] || fail "exit 3 from the recorded server should prove absence, got '$out'"
  printf '4' >"$FAKE/exit"
  out=$(fm_control_endpoint_absence_verdict rex "$T")
  [ "${out%%$'\t'*}" = unproven ] || fail "an unreachable server must leave absence unproven, got '$out'"
  pass "rex: absence is proven by exit 3 from the recorded server and never by an unreachable one"
}

test_kill_closes_proves_gone_and_retires_the_home_session() {
  local out
  new_case kill
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  : >"$FAKE/close-removes"
  printf '{"session_id":"session:%s","label":"fm-local","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  fm_backend_kill rex "$T" "" fm-t1 || fail "kill should succeed"
  calls | grep -q " block close -s session:$SID block:$BID" || fail "kill must close the exact block"
  calls | grep -q " kill session:$SID" || fail "an emptied fm-local session should be retired"
  fm_backend_rex_apply_transition "$STATE" "$SID" "$(fm_transition_record "$BID" "$SID" "" dead "")" >/dev/null \
    && fail "a block Firstmate closed itself must never escalate as dead"
  fm_backend_clear_transition rex "$STATE" "$T"
  fm_backend_rex_apply_transition "$STATE" "$SID" "$(fm_transition_record "$BID" "$SID" "" dead "")" >/dev/null \
    || fail "clearing the transition must re-arm the dead edge"

  new_case kill-keep
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  : >"$FAKE/close-removes"
  printf '{"session_id":"session:%s","label":"captain-work","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  fm_backend_kill rex "$T" "" fm-t1 || fail "kill should succeed"
  calls | grep -q " kill session:" && fail "a session with another label must never be retired"
  : >"$FAKE/log"
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  REX_SESSION=session:$SID fm_backend_kill rex "$T" "" fm-t1 || fail "kill should succeed"
  calls | grep -q " session inspect" && fail "Firstmate's own supervisor session must never be considered for retirement"

  new_case kill-gone
  fm_backend_kill rex "$T" "" fm-t1 || fail "an already-gone block is a successful kill"
  calls | grep -q " block close" && fail "a gone block must not be closed again"

  new_case kill-unreachable
  printf '4' >"$FAKE/exit"
  out=$(fm_backend_kill rex "$T" "" fm-t1 2>&1) && fail "an unreachable server must not report a closed endpoint"
  assert_contains "$out" "unreachable" "the unreachable refusal should say so"

  new_case kill-renamed
  inspect_json "$BID" "$SID" "someone-else"
  out=$(fm_backend_kill rex "$T" "" fm-t1 2>&1) && fail "a block with another label must not be closed"
  calls | grep -q " block close" && fail "a mismatched block must not be closed"

  new_case kill-stuck
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  out=$(fm_backend_kill rex "$T" "" fm-t1 2>&1) && fail "a block still present after close must fail"
  assert_contains "$out" "still present" "the stuck-close refusal should say so"
  fm_backend_rex_apply_transition "$STATE" "$SID" "$(fm_transition_record "$BID" "$SID" "" dead "")" >/dev/null \
    || fail "a close that did not take must leave the block's dead edge armed"
  pass "rex: kill closes the exact block, proves exit 3, pre-commits its dead edge, retires only this home's emptied session, and refuses blind outcomes"
}

test_list_live_filters_by_home_scope() {
  local out
  new_case list
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$SID" >"$FAKE/ls.json"
  printf '{"blocks":[{"block_id":"block:%s","label":"%s"},{"block_id":"block:%s","label":"fm-other-home-t9"}]}' \
    "$BID" "$(fm_backend_rex_scoped_name fm-t1)" "$LBID" >"$FAKE/blocks/session_$SID.json"
  out=$(fm_backend_rex_list_live)
  [ "$out" = "$T"$'\t'fm-t1 ] || fail "list_live should list only this home's blocks, got '$out'"
  pass "rex: list_live lists only this home's scoped blocks"
}

# --- selection and records -----------------------------------------------------

test_detection_requires_structural_proof() {
  local out errfile
  new_case detect
  errfile="$CASE/err"
  inspect_json "$LBID" "$LSID"
  process_json "$LBID" "{\"child\":{\"pid\":$$},\"foreground\":{\"pid\":$$},\"last_exit\":null}"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID TMUX=fake,1,0 fm_backend_detect)
  [ "$out" = tmux ] || fail "tmux started from a Rex pane must still detect tmux, got '$out'"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID HERDR_ENV=1 fm_backend_detect)
  [ "$out" = herdr ] || fail "herdr inside Rex must still detect herdr, got '$out'"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$CASE/none" fm_backend_name 2>"$errfile")
  [ "$out" = rex ] || fail "a proven Rex pane should detect rex, got '$out'"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL rex backend" "auto-detected rex should print its notice"
  process_json "$LBID" '{"child":{"pid":999999},"foreground":{"pid":999999},"last_exit":null}'
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$CASE/none" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "REX_* without process ancestry must not select rex, got '$out'"
  [ -s "$errfile" ] && fail "an unproven Rex marker must fall back to tmux silently"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$SID FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$CASE/none" fm_backend_name 2>/dev/null)
  [ "$out" = tmux ] || fail "a REX_BLOCK outside REX_SESSION must not select rex, got '$out'"
  rm -f "$FAKE/inspect/block_$LBID.json"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$CASE/none" fm_backend_name 2>/dev/null)
  [ "$out" = tmux ] || fail "a REX_BLOCK that is not live must not select rex, got '$out'"
  mkdir -p "$CASE/cfg"
  printf 'rex\n' >"$CASE/cfg/backend"
  out=$(FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$CASE/cfg" fm_backend_name)
  [ "$out" = rex ] || fail "config/backend=rex must select rex, got '$out'"
  pass "rex: detection stays innermost-first and needs live-block, session, and ancestry proof; config selects it explicitly"
}

test_validate_task_endpoint_arm() {
  local dir meta out
  dir="$TMP_ROOT/validate"
  mkdir -p "$dir"
  meta="$dir/t1.meta"
  write_meta() { # <window> <server> <sid> <bid>
    printf '%s\n' "window=$1" "endpoint_task_id=t1" "worktree=/w" "project=/p" "backend=rex" \
      "rex_server=$2" "rex_session_id=$3" "rex_block_id=$4" >"$meta"
  }
  write_meta "$T" "unix:///Users/me/Library/Application%20Support/rex/server.sock" "$SID" "$BID"
  fm_backend_validate_task_endpoint "$meta" t1 || fail "a valid rex record should validate"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$T" ] || fail "validation should select the window target"
  write_meta "$SID:$WID" "$SERVER" "$SID" "$BID"
  out=$(fm_backend_validate_task_endpoint "$meta" t1 2>&1) && fail "a window that is not session:block must refuse"
  assert_contains "$out" "rex endpoint metadata" "the refusal should name rex"
  write_meta "$T" "unix:///with space.sock" "$SID" "$BID"
  fm_backend_validate_task_endpoint "$meta" t1 2>/dev/null && fail "a server with whitespace must refuse"
  write_meta "$T" "" "$SID" "$BID"
  fm_backend_validate_task_endpoint "$meta" t1 2>/dev/null && fail "a missing server must refuse"
  write_meta "x:y" "$SERVER" "x" "y"
  fm_backend_validate_task_endpoint "$meta" t1 2>/dev/null && fail "non-uuid ids must refuse"
  pass "rex: cleanup identity requires the server, both uuids, and window=<session>:<block>"
}

# --- secondmates, reclaim, and session retirement ------------------------------

secondmate_home() { # <dir> <id> -> a secondmate home carrying its marker
  mkdir -p "$1/state"
  printf '%s\n' "$2" >"$1/.fm-secondmate-home"
}

test_secondmate_gets_its_own_session_as_first_tab() {
  local out sm
  new_case sm-new
  sm="$CASE/sm-home"
  secondmate_home "$sm" sm1
  # A proven launcher (the parent's own pane) must be ignored.
  inspect_json "$LBID" "$LSID"
  process_json "$LBID" "{\"child\":{\"pid\":$$},\"foreground\":{\"pid\":$$,\"name\":\"bash\"},\"last_exit\":null}"
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$LSID" >"$FAKE/ls.json"
  printf '{"session_id":"session:%s","initial_windows":[{"window_id":"window:%s","block_ids":["block:%s"]}]}' "$SID" "$WID" "$BID" >"$FAKE/new.json"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID fm_backend_rex_create_task fm-sm1 "$sm" "$sm" "") || fail "secondmate create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "the secondmate pane should be the new session's first tab, got '$out'"
  calls | grep -q " new fm-sm1 -c $sm --window Mate · sm1 --keep-open --json" \
    || fail "the secondmate session must be created as fm-<id> with its first tab: $(calls)"
  calls | grep -q " window new " && fail "a new secondmate session needs no second tab"
  calls | grep -q " block close " && fail "the new session's first tab is the secondmate pane and must not be closed"
  calls | grep -q " block rename -s session:$SID block:$BID $(fm_backend_rex_scoped_name fm-sm1)" \
    || fail "the secondmate block must carry the PARENT home's scoped name"

  new_case sm-unrecorded
  sm="$CASE/sm-home"
  secondmate_home "$sm" sm1
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-sm1"}]}' "$LSID" >"$FAKE/ls.json"
  out=$(fm_backend_rex_create_task fm-sm1 "$sm" "$sm" "" 2>&1) && fail "an unrecorded fm-<id> session must not be adopted for a secondmate pane"
  assert_contains "$out" "refusing to adopt" "the refusal should say it will not adopt the session"

  new_case sm-local
  sm="$CASE/sm-home"
  secondmate_home "$sm" local
  out=$(fm_backend_rex_create_task fm-local "$sm" "$sm" "" 2>&1) && fail "secondmate id 'local' must refuse"
  assert_contains "$out" "fm-local" "the refusal should name the colliding label"
  pass "rex: a secondmate gets a new fm-<id> session whose first tab is its pane, never the parent's nor an unrecorded one"
}

test_secondmate_home_workers_join_its_session() {
  local out sm
  new_case sm-workers
  sm="$CASE/sm-home"
  secondmate_home "$sm" sm1
  inspect_json "$LBID" "$LSID"
  process_json "$LBID" "{\"child\":{\"pid\":$$},\"foreground\":{\"pid\":$$,\"name\":\"bash\"},\"last_exit\":null}"
  printf '{"session_id":"session:%s","label":"fm-sm1","windows":[]}' "$LSID" >"$FAKE/session/session_$LSID.json"
  # A second fm-sm1 session elsewhere: the proven session wins without a label lookup.
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-sm1"},{"session_id":"session:%s","label":"fm-sm1"}]}' "$LSID" "$SID" >"$FAKE/ls.json"
  window_new_json
  out=$(FM_HOME=$sm FM_ROOT=$sm STATE=$sm/state REX_BLOCK=block:$LBID REX_SESSION=session:$LSID fm_backend_rex_create_task fm-w1 /work/proj) \
    || fail "a secondmate's worker create_task failed"
  [ "$out" = "$LSID $WID $BID" ] || fail "a secondmate's worker should open in the fm-<id> session it runs in, got '$out'"
  calls | grep -q " window move " && fail "a secondmate's worker tab must not displace the secondmate pane"

  new_case sm-workers-outside
  sm="$CASE/sm-home"
  secondmate_home "$sm" sm1
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"},{"session_id":"session:%s","label":"fm-sm1"}]}' "$LSID" "$SID" >"$FAKE/ls.json"
  window_new_json
  out=$(FM_HOME=$sm FM_ROOT=$sm STATE=$sm/state fm_backend_rex_create_task fm-w1 /work/proj) || fail "create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "outside Rex a secondmate's worker should adopt its unique fm-<id> session, got '$out'"
  pass "rex: a secondmate's own workers open as further tabs of its fm-<id> session"
}

test_secondmate_relaunch_reuses_its_recorded_live_session() {
  local out sm
  new_case sm-reuse
  sm="$CASE/sm-home"
  secondmate_home "$sm" sm1
  printf '{"session_id":"session:%s","label":"fm-sm1","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-sm1 "$sm" "$sm" "$SID") || fail "secondmate create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "the recorded live session should be reused, got '$out'"
  calls | grep -q -- "--autostart=false new " && fail "a live recorded session must not be duplicated"
  calls | grep -q " window new -s session:$SID Mate · sm1 -c $sm --focus=false --keep-open --json" || fail "the tab must open unfocused in the recorded session"
  calls | grep -q " window move -s session:$SID window:$WID --index 1" || fail "the secondmate tab must move to the front of a reused session"

  new_case sm-relabeled
  secondmate_home "$CASE/sm-home" sm1
  printf '{"session_id":"session:%s","label":"captain-work","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  printf '{"session_id":"session:%s","initial_windows":[{"window_id":"window:%s","block_ids":["block:%s"]}]}' "$LSID" "$WID" "$BID" >"$FAKE/new.json"
  out=$(fm_backend_rex_create_task fm-sm1 "$CASE/sm-home" "$CASE/sm-home" "$SID") || fail "create_task failed"
  [ "$out" = "$LSID $WID $BID" ] || fail "a recorded session now labeled otherwise must not be reused, got '$out'"

  new_case sm-unreadable
  secondmate_home "$CASE/sm-home" sm1
  printf '{}' >"$FAKE/session/session_$SID.json"
  printf '4' >"$FAKE/session/session_$SID.exit"
  out=$(fm_backend_rex_create_task fm-sm1 "$CASE/sm-home" "$CASE/sm-home" "$SID" 2>&1) && fail "an unreadable recorded session must refuse"
  assert_contains "$out" "could not read the recorded Rex session" "the refusal should name the recorded session"
  pass "rex: a secondmate relaunch reuses its live recorded session (tab moved first), never a relabeled one, and refuses an unreadable one"
}

test_reclaim_prefers_the_recorded_session() {
  local out
  new_case reclaim-live
  printf '{"session_id":"session:%s","label":"fm-local","windows":[]}' "$LSID" >"$FAKE/session/session_$LSID.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj "" "$LSID") || fail "reclaim create_task failed"
  [ "$out" = "$LSID $WID $BID" ] || fail "a reclaim should mint its tab in the live recorded session, got '$out'"
  calls | grep -q -- "--autostart=false new " && fail "a live recorded session needs no new home session"

  new_case reclaim-gone
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$SID" >"$FAKE/ls.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj "" "$LSID") || fail "reclaim create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "a gone recorded session should fall back to the home session, got '$out'"

  new_case reclaim-relabeled
  printf '{"session_id":"session:%s","label":"captain-work","windows":[]}' "$LSID" >"$FAKE/session/session_$LSID.json"
  printf '{"sessions":[{"session_id":"session:%s","label":"fm-local"}]}' "$SID" >"$FAKE/ls.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj "" "$LSID") || fail "reclaim create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "a recorded session no longer labeled fm-local must not be reused, got '$out'"
  pass "rex: a reclaim mints its tab in the recorded session while live and labeled, else in this home's session"
}

test_retirement_covers_secondmate_sessions_and_detached_blocks() {
  new_case retire-sm
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-sm1)"
  : >"$FAKE/close-removes"
  printf '{"session_id":"session:%s","label":"fm-sm1","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  fm_backend_kill rex "$T" "" fm-sm1 || fail "kill should succeed"
  calls | grep -q " kill session:$SID" || fail "an emptied fm-<id> session should retire with its secondmate"

  new_case retire-sm-other
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  : >"$FAKE/close-removes"
  printf '{"session_id":"session:%s","label":"fm-sm1","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  fm_backend_kill rex "$T" "" fm-t1 || fail "kill should succeed"
  calls | grep -q " kill session:" && fail "another secondmate's session must never retire with an unrelated task"

  new_case retire-detached
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  : >"$FAKE/close-removes"
  printf '{"session_id":"session:%s","label":"fm-local","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  printf '{"blocks":[{"block_id":"block:%s","label":"fm-afk-daemon-x","placement":"detached"}]}' "$LBID" >"$FAKE/blocks/session_$SID.json"
  fm_backend_kill rex "$T" "" fm-t1 || fail "kill should succeed"
  calls | grep -q " kill session:" && fail "a session holding a detached block must not be retired"
  pass "rex: an emptied secondmate session retires with that secondmate only, and a detached block keeps any session alive"
}

test_child_teardown_scoping_as_the_child_home() {
  local sm out
  new_case child-scope
  sm="$CASE/sm-home"
  secondmate_home "$sm" sm1
  out=$(FM_HOME=$sm FM_ROOT=$sm fm_backend_rex_scoped_name fm-w1)
  [ "$out" != "$(fm_backend_rex_scoped_name fm-w1)" ] || fail "a child home's scoped name must differ from the parent's"
  case "$out" in fm-2ndmate-sm1-*-w1) ;; *) fail "a child home's scoped name should carry its 2ndmate tag, got '$out'" ;; esac
  [ "$(FM_HOME=$sm fm_backend_rex_session_label)" = fm-sm1 ] || fail "a child home's session label should be fm-<id>"
  [ "$(fm_backend_rex_session_label)" = fm-local ] || fail "the primary home's session label should be fm-local"
  pass "rex: a secondmate home scopes its workers' labels and its session label by its own tag"
}

# --- away mode -----------------------------------------------------------------

test_supervisor_discovery_requires_proof() {
  local out
  new_case supervisor
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$ROOT/bin/fm-supervisor-target-lib.sh"
  inspect_json "$LBID" "$LSID"
  process_json "$LBID" "{\"child\":{\"pid\":$$},\"foreground\":{\"pid\":$$},\"last_exit\":null}"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID discover_supervisor_target)
  [ "$out" = "$LSID:$LBID" ] || fail "a proven Rex pane should be the supervisor target, got '$out'"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID discover_supervisor_backend)
  [ "$out" = rex ] || fail "a proven Rex pane should select the rex supervisor backend, got '$out'"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID TMUX_PANE=%9 discover_supervisor_backend)
  [ "$out" = tmux ] || fail "tmux inside Rex must stay tmux, got '$out'"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID HERDR_ENV=1 HERDR_PANE_ID=p1 discover_supervisor_backend)
  [ "$out" = herdr ] || fail "herdr inside Rex must stay herdr, got '$out'"
  out=$(discover_supervisor_rex_server)
  [ "$out" = "$SERVER" ] || fail "the supervisor's Rex server should resolve like the adapter's, got '$out'"
  process_json "$LBID" '{"child":{"pid":999999},"foreground":{"pid":999999},"last_exit":null}'
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID discover_supervisor_target) && fail "an inherited REX_BLOCK without ancestry must not be a supervisor target ('$out')"
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID discover_supervisor_backend)
  [ "$out" = tmux ] || fail "an unproven Rex pane should fall back to tmux, got '$out'"
  pass "rex: supervisor discovery takes a Rex pane only with ancestry proof, after tmux and herdr"
}

test_detached_block_create_and_close() {
  local out payload
  new_case detached
  printf '{"block_id":"block:%s","revision":4}' "$BID" >"$FAKE/api-call.json"
  out=$(fm_backend_rex_detached_create "session:$SID" fm-afk-daemon-x /home/fm $'exec daemon\n') || fail "detached_create failed"
  [ "$out" = "$T" ] || fail "detached_create should print the block's target, got '$out'"
  payload=$(grep $'\037session.new_block\037' "$FAKE/log" | tail -1 | awk -F '\037' '{print $NF}')
  [ "$(printf '%s' "$payload" | jq -r .label)" = fm-afk-daemon-x ] || fail "the detached block should carry its label: $payload"
  [ "$(printf '%s' "$payload" | jq -c .options.initial_input)" = '"exec daemon\n"' ] || fail "the daemon command should be typed into the block's login shell"
  calls | grep -q " api call -s session:$SID session.new_block " || fail "the block must be created in the given session"
  printf 'not-json' >"$FAKE/api-call.json"
  fm_backend_rex_detached_create "session:$SID" l /h x >/dev/null 2>&1 && fail "an unparseable create must fail"
  inspect_json "$BID" "$SID" fm-afk-daemon-x
  : >"$FAKE/close-removes"
  fm_backend_rex_block_close "$T" || fail "block_close should prove the block gone"
  fm_backend_rex_block_close "$T" || fail "closing a gone block is success"
  inspect_json "$BID" "$SID" fm-afk-daemon-x
  rm -f "$FAKE/close-removes"
  fm_backend_rex_block_close "$T" && fail "a block still present after close must fail"
  printf '4' >"$FAKE/exit"
  fm_backend_rex_block_close "$T" && fail "an unreachable server must never read as closed"
  pass "rex: a detached daemon block is created in the captain's session and closes only on proven exit 3"
}

test_afk_launch_rex_terminal_lifecycle() {
  local st out
  new_case afk
  st="$CASE/home/state"
  inspect_json "$LBID" "$LSID"
  printf '{"block_id":"block:%s","revision":4}' "$BID" >"$FAKE/api-call.json"
  inspect_json "$BID" "$LSID" "fm-afk-daemon-x"
  out=$(
    FM_STATE_OVERRIDE=$st FM_AFK_LAUNCH_ENTRY=/bin/true
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-afk-launch.sh"
    fm_afk_launch_create_rex "$LSID:$LBID" rex 2>&1 || echo "create-failed"
    cat "$st/.afk-daemon-terminal"
  )
  assert_contains "$out" "rex"$'\t'"$LSID:$BID"$'\t'"$SERVER" "the record should hold rex, the exact block target, and the server: $out"
  grep $'\037session.new_block\037' "$FAKE/log" | grep -q "FM_REX_SERVER=" || fail "the daemon command must carry FM_REX_SERVER"
  grep $'\037session.new_block\037' "$FAKE/log" | grep -q "FM_SUPERVISOR_BACKEND=rex" || fail "the daemon command must name the rex supervisor backend"
  : >"$FAKE/close-removes"
  out=$(
    FM_STATE_OVERRIDE=$st
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-afk-launch.sh"
    fm_afk_launch_record_read && fm_afk_launch_close_recorded && echo closed
  )
  [ "$out" = closed ] || fail "the recorded rex daemon block should close by exact id, got '$out'"
  [ ! -e "$st/.afk-daemon-terminal" ] || fail "a proven-closed daemon block should drop its record"
  calls | grep -q " block close -s session:$LSID block:$BID" || fail "close must address the recorded block"

  new_case afk-missing-captain
  out=$(
    FM_STATE_OVERRIDE="$CASE/home/state" FM_AFK_LAUNCH_ENTRY=/bin/true
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-afk-launch.sh"
    fm_afk_launch_create_rex "$LSID:$LBID" rex 2>&1 && echo created
  )
  assert_not_contains "$out" created "a captain pane that is not live must refuse the daemon launch"
  calls | grep -q "session.new_block" && fail "no daemon block may be created for a missing captain pane"
  pass "rex: /afk runs the daemon in a recorded detached block on the captain's server and closes it by exact id"
}

# The host control for a remote second mate reads its parent-route record on
# Rex: route names the visible fm-<id> session, an inconsistent record is
# unverified, and a rex endpoint is never relaunched onto herdr.
test_remote_control_rex_arm() {
  local home meta out rc
  new_case remote-control
  home="$CASE/rsm-home"
  mkdir -p "$home/bin" "$home/state/parent-route"
  printf 'rsm\n' >"$home/.fm-secondmate-home"
  : >"$home/AGENTS.md"
  meta="$home/state/parent-route/rsm.meta"
  write_route() { # <rex_session_id>
    printf '%s\n' "window=$T" "endpoint_task_id=rsm" "worktree=$home" "project=$home" "backend=rex" \
      "rex_server=$SERVER" "rex_session_id=$1" "rex_block_id=$BID" "harness=claude" "model=" "effort=" >"$meta"
  }
  write_route "$SID"
  out=$(FM_HOME=$home "$ROOT/bin/fm-remote-secondmate-control.sh" route rsm 2>&1) || fail "route should print a rex record: $out"
  assert_contains "$out" "backend=rex" "route should name the rex backend"
  assert_contains "$out" "target=$T" "route should print the exact block target"
  assert_contains "$out" "rex_session=fm-rsm" "route should name the visible fm-<id> session"
  assert_not_contains "$out" "herdr_session" "a rex route must not name a Herdr session"
  out=$(FM_HOME=$home "$ROOT/bin/fm-remote-secondmate-control.sh" state rsm 2>/dev/null)
  [ "$out" = missing ] || fail "a closed remote block should read missing, got '$out'"
  rc=0
  out=$(FM_HOME=$home "$ROOT/bin/fm-remote-secondmate-control.sh" launch rsm claude - - herdr 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rex endpoint must not be relaunched onto herdr"
  assert_contains "$out" "recorded on backend 'rex'" "the refusal should name the recorded backend"
  write_route "$LSID"
  out=$(FM_HOME=$home "$ROOT/bin/fm-remote-secondmate-control.sh" state rsm 2>/dev/null)
  [ "$out" = unverified ] || fail "a target outside the recorded session should be unverified, got '$out'"
  calls | grep -q ' close \| send \| kill ' && fail "reading a remote record must never close, send, or kill"
  pass "rex: the remote host control routes to fm-<id>, reads a gone block as missing, and refuses inconsistent or cross-backend records"
}

# --- Phase 3: tab labels, attention marks, busy, submit, events -----------------

test_tab_label_is_sidebar_sized() {
  local out
  out=$(fm_backend_rex_tab_label ship rex-backend-p3 "" "Rex backend phase 3: Rex-native status, events, notifications")
  [ "$out" = "Ship · Rex-native status" ] || fail "a backlog title must condense to its subject, got '$out'"
  out=$(fm_backend_rex_tab_label scout s1 "" "Prove extras (palette, web)")
  [ "$out" = "Scout · Prove extras" ] || fail "a scout keeps its marker and drops a parenthetical, got '$out'"
  out=$(fm_backend_rex_tab_label ship x "P3 · Rex status & events")
  [ "$out" = "P3 · Rex status & events" ] || fail "an explicit title is used as given, got '$out'"
  out=$(fm_backend_rex_tab_label ship x "A much longer explicit display title here")
  [ "$out" = "A much longer explicit…" ] || fail "a long title must clip at a word with an ellipsis, got '$out'"
  [ "$(printf '%s' "$out" | jq -Rr 'length')" -le "$FM_BACKEND_REX_TAB_LABEL_MAX" ] || fail "the clipped label is longer than the sidebar limit"
  out=$(fm_backend_rex_tab_label secondmate fm-docs)
  [ "$out" = "Mate · docs" ] || fail "a second mate without a title falls back to its id, got '$out'"
  out=$(fm_backend_rex_tab_label ship no-title-task "" "")
  [ "$out" = "Ship · no-title-task" ] || fail "with no title the task id stands in, got '$out'"
  pass "rex: tab labels are sidebar sized - explicit title, else a condensed backlog title, else the id, under a kind marker"
}

# mark_case: a case whose block resolves to a writable stand-in tty file.
mark_case() { # <name>
  local psdir
  new_case "$1"
  psdir="$CASE/psbin"
  mkdir -p "$psdir" "$CASE/dev"
  cat >"$psdir/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -o tty= "*) echo ttys999; exit 0 ;; esac
exec /bin/ps "$@"
SH
  chmod +x "$psdir/ps"
  export PATH="$psdir:$PATH" FM_BACKEND_REX_DEV_DIR="$CASE/dev"
  : >"$CASE/dev/ttys999"
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  process_json "$BID" '{"last_exit":null,"child":{"pid":1},"foreground":{"pid":1,"name":"zsh","path":"/bin/zsh","argv0":"-zsh"}}'
}

test_mark_is_one_status_record_plus_optional_notification() {
  local tty want
  mark_case mark
  tty="$CASE/dev/ttys999"
  fm_backend_rex_mark "$T" blocked question "Needs your decision" fm-t1 || fail "mark failed"
  want=$(printf '\033]7501;state=blocked:kind=question:app=firstmate:id=fm:msg=%s\033\134' "$(printf 'Needs your decision' | base64)")
  [ "$(cat "$tty")" = "$want" ] || fail "the mark must be exactly one OSC 7501 id=fm record: $(od -c "$tty" | head -3)"
  : >"$tty"
  fm_backend_rex_mark "$T" blocked question "Pick a db" fm-t1 "Firstmate: P3" || fail "mark with notification failed"
  grep -q $'\033\\]777;notify;Firstmate: P3;Pick a db\a' "$tty" || fail "a notifying mark must carry one OSC 777 notification: $(od -c "$tty" | head -5)"
  : >"$tty"
  fm_backend_rex_mark "$T" clear "" "" fm-t1 || fail "clear failed"
  [ "$(cat "$tty")" = $'\033]7501;state=clear:app=firstmate:id=fm\033\\' ] || fail "clear must remove only Firstmate's record: $(od -c "$tty")"
  : >"$tty"
  fm_backend_rex_mark "$T" blocked question "x" fm-other && fail "a block carrying another task's label must be refused"
  [ ! -s "$tty" ] || fail "a refused mark must write nothing"
  fm_backend_rex_mark "$T" "done" "" "PR ready" fm-t1 "P3 · Rex" "P3 · Rex" || fail "titled mark failed"
  want=$(printf '\033]7501;state=done:app=firstmate:id=fm:title=%s:msg=%s\033\134' "$(printf 'P3 · Rex' | base64)" "$(printf 'PR ready' | base64)")
  want="$want"$'\033]777;notify;P3 · Rex;PR ready\a'
  [ "$(cat "$tty")" = "$want" ] || fail "a titled mark must carry the tab label as its record title and notification title: $(od -c "$tty" | head -5)"
  pass "rex: a mark is one id=fm program-status record titled with the tab label (optionally with one OSC 777 notification), cleared alone, never on a foreign block"
}

test_progress_and_tint_sequences() {
  local tty want
  mark_case progress-tint
  tty="$CASE/dev/ttys999"
  fm_backend_rex_progress "$T" 44 $'Validating: review\t4/9' fm-t1 "P4 · Progress" || fail "progress failed"
  want=$(printf '\033]7501;state=working:app=firstmate:id=fm/validate:progress=44:title=%s:msg=%s\033\134' \
    "$(printf 'P4 · Progress' | base64)" "$(printf 'Validating: review 4/9' | base64)")
  [ "$(cat "$tty")" = "$want" ] || fail "progress must be one working id=fm/validate record with its percentage: $(od -c "$tty" | head -5)"
  : >"$tty"
  fm_backend_rex_progress "$T" "" "Validating" fm-t1 || fail "indeterminate progress failed"
  grep -q 'progress=' "$tty" && fail "an empty percentage must be indeterminate (no progress key)"
  : >"$tty"
  fm_backend_rex_progress "$T" clear "" fm-t1 || fail "progress clear failed"
  [ "$(cat "$tty")" = $'\033]7501;state=clear:app=firstmate:id=fm/validate\033\\' ] || fail "clear must remove only the progress record: $(od -c "$tty")"
  [ "$(fm_backend_rex_status_sequence "done" fm "" "" "" 50)" = $'\033]7501;state=done:app=firstmate:id=fm\033\\' ] || fail "progress is kept only for working and blocked"
  : >"$tty"
  fm_backend_rex_tint "$T" '#2b2614' fm-t1 || fail "tint failed"
  [ "$(cat "$tty")" = $'\033]11;#2b2614\033\\' ] || fail "a tint must be one OSC 11 set: $(od -c "$tty")"
  : >"$tty"
  fm_backend_rex_tint "$T" reset fm-t1 || fail "tint reset failed"
  [ "$(cat "$tty")" = $'\033]111\033\\' ] || fail "a reset must be one OSC 111: $(od -c "$tty")"
  : >"$tty"
  fm_backend_rex_tint "$T" '?' fm-t1 && fail "a query or any value other than #rrggbb must be refused"
  fm_backend_rex_tint "$T" '#2b2614' fm-other && fail "a tint for another task's label must be refused"
  fm_backend_rex_progress "$T" 10 x fm-other && fail "progress for another task's label must be refused"
  [ ! -s "$tty" ] || fail "a refused tint or progress must write nothing"
  pass "rex: progress is one id=fm/validate working record, a tint is one OSC 11 or OSC 111, neither queries nor lands on a foreign block"
}

test_mark_read_and_tab_rename() {
  local out
  mark_case mark-read
  printf '{"records":[{"state":"working","app":"claude-code"},{"id":"fm","state":"blocked","kind":"question","app":"firstmate","msg":"Needs it"}]}' \
    >"$FAKE/call/block_$BID.program_status.json"
  out=$(fm_backend_rex_mark_read "$T") || fail "mark_read failed"
  [ "$out" = $'blocked\tquestion\tNeeds it\t\t' ] || fail "mark_read must report only Firstmate's record, got '$out'"
  printf '{"records":[{"state":"working","app":"claude-code"},{"id":"fm/validate","state":"working","app":"firstmate","progress":55,"title":"P4","msg":"Validating"}]}' \
    >"$FAKE/call/block_$BID.program_status.json"
  [ "$(fm_backend_rex_mark_read "$T" fm/validate)" = $'working\t\tValidating\tP4\t55' ] || fail "mark_read must read a named Firstmate record with title and progress"
  printf '{"records":[{"state":"working","app":"claude-code"}]}' >"$FAKE/call/block_$BID.program_status.json"
  [ "$(fm_backend_rex_mark_read "$T")" = $'clear\t\t\t\t' ] || fail "no Firstmate record reads as clear"
  rm -f "$FAKE/call/block_$BID.program_status.json"
  fm_backend_rex_mark_read "$T" >/dev/null && fail "an unreadable pane must fail, never read as clear"
  printf '{"windows":[{"window_id":"window:%s","label":"P3 · Rex"}]}' "$WID" >"$FAKE/window-ls.json"
  fm_backend_rex_tab_rename "$T" "Ship · New title" fm-t1 || fail "tab rename failed"
  calls | grep -q " window rename -s session:$SID window:$WID Ship · New title" || fail "rename must set the tab label: $(calls)"
  : >"$FAKE/log"
  fm_backend_rex_tab_rename "$T" "P3 · Rex" fm-t1 || fail "tab rename failed"
  calls | grep -q " window rename " && fail "a label that already matches must not be renamed"
  fm_backend_rex_tab_rename "$T" "Ship · x" fm-other && fail "a block carrying another task's label must not be renamed"
  calls | grep -q " window rename " && fail "a refused rename must not rename"
  pass "rex: mark_read reports only Firstmate's record and fails on an unreadable pane; tab rename renames only on change"
}

test_busy_state_trusts_only_proven_program_status() {
  mark_case busy
  process_json "$BID" '{"last_exit":null,"child":{"pid":1},"foreground":{"pid":4242,"name":"2.1.308","path":"/Users/x/.local/share/claude/versions/2.1.308","argv0":"claude"}}'
  printf '{"records":[{"state":"working","app":"claude-code"}]}' >"$FAKE/call/block_$BID.program_status.json"
  [ "$(fm_backend_rex_busy_state "$T")" = busy ] || fail "a proven harness's working record over a live agent is busy"
  [ "$(fm_backend_busy_state rex "$T")" = busy ] || fail "the dispatcher must route rex busy_state"
  printf '{"records":[{"state":"blocked","kind":"permission","app":"claude-code"}]}' >"$FAKE/call/block_$BID.program_status.json"
  [ "$(fm_backend_rex_busy_state "$T")" = idle ] || fail "blocked is waiting on the human, so idle"
  printf '{"records":[{"state":"working","app":"some-tool"},{"id":"fm","state":"working","app":"claude-code"}]}' >"$FAKE/call/block_$BID.program_status.json"
  [ "$(fm_backend_rex_busy_state "$T")" = unknown ] || fail "an unproven app or a child record must never read busy"
  printf '{"records":[{"state":"working","app":"claude-code"}]}' >"$FAKE/call/block_$BID.program_status.json"
  process_json "$BID" '{"last_exit":null,"child":{"pid":1},"foreground":{"pid":1,"name":"zsh","path":"/bin/zsh","argv0":"-zsh"}}'
  [ "$(fm_backend_rex_busy_state "$T")" = unknown ] || fail "a working record left over a shell must not read busy"
  pass "rex: busy_state trusts only a proven harness's own root record, and busy also needs a live agent"
}

test_submit_confirms_from_a_working_edge() {
  local out
  mark_case submit
  printf '{"records":[{"state":"working","app":"claude-code","updated_at":"t2"}]}' >"$FAKE/call/block_$BID.program_status.json"
  out=$(FM_BACKEND_REX_SUBMIT_BASELINE=$'done\tt1' fm_backend_rex_submit_state "$T" fm-t1)
  [ "$out" = empty ] || fail "a done -> working edge after the submit confirms it, got '$out'"
  out=$(FM_BACKEND_REX_SUBMIT_BASELINE='' fm_backend_rex_submit_state "$T" fm-t1)
  [ "$out" = empty ] || fail "a first working record after the submit confirms it, got '$out'"
  out=$(FM_BACKEND_REX_SUBMIT_BASELINE=$'working\tt1' fm_backend_rex_submit_state "$T" fm-t1)
  [ "$out" = unknown ] || fail "an agent already working before the submit proves nothing, got '$out'"
  printf '{"records":[{"state":"working","app":"some-tool"}]}' >"$FAKE/call/block_$BID.program_status.json"
  out=$(FM_BACKEND_REX_SUBMIT_BASELINE='' fm_backend_rex_submit_state "$T" fm-t1)
  [ "$out" = unknown ] || fail "an unproven app's working record proves nothing, got '$out'"
  pass "rex: submit confirmation accepts a proven harness's not-working -> working edge and nothing else"
}

events_line() { # <block-uuid> <state> <app> [id]
  printf '{"type":"session_event","payload":{"session_id":"session:%s","event":{"type":"block_event","payload":{"block_id":"block:%s","name":"program_status_changed","payload":{"id":"%s","record":{"state":"%s","app":"%s"}}}}}}\n' \
    "$SID" "$1" "${4:-}" "$2" "$3"
}

test_wait_transition_reads_rex_events() {
  local out rc other=01a15f2e-c301-7b2b-a2fb-000000000001
  new_case events
  export FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1
  inspect_json "$BID" "$SID"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  {
    printf '{"type":"session_event","payload":{"event":{"type":"client_connected"}}}\n'
    events_line "$BID" blocked firstmate fm
    events_line "$other" blocked claude-code
    events_line "$BID" blocked claude-code
  } >"$FAKE/events.jsonl"
  out=$(fm_backend_rex_wait_transition "$SID" 5 "$STATE" "$T")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a watched root blocked record must be actionable (rc=$rc)"
  [ "$out" = "$BID"$'\t'"$SID"$'\t\t'"blocked"$'\t'"claude-code" ] || fail "unexpected record '$out'"
  calls | grep -q " events -s session:$SID --json" || fail "the reader must stream exactly the task session: $(calls)"
  fm_backend_rex_commit_transition "$STATE" "$SID" "$out" || fail "commit failed"
  out=$(fm_backend_rex_wait_transition "$SID" 1 "$STATE" "$T")
  rc=$?
  [ "$rc" -eq 1 ] || fail "an escalated pane must not re-escalate before a working edge (rc=$rc, '$out')"
  { printf '{"type":"x"}\n'; events_line "$BID" working claude-code; events_line "$BID" blocked claude-code; } >"$FAKE/events.jsonl"
  out=$(fm_backend_rex_wait_transition "$SID" 5 "$STATE" "$T") || fail "a working edge must re-arm the next blocked edge"

  new_case events-own
  inspect_json "$BID" "$SID"
  printf '{"records":[{"id":"fm","state":"blocked","app":"firstmate"}]}' >"$FAKE/call/block_$BID.program_status.json"
  { printf '{"type":"x"}\n'; events_line "$BID" blocked firstmate fm; events_line "$BID" blocked claude-code sub/agent; } >"$FAKE/events.jsonl"
  out=$(fm_backend_rex_wait_transition "$SID" 1 "$STATE" "$T")
  rc=$?
  [ "$rc" -eq 1 ] || fail "Firstmate's own marks and child records must never wake the watcher (rc=$rc, '$out')"

  new_case events-reconcile
  inspect_json "$BID" "$SID"
  printf '{"records":[{"state":"blocked","kind":"permission","app":"claude-code"}]}' >"$FAKE/call/block_$BID.program_status.json"
  printf '{"type":"x"}\n' >"$FAKE/events.jsonl"
  out=$(fm_backend_rex_wait_transition "$SID" 5 "$STATE" "$T") || fail "a pane already blocked at subscribe must be returned by the reconcile"
  [ "$(fm_transition_to_status "$out")" = blocked ] || fail "reconcile must report the blocked state, got '$out'"

  new_case events-dead
  inspect_json "$BID" "$SID"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  { printf '{"type":"x"}\n'
    printf '{"type":"session_event","payload":{"event":{"type":"block_event","payload":{"block_id":"block:%s","name":"child_exited","payload":{"exit_code":0}}}}}\n' "$BID"
  } >"$FAKE/events.jsonl"
  : >"$(fm_backend_rex_escalation_marker "$STATE" "$T")"
  out=$(fm_backend_rex_wait_transition "$SID" 5 "$STATE" "$T") || fail "child_exited on a watched block must be actionable, even after its blocked edge escalated"
  [ "$(fm_transition_to_status "$out")" = dead ] || fail "child_exited must normalize to dead, got '$out'"

  new_case events-gone
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  printf '{"type":"x"}\n' >"$FAKE/events.jsonl"
  out=$(fm_backend_rex_wait_transition "$SID" 5 "$STATE" "$T") || fail "a block gone (exit 3) at subscribe must reconcile as dead"
  [ "$(fm_transition_to_status "$out")" = dead ] || fail "exit 3 at reconcile must be dead, got '$out'"

  new_case events-unreachable
  inspect_json "$BID" "$SID"
  printf '4' >"$FAKE/events.exit"
  out=$(fm_backend_rex_wait_transition "$SID" 5 "$STATE" "$T")
  rc=$?
  [ "$rc" -eq 2 ] || fail "a stream that exits 4 makes the wait unusable (2), never a verdict (rc=$rc, '$out')"
  [ -z "$out" ] || fail "an unreachable server must never produce a record, got '$out'"
  unset FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED
  pass "rex: the event wait escalates a watched root blocked or dead edge once, ignores Firstmate's own marks, reconciles on subscribe, and treats exit 4 as unusable"
}

# marks_status: write <task>'s status log line.
marks_status() { # <task> <line>
  printf '%s\n' "$2" >"$STATE/$1.status"
}

test_marks_producer_converges_and_notifies_once() {
  local out tty
  mark_case marks
  tty="$CASE/dev/ttys999"
  mkdir -p "$FM_HOME/config"
  printf '%s\n' "window=$T" "backend=rex" "kind=ship" "rex_server=$SERVER" "rex_session_id=$SID" "rex_block_id=$BID" "rex_tab_label=P3 · Rex" >"$STATE/t1.meta"
  marks_status t1 "needs-decision [at=1700000000] [key=pick-db]: pick a database"
  out=$(FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" plan)
  [ "$out" = $'t1\tblocked\tquestion\tNeeds your decision: pick a database' ] || fail "needs-decision must plan a blocked question mark, got '$out'"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -q "id=fm:title=$(printf 'P3 · Rex' | base64):msg=" "$tty" || fail "sync must write the mark titled with the tab label: $(od -c "$tty" | head -3)"
  grep -q $'777;notify;P3 · Rex;Needs your decision: pick a database' "$tty" || fail "a new mark must notify once, titled with the tab label"
  : >"$tty"
  printf '{"records":[{"id":"fm","state":"blocked","kind":"question","app":"firstmate","title":"P3 · Rex","msg":"Needs your decision: pick a database"}]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  [ ! -s "$tty" ] || fail "an unchanged live mark must not be rewritten"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -q 'id=fm:title=' "$tty" || fail "a dropped record must be repaired"
  grep -q '777;notify' "$tty" && fail "a repair must not notify again"
  : >"$tty"
  marks_status t1 "working [at=1700000100]: back on it"
  printf '{"records":[{"id":"fm","state":"blocked","kind":"question","app":"firstmate","msg":"Needs your decision: pick a database"}]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -q 'state=clear:app=firstmate:id=fm' "$tty" || fail "a working task must clear its mark: $(od -c "$tty" | head -3)"
  [ ! -e "$STATE/.rex-mark-t1" ] || fail "a cleared mark must drop its cache"
  : >"$tty"
  : >"$FAKE/log"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  calls | grep -q 'program_status' && fail "a clear task with no cache must cost no Rex call"
  marks_status t1 "blocked [at=1700000200]: needs a GitHub login"
  out=$(FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" plan t1)
  [ "$(printf '%s' "$out" | cut -f3)" = auth ] || fail "a credential blocker must be kind auth, got '$out'"
  marks_status t1 "done [at=1700000300]: PR https://github.com/o/r/pull/9 checks green"
  out=$(FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" plan t1)
  assert_contains "$out" $'done\t\tPR ready: PR https://' "a done line with a URL plans a PR-ready done mark"
  marks_status t1 "failed [at=1700000400]: build broke"
  out=$(FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" plan t1)
  assert_contains "$out" $'error\t\tFailed: build broke' "failed plans an error mark"

  marks_status t1 "needs-decision [at=1700000500] [key=k2]: second call"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  : >"$tty"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -q 'id=fm:title=' "$tty" || fail "sync must write the second mark"
  [ -e "$STATE/.rex-mark-t1" ] || fail "a written mark must be cached"
  printf 'off\n' >"$FM_HOME/config/rex-status-marks"
  : >"$tty"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "off sync failed"
  grep -q 'state=clear:app=firstmate:id=fm' "$tty" || fail "turning marks off must clear the shown mark: $(od -c "$tty" | head -3)"
  [ ! -e "$STATE/.rex-mark-t1" ] || fail "off must drop the cache"
  : >"$tty"
  : >"$FAKE/log"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "off sync failed"
  [ ! -s "$tty" ] || fail "off with no cached mark must write nothing"
  calls | grep -q 'program_status' && fail "off with no cached mark must cost no Rex call"
  printf 'labels\n' >"$FM_HOME/config/rex-status-marks"
  out=$(FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync 2>&1) || fail "sync with an unknown value failed"
  assert_contains "$out" "unknown value; using on" "a value other than on or off must warn and read as on"
  grep -q 'id=fm:title=' "$tty" || fail "an unknown value must read as on"
  pass "rex: the marks producer plans from status, writes once, repairs without re-notifying, clears on resolve, and honors off"
}

test_nm_run_progress_reads_captured_status() {
  local out caps="$ROOT/tests/captures/no-mistakes-v1.70.1"
  out=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_progress "$(cat "$2")"' _ "$ROOT" "$caps/replacement.toon")
  [ "$out" = $'88\t9\t9\tci\tstarting' ] || fail "a run at its ci step must read 8 of 9 steps done with ci active, got '$out'"
  out=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_progress "$(cat "$2")"' _ "$ROOT" "$caps/parked.toon")
  [ "$(printf '%s' "$out" | cut -f2-4)" = $'4\t9\ttest' ] || fail "a parked run must name its first unfinished step, got '$out'"
  out=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_table_column "$2" active_steps last_activity' _ "$ROOT" "$(cat "$caps/replacement.toon")")
  assert_contains "$out" "quiet 2h58m ago: log: all CI checks passed" "a quoted cell must be read whole by column name"
  bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_progress "$(cat "$2")"' _ "$ROOT" "$caps/overview.toon" >/dev/null \
    && fail "output with no steps table must fail"
  pass "rex: validation progress reads captured no-mistakes status by column name"
}

# nm_status_fake: a `no-mistakes` on PATH whose `axi status` prints
# $CASE/nm-status.toon and logs each call to $CASE/nm.log.
nm_status_fake() {
  cat >"$CASE/psbin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FM_NM_FAKE_DIR:?}/nm.log"
[ "$1 $2" = "axi status" ] && cat "$FM_NM_FAKE_DIR/nm-status.toon"
exit 0
SH
  chmod +x "$CASE/psbin/no-mistakes"
  export FM_NM_FAKE_DIR=$CASE
}

nm_run_toon() { # <branch> <status> <active-step> <round>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: $2
  head: abc1234
  steps[5]{step,status,findings,duration_ms}:
    intent,completed,0,10
    rebase,skipped,0,10
    review,$2,0,0
    test,pending,0,0
    push,pending,0,0
  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:
    $3,$2,1m,1m,"8s ago: log: reviewing, still going",4242,"$4"
EOF
}

test_marks_producer_shows_validation_progress_and_tint() {
  local tty out
  mark_case progress
  tty="$CASE/dev/ttys999"
  nm_status_fake
  mkdir -p "$FM_HOME/config" "$CASE/wt"
  printf '%s\n' "window=$T" "backend=rex" "kind=ship" "mode=no-mistakes" "branch=fm/t1" "worktree=$CASE/wt" \
    "rex_server=$SERVER" "rex_session_id=$SID" "rex_block_id=$BID" "rex_tab_label=P4 · Progress" >"$STATE/t1.meta"
  marks_status t1 "paused [at=1700000000]: waiting on my validation run"
  nm_run_toon fm/t1 running review "auto-fix 1/3" >"$CASE/nm-status.toon"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -q "state=working:app=firstmate:id=fm/validate:progress=40:title=$(printf 'P4 · Progress' | base64):msg=$(printf 'Validating: review 3/5, auto-fix 1/3' | base64)" "$tty" \
    || fail "a running validation must show its progress, active step, and round under the tab label: $(od -c "$tty" | head -5)"
  grep -q '777;notify' "$tty" && fail "progress must never notify"
  : >"$tty"
  printf '{"records":[{"id":"fm/validate","state":"working","app":"firstmate","progress":40,"title":"P4 · Progress","msg":"Validating: review 3/5, auto-fix 1/3"}]}' >"$FAKE/call/block_$BID.program_status.json"
  : >"$CASE/nm.log"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  [ ! -s "$tty" ] || fail "an unchanged progress record must not be rewritten"
  [ ! -s "$CASE/nm.log" ] || fail "a fresh progress plan must not re-read the run within the interval"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -q 'id=fm/validate:progress=40' "$tty" || fail "a dropped progress record must be repaired from the fresh plan"
  : >"$tty"
  nm_run_toon fm/other running review "" >"$CASE/nm-status.toon"
  printf '{"records":[{"id":"fm/validate","state":"working","app":"firstmate","progress":40}]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_REX_PROGRESS_INTERVAL=0 FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  [ "$(cat "$tty")" = $'\033]7501;state=clear:app=firstmate:id=fm/validate\033\\' ] || fail "a run on another branch must remove the progress record: $(od -c "$tty" | head -3)"
  : >"$tty"
  nm_run_toon fm/t1 completed review "" >"$CASE/nm-status.toon"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_REX_PROGRESS_INTERVAL=0 FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  [ ! -s "$tty" ] || fail "a finished run must show no progress"

  nm_run_toon fm/t1 running review "" >"$CASE/nm-status.toon"
  FM_REX_PROGRESS_INTERVAL=0 FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -q 'id=fm/validate:progress=40' "$tty" || fail "a run back in flight must show progress again"
  : >"$tty"
  marks_status t1 "needs-decision [at=1700000100] [key=k]: pick one"
  printf '{"records":[{"id":"fm/validate","state":"working","app":"firstmate","progress":40}]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_REX_PROGRESS_INTERVAL=0 FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -q 'state=clear:app=firstmate:id=fm/validate' "$tty" || fail "a task with a mark must not also show progress: $(od -c "$tty" | head -5)"
  grep -q '\]11;' "$tty" && fail "the tint is off unless config/rex-tint turns it on"

  printf 'subtle\n' >"$FM_HOME/config/rex-tint"
  : >"$tty"
  printf '{"records":[{"id":"fm","state":"blocked","kind":"question","app":"firstmate","title":"P4 · Progress","msg":"Needs your decision: pick one"}]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  [ "$(cat "$tty")" = $'\033]11;#2b2614\033\\' ] || fail "a waiting task must get exactly the subtle waiting tint: $(od -c "$tty" | head -3)"
  : >"$tty"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  [ ! -s "$tty" ] || fail "an unchanged tint must not be rewritten"
  marks_status t1 "failed [at=1700000200]: build broke"
  printf '{"records":[{"id":"fm","state":"error","app":"firstmate","title":"P4 · Progress","msg":"Failed: build broke"}]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  [ "$(cat "$tty")" = $'\033]11;#301a1c\033\\' ] || fail "a failed task must get the subtle failed tint: $(od -c "$tty" | head -3)"
  : >"$tty"
  marks_status t1 "working [at=1700000300]: back on it"
  printf '{"records":[]}' >"$FAKE/call/block_$BID.program_status.json"
  FM_REX_PROGRESS_INTERVAL=0 FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -qF $'\033]111\033\\' "$tty" || fail "a running task must have its tint reset: $(od -c "$tty" | head -3)"
  [ ! -e "$STATE/.rex-tint-t1" ] || fail "a reset tint must drop its cache"

  marks_status t1 "blocked [at=1700000400]: stuck"
  : >"$tty"
  printf 'subtle-light\n' >"$FM_HOME/config/rex-tint"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  grep -qF $'\033]11;#fbf4dd\033\\' "$tty" || fail "subtle-light must use the light-theme waiting tint"
  printf 'loud\n' >"$FM_HOME/config/rex-tint"
  : >"$tty"
  out=$(FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync 2>&1) || fail "sync failed"
  assert_contains "$out" "unknown value; using off" "an unknown tint value must warn and read as off"
  grep -qF $'\033]111\033\\' "$tty" || fail "a tint read as off must reset the shown tint"
  printf 'subtle\n' >"$FM_HOME/config/rex-tint"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" sync || fail "sync failed"
  [ -e "$STATE/.rex-tint-t1" ] || fail "a written tint must be cached"
  : >"$tty"
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-rex-marks.sh" clear t1 || fail "clear failed"
  grep -q $'state=clear:app=firstmate:id=fm\033' "$tty" || fail "clear must remove the mark (and the progress beneath it): $(od -c "$tty" | head -3)"
  grep -qF $'\033]111\033\\' "$tty" || fail "clear must reset the tint"
  [ ! -e "$STATE/.rex-tint-t1" ] && [ ! -e "$STATE/.rex-mark-t1" ] && [ ! -e "$STATE/.rex-progress-t1" ] || fail "clear must drop every cache"
  pass "rex: the producer shows a no-mistakes run's progress only while no mark is set, re-reads the run at most once per interval, and tints waiting and failed tasks only when config/rex-tint opts in"
}

test_every_call_pins_server_and_never_autostarts
test_server_resolution_prefers_the_task_record
test_version_gate
test_container_ensure_pins_server_and_instance
test_create_task_creates_the_fm_local_session_with_the_task_as_first_tab
test_create_task_adopts_a_unique_home_session_and_refuses_duplicates
test_create_task_in_rex_never_uses_the_supervisor_session
test_parse_target
test_target_ready_checks_session_and_label
test_capture_send_and_keys
test_composer_state_and_submit
test_agent_state_mapping
test_absence_verdict
test_kill_closes_proves_gone_and_retires_the_home_session
test_list_live_filters_by_home_scope
test_detection_requires_structural_proof
test_validate_task_endpoint_arm
test_secondmate_gets_its_own_session_as_first_tab
test_secondmate_home_workers_join_its_session
test_secondmate_relaunch_reuses_its_recorded_live_session
test_reclaim_prefers_the_recorded_session
test_retirement_covers_secondmate_sessions_and_detached_blocks
test_child_teardown_scoping_as_the_child_home
test_supervisor_discovery_requires_proof
test_detached_block_create_and_close
test_afk_launch_rex_terminal_lifecycle
test_remote_control_rex_arm
test_tab_label_is_sidebar_sized
test_mark_is_one_status_record_plus_optional_notification
test_mark_read_and_tab_rename
test_progress_and_tint_sequences
test_busy_state_trusts_only_proven_program_status
test_submit_confirms_from_a_working_edge
test_wait_transition_reads_rex_events
test_marks_producer_converges_and_notifies_once
test_nm_run_progress_reads_captured_status
test_marks_producer_shows_validation_progress_and_tint
