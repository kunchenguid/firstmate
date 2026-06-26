#!/usr/bin/env bash
# Start the always-on supervisor daemon (liveness guardian) for THIS home if it
# is not already running. Singleton-safe: a no-op when a live daemon already
# holds this home's lock.
#
# The watcher (bin/fm-watch.sh) is one-shot; on its own, liveness rode entirely on
# firstmate re-arming it every turn, so a single missed re-arm silently stopped
# supervision (the ~69-minute gap). The supervisor daemon
# (bin/fm-supervise-daemon.sh) now runs ALWAYS — not only under /afk — as a
# liveness guardian: while present (afk off) it does not own the watcher or
# process wakes, but every tick it restores a lapsed watcher and nudges firstmate
# once. Bootstrap and recovery call this script so that guarantee is in place from
# session start, independent of re-arm discipline. /afk no longer starts the
# daemon; it only flips the in-process injection policy.
#
# Detaches the daemon (setsid/nohup) so it survives this script's exit and any
# firstmate restart, and inherits this pane's TMUX_PANE so the daemon discovers
# the right supervisor target. Best-effort and non-fatal: it never blocks startup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"
PIDFILE="$STATE/.supervise-daemon.pid"
mkdir -p "$STATE"

[ -x "$DAEMON" ] || { echo "guardian: FAILED - daemon not executable: $DAEMON" >&2; exit 1; }

daemon_alive() {  # 0 only if the pidfile names a LIVE, GENUINE daemon for this home
  local pid cmd
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  # Liveness alone is not enough. An unclean daemon death (kill -9 / OOM) leaves a
  # stale pidfile, and the OS may later recycle that pid to an unrelated process;
  # trusting kill -0 alone would then falsely conclude the daemon is up and no-op,
  # leaving this home with no guardian for as long as that process lives. Mirror
  # the daemon's own lock identity check: require the pid to actually be an
  # fm-supervise-daemon process. ps -o command= is portable on BSD and GNU. A
  # false-negative here is safe — the daemon's portable singleton lock makes a
  # redundant start a no-op — while the false-positive this closes is not.
  cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  case "$cmd" in
    *fm-supervise-daemon*) return 0 ;;
    *) return 1 ;;
  esac
}

# Already running for this home: no-op. The daemon also self-singletons via its
# own portable lock, so even a racing duplicate start can never double-run.
if daemon_alive; then
  echo "guardian: already running pid=$(cat "$PIDFILE" 2>/dev/null)"
  exit 0
fi

# Start detached so the daemon outlives this script and any firstmate restart.
# Pass FM_HOME explicitly; the daemon inherits TMUX_PANE from this pane for target
# discovery.
if command -v setsid >/dev/null 2>&1; then
  FM_HOME="$FM_HOME" setsid "$DAEMON" >/dev/null 2>&1 </dev/null &
else
  FM_HOME="$FM_HOME" nohup "$DAEMON" >/dev/null 2>&1 </dev/null &
fi
disown 2>/dev/null || true

# Brief, bounded confirm: the daemon writes its pidfile only after acquiring its
# singleton lock. If another daemon won a concurrent race, ITS pidfile is what we
# observe alive — still the correct end state (exactly one daemon).
i=0
while [ "$i" -lt 25 ]; do
  if daemon_alive; then
    echo "guardian: started pid=$(cat "$PIDFILE" 2>/dev/null)"
    exit 0
  fi
  sleep 0.2
  i=$((i + 1))
done

# Could not confirm within the window. Non-fatal: the pull-based fm-guard.sh
# banner and firstmate's own fm-watch-arm.sh remain as backstops. Report and exit
# zero so a transient start hiccup never blocks bootstrap or recovery.
echo "guardian: could not confirm daemon start within 5s (continuing; guard banner + re-arm remain as backstops)" >&2
exit 0
