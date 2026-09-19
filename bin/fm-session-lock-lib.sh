#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
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
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
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
#
# When this POSIX walk finds no harness at all, fm_harness_ancestry_pids_windows
# below is tried as an MSYS/Windows-native fallback; see its own header for when
# and why.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ] && return 0
  fm_harness_ancestry_pids_windows
}

# True when Windows process name $1 (e.g. "claude.exe") is a verified harness
# executable. Windows-native counterpart of fm_harness_process_matches, used
# only by the winpid fallback below: FM_HARNESS_NAMES already carries each
# harness's exact executable basename, so exact case-insensitive matching
# against the name minus its .exe suffix is enough - Win32_Process exposes no
# path or argv0 to widen the POSIX walk's extra evidence with, and none is
# needed for the smallest fallback this exists to cover.
FM_HARNESS_IS_CLAUDE_WIN=0
fm_harness_windows_name_matches() {  # <windows process name, e.g. claude.exe>
  local raw=$1 base name
  base=$(printf '%s' "${raw%.[eE][xX][eE]}" | tr '[:upper:]' '[:lower:]')
  FM_HARNESS_IS_CLAUDE_WIN=0
  for name in "${FM_HARNESS_NAMES[@]}"; do
    if [ "$base" = "$name" ]; then
      [ "$name" = claude ] && FM_HARNESS_IS_CLAUDE_WIN=1
      return 0
    fi
  done
  return 1
}

# Windows-native ancestry fallback for fm_harness_ancestry_pids, tried only when
# the POSIX `ps` walk above finds no harness at all.
#
# MSYS/Git Bash's `ps` only reports processes visible through its own emulated
# process table, so a harness that launched the current shell as a native
# Windows process (not a Git-Bash/MSYS one) is invisible to that walk.
#
# Windows' own Win32_Process.ParentProcessId cannot be trusted to climb out of
# MSYS, though: MSYS's fork() emulation does not give the child a live,
# resolvable ParentProcessId on the Windows side - the value Windows records is
# a transient fork-emulation process that Win32_Process no longer lists by the
# time it is queried, even though the real logical parent shell is still very
# much alive (confirmed by comparing MSYS's own $PPID, translated through its
# own /proc/<ppid>/winpid, against Win32_Process's reported ParentProcessId for
# the same child: they are different PIDs, and only the MSYS-derived one is
# still live). So this climbs MSYS's own /proc/<pid>/ppid bookkeeping first -
# the platform that actually owns that part of the process graph - purely
# inside MSYS's logical ancestry, until it runs out of readable /proc entries
# (a real MSYS root has no /proc/1, so every chain currently ends there).
# /proc/<pid>/winpid is read at every hop only to remember the last real
# Windows PID reachable that way, never to walk native ancestry itself, so the
# topmost MSYS-visible process's own winpid is the exact point to cross into
# the native tree from. Only from that crossing point is the native Windows
# process tree - never visible to `ps` or to MSYS's /proc at all - fetched
# with one Get-CimInstance Win32_Process query and walked in memory using the
# same contiguous-harness rule as the POSIX walk: climb until the first match,
# keep climbing only through a further run of matches, stop at the first gap
# right after one.
fm_harness_ancestry_pids_windows() {
  local proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} \
    pid=${FM_MSYS_PID_OVERRIDE:-$$} winpid='' wp table line ppid name \
    extending=0 printed=0

  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    wp=$(cat "$proc_root/$pid/winpid" 2>/dev/null) || break
    case "$wp" in '' | *[!0-9]*) break ;; esac
    winpid=$wp
    ppid=$(cat "$proc_root/$pid/ppid" 2>/dev/null) || break
    case "$ppid" in '' | *[!0-9]*) break ;; esac
    [ "$ppid" = "$pid" ] && break
    pid=$ppid
  done
  [ -n "$winpid" ] || return 1

  table=$(powershell.exe -NoProfile -NonInteractive -Command \
    'Get-CimInstance Win32_Process | ForEach-Object { "{0},{1},{2}" -f $_.ProcessId,$_.ParentProcessId,$_.Name }' \
    2>/dev/null) || return 1
  table=$(printf '%s' "$table" | tr -d '\r')
  [ -n "$table" ] || return 1

  pid=$winpid
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    line=$(printf '%s\n' "$table" | grep "^${pid}," | head -n1)
    [ -n "$line" ] || break
    ppid=${line#*,}; ppid=${ppid%%,*}
    name=${line##*,}
    if fm_harness_windows_name_matches "$name"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE_WIN" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    case "$ppid" in '' | *[!0-9]*) break ;; esac
    [ "$ppid" = "$pid" ] && break
    pid=$ppid
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
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
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
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# True when state dir $1 records a live verified harness outside this process's
# contiguous harness ancestry. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a
# diagnostic caller. Malformed, missing, dead, and ancestry-uncertain locks are
# not foreign-owner evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 1
  done <<EOF
$pids
EOF
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}
