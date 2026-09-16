#!/usr/bin/env bash
# tests/fm-tmux-long-launch.test.sh - regression: a launch command longer than
# the kernel's canonical-mode line limit must actually START A WORKER.
#
# What this proves, and why it is not a string comparison: the reported failure
# (2026-09-15) is silent. A pane whose shell is still running something has its
# tty in canonical mode, where the kernel buffers the typed line itself and
# discards the WHOLE line past MAX_CANON (1024 on macOS; other platforms size it
# differently, which is why nothing here encodes the number). The command never
# reaches the shell, no worker starts, and every downstream signal reports
# success. So each case below asserts a real worker process started and left its
# own evidence behind - a marker file written by the launched process - and only
# then checks that what it received was byte-identical to what was sent.
#
# Against the ungated single-call send these cases fail: the command is eaten and
# no marker appears. The fix is fm_tmux_wait_pane_input_ready
# (bin/fm-tmux-lib.sh), which waits for the pane to be reading input itself
# before typing, and refuses loudly when it never does.
#
# Like tests/fm-backend-tmux-smoke.test.sh this talks to a REAL tmux server on a
# private socket (-L) so it can never touch the host's own sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-long-launch-$$"
SHIM_DIR=
TMP_ROOT=

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"
  return 0
}
trap cleanup_all EXIT

SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-long-launch-shim.XXXXXX")
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-long-launch.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="longlaunch"
tmux new-session -d -s "$SESSION" -x 200 -y 50 || fail "real tmux: new-session failed"

# The fixtures below must be able to tell what state a pane is in WITHOUT using
# the helper under test, or this file would only fail against the unfixed code
# because a function is missing rather than because the launch command was lost.
# This is the same tty read, spelled out locally.
probe_mode() {  # <target> -> raw|canonical|unknown
  local tty out
  tty=$(tmux display-message -p -t "$1" '#{pane_tty}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$tty" in /dev/*) ;; *) printf 'unknown'; return 0 ;; esac
  out=$(stty -f "$tty" -a 2>/dev/null) || out=$(stty -F "$tty" -a 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  out=" $(printf '%s' "$out" | tr '\n;,' '   ') "
  case "$out" in
    *' -icanon '*) printf 'raw' ;;
    *' icanon '*) printf 'canonical' ;;
    *) printf 'unknown' ;;
  esac
}

# A pane running an interactive shell, made busy for <seconds> so its tty is in
# canonical mode when the launch command is typed - the exact state a spawn pane
# is in whenever the step before the launch (a worktree checkout, an rc file, a
# remote round trip) is slower than the fixed settle the spawn path sleeps.
busy_pane() {  # <window> <busy-seconds>
  local window=$1 secs=$2
  tmux new-window -d -t "$SESSION" -n "$window" "/bin/bash --noprofile --norc -i" \
    || fail "could not create window $window"
  # Wait for the shell to reach its prompt before making it busy, so the busy
  # command itself is not the thing that gets eaten.
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(probe_mode "$SESSION:$window")" = raw ] && break
    sleep 0.05
    i=$((i + 1))
  done
  tmux send-keys -t "$SESSION:$window" -l "sleep $secs"
  tmux send-keys -t "$SESSION:$window" Enter
  # Confirm the pane really is in the state this regression is about.
  i=0
  while [ "$i" -lt 100 ]; do
    [ "$(probe_mode "$SESSION:$window")" = canonical ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  fail "fixture did not reach canonical mode in window $window"
}

# A launch command whose PAYLOAD pushes it well past 1024 bytes. It starts a
# background process, exactly like a real launch, and that process is what writes
# the marker - so the marker existing means a worker ran, not that a string
# arrived.
long_launch_command() {  # <marker-path> <payload-path> <payload-bytes>
  local marker=$1 payload_file=$2 bytes=$3 payload
  payload=$(awk -v n="$bytes" 'BEGIN { s = ""; while (length(s) < n) s = s "abcdefghij"; print substr(s, 1, n) }')
  printf '%s' "$payload" > "$payload_file.expected"
  printf "( printf '%%s' '%s' > '%s'; printf 'started\\n' > '%s' ) &" \
    "$payload" "$payload_file" "$marker"
}

wait_for_file() {  # <path> <samples>
  local path=$1 samples=${2:-120} i=0
  while [ "$i" -lt "$samples" ]; do
    [ -s "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- a long launch command into a busy pane must still start a worker ---------

test_long_launch_starts_a_worker() {
  local dir window marker payload cmd
  dir="$TMP_ROOT/starts-worker"
  mkdir -p "$dir"
  window="long-busy"
  marker="$dir/marker"
  payload="$dir/payload"
  cmd=$(long_launch_command "$marker" "$payload" 1400)
  [ "${#cmd}" -gt 1024 ] \
    || fail "fixture command is ${#cmd} bytes, which does not exercise the limit"

  busy_pane "$window" 2

  fm_backend_tmux_send_literal "$SESSION:$window" "$cmd" \
    || fail "the gated send refused a pane that does become ready"
  fm_backend_tmux_send_key "$SESSION:$window" Enter

  wait_for_file "$marker" 120 \
    || fail "no worker started: a ${#cmd}-byte launch command was typed into a busy pane and vanished"
  [ "$(cat "$marker")" = started ] || fail "marker present but not written by the launched process"
  cmp -s "$payload" "$payload.expected" \
    || fail "worker started but the command it received was not byte-identical to what was sent"
  pass "fm_backend_tmux_send_literal: a ${#cmd}-byte launch command starts a worker on a busy pane"
}

# --- a pane that never becomes ready must refuse loudly, not silently ---------

test_never_ready_pane_refuses_loudly() {
  local dir window cmd err status
  dir="$TMP_ROOT/never-ready"
  mkdir -p "$dir"
  window="never-ready"
  err="$dir/stderr"
  cmd=$(long_launch_command "$dir/marker" "$dir/payload" 1400)

  # `cat` never reads a line before its newline, so this pane stays in canonical
  # mode for the whole wait - a pane that never becomes ready.
  tmux new-window -d -t "$SESSION" -n "$window" "cat > /dev/null" \
    || fail "could not create window $window"
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(probe_mode "$SESSION:$window")" = canonical ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(probe_mode "$SESSION:$window")" = canonical ] \
    || fail "never-ready fixture is not in canonical mode"

  status=0
  FM_PANE_READY_TIMEOUT=0.5 fm_backend_tmux_send_literal "$SESSION:$window" "$cmd" 2>"$err" \
    || status=$?
  [ "$status" -eq 2 ] \
    || fail "the gate must refuse with its own status 2, so a caller can tell a busy pane from a failed send, got $status"
  grep -q 'never started reading input' "$err" \
    || fail "refusal did not name the real reason, got: $(cat "$err")"
  grep -q "$window" "$err" \
    || fail "refusal did not name the pane, got: $(cat "$err")"

  # A target whose session does not exist reads `unknown`, which the gate treats
  # as ready, so `tmux send-keys` is what fails - the dead-server shape, which
  # must not carry the gate's status.
  status=0
  fm_backend_tmux_send_literal "no-such-session-$$:win" "$cmd" 2>/dev/null || status=$?
  [ "$status" -eq 1 ] \
    || fail "a send that failed on its own must not be reported with the gate's refusal status, got $status"
  pass "pane that never becomes ready refuses loudly and names the reason"
}

# --- an unreadable tty must stay permissive -----------------------------------

test_unreadable_mode_is_treated_as_ready() {
  local mode
  # A window name that does not exist resolves to the ACTIVE window instead of
  # failing (the tmux fallback bin/fm-spawn.sh already warns about), so the
  # unresolvable case has to be a session that does not exist.
  mode=$(fm_tmux_pane_input_mode "no-such-session-$$:win")
  [ "$mode" = unknown ] || fail "an unresolvable target should read unknown, got '$mode'"
  (
    # shellcheck disable=SC2329
    fm_tmux_pane_input_mode() { printf 'unknown'; }
    fm_tmux_wait_pane_input_ready "$SESSION:whatever" 0.2
  ) || fail "an unreadable tty must be treated as ready so today's sends keep working"
  pass "fm_tmux_wait_pane_input_ready: unreadable tty mode stays permissive"
}

# --- a ready pane costs one poll, not the whole budget ------------------------

test_ready_pane_returns_immediately() {
  local window start end elapsed
  window="already-ready"
  tmux new-window -d -t "$SESSION" -n "$window" "/bin/bash --noprofile --norc -i" \
    || fail "could not create window $window"
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(probe_mode "$SESSION:$window")" = raw ] && break
    sleep 0.05
    i=$((i + 1))
  done
  start=$(date +%s)
  fm_tmux_wait_pane_input_ready "$SESSION:$window" 5 \
    || fail "a pane at its prompt must be ready"
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -le 1 ] \
    || fail "a ready pane should not spend the wait budget, took ${elapsed}s"
  pass "fm_tmux_wait_pane_input_ready: a ready pane returns without spending the budget"
}

test_long_launch_starts_a_worker
test_never_ready_pane_refuses_loudly
test_unreadable_mode_is_treated_as_ready
test_ready_pane_returns_immediately
