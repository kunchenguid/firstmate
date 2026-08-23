#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# Harness identity is pure logic and lives at the top. How a process is read at
# all is a platform question, and its single owner is the "platform process
# access" section below.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
#
# The name is published in FM_HARNESS_PATH_NAME as well as printed, so the
# ancestry walk can read it without a command substitution. A fork per hop is
# invisible on Linux and dominates the whole answer under MSYS, where process
# creation is emulated.
FM_HARNESS_PATH_NAME=
fm_harness_path_name() {  # <path>
  local path=$1 name
  FM_HARNESS_PATH_NAME=
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) FM_HARNESS_PATH_NAME=$name; printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
#
# Every test here is a shell builtin. The walk asks this question once per hop
# on every turn end, and the basename, grep and command-substitution forks it
# used to spend were free on Linux but cost roughly a tenth of a second each
# under MSYS's emulated process creation - enough to dominate the answer.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0
  FM_HARNESS_IS_CLAUDE=0
  base=${comm##*/}
  if [[ $base =~ $FM_HARNESS_RE ]]; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if fm_harness_path_name "$comm" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
    case "$FM_HARNESS_PATH_NAME" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if [[ $args =~ $FM_HARNESS_RE ]]; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}


# --- platform process access -------------------------------------------------
#
# ONE owner of the questions the ancestry walk and the liveness predicate ask
# about a process: its command, its arguments, its parent, and whether it still
# exists. Everything above this point is pure identity logic and stays platform
# independent; everything below it asks the platform.
#
# POSIX answers with ps and kill. Windows can answer neither way. Under Git
# Bash, MSYS2, and Cygwin the emulation layer tracks parentage only between its
# own processes, so a shell spawned by a native Windows parent - which is every
# tool shell a harness starts - reports PPid 1, and the walk ends before it can
# reach the harness. The bundled ps has no -o at all. The Windows branch
# therefore ignores the emulated view and walks the real Win32 process tree by
# WINPID, the only pid namespace a native harness process exists in. Every pid
# this file reports on Windows is a WINPID, including the one written to
# state/.lock, because a native harness has no other identity to record.
#
# A Windows lookup costs a PowerShell start, so the table is read once per shell
# and reused. fm_session_lock_owned_by_self primes it in the caller's own shell
# before forking, so the subshell it uses for the walk inherits the table and
# one lock decision costs one read.
#
# FM_PROC_PLATFORM_OVERRIDE and FM_PROC_SELF_PID_OVERRIDE are test seams so the
# portable regression can drive either branch from either host. Nothing in bin/
# sets them.

FM_PROC_IS_WINDOWS=
fm_proc_is_windows() {
  if [ -z "$FM_PROC_IS_WINDOWS" ]; then
    case "${FM_PROC_PLATFORM_OVERRIDE:-$(uname -s 2>/dev/null)}" in
      windows|MINGW*|MSYS*|CYGWIN*) FM_PROC_IS_WINDOWS=0 ;;
      *) FM_PROC_IS_WINDOWS=1 ;;
    esac
  fi
  return "$FM_PROC_IS_WINDOWS"
}

# The Win32 process table as pid<TAB>ppid<TAB>start<TAB>exe<TAB>command-line.
#
# The start time is carried because a Windows ParentProcessId is only the pid
# recorded when the child was created: once that parent exits, Windows may hand
# its number to an unrelated process, and a walk that trusted the number alone
# could climb into a stranger and hand this home's lock to the wrong session. A
# real parent always starts no later than its child, so the walk refuses any hop
# that violates that ordering.
# shellcheck disable=SC2016 # single quotes are required: every $ below is PowerShell's, not the shell's
FM_WIN_PROC_QUERY='$ErrorActionPreference="Stop";$t=[char]9;Get-CimInstance -Query "SELECT ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine,CreationDate FROM Win32_Process"|ForEach-Object{$e=$_.ExecutablePath;if([string]::IsNullOrEmpty($e)){$e=$_.Name};$c=$_.CommandLine;if($null -eq $c){$c=""};$k=0;if($null -ne $_.CreationDate){$k=$_.CreationDate.Ticks};[string]$_.ProcessId+$t+[string]$_.ParentProcessId+$t+[string]$k+$t+($e -replace "[\t\r\n]"," ")+$t+($c -replace "[\t\r\n]"," ")}'

# The table is indexed by pid into an associative array at load time, so a walk
# costs one PowerShell start and no process at all per hop. That matters because
# a Claude Stop hook asks this question at every turn end, and MSYS process
# creation is expensive enough that a fork per hop would dominate the answer.
declare -A FM_WIN_PROC_ROW=()
FM_WIN_PROC_TABLE_STATE=

# Windows parentage is not enough on its own, because MSYS has no execve: it
# implements exec by starting a fresh Windows process and ending the old one.
# Every MSYS process launched from a shell therefore records a Windows parent
# that is already dead by the time anyone asks - a session-start script would
# see its own chain end one hop up, one hop short of everything.
#
# MSYS does track its own processes correctly, so this index maps each MSYS
# process's WINPID to its MSYS parent's WINPID, and fm_proc_read prefers that
# link when it has one. The walk then crosses the emulation boundary without
# knowing it exists: inside MSYS the parent comes from here, and at the
# outermost MSYS process - the one a native harness actually started - there is
# no entry and the real Windows parent takes over.
#
# FM_PROC_MSYS_PROC_ROOT is a test seam, like the two overrides above: it lets
# the portable regression build this boundary out of ordinary files and prove
# the bridge is load-bearing from a host that has no MSYS at all. Nothing in
# bin/ sets it, and on a real host the emulation's own /proc is the only source.
declare -A FM_MSYS_PARENT_WINPID=()
fm_msys_parent_index_load() {
  local root=${FM_PROC_MSYS_PROC_ROOT:-/proc} dir winpid parent parent_winpid
  FM_MSYS_PARENT_WINPID=()
  for dir in "$root"/[0-9]*; do
    [ -d "$dir" ] || continue
    read -r winpid < "$dir/winpid" 2>/dev/null || continue
    read -r parent < "$dir/ppid" 2>/dev/null || continue
    case "$winpid" in ''|*[!0-9]*) continue ;; esac
    case "$parent" in ''|*[!0-9]*) continue ;; esac
    # PPid 1 is MSYS's own root: that process was started by something native,
    # which is exactly the hop the Windows table answers correctly.
    [ "$parent" -gt 1 ] || continue
    read -r parent_winpid < "$root/$parent/winpid" 2>/dev/null || continue
    case "$parent_winpid" in ''|*[!0-9]*) continue ;; esac
    FM_MSYS_PARENT_WINPID[$winpid]=$parent_winpid
  done
}

fm_win_proc_table_load() {
  case "$FM_WIN_PROC_TABLE_STATE" in
    ok) return 0 ;;
    failed) return 1 ;;
  esac
  local exe line pid
  exe=$(command -v powershell.exe 2>/dev/null || command -v pwsh.exe 2>/dev/null || true)
  if [ -z "$exe" ]; then
    FM_WIN_PROC_TABLE_STATE=failed
    echo "fm-session-lock: no powershell.exe or pwsh.exe on PATH; the Windows process tree cannot be read, so this session cannot prove it owns the fleet lock" >&2
    return 1
  fi
  FM_WIN_PROC_ROW=()
  # Read the rows straight off the pipe. Capturing them into a variable first
  # and feeding the loop a here-document costs a temporary file per load, and
  # the whole point of indexing once is that the load is the only slow step.
  # The row count below is what proves the query actually produced a table, so
  # nothing is lost by not inspecting the capture.
  while IFS= read -r line; do
    pid=${line%%$'\t'*}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    FM_WIN_PROC_ROW[$pid]=${line#*$'\t'}
  done < <("$exe" -NoProfile -NonInteractive -Command "$FM_WIN_PROC_QUERY" 2>/dev/null | tr -d '\r')
  if [ "${#FM_WIN_PROC_ROW[@]}" -eq 0 ]; then
    FM_WIN_PROC_TABLE_STATE=failed
    echo "fm-session-lock: the Win32 process table from $exe held no readable rows; this session cannot prove it owns the fleet lock" >&2
    return 1
  fi
  fm_msys_parent_index_load
  FM_WIN_PROC_TABLE_STATE=ok
  return 0
}

# fm_proc_read <pid>: publish FM_PROC_COMM, FM_PROC_ARGS, FM_PROC_PPID and
# FM_PROC_START for <pid>, or return 1 when the process cannot be read.
# FM_PROC_START is empty on POSIX, which carries no start time here.
#
# The Windows branch reports the executable path as the command, with separators
# normalized to forward slashes, so the whole-path-component evidence in
# fm_harness_path_name keeps meaning what it means everywhere else: a
# backslash path has no components to match, and every ordinary firstmate script
# path would collapse into one basename that spuriously contains a harness name.
FM_PROC_COMM=
FM_PROC_ARGS=
FM_PROC_PPID=
FM_PROC_START=
fm_proc_read() {  # <pid>
  local pid=$1 rest
  FM_PROC_COMM=
  FM_PROC_ARGS=
  FM_PROC_PPID=
  FM_PROC_START=
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_proc_is_windows; then
    fm_win_proc_table_load || return 1
    rest=${FM_WIN_PROC_ROW[$pid]-}
    [ -n "$rest" ] || return 1
    # Split in the shell, without forking: the command line is the only field
    # that may contain anything at all, and it is last, so it is whatever
    # remains after the three fixed fields have been taken off the front.
    FM_PROC_PPID=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    FM_PROC_START=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    FM_PROC_COMM=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    FM_PROC_COMM=${FM_PROC_COMM//\\//}
    FM_PROC_ARGS=$rest
    # An MSYS process knows its real parent; the Windows table only remembers
    # the one that exec replaced. Prefer the link that is still true.
    if [ -n "${FM_MSYS_PARENT_WINPID[$pid]-}" ]; then
      FM_PROC_PPID=${FM_MSYS_PARENT_WINPID[$pid]}
    fi
    return 0
  fi
  FM_PROC_COMM=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  FM_PROC_ARGS=$(ps -o args= -p "$pid" 2>/dev/null)
  FM_PROC_PPID=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  return 0
}

# True unless the platform can prove the hop impossible, because a real parent
# starts no later than its child. Only Windows carries a start time, so this is
# where a recycled ParentProcessId is caught; POSIX stands aside.
fm_proc_parent_ordered() {  # <parent-pid> <child-start>
  local parent=$1 child=$2 parent_start
  [ -n "$child" ] && [ "$child" != 0 ] || return 0
  fm_proc_read "$parent" || return 1
  parent_start=$FM_PROC_START
  [ -n "$parent_start" ] && [ "$parent_start" != 0 ] || return 0
  [ "$parent_start" -le "$child" ]
}

# The pid the ancestry walk starts from, in the namespace fm_proc_read answers
# in. A Windows shell must translate its emulated pid to its WINPID, and a
# translation that cannot be read fails closed rather than walking a pid that
# means something else entirely. Published in FM_PROC_SELF_PID as well as
# printed, so the walk need not fork to ask.
FM_PROC_SELF_PID=
fm_proc_self_pid() {
  local winpid
  FM_PROC_SELF_PID=
  if [ -n "${FM_PROC_SELF_PID_OVERRIDE:-}" ]; then
    FM_PROC_SELF_PID=$FM_PROC_SELF_PID_OVERRIDE
    printf '%s\n' "$FM_PROC_SELF_PID"
    return 0
  fi
  if fm_proc_is_windows; then
    read -r winpid < "/proc/$$/winpid" 2>/dev/null || return 1
    case "$winpid" in ''|*[!0-9]*) return 1 ;; esac
    FM_PROC_SELF_PID=$winpid
    printf '%s\n' "$winpid"
    return 0
  fi
  FM_PROC_SELF_PID=$$
  printf '%s\n' "$$"
}

# Load the platform's process table into THIS shell, so a caller that asks its
# question across a subshell pays for it once. A no-op wherever reads are cheap.
fm_proc_prime() {
  fm_proc_is_windows || return 0
  fm_win_proc_table_load
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid parent child_start extending=0 printed=0
  fm_proc_self_pid >/dev/null || return 1
  pid=$FM_PROC_SELF_PID
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    fm_proc_read "$pid" || break
    if fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    parent=$FM_PROC_PPID
    child_start=$FM_PROC_START
    [ -n "$parent" ] && [ "$parent" -gt 1 ] || break
    fm_proc_parent_ordered "$parent" "$child_start" || break
    pid=$parent
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1
  # kill -0 answers existence in the pid namespace ps reports in. On Windows
  # that namespace is not the one the lock records, so presence in the Win32
  # table is the existence proof there.
  if ! fm_proc_is_windows; then
    kill -0 "$pid" 2>/dev/null || return 1
  fi
  fm_proc_read "$pid" || return 1
  fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Prime here, in the caller's own shell, so the walk's subshell inherits the
  # platform's process table instead of paying for its own copy.
  fm_proc_prime || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
