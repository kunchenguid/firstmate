#!/usr/bin/env bash
# tests/fm-afk-inject-e2e.test.sh - private-socket end-to-end test for the afk
# daemon's injection path. It covers three operator-visible injection contracts:
#
#   Scenario A (human-partial-input): a partial line is typed into the
#     supervisor pane with NO Enter, then an escalation fires. The daemon must
#     DEFER (not merge the digest into the human's text). After the pane goes
#     idle, the digest arrives as a separate, clean submission.
#
#   Scenario B (native-submit-once): the daemon must use exactly one supported
#     native agent command carrying the complete digest, with no terminal-key
#     submission or duplicate.
#
#   Scenario C (normal digest): no human input.
#     A captain-relevant status must deliver exactly ONE sentinel-prefixed,
#     single-line digest with no duplicate or spurious user submission.
#
# Isolation: all direct and indirect terminal commands use the guarded named
# Herdr lab; the daemon sees only a throwaway state dir and exact test pane.
# The test shim observes the public native-agent command and adapts that one
# command to the synthetic shell composer; real-agent coverage lives in the
# separate native Herdr lab.
#
# Assert on submitted CONTENT (logged verbatim by the supervisor pane), not pane
# appearance - terminal line-wrapping looks like newlines but isn't.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

. "$ROOT/tests/herdr-test-safety.sh"
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CLEAN_PATH=$PATH
SESSION=$("$HELPER" name "${FM_HERDR_LAB_TASK:-afk-inject}") || exit 1
STATE_DIR=
HERDR_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  PATH="$CLEAN_PATH" "$HELPER" teardown "$SESSION" || exit 1
  rm -rf "${HERDR_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get FM_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=/dev/null
. "$DAEMON"

"$HELPER" provision "$SESSION" || fail 'lab provision failed'
herdr_test_guard_cli "$SESSION" "$STATE_DIR/guard" "$HELPER" || fail 'lab guard failed'
export PATH="$STATE_DIR/guard:$PATH" HERDR_SESSION="$SESSION"
fm_backend_source herdr
container_raw=$(fm_backend_herdr_container_ensure "$STATE_DIR") || fail 'container failed'
container=${container_raw%%$'\t'*}
ids=$(fm_backend_herdr_create_task "$container" afk-supervisor "$STATE_DIR") || fail 'pane failed'
read -r _ PANE <<< "$ids"
SUPERVISOR_PANE="$SESSION:$PANE"

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). It draws the in-progress input
# itself instead of relying on the terminal driver's canonical-mode echo, because
# terminal cursor placement for that echo varies across CI environments.
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
# The drawn composer row carries a real agent prompt glyph, matching the
# production supervisor pane this daemon injects into: under the strict
# container-proof rule (captain decision blank-row-injection-posture) a bare
# unidentified row is never a safe injection target, so the fixture must
# render the shape the classifier positively proves - "❯ " when idle,
# "❯ <buffer>" while input is pending. The glyph is rendering only; it never
# enters the buffer, so submitted-content assertions are unchanged.
redraw() {
  printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"
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

# Start the deterministic composer in the isolated pane.
fm_backend_herdr_send_text_line "$SUPERVISOR_PANE" "bash '$LOOP_SCRIPT' '$LOG_FILE'" || fail 'composer launch failed'
sleep 1
HERDR_SHIM_DIR="$STATE_DIR/shim"
mkdir -p "$HERDR_SHIM_DIR"
cat > "$HERDR_SHIM_DIR/herdr" <<SHIM
#!/usr/bin/env bash
set -eu
if [ "\${1:-}" = agent ] && { [ "\${2:-}" = prompt ] || [ "\${2:-}" = send ]; }; then
  [ "\${3:-}" = "$PANE" ] || { echo 'refused wrong synthetic target' >&2; exit 97; }
  printf '%s\t%s\t%s\n' "\$2" "\$3" "\${4:-}" >> "$STATE_DIR/.native-submit"
  "$STATE_DIR/guard/herdr" pane send-text "\$3" "\${4:-}" >/dev/null
  "$STATE_DIR/guard/herdr" pane send-keys "\$3" enter >/dev/null
  exit 0
fi
exec "$STATE_DIR/guard/herdr" "\$@"
SHIM
chmod +x "$HERDR_SHIM_DIR/herdr"

start_daemon() {
  PATH="$HERDR_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=herdr \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
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
  # Clear daemon and watcher state for a fresh scenario.
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
         2>/dev/null || true
  : > "$LOG_FILE"
  : > "$STATE_DIR/.native-submit"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify that pane_input_pending (which uses the shared composer classifier) can detect
# typed text in this Herdr environment. If it can't, the e2e cannot prove the
# operator-visible injection contracts it owns.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  "$HELPER" run "$SESSION" pane send-text "$PANE" "$check_text"
  if wait_for_pane_input_pending; then
    # Detected - clean up the text and proceed.
    "$HELPER" run "$SESSION" pane send-keys "$PANE" Enter
    sleep 0.3
    return 0
  fi
  # Not detected - print diagnostics and fail.
  echo "pane_input_pending cannot detect typed text in this Herdr environment" >&2
  "$HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 20 >&2
  "$HELPER" run "$SESSION" pane send-keys "$PANE" Enter
  fail "pane_input_pending self-check failed"
}

wait_for_pane_input_pending() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if PATH="$HERDR_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  # Type partial text into the supervisor pane with NO Enter. This simulates the
  # captain returning and starting to type before afk has been cleared.
  "$HELPER" run "$SESSION" pane send-text "$PANE" "human draft text"
  wait_for_pane_input_pending \
    || fail "Scenario A: human draft text did not become detectable as pending input"

  # Write a captain-relevant status to trigger a real escalation through the
  # real watcher child.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  # Wait for the watcher to detect the change and the daemon to attempt inject.
  sleep 6

  # Assert: the digest was NOT injected while the pane had pending input.
  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected while pane had pending input (merged with human text?)"
  fi

  # Assert: no merged line (human text + digest) was submitted.
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  # Now submit the human's text (Enter). The pane goes idle.
  "$HELPER" run "$SESSION" pane send-keys "$PANE" Enter
  sleep 0.5

  # Wait for the daemon to retry injection (housekeeping tick = 1s).
  sleep 6

  # Assert: human text was submitted alone (as a user message).
  grep -q 'human draft text' "$LOG_FILE" \
    || fail "Scenario A: human text not in log after submit"

  # Assert: digest arrived after the pane went idle.
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    || fail "Scenario A: digest not injected after pane went idle"

  # Assert: human text and digest are on SEPARATE lines (never merged).
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line (after idle)"
  fi

  # Assert: the human text line is classified as "user", not "injection".
  local human_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;  # correct
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  # Assert: the digest line is classified as "injection".
  local digest_line
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;  # correct
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "Scenario A: partial input defers injection; digest arrives clean after idle"
}

# --- Scenario B: one native agent command -----------------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"

  start_daemon

  # Write a captain-relevant status to trigger a real escalation.
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  # Wait for the daemon to process the escalation and submit it natively.
  sleep 8

  # The daemon must issue one capability-selected native agent command. The
  # shim's private shell adaptation is not production transport evidence.
  [ "$(wc -l < "$STATE_DIR/.native-submit")" -eq 1 ] \
    || fail "Scenario B: expected exactly one native agent command"
  awk -F '\t' -v pane="$PANE" \
    '($1 == "prompt" || $1 == "send") && $2 == pane && $3 ~ /Supervisor escalate/ { found=1 } END { exit !found }' \
    "$STATE_DIR/.native-submit" \
    || fail "Scenario B: native command changed the capability, target, or text"
  # Assert: exactly ONE terminal-safe marker in the log (no duplicate, no loss).
  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario B: expected exactly 1 U+2063 marker, got $marker_count (duplicate or lost)"

  # Assert: the digest line is classified as "injection" and starts with the
  # terminal-safe sentinel marker (hex starts with e281a3).
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;  # correct: starts with the terminal-safe sentinel marker
    *) fail "Scenario B: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # Assert: exactly ONE user-message line was submitted (no spurious empty lines
  # from extra Enters). The log should have exactly 1 injection line and 0 user
  # lines.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario B: expected 0 user lines, got $user_count (spurious submission?)"

  stop_daemon
  pass "Scenario B: one capability-selected native command carries one exact digest"
}

# --- Scenario C: normal status, single clean digest -------------------------
# With no human input, a captain-relevant status must produce
# exactly ONE sentinel-prefixed, single-line digest, submitted once. This owns
# the marker + single-line + no-duplicate operator contract that the deleted
# earlier transport-unit tests used to assert through internal send counts.

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 6

  # Exactly one terminal-safe marker in the submitted log (no duplicate, no loss).
  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 U+2063 marker, got $marker_count"

  # The digest is classified as an injection and starts with the sentinel byte.
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # The digest was submitted as ONE line (a multi-line digest would log >1 line),
  # and no spurious user-classified lines were submitted.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario C: expected 0 user lines, got $user_count (spurious submission?)"

  stop_daemon
  pass "Scenario C: a normal captain status injects exactly one clean single-line sentinel digest"
}

test_scenario_a
test_scenario_b
test_scenario_c

echo "all e2e injection tests passed"
