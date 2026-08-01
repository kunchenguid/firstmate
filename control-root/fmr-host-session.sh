#!/usr/bin/env bash
# fmr-host-session.sh - start and report the DESKTOP host session on a GUI task host.
#
# Usage (run ON the task host, from a desktop terminal window):
#   fmr-host-session.sh start   [--control-root <dir>]
#   fmr-host-session.sh status  [--control-root <dir>]
#   fmr-host-session.sh stop    [--control-root <dir>]
#
# WHAT THIS IS AND WHY IT CANNOT BE A LAUNCHD JOB
# control-root/fmr-gui-lib.sh's header owns the measured constraint: an agent
# whose ancestry is a launchd job wedges permanently in openat(2). bifrost's
# daemon is launchd-managed, so verbs/fmr-verb.sh must not create the session
# provider a dispatched agent will run in - it can only hand work to one that
# already exists and was started from the desktop. This script is how that
# session comes to exist, and `status` is how the verb's preflight answers
# whether it still does.
#
# HOW TO START IT, AND THE TRADE THAT CHOICE MAKES
# Open a terminal window on the machine's own desktop and run `start`. That is
# the whole procedure, it changes no system setting, and it needs no
# authorization. What it costs is durability: the session does not come back by
# itself after a logout or a reboot, and the verb refuses dispatch until someone
# starts it again - loudly, naming this command.
#
# The durable alternative is a real Login Item (System Settings > General >
# Login Items, or an app registered through SMAppService) that runs this same
# `start`. It survives reboots and keeps desktop ancestry. It is not done here
# because adding one is a change to the machine owner's system settings, which is
# the owner's call to make, not this script's. docs/relay-gui-host.md records
# both options.
#
# A LaunchAgent is NOT an alternative. It is the one shape that reintroduces the
# wedge, which is why `start` refuses to run from launchd-job ancestry at all.
#
# PROVENANCE IS RECORDED, NOT INFERRED LATER
# A tmux server daemonises, so after the fact its parent is pid 1 and its origin
# is gone. Provenance can therefore only be captured at start, and it lands in
# the marker file:
#   desktop   an .app bundle appears in this script's own ancestry - the shape
#             the wedge was never reproduced under
#   indirect  started from inside a multiplexer, whose own origin is unreadable;
#             not proven either way, and said so out loud
#   adopted   a tmux server already owned the socket and was taken over as-is;
#             it was not observed being started, so nothing is claimed about it
# `start` refuses only launchd-job ancestry, because that is the only class known
# to break. The other two are reported rather than blocked: refusing what cannot
# be disproven would make the tool unusable on a machine whose fleet server is
# already up, and would not buy a guarantee this script is able to make.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

CMD=${1:-}
case "$CMD" in
  -h|--help|'') usage; exit 0 ;;
esac
shift || true

CONTROL_ROOT=$SELF_DIR
while [ "$#" -gt 0 ]; do
  case "$1" in
    --control-root) CONTROL_ROOT=${2:?--control-root needs a directory}; shift 2 ;;
    --control-root=*) CONTROL_ROOT=${1#--control-root=}; shift ;;
    *) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done

LIB="$SELF_DIR/fmr-gui-lib.sh"
[ -f "$LIB" ] || { echo "error: missing $LIB" >&2; exit 1; }
# shellcheck source=control-root/fmr-gui-lib.sh
. "$LIB"

cfg_value() {  # <key>
  local key=$1 file="$CONTROL_ROOT/config"
  [ -f "$file" ] || return 0
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

SOCKET=$(cfg_value TMUX_SOCKET)
[ -n "$SOCKET" ] || SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
MARKER=$(cfg_value HOST_SESSION)
[ -n "$MARKER" ] || MARKER="$CONTROL_ROOT/host-session"
SESSION_NAME=fm-host-session

marker_text() { cat "$MARKER" 2>/dev/null || true; }

verdict_now() {
  fmr_gui_session_verdict "$(marker_text)" \
    "$(fmr_gui_socket_server_pid "$SOCKET")" "$(fmr_gui_console_asid)"
}

case "$CMD" in

  status)
    printf '%s\n' "$(verdict_now)"
    printf 'socket=%s\nmarker=%s\n' "$SOCKET" "$MARKER"
    case "$(verdict_now)" in ok\ *) exit 0 ;; *) exit 1 ;; esac
    ;;

  start)
    chain=$(fmr_gui_ancestry_chain)
    class=$(fmr_gui_ancestry_class "$chain")
    if [ "$class" = launchd-job ]; then
      echo "REFUSED: this shell's ancestry reaches launchd with no desktop app in it." >&2
      echo "An agent started from a launchd job wedges permanently in openat(2) - measured," >&2
      echo "not theoretical - so a host session started from here would accept work and then" >&2
      echo "hang every task it was given." >&2
      echo "Open a terminal window on this machine's desktop and run this command there." >&2
      printf '%s\n' "$chain" | sed 's/^/  chain: /' >&2
      exit 1
    fi

    live=$(fmr_gui_socket_server_pid "$SOCKET")
    if [ -n "$live" ]; then
      case "$(verdict_now)" in
        ok\ *)
          printf 'already running: %s\n' "$(verdict_now)"
          exit 0
          ;;
      esac
      provenance=adopted
    else
      mkdir -p "$(dirname "$SOCKET")" 2>/dev/null || true
      tmux -S "$SOCKET" new-session -d -s "$SESSION_NAME" 2>/dev/null || true
      live=$(fmr_gui_socket_server_pid "$SOCKET")
      [ -n "$live" ] || { echo "error: could not start a tmux server on $SOCKET" >&2; exit 1; }
      provenance=$class
    fi

    mkdir -p "$(dirname "$MARKER")"
    umask 077
    {
      printf 'socket=%s\n' "$SOCKET"
      printf 'server_pid=%s\n' "$live"
      printf 'asid=%s\n' "$(fmr_gui_console_asid)"
      printf 'provenance=%s\n' "$provenance"
      printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s\n' "$chain" | sed 's/^/starter_chain=/'
    } > "$MARKER"

    printf 'host session ready: %s\n' "$(verdict_now)"
    case "$provenance" in
      desktop) ;;
      indirect)
        echo "note: started from inside a multiplexer, so desktop ancestry is not proven." >&2
        echo "      If agents on this host wedge at startup, restart it from a desktop terminal." >&2
        ;;
      adopted)
        echo "note: a tmux server already owned $SOCKET and was adopted as-is." >&2
        echo "      Its origin was not observed, so nothing is claimed about its ancestry." >&2
        ;;
    esac
    ;;

  stop)
    text=$(marker_text)
    [ -n "$text" ] || { echo "no host session marker at $MARKER"; exit 0; }
    prov=$(fmr_gui_marker_field "$text" provenance)
    pid=$(fmr_gui_marker_field "$text" server_pid)
    live=$(fmr_gui_socket_server_pid "$SOCKET")
    if [ "$prov" = adopted ]; then
      # This script did not create that server and cannot know what else is on
      # it. On the machine this was built for, the adopted server is the
      # captain's own fleet: killing it would take every running agent with it.
      echo "REFUSED: the host session on $SOCKET was adopted, not started here." >&2
      echo "Whatever else lives on that server would go with it. Removing the marker only." >&2
      rm -f "$MARKER"
      echo "marker removed; the tmux server (pid ${pid:-unknown}) was left alone."
      exit 0
    fi
    if [ -n "$live" ] && [ "$live" = "$pid" ]; then
      tmux -S "$SOCKET" kill-server 2>/dev/null || true
      echo "stopped: host session (pid $pid)"
    else
      echo "host session (pid ${pid:-unknown}) was already gone"
    fi
    rm -f "$MARKER"
    ;;

  *)
    usage
    exit 2
    ;;
esac
