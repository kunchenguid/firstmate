#!/usr/bin/env bash
# tests/fm-afk-inject-herdr-e2e.test.sh - real-herdr end-to-end test for the
# away-mode daemon's Herdr transport and real-Herdr composer guard
# (bin/fm-supervise-daemon.sh), complementing
# tests/fm-afk-inject-e2e.test.sh's guarded Herdr cases.
# Mirrors tests/fm-backend-herdr-smoke.test.sh and tests/herdr-test-safety.sh's
# isolation patterns: everything runs on a throwaway, named, NEVER-default
# HERDR_SESSION, provisioned and torn down by fm-herdr-lab.sh. Skips cleanly
# when herdr or jq is not installed.
#
# The daemon receives an explicit Herdr backend and a session-qualified pane.
# Its synthetic shell loop is not a Herdr native agent. Native submission is
# therefore intercepted at the public command boundary and delivered to that
# loop by the fixture, while composer reads and target routing use real Herdr.

#
# The "supervisor pane" is a tiny deterministic bash loop (not a real harness
# binary): it draws a bordered composer row ("│ > <buf> │") that exercises the
# bordered branch of fm_backend_herdr_composer_state, and logs every submitted
# line (hex + text + injection/user classification) - the same technique
# tests/fm-afk-inject-e2e.test.sh uses for its supervisor pane, so this
# test asserts on submitted content, preserved drafts, and durable alarm state.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=${FM_HERDR_LAB_SESSION:-$("$HERDR_LAB_HELPER" name "${FM_HERDR_LAB_TASK:-afk-inject-herdr-e2e}")}
export HERDR_SESSION="$SESSION"
STATE_DIR=
HERDR_SHIM_DIR=
HERDR_GUARD_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_TARGET=
PANE_ID=
LOOP_SCRIPT=

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  "$HERDR_LAB_HELPER" teardown "$SESSION" 2>/dev/null || true
  rm -rf "${HERDR_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${HERDR_GUARD_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not prepare isolated Herdr lab session"
HERDR_GUARD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-guard.XXXXXX")
herdr_test_guard_cli "$SESSION" "$HERDR_GUARD_DIR" "$HERDR_LAB_HELPER" \
  || fail "could not install the guarded Herdr lab wrapper"
export PATH="$HERDR_GUARD_DIR:$PATH"

# --- source the daemon (for afk_enter/afk_exit/FM_INJECT_MARK) + the backend -
# shellcheck source=/dev/null
. "$DAEMON"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- build the isolated session's supervisor pane ----------------------------

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-afk-e2e-supervisor" /tmp "$SEEDED_TAB_ID") \
  || fail "create_task for the scratch supervisor pane failed"
read -r _TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$PANE_ID" ] || fail "create_task did not return a pane id"
SUPERVISOR_TARGET="$SESSION:$PANE_ID"

# Herdr can return the created pane before its interactive shell is ready to
# receive Enter. Require a stable shell-owned foreground before launching the
# fixture, or the command can remain typed but unsubmitted in the shell buffer.
PANE_READY=false
READY_SAMPLES=0
for _ in $(seq 1 100); do
  PROCESS_INFO=$(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE_ID" 2>/dev/null || true)
  if printf '%s' "$PROCESS_INFO" | jq -e '
    .result.process_info as $process
    | ($process.foreground_processes | length == 1)
      and ($process.foreground_processes[0].pid == $process.shell_pid)
  ' >/dev/null 2>&1; then
    READY_SAMPLES=$((READY_SAMPLES + 1))
    if [ "$READY_SAMPLES" -ge 10 ]; then
      PANE_READY=true
      break
    fi
  else
    READY_SAMPLES=0
  fi
  sleep 0.1
done
[ "$PANE_READY" = true ] || fail "the supervisor pane's shell did not become ready"

# --- deterministic bare-composer loop, drawn in the scratch pane -------------
# Mirrors tests/fm-afk-inject-e2e.test.sh's supervisor-loop.sh, but draws the
# shared classifier's positively identified bare-agent shape (`❯ <buf>`). This
# remains readable under the strict blank-row posture without pretending that
# one side-bordered row is a complete composer box. It is intentionally only a
# composer fixture, not a claimed native agent endpoint.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
# redraw: keep the composer visually pinned to ONE terminal row regardless of
# _buf's length - a realistic bordered single-line composer horizontally
# scrolls to show the tail near the cursor rather than letting the terminal
# hard-wrap a too-long line across multiple rows (which would break the
# structural border-row classifier's one-row assumption: a batched escalation
# digest easily exceeds a narrow pane's column width). A hardcoded width
# (not `tput cols`) is used deliberately: verified empirically against a real
# herdr pane launched this same way that `tput cols` inside this script's own
# process reports 80 regardless of the pane's ACTUAL width (54, confirmed via
# a separate interactively-typed `tput cols`), so trusting it here silently
# let content overflow the real width and wrap across two rows. 40 is
# comfortably under every real pane width observed on this machine.
redraw() {
  local avail=40 shown tail_n
  if [ "${#_buf}" -gt "$avail" ]; then
    tail_n=$((avail - 3))
    shown="...${_buf: -$tail_n}"
  else
    shown="$_buf"
  fi
  printf '\r\033[K❯ %s' "$shown"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

fm_backend_herdr_send_text_line "$SUPERVISOR_TARGET" "bash '$LOOP_SCRIPT' '$LOG_FILE'" \
  || fail "could not start the supervisor-loop script in the scratch herdr pane"
sleep 1  # let the loop start and settle

# --- Native command seam for the synthetic destination ----------------------
# The lower wrapper routes every real Herdr operation through the named lab
# helper. For the one operation the shell fixture cannot natively receive, this
# seam records the public agent command and emulates its accepted delivery into
# the exact pane. It does not stand in for the separate real-agent lab proof.
REAL_HERDR="$HERDR_GUARD_DIR/herdr"
HERDR_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-shim.XXXXXX")
cat > "$HERDR_SHIM_DIR/herdr" <<SHIM
#!/usr/bin/env bash
set -eu
if [ "\${1:-}" = agent ] && { [ "\${2:-}" = prompt ] || [ "\${2:-}" = send ]; }; then
  [ "\${3:-}" = "$PANE_ID" ] || { echo 'refused wrong synthetic target' >&2; exit 97; }
  printf '%s\t%s\t%s\n' "\$2" "\$3" "\${4:-}" >> "$STATE_DIR/.native-submit"
  "$REAL_HERDR" pane send-text "\$3" "\${4:-}" >/dev/null
  "$REAL_HERDR" pane send-keys "\$3" enter >/dev/null
  exit 0
fi
exec "$REAL_HERDR" "\$@"
SHIM
chmod +x "$HERDR_SHIM_DIR/herdr"

wait_daemon_started() {
  local label=${1:-daemon} start_line=${2:-0} i=0 new_log
  while [ "$i" -lt 30 ]; do
    new_log=$(tail -n +"$((start_line + 1))" "$STATE_DIR/.supervise-daemon.log" 2>/dev/null || true)
    if printf '%s\n' "$new_log" | grep -q 'backend=herdr'; then
      [ -f "$STATE_DIR/.supervise-daemon.pid" ] || fail "$label startup log recorded backend=herdr but no pid file was written"
      kill -0 "$DAEMON_PID" 2>/dev/null || fail "$label exited after recording backend=herdr"
      return 0
    fi
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
      echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
      fail "$label exited before recording backend=herdr: $(cat "$STATE_DIR/.supervise-daemon.log" 2>/dev/null)"
    fi
    sleep 0.2
    i=$((i + 1))
  done
  echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
  fail "$label did not record backend=herdr after 6s: $new_log"
}

start_daemon() {
  local log_start=0
  [ ! -f "$STATE_DIR/.supervise-daemon.log" ] || log_start=$(wc -l < "$STATE_DIR/.supervise-daemon.log")
  PATH="$HERDR_SHIM_DIR:$PATH" \
  HERDR_SESSION="$SESSION" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_BACKEND=herdr \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_TARGET" \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.5 \
  FM_INJECT_CONFIRM_RETRIES=6 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  wait_daemon_started daemon "$log_start"
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.native-submit \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify pane_input_pending (dispatched through fm_backend_composer_state for
# backend=herdr) can detect typed text in THIS real herdr environment before
# trusting the scenarios below to prove anything.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "$check_text" \
    || fail "selfcheck: could not send literal text to the scratch pane"
  sleep 0.5
  if PATH="$HERDR_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_TARGET" herdr; then
    fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
    sleep 0.5
    return 0
  fi
  echo "pane_input_pending cannot detect typed text in this real-herdr environment" >&2
  fm_backend_herdr_capture "$SUPERVISOR_TARGET" 10 | sed 's/^/    /' >&2
  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
  fail "pane_input_pending self-check failed against real herdr"
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "human draft text"
  sleep 0.5
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"
  sleep 8

  [ ! -s "$STATE_DIR/.native-submit" ] \
    || fail "Scenario A: daemon submitted while the real Herdr pane had pending input"
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
  sleep 8

  grep -q 'human draft text' "$LOG_FILE" \
    || fail "Scenario A: human text not in log after submit"
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    || fail "Scenario A: digest not submitted after the pane went idle"
  [ "$(wc -l < "$STATE_DIR/.native-submit")" -eq 1 ] \
    || fail "Scenario A: deferred digest did not use exactly one native command"
  awk -F '\t' -v pane="$PANE_ID" '$2 == pane && $3 ~ /Supervisor escalate/ { found=1 } END { exit !found }' \
    "$STATE_DIR/.native-submit" \
    || fail "Scenario A: native command changed the target or escalation text"
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line after idle"
  fi

  local human_line digest_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "real herdr Scenario A: partial input defers the native command; exact digest arrives after idle"
}

# --- Scenario B: native command shape is single-shot ------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"
  sleep 10

  [ "$(wc -l < "$STATE_DIR/.native-submit")" -eq 1 ] \
    || fail "Scenario B: expected exactly one native agent command"
  awk -F '\t' -v pane="$PANE_ID" \
    '($1 == "prompt" || $1 == "send") && $2 == pane && $3 ~ /Supervisor escalate/ { found=1 } END { exit !found }' \
    "$STATE_DIR/.native-submit" \
    || fail "Scenario B: native command changed the capability, target, or text"
  [ "$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")" -eq 1 ] \
    || fail "Scenario B: expected exactly one delivered sentinel marker"

  stop_daemon
  pass "real herdr Scenario B: one capability-selected native command carries one exact digest"
}

# --- Scenario C: normal digest content --------------------------------------

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon
  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 8

  local marker_count digest_line digest_hex
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 U+2063 marker, got $marker_count"
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with the terminal-safe sentinel marker (hex: $digest_hex)" ;;
  esac
  [ "$(grep -c $'\tuser$' "$LOG_FILE" || true)" -eq 0 ] \
    || fail "Scenario C: expected no unrelated user submission"

  stop_daemon
  pass "real herdr Scenario C: a normal status produces one clean sentinel digest"
}

# --- Scenario D: max-defer alarm on a persistently non-clearing composer -----
# A pending composer that NEVER clears (every Enter attempt leaves real text
# behind) must never be silently swallowed: the daemon must alarm (write
# state/.subsuper-inject-wedged) while preserving the buffered escalation, and
# must never crash or hot-loop. Exercises fm_backend_composer_state(herdr, ...)
# reporting "pending" indefinitely through the REAL structural border reader.

test_scenario_d_max_defer() {
  reset_state
  afk_enter "$STATE_DIR"
  local log_start=0
  [ ! -f "$STATE_DIR/.supervise-daemon.log" ] || log_start=$(wc -l < "$STATE_DIR/.supervise-daemon.log")
  # Persistent-pending composer: type real text and never submit it, so every
  # composer read is genuinely "pending" against the real herdr binary.
  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "stuck-in-the-box"
  sleep 0.5

  PATH="$HERDR_SHIM_DIR:$PATH" \
  HERDR_SESSION="$SESSION" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_BACKEND=herdr \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_TARGET" \
  FM_ESCALATE_BATCH_SECS=99999 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_MAX_DEFER_SECS=3 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=2 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  wait_daemon_started "Scenario D daemon" "$log_start"

  echo "needs-decision: pick A or B" > "$STATE_DIR/fake-c1.status"

  sleep 12

  [ -s "$STATE_DIR/.subsuper-inject-wedged" ] \
    || fail "Scenario D: a persistently pending real herdr composer never raised the max-defer wedge alarm"
  [ -s "$STATE_DIR/.subsuper-escalations" ] \
    || fail "Scenario D: the buffered escalation was lost instead of preserved during the wedge"
  if grep -q 'Supervisor escalate' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario D: a digest was somehow logged as submitted despite the composer never clearing"
  fi
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "Scenario D: the daemon process died instead of alarming and continuing"
  grep -F 'stuck-in-the-box' "$STATE_DIR/daemon.err" >/dev/null 2>&1 && : # not fatal either way

  stop_daemon
  # Clean up the stuck composer text for a tidy teardown (best-effort).
  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" C-c >/dev/null 2>&1 || true
  pass "real herdr Scenario D: a persistently pending composer raises the max-defer wedge alarm, preserves the buffer, and never crashes the daemon"
}

test_scenario_a
test_scenario_b
test_scenario_c
test_scenario_d_max_defer

echo "all real-herdr afk transport and composer-guard e2e tests passed"

fm_backend_herdr_kill "$SUPERVISOR_TARGET" 2>/dev/null || true
cleanup_all
trap - EXIT
