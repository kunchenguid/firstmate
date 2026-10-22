#!/usr/bin/env bash
# tests/fm-backend-rex-smoke.test.sh - real Rex smoke test for the Rex
# session-provider adapter (bin/backends/rex.sh). Every other suite fakes the
# CLI; this one talks to the REAL personal Rex server, so it is built around
# not disturbing anything else on it:
#   - it never starts, stops, restarts, or reconfigures a server: it skips
#     unless a server is already reachable without autostart;
#   - it works only inside one session it creates itself, labeled fm-test-*,
#     addressed by explicit id, and kills exactly that session at exit;
#   - every adapter call goes through a forwarding guard on REX_BIN_DIR that
#     REFUSES any state-changing command naming a session outside the one the
#     test created (and any `new` not labeled fm-test-*), and the test fails
#     if the guard ever tripped;
#   - a before/after snapshot of every other session's structure (session,
#     window, and block ids and labels) must be byte-identical; concurrent
#     activity by another Rex user can also trip it, which the failure says.
# No harness is launched: only a plain shell runs in the test's blocks, so no
# update prompt or install can be triggered.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIP=""
GUARD_DIR=""
SMOKE_SID=""
WORK=""
CLEANED=""

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup_all
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

# The test must never mistake the caller's own Rex session for a launcher
# session it may place tabs into.
unset REX_SESSION REX_BLOCK REX_SERVER
export TERM_PROGRAM=fm-test

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the rex adapter)"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source rex || { echo "skip: could not source the rex adapter"; exit 0; }
REAL_REX=$(fm_backend_rex_bin) || { echo "skip: rex CLI not found at \$REX_BIN_DIR, on PATH, or at the server bundle path"; exit 0; }
"$REAL_REX" --autostart=false api call server.status >/dev/null 2>&1 \
  || { echo "skip: no Rex server is reachable (this test never starts one)"; exit 0; }
fm_backend_rex_version_check >/dev/null 2>&1 || { echo "skip: installed Rex is older than the verified API revision"; exit 0; }

WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-rex-smoke.XXXXXX")" && pwd -P)
GUARD_DIR="$WORK/guard"
TRIP="$WORK/tripwire"
mkdir -p "$GUARD_DIR" "$WORK/home/state" "$WORK/sub"
: >"$WORK/allowed"
export FM_HOME="$WORK/home" STATE="$WORK/home/state"

cat >"$GUARD_DIR/rex" <<'SH'
#!/usr/bin/env bash
# Forwarding guard: reads pass through; a state-changing command must name a
# session the smoke test created, and `new` must be labeled fm-test-*.
real=${FM_REX_SMOKE_REAL:?}; allowed=${FM_REX_SMOKE_ALLOWED:?}; trip=${FM_REX_SMOKE_TRIP:?}
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ] && [ "${args[$i]#--}" != "${args[$i]}" ]; do i=$((i + 1)); done
cmd=${args[$i]:-}; sub=${args[$((i + 1))]:-}
sid=; j=$i
while [ "$j" -lt "${#args[@]}" ]; do
  [ "${args[$j]}" = -s ] && sid=${args[$((j + 1))]:-}
  j=$((j + 1))
done
refuse() { printf '%s\n' "$*" >>"$trip"; echo "fm-rex-smoke guard: refused $*" >&2; exit 97; }
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
  send|send-key) scoped "$@" ;;
  kill) grep -qxF -- "${args[$((i + 1))]:-}" "$allowed" || refuse "$@" ;;
  *) refuse "$@" ;;
esac
exec "$real" "$@"
SH
chmod +x "$GUARD_DIR/rex"
export REX_BIN_DIR="$GUARD_DIR" FM_REX_SMOKE_REAL="$REAL_REX" FM_REX_SMOKE_ALLOWED="$WORK/allowed" FM_REX_SMOKE_TRIP="$TRIP"

# foreign_snapshot: every session except the test's own, reduced to its ids
# and labels (focus and revision change whenever a viewer clicks).
foreign_snapshot() {
  local sid
  "$REAL_REX" --autostart=false ls --json | jq -r '.sessions[].session_id' | sort | while IFS= read -r sid; do
    [ "$sid" != "$SMOKE_SID" ] || continue
    "$REAL_REX" --autostart=false api call -s "$sid" session.view \
      | jq -cS '{session_id, label, windows: [.windows[]? | {window_id, label,
          blocks: [.layers[]?.blocks[]? | {block_id, label}]}]}'
  done
}

cleanup_all() {
  local label
  [ -z "$CLEANED" ] || return 0
  CLEANED=1
  if [ -n "$SMOKE_SID" ]; then
    label=$("$REAL_REX" --autostart=false api call -s "$SMOKE_SID" session.view 2>/dev/null | jq -r '.label // empty')
    case "$label" in
      fm-test-*) "$REAL_REX" --autostart=false kill "$SMOKE_SID" >/dev/null 2>&1 || true ;;
      '') ;;
      *) printf 'note: not killing %s (label %s is not the test session)\n' "$SMOKE_SID" "$label" >&2 ;;
    esac
  fi
  [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup_all EXIT

wait_for() {  # <tries> <command...>: retry a predicate every 0.2s
  local tries=$1 n=0
  shift
  while [ "$n" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.2
    n=$((n + 1))
  done
  return 1
}

BEFORE=$(foreign_snapshot) || fail "could not snapshot the other sessions before the test"

# --- the test's own session --------------------------------------------------

OUT=$(fm_backend_rex_cli new "fm-test-smoke-$$" --window fm-test-main --cwd "$WORK" --json) \
  || fail "could not create the test's own fm-test- session"
SMOKE_SID=$(printf '%s' "$OUT" | jq -r .session_id)
MAIN_BLOCK=$(printf '%s' "$OUT" | jq -r '.initial_windows[0].block_ids[0]')
if ! fm_backend_rex_id_valid session "$SMOKE_SID" || ! fm_backend_rex_id_valid block "$MAIN_BLOCK"; then
  fail "rex new did not return session and block ids: $OUT"
fi
printf '%s\n' "$SMOKE_SID" >"$WORK/allowed"
pass "real rex: created the test's own session $SMOKE_SID"

# --- placement: a Rex-hosted launcher gets focus-safe tabs in its own session

TRIPLE=$(TERM_PROGRAM=rex REX_SESSION="$SMOKE_SID" REX_BLOCK="$MAIN_BLOCK" fm_backend_rex_create_task fm-test-alpha "$WORK") \
  || fail "create_task from a Rex-hosted launcher failed"
read -r SID WID BID <<<"$TRIPLE"
[ "$SID" = "$SMOKE_SID" ] || fail "the task tab must open in the launcher's own session, got $SID"
fm_backend_rex_id_valid window "$WID" || fail "create_task returned no window id"
T=$(fm_backend_rex_target "$SID" "$BID")
VIEW=$(fm_backend_rex_session_view "$SMOKE_SID")
[ "$(printf '%s' "$VIEW" | jq '.windows | length')" = 2 ] || fail "the launcher session must now hold two tabs"
[ "$(printf '%s' "$VIEW" | jq -r '.active_window_id')" != "$WID" ] || fail "the new tab must not take focus"
SIZE=$(fm_backend_rex_block_call "$T" size)
[ "$(printf '%s' "$SIZE" | jq -r '"\(.columns)x\(.rows)"')" = 200x50 ] || fail "the task block must be resized to 200x50, got $SIZE"
SCOPED=$(fm_backend_rex_scoped_name fm-test-alpha)
[ "$(printf '%s' "$VIEW" | jq -r --arg b "$BID" '.windows[].layers[].blocks[] | select(.block_id == $b) | .label')" = "$SCOPED" ] \
  || fail "the task block must carry the home-scoped label $SCOPED"
TERM_PROGRAM=rex REX_SESSION="$SMOKE_SID" REX_BLOCK="$MAIN_BLOCK" fm_backend_rex_create_task fm-test-alpha "$WORK" >/dev/null 2>&1 \
  && fail "a duplicate task label in the session must be refused"
pass "real rex: a Rex-hosted launcher gets a focus-safe 200x50 tab in its own session; duplicates are refused"

# --- input, capture, viewport ------------------------------------------------

shell_ready() { [ "$(fm_backend_rex_agent_state "$T")" = dead ]; }
wait_for 50 shell_ready || fail "the task block's shell never reached a prompt"
fm_backend_rex_send_text_line "$T" "printf 'fm-smoke-%s\\n' ok" || fail "send_text_line failed"
smoke_echoed() { fm_backend_rex_capture "$T" 20 | grep -qx 'fm-smoke-ok'; }
wait_for 50 smoke_echoed || fail "send_text_line output never appeared in the capture"
ROWS=$(fm_backend_rex_rows "$T") || fail "could not read the block's rows"
VISIBLE=$(fm_backend_visible_capture rex "$T" && printf x) || fail "visible capture failed"
LINES=$(printf '%s' "${VISIBLE%x}" | awk 'END { print NR }')
[ "$LINES" = "$ROWS" ] || fail "the derived viewport must be exactly size.rows ($ROWS) lines, got $LINES"
printf '%s' "${VISIBLE%x}" | grep -qx 'fm-smoke-ok' || fail "the derived viewport must show the echoed line"
fm_backend_rex_send_literal "$T" '-n dashed' || fail "an option-shaped literal must send"
fm_backend_rex_send_key "$T" C-u || fail "send_key C-u failed"
for key in Tab Escape C-c Enter; do
  fm_backend_rex_send_key "$T" "$key" || fail "send_key $key failed"
done
pass "real rex: line submit, capture, and a derived viewport of exactly size.rows lines; literal and every mapped key send"

# --- process view: cwd through a nested subshell, agent state -----------------

wait_for 50 shell_ready || fail "the shell did not return to a prompt after the keys"
fm_backend_rex_send_text_line "$T" "cd '$WORK/sub' && exec /bin/sh" || fail "could not start the nested shell"
in_sub() { [ "$(fm_backend_rex_current_path "$T")" = "$WORK/sub" ]; }
wait_for 50 in_sub || fail "current_path must follow the nested shell's cwd, got '$(fm_backend_rex_current_path "$T")'"
fm_backend_rex_send_text_line "$T" "sleep 60" || fail "could not start sleep"
sleeping() { [ "$(fm_backend_rex_agent_state "$T")" = ambiguous ]; }
wait_for 50 sleeping || fail "a non-shell non-harness foreground must read ambiguous"
fm_backend_rex_send_key "$T" C-c || fail "C-c failed"
wait_for 50 shell_ready || fail "the shell must read dead again after C-c"
pass "real rex: current_path follows a nested shell; agent_state reads dead at a shell, ambiguous under another program"

# --- program status: trusted only while its owner is in the foreground chain -

fm_backend_rex_send_text_line "$T" "printf '\\033]7501;state=working:app=fm-test\\033\\\\'" || fail "could not emit OSC 7501"
reads_busy() { [ "$(fm_backend_rex_busy_state "$T")" = busy ]; }
wait_for 50 reads_busy || fail "a working record from the foreground shell must read busy"
fm_backend_rex_send_text_line "$T" "printf '\\033]7501;state=idle:app=fm-test\\033\\\\'" || fail "could not emit OSC 7501 idle"
reads_idle() { [ "$(fm_backend_rex_busy_state "$T")" = idle ]; }
wait_for 50 reads_idle || fail "an idle record from the foreground shell must read idle"
pass "real rex: OSC 7501 records from the foreground shell drive busy_state"

# --- cleanup and absence proof -----------------------------------------------

ENDPOINT=$(fm_backend_rex_server_endpoint) || fail "could not read the server endpoint"
fm_backend_rex_kill "$T" || fail "kill must close the block and prove it gone"
[ "$(fm_backend_rex_block_presence "$T")" = missing ] || fail "a killed block must read missing"
[ "$(fm_backend_rex_endpoint_absence_recheck "$T" "$ENDPOINT")" = missing ] || fail "the absence proof must read missing"
[ "$(fm_backend_rex_endpoint_absence_recheck "$T" unix:///not-this-server.sock)" = unproven ] \
  || fail "an absence claim against another server must be unproven"
[ "$(fm_backend_rex_session_view "$SMOKE_SID" | jq '.windows | length')" = 1 ] \
  || fail "kill must close only the task's tab"
pass "real rex: kill closes exactly the task tab and the recorded server proves it gone"

TRIPLE2=$(fm_backend_rex_create_task_in_session "$SMOKE_SID" fm-test-beta "$WORK") || fail "create_task_in_session failed"
read -r _ _ BID2 <<<"$TRIPLE2"
fm_backend_rex_kill "$(fm_backend_rex_target "$SMOKE_SID" "$BID2")" || fail "kill of the reclaimed tab failed"
fm_backend_rex_create_task_in_session "session:00000000-0000-7000-8000-000000000000" fm-test-gamma "$WORK" >/dev/null 2>&1
[ "$?" = 2 ] || fail "create_task_in_session on a session that does not exist must return 2"
pass "real rex: relaunch reclaim opens a tab in the exact session, and a gone session returns 2 creating nothing"

[ ! -s "$TRIP" ] || fail "the guard refused state-changing calls outside the test session:"$'\n'"$(cat "$TRIP")"
AFTER=$(foreign_snapshot) || fail "could not snapshot the other sessions after the test"
[ "$BEFORE" = "$AFTER" ] || fail "other sessions changed during the test (another Rex user acting concurrently can also cause this):"$'\n'"$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
pass "real rex: no state-changing call left the test session and every other session is byte-identical"
