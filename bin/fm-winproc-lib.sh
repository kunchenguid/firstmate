#!/usr/bin/env bash
# shellcheck shell=bash
# Native Windows process facts for a Git Bash (MSYS) firstmate home.
#
# ONE owner of the "what does the Windows kernel say about process N?" question.
# It exists because the MSYS process tree is severed from the Windows tree: an
# MSYS shell launched by a native Windows parent reports ppid 1, and `ps -W`
# lists every native process with ppid 0, so the ancestry walk in
# bin/fm-session-lock-lib.sh cannot reach its own harness. Without a bridge the
# session lock is never taken, and bin/fm-claude-stop-autoarm.sh then exits 0,
# which silently disables the whole watcher and turn-end continuity layer.
#
# This file reports raw process facts only. It never decides what a harness is;
# bin/fm-session-lock-lib.sh remains the single owner of that decision.
# This file is sourced by scripts and has no side effects on source.
#
# Consent, then capability, never uname: every entry point gates on
# fm_winproc_available, which requires the home's FM_WINDOWS=1 opt-in and then
# tests the one file the bridge actually reads. A Linux or macOS home has no
# such file, and a home that has not opted in never asks, so every function here
# returns 1 and callers fall through to their existing path unchanged.
# bin/fm-platform-lib.sh owns the opt-in contract; this file reads FM_WINDOWS
# directly rather than sourcing it, because bin/fm-session-lock-lib.sh sources
# this file alone and must keep working when the platform lib is unreadable.
#
# That probe reads /proc/$$/winpid and not /proc/self/winpid. /proc/self names
# whichever process performs the read, so `$(cat /proc/self/winpid)` reports
# cat's own short-lived pid rather than the shell's, and every lookup built on
# it then misses.
#
# Two independent sources, because they fail differently:
#   ps -W        cheap (~80ms), gives WINPID plus the full Windows image path,
#                but reports ppid 0 for native processes, so it answers
#                "is this pid a live X?" and never "who is its parent?".
#   Win32_Process via PowerShell CIM (~1s) gives real ParentProcessId, so it is
#                the only source that can walk the tree. Memoized per process.
#
# Env overrides, for tests only. They exist so the two evidence sources can be
# driven apart on a host that has neither, which is the only way CI can prove
# that losing one source does not silently lose the verdict:
#   FM_WINPROC_DISABLE=1     force fm_winproc_available to fail on any host.
#   FM_WINPROC_FORCE=1       force fm_winproc_available to succeed on an
#                            opted-in host. It cannot lift the opt-in.
#   FM_WINPROC_SELF          replace this shell's reported Windows pid.
#   FM_WINPROC_PS_CMD        replace `ps -W` with a fixture emitting the same
#                            columns, so source 1 can be supplied or withheld.
#   FM_WINPROC_TABLE_CMD     replace the CIM command with a fixture producing
#                            "<pid> <ppid> <image-path>" lines, so source 2 can
#                            be supplied or withheld.
# DISABLE wins over FORCE, so a test can always prove the inert path, and the
# FM_WINDOWS opt-in wins over both, so no seam can switch the bridge on in a
# home that never asked for it.

# True when this home opted in AND this host exposes the MSYS/Windows pid bridge.
fm_winproc_available() {
  [ "${FM_WINDOWS:-}" = 1 ] || return 1
  [ "${FM_WINPROC_DISABLE:-0}" = 1 ] && return 1
  [ "${FM_WINPROC_FORCE:-0}" = 1 ] && return 0
  [ -r "/proc/$$/winpid" ]
}

# Print the Windows pid of the current shell.
fm_winproc_self() {
  local winpid
  fm_winproc_available || return 1
  if [ -n "${FM_WINPROC_SELF:-}" ]; then
    winpid=$FM_WINPROC_SELF
  else
    read -r winpid < "/proc/$$/winpid" 2>/dev/null || return 1
  fi
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$winpid"
}

_FM_WINPROC_PS_ROWS=
_FM_WINPROC_PS_LOADED=0

# Populate the memoized `ps -W` snapshot once per process, or a test fixture's.
#
# Memoized for the same reason the CIM table below is: it is a snapshot either
# way, so a caller asking twice wants one consistent answer rather than two. It
# is also the difference between one fork and one per lookup, on the platform
# that already pays the highest fork price - measured at 0.6s per call here,
# against a turn-end path that asks three times.
#
# This is a loader rather than a producer on purpose. Emitting the rows and
# piping them into awk would run the producer inside the pipeline's subshell,
# where the assignment that records the snapshot is discarded the moment the
# pipeline ends - so every call would pay full price while looking memoized.
_fm_winproc_ps_load() {
  [ "$_FM_WINPROC_PS_LOADED" = 1 ] && return 0
  _FM_WINPROC_PS_LOADED=1
  if [ -n "${FM_WINPROC_PS_CMD:-}" ]; then
    _FM_WINPROC_PS_ROWS=$(eval "$FM_WINPROC_PS_CMD" 2>/dev/null)
  else
    _FM_WINPROC_PS_ROWS=$(LC_ALL=C ps -W 2>/dev/null)
  fi
  return 0
}

# Print the full Windows image path of live Windows pid $1, or return 1.
#
# The image path is the whole tail of the ps -W row because a Windows path
# contains spaces ("C:\Program Files\..."), so a single positional field would
# truncate it and lose the very component that identifies the harness.
# Rows whose image ps cannot read arrive as "*** unknown ***" and are rejected
# as unidentifiable rather than reported as an image path.
fm_winproc_command() {  # <winpid>
  local winpid=$1 out
  fm_winproc_available || return 1
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  _fm_winproc_ps_load
  out=$(printf '%s
' "$_FM_WINPROC_PS_ROWS" | awk -v w="$winpid" '
    $4 == w {
      line = ""
      for (i = 8; i <= NF; i++) line = (line == "" ? $i : line " " $i)
      if (line != "" && line !~ /^\*\*\* unknown \*\*\*$/) { print line; exit }
    }
  ') || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

_FM_WINPROC_TABLE=
_FM_WINPROC_TABLE_LOADED=0

# Populate the memoized "<pid> <ppid> <image-path>" table once per process.
#
# ProcessId and ParentProcessId come back as UInt32, so both are cast to [int]
# before formatting; without the cast a caller comparing against a bash integer
# string can silently miss. A process whose ExecutablePath is not readable
# still contributes its parent link, so the walk can pass through it.
_fm_winproc_load_table() {
  local cmd out ps_exe
  [ "$_FM_WINPROC_TABLE_LOADED" = 1 ] && return 0
  _FM_WINPROC_TABLE_LOADED=1
  if [ -n "${FM_WINPROC_TABLE_CMD:-}" ]; then
    out=$(eval "$FM_WINPROC_TABLE_CMD" 2>/dev/null) || return 1
    _FM_WINPROC_TABLE=$out
    [ -n "$_FM_WINPROC_TABLE" ]
    return
  fi
  ps_exe=$(command -v pwsh 2>/dev/null) || ps_exe=$(command -v powershell 2>/dev/null) || return 1
  # shellcheck disable=SC2016 # $_ is PowerShell's pipeline variable, so bash must not expand it.
  cmd='Get-CimInstance Win32_Process | ForEach-Object { "{0} {1} {2}" -f [int]$_.ProcessId, [int]$_.ParentProcessId, $_.ExecutablePath }'
  out=$("$ps_exe" -NoProfile -NonInteractive -Command "$cmd" 2>/dev/null) || return 1
  _FM_WINPROC_TABLE=$(printf '%s' "$out" | tr -d '\r')
  [ -n "$_FM_WINPROC_TABLE" ]
}

# Print the Windows parent pid of Windows pid $1, or return 1.
fm_winproc_ppid() {  # <winpid>
  local winpid=$1 ppid
  fm_winproc_available || return 1
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  _fm_winproc_load_table || return 1
  ppid=$(printf '%s\n' "$_FM_WINPROC_TABLE" | awk -v w="$winpid" '$1 == w { print $2; exit }')
  case "$ppid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$ppid"
}

# Drop both memoized snapshots so the next lookup re-reads the live system.
#
# Both loaders memoize for a process lifetime, which is right for a caller
# asking several questions about one moment. A caller that deliberately
# re-observes a process after acting on it wants the opposite, and a stale
# snapshot there would report a pid that has already exited as still live.
# Callers reached through command substitution get a fresh subshell, and so a
# fresh snapshot, for free; this exists for the ones that do not.
fm_winproc_flush() {
  _FM_WINPROC_PS_ROWS=
  _FM_WINPROC_PS_LOADED=0
  _FM_WINPROC_TABLE=
  _FM_WINPROC_TABLE_LOADED=0
}

# Print "<rows-for-pid> <rows-parented-by-pid>" for Windows pid $1.
#
# Both counts come from one snapshot on purpose: taken separately they could
# straddle a process exit and describe two different moments, which is exactly
# the ambiguity a caller proving a process is alone and childless must not
# have. Raw counts, not a verdict - what "alone" and "childless" mean belongs
# to the caller holding the proof contract.
# fm_winproc_process_table: the whole "<pid> <ppid> <command>" table, one row
# per process, for callers that walk process relationships rather than ask about
# one pid. Asking a per-pid accessor once per process would re-read the same
# memoized snapshot N times and still could not see a parent link the walk has
# not reached yet, so the table is its own entry point.
#
# Built from the `ps -W` snapshot rather than the CIM table on purpose. CIM
# speaks only native Windows pids; `ps -W` is a superset that carries MSYS
# processes with their real MSYS pid and parent, native Windows processes
# alongside them, and the WINPID column that maps one space onto the other. A
# walk down from a shell needs parent links in that shell's own pid space, and
# only `ps -W` has them.
#
# Rows whose image ps cannot read keep their parent link and carry an empty
# command, so a walk can still pass through them.
fm_winproc_process_table() {
  fm_winproc_available || return 1
  _fm_winproc_ps_load
  [ -n "$_FM_WINPROC_PS_ROWS" ] || return 1
  printf '%s\n' "$_FM_WINPROC_PS_ROWS" | awk '
    NR == 1 && $1 == "PID" { next }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      line = ""
      for (i = 8; i <= NF; i++) line = (line == "" ? $i : line " " $i)
      if (line ~ /^\*\*\* unknown \*\*\*$/) line = ""
      print $1, $2, line
    }
  '
}

# fm_winproc_pid_cmdline: the argument vector of MSYS pid $1, space-joined.
#
# The image path alone is not enough to identify a harness. A process started
# through a differently named symlink runs the target's image, so every
# Windows-facing source - CIM, `ps`, and `ps -W` alike - reports the resolved
# binary and the name the caller actually invoked is gone. The MSYS procfs is
# the one place that keeps argv, so a process launched as `pi` is still
# recognisable as `pi` rather than as the `sleep` it resolves to.
#
# MSYS pid space, because that is whose procfs this is. Returns 1 for a pid
# with no procfs entry, which is every native Windows process.
fm_winproc_pid_cmdline() {  # <msys-pid>
  local pid=$1 out
  fm_winproc_available || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$pid/cmdline" ] || return 1
  out=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
  out=${out%"${out##*[![:space:]]}"}
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fm_winproc_pid_argv0: argv[0] of MSYS pid $1, read as one procfs field.
#
# Separate from the joined cmdline above because an install path can contain
# spaces ("/Library/Application Support/..."), and a caller that splits the
# joined string on whitespace to recover argv[0] gets a fragment. The NUL
# delimiter is the only place the boundary actually survives.
fm_winproc_pid_argv0() {  # <msys-pid>
  local pid=$1 out
  fm_winproc_available || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$pid/cmdline" ] || return 1
  out=$(cut -z -d '' -f 1 < "/proc/$pid/cmdline" 2>/dev/null | tr -d '\0') || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fm_winproc_local_pid: the MSYS pid for a pid named in either space, so a
# caller holding a pid from a Windows-facing source can walk the MSYS process
# tree with it.
#
# Herdr reports a pane's shell in native Windows pid space, while the processes
# firstmate itself starts are MSYS ones. The WINPID column is the only reliable
# bridge; a bare integer does not say which space it belongs to. An input that
# is already an MSYS pid is returned unchanged, which is checked FIRST so a
# WINPID that happens to collide with a live MSYS pid can never rewrite it.
fm_winproc_local_pid() {  # <pid>
  local pid=$1 out
  fm_winproc_available || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  _fm_winproc_ps_load
  [ -n "$_FM_WINPROC_PS_ROWS" ] || return 1
  out=$(printf '%s\n' "$_FM_WINPROC_PS_ROWS" | awk -v p="$pid" '
    $1 == p { print $1; found = 1; exit }
    $4 == p { winmatch = $1 }
    END { if (!found && winmatch != "") print winmatch }
  ')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_winproc_pid_census() {  # <winpid>
  local winpid=$1
  fm_winproc_available || return 1
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  _fm_winproc_load_table || return 1
  printf '%s\n' "$_FM_WINPROC_TABLE" | awk -v w="$winpid" '
    $1 == w { self++ }
    $2 == w { kids++ }
    END { print self + 0, kids + 0 }
  '
}

# Print the Windows image path recorded for Windows pid $1 by the CIM table.
#
# This is the tree-walk counterpart to fm_winproc_command: the ps -W source
# cannot describe an ancestor, because it has no parent links at all.
fm_winproc_table_command() {  # <winpid>
  local winpid=$1 out
  fm_winproc_available || return 1
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  _fm_winproc_load_table || return 1
  out=$(printf '%s\n' "$_FM_WINPROC_TABLE" | awk -v w="$winpid" '
    $1 == w {
      line = ""
      for (i = 3; i <= NF; i++) line = (line == "" ? $i : line " " $i)
      print line
      exit
    }
  ')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
