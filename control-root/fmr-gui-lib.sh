# shellcheck shell=bash
# fmr-gui-lib.sh - the host-side decision logic for a GUI-capable relay task host.
#
# Deployed alongside control-root/verbs/fmr-verb.sh by bin/fm-relay-conn.sh, and
# sourced ONLY when the host config declares GUI=1, so a non-GUI task host
# (docs/relay-host.md's box151 shape) neither needs this file nor changes
# behaviour by one byte when it is absent.
#
# Two consumers, one owner:
#   - control-root/verbs/fmr-verb.sh, which must answer "can this machine take
#     work right now" BEFORE it claims a task;
#   - control-root/fmr-host-session.sh, which starts and reports the desktop host
#     session those checks look for.
#
# THE HARD CONSTRAINT THIS FILE EXISTS FOR
# An agent must not be a descendant of a launchd job. A `claude -p` started from
# one wedges permanently in openat(2): ten minutes, 0.26 s of CPU, not one
# request sent. The identical binary and prompt work every time when the ancestry
# runs through a desktop app. Measured three ways - tmux, direct launch, login
# shell - and all three wedged under launchd
# (data/fm-mac-as-worker-demo/report.md, evidence/05-tmux-under-launchd-hang.log).
# The root cause is not pinned; environment, tmux, network, keychain, and binary
# startup were each excluded, leaving TCC/XPC responsible-process attribution as
# the suspicion. The workaround is proven, so this is built as a workaround and
# not as a fix.
#
# The consequence for the architecture: bifrost's daemon is itself launchd-managed
# on macOS, so the verb may NOT start the agent's session provider. It hands work
# to a tmux server that was started from the desktop and refuses when that server
# is not there. control-root/fmr-host-session.sh starts it.
#
# WHY THE CHECKS RUN BEFORE THE CLAIM
# A claim tells the control machine "this work has an owner". Claiming and then
# failing is strictly worse than refusing: the control side stops looking for
# somewhere else to run it, and the task sits owned by a machine that cannot do
# it. So every check here is asked before verbs/fmr-verb.sh's claim mkdir, in the
# same process, which is also what closes the gap between asking and acting.
#
# WHAT IS DELIBERATELY NOT USED AS A SIGNAL, and why - all measured, same report:
#   - $SECURITYSESSIONID: a launchd job never receives it, and it is an ordinary
#     environment variable that anything can set. The kernel's audit session id
#     (getaudit_addr(2)) is the real one.
#   - `launchctl managername`: a process reporting Background screenshots and
#     opens a headed browser perfectly well. It says which launchd domain manages
#     a job, not whether the WindowServer will talk to it.
#   - Ancestry at check time: a tmux server daemonises, so its parent is always
#     pid 1 and its origin is unreadable afterwards. Provenance can only be
#     captured when the session is started, which is why it lands in the marker.

FMR_GUI_MARKER_FIELDS='socket server_pid asid provenance started_at'

# --- pure verdict functions ---------------------------------------------------
# Every function below takes probe TEXT and returns a verdict, so the decisions
# are testable without a Mac, a desktop session, or a locked screen
# (tests/fm-relay-gui-host.test.sh). The probes that collect that text are at the
# bottom of the file and are the only part that touches the machine.

# fmr_gui_lock_verdict: locked | unlocked | unknown, from `ioreg -n Root -d1 -a`.
#
# The key is absent entirely on a session that has not been locked since login,
# so absence means unlocked - but only when the surrounding IOConsoleUsers array
# is present. An unreadable probe is `unknown` and the caller refuses on it: a
# screen whose state cannot be read is not a screen known to be unlocked.
fmr_gui_lock_verdict() {  # <ioreg-plist-text>
  local text=$1
  case "$text" in
    *IOConsoleUsers*) ;;
    *) printf 'unknown'; return 0 ;;
  esac
  if printf '%s\n' "$text" \
    | grep -A1 -F '<key>CGSSessionScreenIsLocked</key>' 2>/dev/null \
    | grep -qF '<true/>'; then
    printf 'locked'
  else
    printf 'unlocked'
  fi
}

# fmr_gui_ancestry_class: desktop | indirect | launchd-job, from a normalised
# "<pid> <ppid> <executable>" chain, outermost ancestor last.
#
# desktop      an .app bundle executable appears in the chain. This is the shape
#              the wedge was never reproduced under.
# indirect     no .app, but a terminal multiplexer appears. The multiplexer's own
#              origin is not observable, so this is honestly "not proven either
#              way" rather than a pass dressed up as one.
# launchd-job  the chain reaches launchd with neither of the above, which is
#              exactly the shape that wedges. Starting a host session from here
#              is refused.
fmr_gui_ancestry_class() {  # <chain-text>
  local text=$1 line exe
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    exe=${line#* }; exe=${exe#* }
    case "$exe" in
      *.app/Contents/MacOS/*) printf 'desktop'; return 0 ;;
    esac
  done <<EOF
$text
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    exe=${line#* }; exe=${exe#* }
    case "${exe##*/}" in
      tmux|tmux:*|screen|SCREEN|zellij) printf 'indirect'; return 0 ;;
    esac
  done <<EOF
$text
EOF
  printf 'launchd-job'
}

# fmr_gui_marker_field: read one key from marker text. Marker files are written
# by fmr-host-session.sh as key=value lines and never by hand.
fmr_gui_marker_field() {  # <marker-text> <key>
  local text=$1 key=$2
  printf '%s\n' "$text" | grep "^$key=" | tail -1 | cut -d= -f2- || true
}

# fmr_gui_session_verdict: the host-session state machine, as
# "<verdict> <human sentence>".
#
# The distinction the design asks for - "never started" versus "started and then
# died" - is the difference between `absent` and `dead`, and it matters because
# the operator actions differ: start it, versus find out what killed it.
#
#   ok         the recorded server is the live owner of the socket, in this login
#   absent     no marker: the host session was never started on this machine
#   malformed  a marker exists but does not carry the fields it must
#   dead       the marker names a server that is no longer running
#   replaced   some other tmux server owns that socket now, so whatever is there
#              was not started as a host session and its provenance is unknown
#   stale      the desktop login changed since the session started, so the
#              session belongs to a login that is gone
fmr_gui_session_verdict() {  # <marker-text> <live-server-pid-or-empty> <current-asid>
  local marker=$1 live=$2 cur_asid=$3 f v pid asid started prov
  if [ -z "$marker" ]; then
    printf 'absent no desktop host session has been started on this machine'
    return 0
  fi
  for f in $FMR_GUI_MARKER_FIELDS; do
    v=$(fmr_gui_marker_field "$marker" "$f")
    [ -n "$v" ] || { printf 'malformed the host session marker is missing %s' "$f"; return 0; }
  done
  pid=$(fmr_gui_marker_field "$marker" server_pid)
  asid=$(fmr_gui_marker_field "$marker" asid)
  started=$(fmr_gui_marker_field "$marker" started_at)
  prov=$(fmr_gui_marker_field "$marker" provenance)
  if [ -z "$live" ]; then
    printf 'dead the desktop host session started at %s (server pid %s) is no longer running' \
      "$started" "$pid"
    return 0
  fi
  if [ "$live" != "$pid" ]; then
    printf 'replaced another tmux server (pid %s) owns that socket now, not the recorded host session (pid %s)' \
      "$live" "$pid"
    return 0
  fi
  if [ -n "$cur_asid" ] && [ "$cur_asid" != "$asid" ]; then
    printf 'stale the desktop host session belongs to login session %s but this machine is now in login session %s' \
      "$asid" "$cur_asid"
    return 0
  fi
  printf 'ok desktop host session pid %s, started %s, provenance %s' "$pid" "$started" "$prov"
}

# --- machine probes -----------------------------------------------------------
# The only functions here that read the machine. Each is a single command so the
# verdict logic above stays free of them.

fmr_gui_ioreg_text() {
  ioreg -n Root -d1 -a 2>/dev/null || true
}

# The kernel's audit session id for THIS process, via getaudit_addr(2). The
# console session's own id is read separately below; a host session whose id no
# longer matches the console belongs to a login that has ended.
fmr_gui_console_asid() {
  fmr_gui_ioreg_text \
    | grep -A1 -F '<key>kCGSSessionAuditIDKey</key>' \
    | grep -oE '<integer>[0-9]+</integer>' \
    | grep -oE '[0-9]+' \
    | head -1 || true
}

# The pid of the tmux server owning <socket>, or empty. `display-message -p`
# against an absent server exits non-zero and prints nothing, which is exactly
# the "no server" answer, so a failure here is data rather than an error.
fmr_gui_socket_server_pid() {  # <socket>
  tmux -S "$1" display-message -p '#{pid}' 2>/dev/null | head -1 || true
}

# A normalised ancestry chain for <pid>, outermost last, stopping at launchd.
# `ps -o comm=` reports the executable path on macOS, which is what carries the
# .app bundle marker the classifier looks for.
fmr_gui_ancestry_chain() {  # [pid]
  local p=${1:-$$} line ppid exe i=0
  while [ "$i" -lt 24 ]; do
    line=$(ps -o ppid=,comm= -p "$p" 2>/dev/null) || break
    [ -n "$line" ] || break
    # `ps` pads its numeric column, so split with read rather than parameter
    # expansion; the executable path keeps its own spaces in the remainder.
    ppid=; exe=
    read -r ppid exe <<EOF
$line
EOF
    [ -n "$ppid" ] || break
    printf '%s %s %s\n' "$p" "$ppid" "$exe"
    [ "$ppid" = 1 ] && break
    p=$ppid
    i=$((i + 1))
  done
}
