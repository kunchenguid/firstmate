#!/usr/bin/env bash
# tests/rex-test-safety.sh - private Rex server lifecycle and state-change
# isolation shared by real-Rex suites. Each run uses its own Unix socket,
# state directory, and empty config; no call can reach the user's server.
# All clients explicitly select the private endpoint with autostart disabled.
# Adapter calls pass through a forwarding guard which refuses state changes
# outside the sessions created by the test; non-test sessions' ids and labels
# must remain unchanged. Cleanup kills labeled test sessions, stops the owned
# server PID, and removes the temporary data.
# The caller defines fail() and pass(), and registers rex_test_cleanup on EXIT
# before calling rex_test_prepare so interrupted startup is also cleaned up.
set -u

REX_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REX_TEST_WORK=""
REX_TEST_REAL=""
REX_TEST_BEFORE=""
REX_TEST_CLEANED=""
REX_TEST_SERVER_PID=""
REX_TEST_ENDPOINT=""

# rex_test_prepare starts a private server. Missing jq or rex is a capability
# skip; server startup and readiness failures are test failures, never a
# fallback to another server.
rex_test_prepare() {
  unset REX_SESSION REX_BLOCK REX_SERVER
  export TERM_PROGRAM=fm-test
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the rex adapter)"; return 1; }
  # shellcheck source=/dev/null
  . "$REX_TEST_ROOT/bin/fm-backend.sh"
  fm_backend_source rex || { echo "not ok - could not source the rex adapter" >&2; return 2; }
  REX_TEST_REAL=$(fm_backend_rex_bin) || { echo "skip: rex CLI not found at \$REX_BIN_DIR, on PATH, or at the server bundle path"; return 1; }
  REX_TEST_WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-rex-test.XXXXXX")" && pwd -P) || return 2
  mkdir -p "$REX_TEST_WORK/guard" "$REX_TEST_WORK/home/state" "$REX_TEST_WORK/server-state"
  : >"$REX_TEST_WORK/allowed"
  : >"$REX_TEST_WORK/rex-config.lua"
  REX_TEST_ENDPOINT="unix://$REX_TEST_WORK/rex.sock"
  export REX_SERVER="$REX_TEST_ENDPOINT" FM_HOME="$REX_TEST_WORK/home" STATE="$REX_TEST_WORK/home/state"
  "$REX_TEST_REAL" --autostart=false server run --listen "$REX_TEST_ENDPOINT" \
    --state-dir "$REX_TEST_WORK/server-state" --config "$REX_TEST_WORK/rex-config.lua" --exit-empty \
    >"$REX_TEST_WORK/server.log" 2>&1 &
  REX_TEST_SERVER_PID=$!
  local i
  for i in {1..100}; do
    "$REX_TEST_REAL" --autostart=false -S "$REX_TEST_ENDPOINT" api call server.status >/dev/null 2>&1 && break
    kill -0 "$REX_TEST_SERVER_PID" 2>/dev/null || break
    sleep 0.1
  done
  if ! kill -0 "$REX_TEST_SERVER_PID" 2>/dev/null || ! "$REX_TEST_REAL" --autostart=false -S "$REX_TEST_ENDPOINT" api call server.status >/dev/null 2>&1; then
    echo "not ok - private Rex server failed to start; see $REX_TEST_WORK/server.log" >&2
    rex_test_cleanup
    return 2
  fi
  rex_test_write_guard "$REX_TEST_WORK/guard/rex"
  export REX_BIN_DIR="$REX_TEST_WORK/guard" FM_REX_TEST_REAL="$REX_TEST_REAL" \
    FM_REX_TEST_ENDPOINT="$REX_TEST_ENDPOINT" FM_REX_TEST_ALLOWED="$REX_TEST_WORK/allowed" \
    FM_REX_TEST_TRIP="$REX_TEST_WORK/tripwire" FM_REX_TEST_CALLS="$REX_TEST_WORK/calls"
  fm_backend_rex_version_check read >/dev/null 2>&1 || {
    echo "not ok - private Rex server is below the verified API revision" >&2
    rex_test_cleanup
    return 2
  }
  REX_TEST_BEFORE=$(rex_test_foreign_snapshot) || { echo "not ok - could not inspect private server" >&2; rex_test_cleanup; return 2; }
}

rex_test_write_guard() {  # <path>
  cat >"$1" <<'SH'
#!/usr/bin/env bash
# Forwarding guard: reads pass through; a state-changing command must name a
# session the test created, and `new` must be labeled fm-test-*. Each call is
# logged with whether the caller itself disabled autostart.
real=${FM_REX_TEST_REAL:?}; allowed=${FM_REX_TEST_ALLOWED:?}; trip=${FM_REX_TEST_TRIP:?}; endpoint=${FM_REX_TEST_ENDPOINT:?}
calls=${FM_REX_TEST_CALLS:?}
args=("$@"); i=0; autostart=default
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --autostart=false) autostart=off; i=$((i + 1)) ;;
    --*) i=$((i + 1)) ;;
    -S|-C) i=$((i + 2)) ;;
    *) break ;;
  esac
done
printf '%s\t%s\n' "$autostart" "$*" >>"$calls"
cmd=${args[$i]:-}; sub=${args[$((i + 1))]:-}
sid=; j=$i
while [ "$j" -lt "${#args[@]}" ]; do
  [ "${args[$j]}" = -s ] && sid=${args[$((j + 1))]:-}
  j=$((j + 1))
done
refuse() { printf '%s\n' "$*" >>"$trip"; echo "fm-rex-test guard: refused $*" >&2; exit 97; }
scoped() { [ -n "$sid" ] && grep -qxF -- "$sid" "$allowed" || refuse "$@"; }
case "$cmd" in
  version|whoami|ls|capture) ;;
  api)
    case " $* " in
      *" server.status "*|*" session.view "*) ;;
      *) refuse "$@" ;;
    esac ;;
  new)
    case "${args[$((i + 1))]:-}" in fm-test-*) ;; *) refuse "$@" ;; esac ;;
  window) [ "$sub" = new ] && scoped "$@" || refuse "$@" ;;
  block)
    case "$sub" in
      rename|close) scoped "$@" ;;
      call)
        case " $* " in
          *" size "*|*" process "*|*" program_status "*) ;;
          *) scoped "$@" ;;
        esac ;;
      *) refuse "$@" ;;
    esac ;;
  send|send-key|do) scoped "$@" ;;
  kill) grep -qxF -- "${args[$((i + 1))]:-}" "$allowed" || refuse "$@" ;;
  *) refuse "$@" ;;
esac
if [ "$cmd" = new ]; then
  out=$("$real" --autostart=false -S "$endpoint" "$@")
  rc=$?
  created=$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)
  case "$created" in session:*) printf '%s\n' "$created" >>"$allowed" ;; esac
  printf '%s\n' "$out"
  exit "$rc"
fi
exec "$real" --autostart=false -S "$endpoint" "$@"
SH
  chmod +x "$1"
}

# rex_test_foreign_snapshot: private-server sessions not created by this test,
# reduced to ids and labels.
rex_test_foreign_snapshot() {
  local sid
  rex_test_cli ls --json | jq -r '.sessions[].session_id' | sort | while IFS= read -r sid; do
    [ -z "$REX_TEST_WORK" ] || ! grep -qxF -- "$sid" "$REX_TEST_WORK/allowed" || continue
    rex_test_cli api call -s "$sid" session.view \
      | jq -cS '{session_id, label, windows: [.windows[]? | {window_id, label,
          blocks: [.layers[]?.blocks[]? | {block_id, label}]}]}'
  done
}

# rex_test_cli: connect only to the private server, with autostart disabled.
rex_test_cli() { "$REX_TEST_REAL" --autostart=false -S "$REX_TEST_ENDPOINT" "$@"; }

# rex_test_stop_server and rex_test_start_server control only this run's PID.
rex_test_stop_server() {
  [ -n "$REX_TEST_SERVER_PID" ] || return 0
  kill "$REX_TEST_SERVER_PID" 2>/dev/null || true
  wait "$REX_TEST_SERVER_PID" 2>/dev/null || true
  REX_TEST_SERVER_PID=""
}
rex_test_start_server() {
  "$REX_TEST_REAL" --autostart=false server run --listen "$REX_TEST_ENDPOINT" \
    --state-dir "$REX_TEST_WORK/server-state" --config "$REX_TEST_WORK/rex-config.lua" --exit-empty \
    >"$REX_TEST_WORK/server.log" 2>&1 &
  REX_TEST_SERVER_PID=$!
  local i
  for ((i=0; i<100; i++)); do
    rex_test_cli api call server.status >/dev/null 2>&1 && return 0
    kill -0 "$REX_TEST_SERVER_PID" 2>/dev/null || break
    sleep 0.1
  done
  return 1
}

# rex_test_new_session: create one fm-test-* session, allow the guard to act on
# it, and print "<session-id> <first-block-id>".
rex_test_new_session() {  # <label-suffix>
  local out sid bid
  out=$(fm_backend_rex_cli new "fm-test-$1-$$" --window fm-test-main --cwd "$REX_TEST_WORK" --json) || return 1
  sid=$(printf '%s' "$out" | jq -r .session_id)
  bid=$(printf '%s' "$out" | jq -r '.initial_windows[0].block_ids[0]')
  fm_backend_rex_id_valid session "$sid" && fm_backend_rex_id_valid block "$bid" || return 1
  printf '%s\n' "$sid" >>"$REX_TEST_WORK/allowed"
  printf '%s %s' "$sid" "$bid"
}

# rex_test_wait_for: retry a predicate every 0.2s.
rex_test_wait_for() {  # <tries> <command...>
  local tries=$1 n=0
  shift
  while [ "$n" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.2
    n=$((n + 1))
  done
  return 1
}

# rex_test_assert_isolated: no guard refusal and every other session unchanged.
rex_test_assert_isolated() {
  local after
  [ ! -s "$REX_TEST_WORK/tripwire" ] \
    || fail "the guard refused state-changing calls outside the test session:"$'\n'"$(cat "$REX_TEST_WORK/tripwire")"
  after=$(rex_test_foreign_snapshot) || fail "could not snapshot the other sessions after the test"
  [ "$REX_TEST_BEFORE" = "$after" ] \
    || fail "unexpected sessions appeared on the private test server:"$'\n'"$(diff <(printf '%s\n' "$REX_TEST_BEFORE") <(printf '%s\n' "$after"))"
  pass "real rex: all state-changing calls stayed within this run's private server"
}

# rex_test_cleanup: kill exactly the sessions this test created, re-checking
# each one's fm-test- label first, stop the private server, and remove its data.
rex_test_cleanup() {
  local sid label
  [ -z "$REX_TEST_CLEANED" ] || return 0
  REX_TEST_CLEANED=1
  [ -n "$REX_TEST_WORK" ] || return 0
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    label=$(rex_test_cli api call -s "$sid" session.view 2>/dev/null | jq -r '.label // empty')
    case "$label" in
      fm-test-*) rex_test_cli kill "$sid" >/dev/null 2>&1 || true ;;
      '') ;;
      *) printf 'note: not killing %s (label %s is not a test session)\n' "$sid" "$label" >&2 ;;
    esac
  done <"$REX_TEST_WORK/allowed"
  rex_test_stop_server
  rm -rf "$REX_TEST_WORK"
}
