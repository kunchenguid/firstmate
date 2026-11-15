#!/usr/bin/env bash
# tests/fm-afk-inject-hc-smoke.test.sh - real herdr-core (`hc`) end-to-end
# test for the away-mode daemon's hc supervisor transport
# (bin/fm-supervise-daemon.sh), the hc counterpart of
# tests/fm-afk-inject-herdr-e2e.test.sh.
#
# Drives the REAL hc binary, but only inside a lab session provisioned by
# bin/fm-hc-lab.sh (a unique fm-hclab-* HC_SESSION, scratch XDG roots, a
# pinned FM_HC_SOCKET, and a real-fleet tripwire); tests/hc-test-safety.sh
# owns the only sanctioned teardown, and its failure fails the run.
#
# The supervisor terminal runs a deterministic bash loop, not a real harness:
# it draws a Claude-shaped composer (a `❯` row between two rules) that the
# shared plain-screen composer classifier can prove empty, logs every submitted
# line (hex + text + injection/user classification), and draws Claude's
# rendered busy line while a flag file exists. hc's own `send` pastes and
# presses Enter, so typed-but-unsent text is staged through a prefill file the
# loop reads. The loop reports no native agent status, so `send --wait` falls
# back to the composer screen for its verdict, exactly the fallback a harness
# without hc status reporting takes.
#
# Covers: discovery of this terminal's own target from real markers and the
# core identity check, startup acceptance of backend=hc, one clean digest
# through the real daemon, deferral while the composer holds text, deferral
# while the rendered busy line shows, and a gone core judged without contacting
# hc. Skips cleanly when no herdr-core binary or jq is installed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Binary resolution identical to the adapter, installer, and lab.
HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the core liveness probe)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-inject-hc-smoke)
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name afkinject)
DAEMON_PID=

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=
}

# Armed before provision so a half-provisioned session is still swept; the
# teardown's own result propagates.
cleanup_lab() {
  local rc=$?
  trap - EXIT
  stop_daemon
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with $HC_BIN"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"
hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND

STATE_DIR="$TMP_ROOT/state"
FIX="$TMP_ROOT/fixture"
mkdir -p "$STATE_DIR" "$FIX"
LOG_FILE="$FIX/submitted.log"
: > "$LOG_FILE"
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT/home"
mkdir -p "$FM_HOME"

# shellcheck source=/dev/null
. "$DAEMON"
fm_backend_source hc || fail "could not source the hc adapter"
SES=$(fm_backend_hc_container_ensure) || fail "container_ensure failed"
[ "$SES" = "$HC_TEST_SES" ] || fail "container_ensure named '$SES', not the lab session"

wait_for() {  # <seconds> <cmd...>
  local tries=$(( $1 * 10 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

# --- the supervisor terminal --------------------------------------------------
LOOP_SCRIPT="$FIX/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
NBSP=$'\xC2\xA0'
LOG=$1 DIR=$2
RULE='────────────────────────────────────────'
stty -echo -icanon min 0 time 2 2>/dev/null || true
_buf=
redraw() {
  local row shown=$_buf
  [ "${#shown}" -le 36 ] || shown=${shown: -36}
  if [ -z "$shown" ]; then row="❯$NBSP"; else row="❯ $shown"; fi
  printf '\033[H\033[2J'
  printf 'supervisor fixture\n%s\n%s\n%s\n' "$RULE" "$row" "$RULE"
  [ ! -e "$DIR/busy" ] || printf '  ✻ Working… (esc to interrupt)\n'
}
submit_line() {
  local line=$_buf class=user hex
  [ "${line:0:1}" != "$MARK" ] || class=injection
  hex=$(printf '%s' "$line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$hex" "$line" "$class" >> "$LOG"
  _buf=
  redraw
}
redraw
last_busy=0
while :; do
  if IFS= read -r -n 1 -t 0.2 ch; then
    case "$ch" in
      '') submit_line ;;
      $'\r'|$'\n') submit_line ;;
      $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
      *) _buf="$_buf$ch" ;;
    esac
    continue
  fi
  if [ -e "$DIR/prefill" ]; then
    _buf=$(cat "$DIR/prefill"); rm -f "$DIR/prefill"; redraw
  fi
  now_busy=0; [ ! -e "$DIR/busy" ] || now_busy=1
  if [ "$now_busy" != "$last_busy" ]; then last_busy=$now_busy; redraw; fi
  # A pasted line arrives in one burst; draw it once the burst ends.
  case "$(printf '%s' "$_buf" | tail -c 1)" in '') ;; *) redraw ;; esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

OUT=$(fm_backend_hc_cli "$SES" run --bg --json --no-parent --outlive-parent --no-notify \
  --cwd "$FIX" -- bash "$LOOP_SCRIPT" "$LOG_FILE" "$FIX" 2>&1) || fail "hc run of the supervisor loop failed: $OUT"
ADDR=$(printf '%s' "$OUT" | jq -r '.address // empty')
fm_backend_hc_address_valid "$ADDR" || fail "hc run returned no terminal address: $OUT"
TARGET="$SES:$ADDR"

composer_empty() { [ "$(fm_backend_composer_state hc "$TARGET")" = empty ]; }
wait_for 10 composer_empty \
  || fail "the idle fixture composer never read empty through hc read: $(fm_backend_hc_visible_capture "$TARGET")"
pass "real hc: the plain-screen composer reader proves the idle supervisor composer empty"

# --- discovery and identity from a real terminal's markers -------------------
PROBE="$FIX/probe.sh"
cat > "$PROBE" <<PROBE
#!/usr/bin/env bash
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-supervisor-target-lib.sh"
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND TMUX_PANE HERDR_ENV HERDR_PANE_ID REX_SESSION REX_BLOCK
t=\$(discover_supervisor_target); b=\$(discover_supervisor_backend)
if err=\$(fm_supervisor_hc_identity_check "\$t"); then v=ok; else v="refused: \$err"; fi
printf '%s\t%s\t%s\t%s\n' "\$t" "\$b" "\$HC_TERMINAL_ID" "\$v" > "\$1"
PROBE
chmod +x "$PROBE"

probe_in_terminal() {  # <out-file> [env assignments...]
  local out=$1 res
  shift
  rm -f "$out"
  res=$(fm_backend_hc_cli "$SES" run --bg --json --no-parent --outlive-parent --no-notify \
    --cwd "$FIX" -- env FM_HC_SOCKET="$HC_TEST_SOCK" "$@" bash "$PROBE" "$out" 2>&1) \
    || fail "hc run of the discovery probe failed: $res"
  wait_for 10 test -s "$out" || fail "the discovery probe wrote nothing"
}

probe_in_terminal "$FIX/probe-own.txt"
IFS=$'\t' read -r P_TARGET P_BACKEND P_ID P_VERDICT < "$FIX/probe-own.txt"
[ "$P_TARGET" = "$SES:$P_ID" ] || fail "real markers must resolve this terminal's own target, got '$P_TARGET' (id $P_ID)"
[ "$P_BACKEND" = hc ] || fail "real markers must resolve backend hc, got '$P_BACKEND'"
[ "$P_VERDICT" = ok ] || fail "this terminal's own core must pass the identity check: $P_VERDICT"
probe_in_terminal "$FIX/probe-other.txt" FM_HC_SOCKET="$TMP_ROOT/not-this-core.sock"
IFS=$'\t' read -r _ _ _ P_VERDICT < "$FIX/probe-other.txt"
case "$P_VERDICT" in
  refused:*"would reach another terminal"*) ;;
  *) fail "a terminal whose markers name another core must be refused: $P_VERDICT" ;;
esac
pass "real hc: a terminal's own markers resolve <session>:<address> + hc and pass identity; another core's address is refused"

# --- the real daemon ----------------------------------------------------------
wait_daemon_started() {
  local i=0
  while [ "$i" -lt 50 ]; do
    if grep -q 'backend=hc' "$STATE_DIR/.supervise-daemon.log" 2>/dev/null; then
      kill -0 "$DAEMON_PID" 2>/dev/null || fail "the daemon exited after recording backend=hc"
      return 0
    fi
    kill -0 "$DAEMON_PID" 2>/dev/null \
      || fail "the daemon exited before accepting backend=hc: $(cat "$STATE_DIR/daemon.err" 2>/dev/null)"
    sleep 0.2
    i=$((i + 1))
  done
  fail "the daemon never recorded backend=hc: $(cat "$STATE_DIR/daemon.err" 2>/dev/null)"
}

# The fixture is no real harness; pinning "unknown" keeps the typed U+2063
# envelope whatever harness runs this test.
start_daemon() {
  FM_DAEMON_PRIMARY_HARNESS=unknown \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_BACKEND=hc \
  FM_SUPERVISOR_TARGET="$TARGET" \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.5 \
  FM_INJECT_CONFIRM_RETRIES=4 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  wait_daemon_started
}

reset_state() {
  rm -f "$STATE_DIR"/*.status "$STATE_DIR"/.subsuper-* "$STATE_DIR"/.wake-queue* \
    "$STATE_DIR"/.watch.lock* "$STATE_DIR"/.last-* "$STATE_DIR"/.seen-* \
    "$STATE_DIR"/.supervise-daemon.log 2>/dev/null || true
  rm -f "$FIX/busy" "$FIX/prefill"
  : > "$LOG_FILE"
}

digest_logged() { grep -q 'Supervisor escalate' "$LOG_FILE"; }
marker_count() { awk -F '\t' '{ hex=$1; n += gsub(/e281a3/, "", hex) } END { print n + 0 }' "$LOG_FILE"; }

# Scenario: a normal captain status injects exactly one clean digest.
reset_state
afk_enter "$STATE_DIR"
start_daemon
echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
wait_for 20 digest_logged || fail "no digest reached the hc supervisor: $(cat "$STATE_DIR/.supervise-daemon.log")"
sleep 2
[ "$(marker_count)" -eq 1 ] || fail "expected exactly one U+2063 envelope, got $(marker_count): $(cat "$LOG_FILE")"
case "$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)" in
  e281a3*injection) ;;
  *) fail "the digest must arrive whole, envelope first: $(grep 'Supervisor escalate' "$LOG_FILE" | head -1)" ;;
esac
[ "$(grep -c $'\tuser$' "$LOG_FILE" || true)" -eq 0 ] || fail "a spurious user line was submitted: $(cat "$LOG_FILE")"
stop_daemon
pass "real hc: the daemon accepts backend=hc and delivers exactly one clean envelope-first digest through send --wait"

# Scenario: text in the composer defers the digest until it is submitted.
reset_state
afk_enter "$STATE_DIR"
printf 'human draft text' > "$FIX/prefill"
composer_held() { [ "$(fm_backend_composer_state hc "$TARGET")" != empty ]; }
wait_for 10 composer_held || fail "the staged draft never showed in the composer: $(fm_backend_hc_visible_capture "$TARGET"; fm_backend_hc_get "$TARGET")"
start_daemon
echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"
sleep 8
! digest_logged || fail "the daemon injected while the hc composer held a draft: $(cat "$LOG_FILE")"
grep -q 'composer not confirmed-empty' "$STATE_DIR/.supervise-daemon.log" \
  || fail "the deferral must name the composer guard: $(cat "$STATE_DIR/.supervise-daemon.log")"
fm_backend_send_key hc "$TARGET" Enter || fail "could not submit the staged draft"
wait_for 20 digest_logged || fail "the digest never arrived after the draft was submitted"
grep -q $'\thuman draft text\tuser$' "$LOG_FILE" || fail "the draft must be submitted on its own line: $(cat "$LOG_FILE")"
! grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || fail "the draft and the digest merged"
stop_daemon
pass "real hc: a composer holding a draft defers the digest; it arrives clean once the draft is submitted"

# Scenario: the rendered busy line defers injection; a gone core is judged
# without contacting hc (any hc call would start it).
reset_state
afk_enter "$STATE_DIR"
: > "$FIX/busy"
busy_shown() { FM_DAEMON_PRIMARY_HARNESS=claude pane_is_busy "$TARGET" hc; }
wait_for 10 busy_shown || fail "the rendered busy line never read busy through hc read"
if FM_DAEMON_PRIMARY_HARNESS=claude FM_STATE_OVERRIDE="$STATE_DIR" FM_SUPERVISOR_BACKEND=hc FM_SUPERVISOR_TARGET="$TARGET" \
  inject_msg "busy probe" "$STATE_DIR"; then
  fail "inject_msg must defer while the supervisor shows Claude's busy line"
fi
case "$INJECT_LAST_FAILURE" in *busy*) ;; *) fail "the busy deferral must name the busy guard: $INJECT_LAST_FAILURE" ;; esac
rm -f "$FIX/busy"
if FM_HC_SOCKET="$TMP_ROOT/gone.sock" FM_STATE_OVERRIDE="$STATE_DIR" FM_SUPERVISOR_BACKEND=hc FM_SUPERVISOR_TARGET="$TARGET" \
  inject_msg "gone probe" "$STATE_DIR"; then
  fail "inject_msg must defer when the supervisor core is gone"
fi
[ ! -e "$TMP_ROOT/gone.sock" ] || fail "judging a gone core must not start one at its socket"
[ ! -s "$LOG_FILE" ] || fail "nothing may be submitted in the busy or gone cases: $(cat "$LOG_FILE")"
pass "real hc: the rendered busy line defers injection, and a gone core reads as gone without being started"

echo FM_TEST_COMPLETE
