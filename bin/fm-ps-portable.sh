#!/usr/bin/env bash
# fm-ps-portable.sh - portable process introspection for firstmate.
#
# Emulates the `ps -o <field>= -p <pid>` queries firstmate uses to walk the
# harness process ancestry (fm-lock.sh, fm-harness.sh) and to fingerprint a
# pid for reuse-detection (fm-wake-lib.sh). MSYS2 / Git Bash on Windows ships
# a `ps` with no `-o` flag - it errors "ps: unknown option -- o" - so those
# walks break there as written.
#
# On macOS/Linux the native `ps -o` path is used unchanged (exact, fast). Only
# where `ps -o` is unavailable do we fall back to parsing `ps -f`, which MSYS
# supports and which prints the full command line WITH arguments:
#     UID  PID  PPID  TTY  STIME  COMMAND...
# This mirrors the existing platform-branch convention in fm-wake-lib.sh
# (`stat -f` on Darwin vs `stat -c` elsewhere).
#
# Sourced, never executed. Sets no global shell options.

# Capability probe, run once and cached (idempotent across multiple `source`s).
if [ -z "${FM_PS_NATIVE:-}" ]; then
  if ps -o comm= -p "$$" >/dev/null 2>&1; then
    FM_PS_NATIVE=1
  else
    FM_PS_NATIVE=0
  fi
fi

# fm_ps_field <comm|args|ppid|identity> <pid>
#   comm     - basename of argv[0] (handles / and \ so Windows node.exe resolves)
#   args     - full command line
#   ppid     - parent pid (whitespace stripped)
#   identity - a stable "start-time command" fingerprint for pid-reuse detection
# Prints the field to stdout; returns non-zero when the pid is not found.
fm_ps_field() {
  local field=$1 pid=$2
  if [ "${FM_PS_NATIVE:-1}" = 1 ]; then
    case "$field" in
      comm)     ps -o comm= -p "$pid" 2>/dev/null ;;
      args)     ps -o args= -p "$pid" 2>/dev/null ;;
      ppid)     ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' ;;
      identity) ps -p "$pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//' ;;
    esac
    return
  fi
  # MSYS fallback: parse one `ps -f` row. Columns: UID PID PPID TTY STIME COMMAND...
  local row ppid stime cmd first
  row=$(ps -f 2>/dev/null | awk -v want="$pid" 'NR>1 && $2==want {
    p=$3; s=$5; c=""; for (i=6; i<=NF; i++) c = c (i>6 ? " " : "") $i;
    print p "\t" s "\t" c; exit }')
  [ -n "$row" ] || return 1
  ppid=${row%%$'\t'*}; row=${row#*$'\t'}
  stime=${row%%$'\t'*}; cmd=${row#*$'\t'}
  case "$field" in
    ppid)     printf '%s' "$ppid" ;;
    args)     printf '%s' "$cmd" ;;
    comm)     first=${cmd%%[[:space:]]*}; printf '%s' "${first##*[\\/]}" ;;
    identity) printf '%s %s' "$stime" "$cmd" ;;
  esac
}
