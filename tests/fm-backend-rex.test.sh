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
#   window-new.json      `window new ... --json`
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
{ printf '%s' "$leak"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >>"$F/log"
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
  api) [ -f "$F/methods" ] || printf '%s\n' block.close session.new_window session.set_block_label com.superlogical.terminal.process com.superlogical.terminal.format >"$F/methods"; cat "$F/methods" ;;
  ls) [ -f "$F/ls.json" ] || printf '{"sessions":[]}' >"$F/ls.json"; emit "$F/ls.json" ;;
  new) emit "$F/new.json" 1 ;;
  window) emit "$F/window-new.json" 1 ;;
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

test_create_task_outside_rex_creates_an_empty_home_session() {
  local out
  new_case create-new
  printf '{"session_id":"session:%s","initial_windows":[{"window_id":"window:x","block_ids":["block:%s"]}]}' "$SID" "$LBID" >"$FAKE/new.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj) || fail "create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "create_task must print bare session/window/block uuids, got '$out'"
  calls | grep -q " new firstmate -c /work/proj --json" || fail "the home session should be created with the firstmate label"
  calls | grep -q " block close -s session:$SID block:$LBID" || fail "the session's initial shell tab should be closed"
  calls | grep -q " window new -s session:$SID proj·t1 -c /work/proj --focus=false --keep-open --json" \
    || fail "the task tab must be created with --focus=false --keep-open and a <project>·<id> label: $(calls)"
  calls | grep -q " block rename -s session:$SID block:$BID $(fm_backend_rex_scoped_name fm-t1)" \
    || fail "the block must be labeled with the home-scoped name"
  pass "rex: outside Rex, create_task makes one empty firstmate session and opens an unfocused kept-open tab"
}

test_create_task_adopts_a_unique_home_session_and_refuses_duplicates() {
  local out
  new_case create-adopt
  printf '{"sessions":[{"session_id":"session:%s","label":"firstmate"},{"session_id":"session:%s","label":"other"}]}' "$SID" "$LSID" >"$FAKE/ls.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj) || fail "create_task failed"
  [ "$out" = "$SID $WID $BID" ] || fail "unexpected ids '$out'"
  calls | grep -q -- "--autostart=false new " && fail "an existing unique firstmate session must be adopted, not duplicated"

  new_case create-ambiguous
  printf '{"sessions":[{"session_id":"session:%s","label":"firstmate"},{"session_id":"session:%s","label":"firstmate"}]}' "$SID" "$LSID" >"$FAKE/ls.json"
  window_new_json
  out=$(fm_backend_rex_create_task fm-t1 /work/proj 2>&1) && fail "two firstmate sessions must refuse"
  assert_contains "$out" "refusing to guess" "the ambiguity refusal should explain itself"

  new_case create-dup
  printf '{"sessions":[{"session_id":"session:%s","label":"firstmate"}]}' "$SID" >"$FAKE/ls.json"
  printf '{"blocks":[{"block_id":"block:%s","label":"%s"}]}' "$BID" "$(fm_backend_rex_scoped_name fm-t1)" >"$FAKE/blocks/session_$SID.json"
  out=$(fm_backend_rex_create_task fm-t1 /work/proj 2>&1) && fail "a live duplicate label must refuse"
  assert_contains "$out" "already exists" "the duplicate refusal should say so"

  new_case create-unreadable
  printf '{"sessions":[{"session_id":"session:%s","label":"firstmate"}]}' "$SID" >"$FAKE/ls.json"
  printf '{"blocks":[]}' >"$FAKE/blocks/session_$SID.json"
  printf '1' >"$FAKE/blocks/session_$SID.exit"
  out=$(fm_backend_rex_create_task fm-t1 /work/proj 2>&1) && fail "an unreadable block inventory must refuse"
  assert_contains "$out" "could not read the Rex block inventory" "the unreadable refusal should say so"
  pass "rex: create_task adopts a unique home session, refuses two, and refuses a duplicate or unreadable inventory"
}

test_create_task_in_rex_uses_the_launcher_session() {
  local out
  new_case create-launcher
  inspect_json "$LBID" "$LSID"
  process_json "$LBID" "{\"child\":{\"pid\":$$},\"foreground\":{\"pid\":$$,\"name\":\"bash\"},\"last_exit\":null}"
  window_new_json
  out=$(REX_BLOCK=block:$LBID REX_SESSION=session:$LSID fm_backend_rex_create_task fm-t1 /work/proj) || fail "create_task failed"
  [ "$out" = "$LSID $WID $BID" ] || fail "the task tab should open in the launcher's session, got '$out'"
  calls | grep -q -- "--autostart=false new " && fail "a proven launcher must never create a home session"
  pass "rex: inside a proven Rex pane, the task tab opens in firstmate's own session"
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
  printf '{"session_id":"session:%s","label":"firstmate","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  fm_backend_kill rex "$T" "" fm-t1 || fail "kill should succeed"
  calls | grep -q " block close -s session:$SID block:$BID" || fail "kill must close the exact block"
  calls | grep -q " kill session:$SID" || fail "an emptied firstmate session should be retired"

  new_case kill-keep
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  : >"$FAKE/close-removes"
  printf '{"session_id":"session:%s","label":"captain-work","windows":[]}' "$SID" >"$FAKE/session/session_$SID.json"
  fm_backend_kill rex "$T" "" fm-t1 || fail "kill should succeed"
  calls | grep -q " kill session:" && fail "a session with another label must never be retired"
  : >"$FAKE/log"
  inspect_json "$BID" "$SID" "$(fm_backend_rex_scoped_name fm-t1)"
  REX_SESSION=session:$SID fm_backend_kill rex "$T" "" fm-t1 || fail "kill should succeed"
  calls | grep -q " session inspect" && fail "firstmate's own launcher session must never be considered for retirement"

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
  pass "rex: kill closes the exact block, proves exit 3, retires only this home's emptied session, and refuses blind outcomes"
}

test_list_live_filters_by_home_scope() {
  local out
  new_case list
  printf '{"sessions":[{"session_id":"session:%s","label":"firstmate"}]}' "$SID" >"$FAKE/ls.json"
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

test_secondmate_spawn_is_refused() {
  local dir out
  dir="$TMP_ROOT/secondmate"
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects"
  out=$(PATH="$ORIG_PATH" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_PROJECTS_OVERRIDE="$dir/projects" "$ROOT/bin/fm-spawn.sh" sm-rex-test --secondmate --backend rex 2>&1)
  assert_contains "$out" "backend=rex supports ship and scout spawns only" "fm-spawn.sh must refuse --secondmate on rex"
  pass "fm-spawn.sh: --secondmate on rex is refused with a clear message"
}

test_every_call_pins_server_and_never_autostarts
test_server_resolution_prefers_the_task_record
test_version_gate
test_container_ensure_pins_server_and_instance
test_create_task_outside_rex_creates_an_empty_home_session
test_create_task_adopts_a_unique_home_session_and_refuses_duplicates
test_create_task_in_rex_uses_the_launcher_session
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
test_secondmate_spawn_is_refused
