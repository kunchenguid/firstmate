#!/usr/bin/env bash
# fm-osc7501.sh - worker-side OSC 7501 (Program Status Protocol) reporter.
#
# The protocol (revision 0.4, https://control-codes.page/proposals/osc-7501/)
# lets a program tell its terminal what it is doing: idle, working, blocked,
# done, or error, with a one-line reason. 7501-aware terminals - herdr-core
# (`hc`), the Herdr app, Ghostty, Rex - then show working/blocked/done with no
# screen inference; every other terminal ignores the unknown OSC unharmed.
#
# `arm` runs inside a task pane at launch (fm-spawn stages it into the launch
# command) and decides whether this worker may report:
#
#   1. config/osc7501-status must not say off (default on; an unrecognized
#      word warns once and reads as off)
#   2. the pane must have a writable controlling terminal
#   3. the terminal must be KNOWN 7501-aware by its environment
#      (HC_TERMINAL_ID = herdr-core, REX_BLOCK/REX_SESSION = Rex,
#      TERM_PROGRAM=ghostty) or answer the `OSC 7501 ; ?` capability query;
#      a backend=herdr pane is known to be unaware - old herdr does not
#      implement the protocol - and a pane with no readable tty can never
#      answer, so both exit before the query
#   4. the harness must not already report natively: Claude Code >= 2.1.295
#      and Pi >= 1.1.0 send their own records (herdr discussions #5073/#5106,
#      verified 2026-10-30), so a firstmate record would only fight theirs
#
# When all of that holds, arm daemonizes `watch`, which polls firstmate's own
# durable signals for the task and emits records to /dev/tty:
#
#   state/<id>.status current line (bin/fm-classify-lib.sh owns the fold -
#   an open needs-decision or blocked wins over routine events):
#     needs-decision/held -> blocked kind=question
#     blocked             -> blocked kind=permission (kind=auth when the note
#                            names a credential)
#     failed              -> error
#     done                -> done ("PR ready" when the note has a URL)
#     paused              -> working, msg "Waiting: <note>"
#   otherwise the task's activity as fm_busy_classify reads it
#   (bin/fm-busy-lib.sh owns every source: the busy-state record, or
#   Cursor's transcript / Muse's session log):
#     busy -> working, idle -> idle, unknown -> hold the last record
#   unhandled <id>.inbox/*.msg with idle or unknown activity reads as
#     working "Steering received"
#   a working: line supplies the working message, and reads as working while
#     the activity is unknown
#   a failed/done/paused declaration yields only to a follow-up: once any
#   steer (unhandled or in handled/) was enqueued after it, the declaration is
#   retired and activity and inbox map as above. Busy-state writes never
#   retire one - a mid-turn rewrite looks the same as a new turn - and
#   ordering uses nanosecond file times so a steer in the declaration's own
#   second still counts; an open decision or blocker always wins
#
# Records go to the ROOT record (no id) with app=firstmate-<harness> and
# title=fm-<task> so `hc get .status` and the app sidebar classify the worker;
# firstmate's own id=fm attention marks on Rex are a separate supervisor-side
# feature (bin/fm-rex-marks.sh) and compose unchanged. The watcher re-emits
# only on change plus a heartbeat (records outlive resends, but a terminal
# that dropped one is repaired). Its lifetime is the agent incarnation: the
# launch runs `disarm` right after the agent command returns, and the watcher
# also exits when its recorded parent - the shell running the launch - dies.
# Either way a final emit keeps done/error and otherwise parks the record at
# idle; a TERM/HUP retires it the same way. One watcher per controlling
# terminal (<state>/.osc7501watch-<tty>): every arm retires the pane's
# previous watcher before any gate, so a relaunch rebinds to the new agent and
# a natively reporting agent never shares the pane with a stale writer.
#
# Safety: the capability query is the ONLY terminal-input read; it runs while
# the pane shell still owns the tty (before the agent launches), sets
# -icanon -echo for under a second, restores the saved mode (also when a
# signal interrupts it), and drains any
# straggler bytes so nothing escape-shaped reaches the worker's composer or
# the agent's input later. Every record write is one small write() to the
# pane's tty in the output direction - the same channel fm-rex-marks.sh uses -
# so it can never be read as typed input.
#
# Subcommands:
#   arm --task <id> --harness <h> --backend <b> --kind <k> --state <dir>
#       --config <dir> [--agent-bin <path>]   detect + spawn watcher; exit 0
#   watch --task <id> --kind <k> --state <dir> --harness <h> --parent <pid>
#                                            the reporter loop (internal)
#   disarm --state <dir>                     retire this terminal's watcher
#
# Test seams: FM_OSC7501_TTY replaces /dev/tty as the emit/query device (a
# regular file then captures exactly what a terminal would receive), and
# FM_OSC7501_INTERVAL/_HEARTBEAT/_QUERY_DS/_PROBE_SECS tune the loop and
# probes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FM_OSC7501_MSG_MAX=${FM_OSC7501_MSG_MAX:-120}
FM_OSC7501_TITLE_MAX=${FM_OSC7501_TITLE_MAX:-64}
FM_OSC7501_INTERVAL=${FM_OSC7501_INTERVAL:-2}
FM_OSC7501_HEARTBEAT=${FM_OSC7501_HEARTBEAT:-45}
FM_OSC7501_QUERY_DS=${FM_OSC7501_QUERY_DS:-5}
FM_OSC7501_PROBE_SECS=${FM_OSC7501_PROBE_SECS:-3}
FM_OSC7501_APP_MAX=32
FM_OSC7501_AUTH_RE='credential|login|log in|sign[ -]?in|auth|token|password|api key'
FM_OSC7501_CONFIG=osc7501-status
FM_OSC7501_UNKNOWN_PREFIX=.osc7501-gate-

usage() {
  {
    echo "usage: fm-osc7501.sh arm --task <id> --harness <h> --backend <b> --kind <k> --state <dir> --config <dir> [--agent-bin <path>]"
    echo "       fm-osc7501.sh watch --task <id> --kind <k> --state <dir> --harness <h> --parent <pid>"
    echo "       fm-osc7501.sh disarm --state <dir>"
  } >&2
  exit 2
}

warn() { printf 'warning: osc7501: %s\n' "$*" >&2; }

task_ok() { # <id>
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# --- record formatting --------------------------------------------------------

osc_clean() { # <text> -> one line, control characters as spaces
  printf '%s' "$1" | tr '\000-\037\177' ' '
}

osc_b64() { # <text> -> base64 on one line
  printf '%s' "$1" | base64 | tr -d '\n'
}

# osc_seq <state> [id] [kind] [progress] [title] [msg] -> one OSC 7501 report.
# msg/title are clipped and base64-encoded; progress survives only on
# working/blocked. FM_OSC_APP must name the reporting program.
osc_seq() {
  local f="state=$1"
  case "${3:-}" in '') ;; *) f="$f:kind=$3" ;; esac
  f="$f:app=$FM_OSC_APP"
  case "$2" in '') ;; *) f="$f:id=$2" ;; esac
  case "$1:${4:-}" in
    working:[0-9] | working:[1-9][0-9] | working:100 | blocked:[0-9] | blocked:[1-9][0-9] | blocked:100)
      f="$f:progress=$4" ;;
  esac
  case "${5:-}" in '') ;; *)
    local t
    t=$(osc_clean "${5:0:$FM_OSC7501_TITLE_MAX}")
    f="$f:title=$(osc_b64 "$t")" ;;
  esac
  case "${6:-}" in '') ;; *)
    local m
    m=$(osc_clean "${6:0:$FM_OSC7501_MSG_MAX}")
    f="$f:msg=$(osc_b64 "$m")" ;;
  esac
  printf '\033]7501;%s\033\134' "$f"
}

# --- gates --------------------------------------------------------------------

# config gate: first non-comment word of config/osc7501-status; absent -> on.
# An unrecognized word warns once per value (marker under the state dir).
osc_gate() { # <config> <state>
  local file="$1/$FM_OSC7501_CONFIG" line word marker
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in '' | '#'*) continue ;; esac
    word=$(printf '%s' "${line%%[[:space:]]*}" | tr '[:upper:]' '[:lower:]')
    case "$word" in
      on) return 0 ;;
      off) return 1 ;;
    esac
    case "$word" in *[!a-z0-9_-]*) word=invalid ;; esac
    marker="$2/$FM_OSC7501_UNKNOWN_PREFIX$word"
    if [ ! -e "$marker" ]; then
      warn "$file: unknown value; using off (on or off)"
      : >"$marker" 2>/dev/null || true
    fi
    return 1
  done <"$file"
  return 0
}

# known-aware environment: the pane runs inside a terminal whose 7501 support
# is established by its own marker, so no query is needed.
osc_env_aware() {
  [ -n "${HC_TERMINAL_ID:-}" ] && return 0
  [ -n "${REX_BLOCK:-}${REX_SESSION:-}" ] && return 0
  [ "${TERM_PROGRAM:-}" = ghostty ] && return 0
  return 1
}

# capability query: write `OSC 7501 ; ?`, read the answer, and restore the
# saved terminal mode. The tty is set VMIN=0 VTIME=FM_OSC7501_QUERY_DS
# (deciseconds) so each raw read() returns at the first byte or on a bounded
# silence; `dd` treats that empty read as EOF, which makes the wait
# version-proof where bash 3.2's own read would block forever. Runs only
# while the pane shell owns the tty in the foreground, before the agent
# starts. A second gap-bounded read mops up a response that straddled a
# silence so no escape-shaped bytes are left for the next program on the
# pane to read.
osc_query_restore() { # <signal>: restore the saved mode, then die by it
  stty "$old" <"$dev" 2>/dev/null
  trap - "$1"
  kill -"$1" "$$"
}

osc_query_supported() {
  local dev=${FM_OSC7501_TTY:-/dev/tty} old reply='' more
  old=$(stty -g <"$dev" 2>/dev/null) || return 1
  trap 'osc_query_restore INT' INT
  trap 'osc_query_restore TERM' TERM
  trap 'osc_query_restore HUP' HUP
  if stty -icanon -echo min 0 time "$FM_OSC7501_QUERY_DS" <"$dev" 2>/dev/null; then
    printf '\033]7501;?\033\134' >"$dev" 2>/dev/null
    reply=$(dd bs=1 count=8192 if="$dev" 2>/dev/null)
    if [ -n "$reply" ]; then
      more=$(dd bs=1 count=8192 if="$dev" 2>/dev/null)
      reply="$reply$more"
    fi
  fi
  stty "$old" <"$dev" 2>/dev/null || true
  trap - INT TERM HUP
  case "$reply" in *"$FM_OSC7501_QUERY_MATCH"*) return 0 ;; esac
  return 1
}
FM_OSC7501_QUERY_MATCH=$(printf '\033]7501')

# --- native reporting ---------------------------------------------------------

# osc_mtime_ns <file> -> mtime in integer nanoseconds, portable.
OSC_DARWIN=0
[ "$(uname -s 2>/dev/null)" = Darwin ] && OSC_DARWIN=1
osc_mtime_ns() {
  local t s f
  if [ "$OSC_DARWIN" = 1 ]; then
    t=$(/usr/bin/stat -f %Fm "$1" 2>/dev/null) || return 1
  else
    t=$(stat -c '%Y %y' "$1" 2>/dev/null) || return 1
    t=$(printf '%s' "$t" | awk '{n = split($3, a, "."); printf "%s.%s", $1, (n > 1 ? a[2] : "")}')
  fi
  s=${t%%.*}
  f="${t#"$s"}"
  f="${f#.}000000000"
  f=${f:0:9}
  case "$s$f" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s%s' "$s" "$f"
}

# osc_probe_version <bin> -> first x.y.z in `<bin> --version`, bounded by
# FM_OSC7501_PROBE_SECS and run at every launch.
osc_probe_version() { # <bin>
  local rp tmp pid i ver
  rp=$(command -v "$1" 2>/dev/null) || rp=$1
  case "$rp" in /*) ;; *) return 1 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-osc7501.XXXXXX") || return 1
  ( "$rp" --version >"$tmp" 2>/dev/null ) & pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$(( ${FM_OSC7501_PROBE_SECS%.*} * 10 ))" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    ver=
  else
    wait "$pid" 2>/dev/null
    ver=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' "$tmp" 2>/dev/null | head -1)
  fi
  rm -f "$tmp"
  [ -n "${ver:-}" ] || return 1
  printf '%s' "$ver"
}

# osc_version_ge <ver> <floor>
osc_version_ge() {
  local v1 v2 v3 f1 f2 f3 rest
  IFS=. read -r v1 v2 v3 rest <<EOF
$1
EOF
  IFS=. read -r f1 f2 f3 rest <<EOF
$2
EOF
  case "$v1$v2" in *[!0-9]*) return 1 ;; esac
  v3=${v3:-0}; f3=${f3:-0}
  case "$v3$f3" in *[!0-9]*) return 1 ;; esac
  if [ "$v1" -ne "$f1" ]; then [ "$v1" -gt "$f1" ]; return; fi
  if [ "$v2" -ne "$f2" ]; then [ "$v2" -gt "$f2" ]; return; fi
  [ "$v3" -ge "$f3" ]
}

# osc_native <harness> <agent-bin>: 0 when the launched agent reports
# OSC 7501 itself at the probed version. An unprobed or failed probe reads as
# not native: coverage wins, and two writers on one record only ever produce
# the newer state.
osc_native() {
  local floor ver
  case "$1" in
    claude) floor=2.1.295 ;;
    pi | pi-signed) floor=1.1.0 ;;
    *) return 1 ;;
  esac
  ver=$(osc_probe_version "${2:-$1}") || return 1
  osc_version_ge "$ver" "$floor"
}

# --- signal -> state ----------------------------------------------------------

LIBS_LOADED=0
OSC_DECL_LINE=
OSC_DECL_AT=0
osc_load_libs() {
  [ "$LIBS_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh" || return 1
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh" || return 1
  LIBS_LOADED=1
}

# osc_inbox_since <dir> <ns>: 0 when a steer message in <dir> was written after
# <ns> (0 = any message).
osc_inbox_since() {
  local msg mt
  for msg in "$1"/*.msg; do
    [ -e "$msg" ] || continue
    mt=$(osc_mtime_ns "$msg") || continue
    [ "${mt:-0}" -gt "$2" ] 2>/dev/null && return 0
  done
  return 1
}

# osc_plan sets W_STATE, W_KIND, W_MSG; returns 1 when nothing should be
# emitted (no signal yet, or the activity is unknown). A declaration's time,
# in nanoseconds, is fixed the first poll that sees its line (OSC_DECL_LINE /
# OSC_DECL_AT): no later than the status file's mtime then, nor than the end
# of its own stamped second, so later unrelated appends never move it.
osc_plan() { # <task> <kind> <state> <harness>
  local task=$1 kind=$2 state_dir=$3 line verb note held act bs since sf wmsg=''
  W_STATE=
  W_KIND=
  W_MSG=
  osc_load_libs || return 1
  act=$(fm_busy_classify '' '' "$4" "$task" "$state_dir" 2>/dev/null) || act=
  bs=${act%% *}
  line=$(status_current_line "$state_dir/$task.status" "$kind" 2>/dev/null)
  verb=$(status_line_verb "$line" 2>/dev/null) || verb=
  note=$(status_line_note "$line" 2>/dev/null) || note=
  note=$(printf '%s' "$note" | tr '\t\r\n' '   ')
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    needs-decision | "$held")
      W_STATE=blocked
      W_KIND=question
      W_MSG="Needs your decision: $note"
      return 0
      ;;
    blocked)
      W_STATE=blocked
      W_KIND=permission
      if printf '%s' "$note" | grep -Eiq "$FM_OSC7501_AUTH_RE"; then W_KIND=auth; fi
      W_MSG="Blocked: $note"
      return 0
      ;;
    failed)
      W_STATE=error
      W_MSG="Failed: $note"
      ;;
    done)
      W_STATE='done'
      case "$note" in
        *https://*) W_MSG="PR ready: $note" ;;
        *) W_MSG="Done: $note" ;;
      esac
      ;;
    paused)
      W_STATE=working
      W_MSG="Waiting: $note"
      ;;
    working) wmsg=$note ;;
  esac
  if [ -n "$W_STATE" ]; then
    if [ "$line" != "$OSC_DECL_LINE" ]; then
      since=$(status_line_at_epoch "$line" 2>/dev/null) || return 0
      since=$((since * 1000000000 + 999999999))
      if sf=$(osc_mtime_ns "$state_dir/$task.status") && [ "$sf" -lt "$since" ]; then since=$sf; fi
      OSC_DECL_LINE=$line
      OSC_DECL_AT=$since
    fi
    if ! osc_inbox_since "$state_dir/$task.inbox" "$OSC_DECL_AT" &&
      ! osc_inbox_since "$state_dir/$task.inbox/handled" "$OSC_DECL_AT"; then
      return 0
    fi
    W_STATE=
    W_MSG=
  fi
  if [ "$bs" = busy ]; then
    W_STATE=working
    W_MSG=$wmsg
  elif osc_inbox_since "$state_dir/$task.inbox" 0; then
    W_STATE=working
    W_MSG="Steering received"
  elif [ "$bs" = idle ]; then
    W_STATE=idle
  elif [ "$verb" = working ]; then
    W_STATE=working
    W_MSG=$wmsg
  fi
  [ -n "$W_STATE" ]
}

# --- watcher ------------------------------------------------------------------

# final record before exit: keep a result worth finding (done/error) and park
# everything else at idle, never clearing records another program owns.
osc_final() {
  if osc_plan "$WATCH_TASK" "$WATCH_KIND" "$WATCH_STATE" "$WATCH_HARNESS" && { [ "$W_STATE" = 'done' ] || [ "$W_STATE" = error ]; }; then
    printf '%s' "$(osc_seq "$W_STATE" '' "$W_KIND" '' "$WATCH_TITLE" "$W_MSG")" >&3 2>/dev/null
  else
    printf '%s' "$(osc_seq idle '' '' '' "$WATCH_TITLE" '')" >&3 2>/dev/null
  fi
}

osc_watch() { # --task --kind --state --harness --parent
  local opt
  WATCH_TASK=
  WATCH_KIND=
  WATCH_STATE=
  WATCH_HARNESS=
  WATCH_PARENT=
  while [ $# -gt 0 ]; do
    opt=$1
    shift
    case "$opt" in
      --task) WATCH_TASK=$1 ;;
      --kind) WATCH_KIND=$1 ;;
      --state) WATCH_STATE=$1 ;;
      --harness) WATCH_HARNESS=$1 ;;
      --parent) WATCH_PARENT=$1 ;;
      *) usage ;;
    esac
    shift
  done
  task_ok "$WATCH_TASK" || exit 0
  case "$WATCH_PARENT" in '' | *[!0-9]*) exit 0 ;; esac
  [ -d "$WATCH_STATE" ] || exit 0
  WATCH_KIND=${WATCH_KIND:-ship}
  FM_OSC_APP="firstmate-$WATCH_HARNESS"
  FM_OSC_APP="${FM_OSC_APP:0:$FM_OSC7501_APP_MAX}"
  WATCH_TITLE="fm-$WATCH_TASK"
  local dev=${FM_OSC7501_TTY:-/dev/tty} hb=0 hb_ticks last='' seq
  exec 3>>"$dev" 2>/dev/null || exit 0
  osc_load_libs || exit 0
  trap 'osc_final; exit 0' TERM INT HUP
  [ "${FM_OSC7501_INTERVAL:-1}" -ge 1 ] 2>/dev/null || FM_OSC7501_INTERVAL=1
  hb_ticks=$((FM_OSC7501_HEARTBEAT / FM_OSC7501_INTERVAL))
  [ "$hb_ticks" -ge 1 ] || hb_ticks=1
  while :; do
    if ! kill -0 "$WATCH_PARENT" 2>/dev/null; then
      osc_final
      break
    fi
    if osc_plan "$WATCH_TASK" "$WATCH_KIND" "$WATCH_STATE" "$WATCH_HARNESS"; then
      seq=$(osc_seq "$W_STATE" '' "$W_KIND" '' "$WATCH_TITLE" "$W_MSG")
      if [ "$seq" != "$last" ]; then
        printf '%s' "$seq" >&3 2>/dev/null
        last=$seq
        hb=0
      else
        hb=$((hb + 1))
        if [ "$hb" -ge "$hb_ticks" ]; then
          printf '%s' "$seq" >&3 2>/dev/null
          hb=0
        fi
      fi
    fi
    sleep "$FM_OSC7501_INTERVAL" 2>/dev/null &
    wait $! 2>/dev/null
  done
}

# --- arm / disarm -------------------------------------------------------------

# osc_tty_key -> pidfile key naming this process's controlling terminal (the
# device /dev/tty opens), or the FM_OSC7501_TTY stand-in; 1 without one.
osc_tty_key() {
  local key
  if [ -n "${FM_OSC7501_TTY:-}" ]; then
    key=$FM_OSC7501_TTY
  else
    key=$(ps -o tty= -p "$$" 2>/dev/null) || return 1
    key=${key//[[:space:]]/}
  fi
  case "$key" in '' | *'?'*) return 1 ;; esac
  key=${key#/dev/}
  printf '%s' "${key//\//_}"
}

# osc_gone <pid> <ticks>: 0 once <pid> has exited, polling every 0.1s.
osc_gone() {
  local i=0
  while kill -0 "$1" 2>/dev/null; do
    [ "$i" -ge "$2" ] && return 1
    sleep 0.1
    i=$((i + 1))
  done
}

# osc_retire <pidfile>: stop the watcher it records (its TERM trap emits the
# final record), confirm it exited - a watcher still busy past the grace is
# killed so it can never write after the next owner - and forget it. Returns
# 1, keeping the pidfile, when the watcher survives.
osc_retire() {
  local opid=''
  [ -f "$1" ] || return 0
  read -r opid _ <"$1" 2>/dev/null || opid=
  case "$opid" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$opid" 2>/dev/null && ps -o command= -p "$opid" 2>/dev/null | grep -q 'fm-osc7501\.sh'; then
        kill "$opid" 2>/dev/null || true
        if ! osc_gone "$opid" 50; then
          kill -KILL "$opid" 2>/dev/null || true
          osc_gone "$opid" 10 || return 1
        fi
      fi
      ;;
  esac
  rm -f "$1"
}

osc_disarm() { # --state <dir>
  local opt state=''
  while [ $# -gt 0 ]; do
    opt=$1
    shift
    case "$opt" in
      --state) state=$1 ;;
      *) usage ;;
    esac
    shift
  done
  [ -d "$state" ] || exit 0
  local key
  key=$(osc_tty_key) || exit 0
  osc_retire "$state/.osc7501watch-$key"
  exit 0
}

osc_arm() { # --task --harness --backend --kind --state --config [--agent-bin]
  local opt task='' harness='' backend='' kind='' state='' config='' agent_bin=''
  while [ $# -gt 0 ]; do
    opt=$1
    shift
    case "$opt" in
      --task) task=$1 ;;
      --harness) harness=$1 ;;
      --backend) backend=$1 ;;
      --kind) kind=$1 ;;
      --state) state=$1 ;;
      --config) config=$1 ;;
      --agent-bin) agent_bin=$1 ;;
      *) usage ;;
    esac
    shift
  done
  task_ok "$task" || exit 0
  [ -d "$state" ] || exit 0
  local key pidfile
  key=$(osc_tty_key) || exit 0
  pidfile="$state/.osc7501watch-$key"
  osc_retire "$pidfile" || exit 0
  osc_gate "$config" "$state" || exit 0
  # a pane without a writable tty can never report, and one without a readable
  # tty can never answer the capability query either
  local dev=${FM_OSC7501_TTY:-/dev/tty}
  [ -w "$dev" ] || exit 0
  case "$backend" in herdr | t3code) exit 0 ;; esac
  # a natively reporting agent never sees a query or a competing record
  osc_native "$harness" "${agent_bin:-$harness}" && exit 0
  if ! osc_env_aware; then
    [ -r "$dev" ] || exit 0
    osc_query_supported || exit 0
  fi
  FM_OSC7501_WATCHER=1 nohup bash "$SCRIPT_DIR/fm-osc7501.sh" watch \
    --task "$task" --kind "$kind" --state "$state" --harness "$harness" \
    --parent "$PPID" </dev/null >/dev/null 2>&1 &
  printf '%s %s %s\n' "$!" "$task" "$$" >"$pidfile" 2>/dev/null || true
  exit 0
}

case "${1:-}" in
  -h | --help | help)
    sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 0 ;;
  arm)
    shift
    osc_arm "$@" ;;
  watch)
    shift
    osc_watch "$@" ;;
  disarm)
    shift
    osc_disarm "$@" ;;
  *) usage ;;
esac
