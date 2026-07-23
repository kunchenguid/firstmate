#!/usr/bin/env bash
# tests/fm-present-inject-e2e.test.sh - private-socket end-to-end smoke for the
# PRESENT-mode supervision daemon (issue #352). It proves the Codex/traex
# durable-wake path: a non-away primary session whose supervision daemon runs in
# a separate terminal must automatically catch a background wake and inject a
# marked nudge into the captain's pane, with NO manual bin/fm-wake-drain.sh.
#
# Two event classes, the two the acceptance criteria name explicitly:
#
#   Event 1 (crewmate status append): a crewmate writes a captain-relevant
#     status file. The real watcher child scans it, enqueues a `signal:` wake,
#     and exits; the daemon reaps that exit and injects the nudge. This is
#     actionable independent of away mode because the status carries a `done:`
#     verb, so it exercises the present-mode (afk-inactive) inject gate.
#
#   Event 2 (PR check.sh poll): firstmate arms a `<task>.check.sh` merge poll.
#     The watcher runs it, and non-empty output is an always-actionable `check:`
#     wake. This is the PR-merge-monitoring class from #346/#352.
#
# The DIFFERENCE from the away e2e (tests/fm-afk-inject-e2e.test.sh): away mode
# is NEVER entered here (no afk_enter, no state/.afk). The daemon is launched
# with FM_SUPERVISE_PRESENT=1, so it uses the .supervise-present.* lock/pidfile
# and the present-mode inject gate (inject only while afk is INACTIVE). The
# assertion each scenario owns is the #352 contract: the nudge lands WITHOUT any
# manual drain, and its wake reason discriminates the event class.
#
# Isolation matches the away e2e: a dedicated tmux socket (tmux -L present-e2e-
# <pid>), a tmux shim first on PATH redirecting the daemon's bare `tmux` to that
# socket, a throwaway FM_STATE_OVERRIDE, and an explicit FM_SUPERVISOR_BACKEND=
# tmux so an ambient HERDR_ENV cannot misroute the spawned daemon. Nothing
# touches the live fleet.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="present-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get FM_INJECT_MARK (only for reference in comments; the
# assertions match on the injected wake text and its sentinel hex prefix).
# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

# Composer pane loop: logs each submitted line verbatim (hex + text + class).
# Identical in spirit to the away e2e's composer; it classifies a line as an
# "injection" when it begins with the U+2063 sentinel (UTF-8 e2 81 a3).
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.pl"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env perl
use strict;
use warnings;
use bytes;

$| = 1;
my $mark = "\xe2\x81\xa3";
my $log = shift @ARGV;
my $old_stty = `stty -g 2>/dev/null`;
chomp $old_stty;
system('stty', '-echo', '-icanon', 'min', '1', 'time', '0') if $old_stty ne '';
$SIG{INT} = $SIG{TERM} = sub {
  system('stty', $old_stty) if $old_stty ne '';
  exit 0;
};
END {
  system('stty', $old_stty) if defined $old_stty && $old_stty ne '';
}

binmode STDIN;
binmode STDOUT;
my $buf = '';

sub redraw {
  print "\r\033[K$buf";
}

sub submit_line {
  my $class = substr($buf, 0, length($mark)) eq $mark ? 'injection' : 'user';
  my $hex = unpack('H*', $buf);
  open my $fh, '>>', $log or die "open log: $!";
  binmode $fh;
  print {$fh} "$hex\t$buf\t$class\n";
  close $fh;
  $buf = '';
  print "\r\033[K\n";
  redraw();
}

redraw();
while (sysread(STDIN, my $ch, 1)) {
  if ($ch eq "\r" || $ch eq "\n") {
    submit_line();
  } elsif ($ch eq "\177" || $ch eq "\b") {
    chop $buf;
    redraw();
  } else {
    $buf .= $ch;
    redraw();
  }
}
LOOP
chmod +x "$LOOP_SCRIPT"

# Private tmux server with a composer pane. The shell-target guard refuses panes
# whose foreground command is a shell, so the fixture models a real agent-like
# process rather than a shell that was later sent a command.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50 \
  "perl '$LOOP_SCRIPT' '$LOG_FILE'"
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')
sleep 1

# tmux shim: redirect the daemon's bare `tmux` calls to the private socket.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

start_daemon() {
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_SUPERVISE_PRESENT=1 \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=1 \
  FM_HEARTBEAT=999999 \
  FM_STALE_ESCALATE_SECS=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-present.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-present.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "present daemon did not start (no .supervise-present.pid after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

# Wait up to ~18s for a submitted injection line matching a reason substring.
# The nudge text is "Supervision wake (<reason>): drain queued wakes with
# bin/fm-wake-drain.sh ...". Nobody in this test ever runs fm-wake-drain.sh, so a
# match proves the daemon delivered the wake on its own.
wait_for_nudge() {
  local needle=$1 i=0
  while [ "$i" -lt 90 ]; do
    if grep -q "Supervision wake ($needle" "$LOG_FILE" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

reset_state() {
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/*.check.sh \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.supervise-present.* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         2>/dev/null || true
  : > "$LOG_FILE"
}

assert_clean_injection() {
  # exactly one sentinel-marked injection line, no spurious user submission.
  local label=$1
  local marker_count user_count digest_line digest_hex
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "$label: expected exactly 1 U+2063 marker, got $marker_count (duplicate or lost)"
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "$label: expected 0 user lines, got $user_count (spurious submission?)"
  digest_line=$(grep 'Supervision wake' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "$label: nudge misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "$label: nudge does not start with the sentinel marker (hex: $digest_hex)" ;;
  esac
}

# --- Event 1: crewmate status append auto-caught, no manual drain -----------

test_status_append_auto_wake() {
  reset_state
  start_daemon
  # A crewmate writes a captain-relevant status. No one drains the queue.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"
  wait_for_nudge "signal:" \
    || { echo "daemon log:" >&2; cat "$STATE_DIR/.supervise-present.log" >&2 2>/dev/null || true; \
         fail "Event 1: status append did not auto-inject a signal nudge (manual drain would have been required)"; }
  assert_clean_injection "Event 1"
  # The queued wake is still recorded durably (the injected turn, not this test,
  # would drain it), proving the wake did not depend on a foreground checkpoint.
  grep -q 'signal' "$STATE_DIR/.wake-queue" 2>/dev/null \
    || fail "Event 1: signal wake was not recorded in the durable wake queue"
  stop_daemon
  pass "Event 1: crewmate status append auto-injects a signal nudge with no manual drain"
}

# --- Event 2: PR check.sh poll auto-caught, no manual drain -----------------

test_pr_check_auto_wake() {
  reset_state
  start_daemon
  # firstmate arms a merged-PR poll as a task check script. Non-empty output is
  # an always-actionable check wake, regardless of away state.
  cat > "$STATE_DIR/merge-200.check.sh" <<'CHK'
#!/usr/bin/env bash
echo "merged: PR https://example.test/pr/200"
CHK
  chmod +x "$STATE_DIR/merge-200.check.sh"
  wait_for_nudge "check:" \
    || { echo "daemon log:" >&2; cat "$STATE_DIR/.supervise-present.log" >&2 2>/dev/null || true; \
         fail "Event 2: PR check.sh did not auto-inject a check nudge (manual drain would have been required)"; }
  assert_clean_injection "Event 2"
  grep -q 'check' "$STATE_DIR/.wake-queue" 2>/dev/null \
    || fail "Event 2: check wake was not recorded in the durable wake queue"
  stop_daemon
  pass "Event 2: PR check.sh poll auto-injects a check nudge with no manual drain"
}

test_status_append_auto_wake
test_pr_check_auto_wake

echo "all present-mode injection e2e smokes passed"
