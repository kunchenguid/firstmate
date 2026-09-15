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

# Git Bash/MSYS/Cygwin's own `ps` only sees the POSIX-emulation process tree it
# manages itself. A harness that launched this shell as an ordinary Windows
# child process (for example Claude Code's own host process running bash.exe as
# a tool) sits outside that tree entirely, and `ps` reports a synthetic ppid of
# 1 the moment the walk below would need to cross that boundary - so it can
# never find the harness on this platform, no matter how many hops it is given.
# Ask Windows directly instead, keyed from this shell's own real Windows pid
# (exposed at /proc/<pid>/winpid under MSYS and Cygwin).
fm_windows_env() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print this shell's own real Windows pid, or return 1.
fm_windows_own_pid() {
  local pid
  if [ -r "/proc/$$/winpid" ]; then
    pid=$(cat "/proc/$$/winpid" 2>/dev/null) || pid=
    case "$pid" in [0-9]*) printf '%s' "$pid"; return 0 ;; esac
  fi
  pid=$(ps -p "$$" -o winpid= 2>/dev/null | tr -d '[:space:]') || return 1
  case "$pid" in [0-9]*) printf '%s' "$pid"; return 0 ;; esac
  return 1
}

# Print "<pid>\t<name>\t<commandline>" for real Windows pids from $1 up through
# its parents (16 hops), one per line, innermost first - the same shape
# fm_harness_ancestry_pids walks below, sourced from Win32_Process instead of
# `ps` so it sees the real ancestry regardless of the POSIX/Windows boundary.
# One powershell.exe per call, the whole chain in one round trip.
fm_windows_ancestry_rows() {  # <starting real windows pid>
  local start=$1
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  command -v powershell.exe >/dev/null 2>&1 || return 1
  powershell.exe -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "SilentlyContinue"
    # $fmPid, never $pid: PowerShell reserves $PID (case-insensitive) as a
    # read-only automatic variable naming THIS powershell.exe process, so
    # assigning to $pid silently fails under SilentlyContinue and the walk
    # would just keep re-querying its own process instead of climbing.
    $fmPid = '"$start"'
    for ($i = 0; $i -lt 16; $i++) {
      $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $fmPid)
      if (-not $p) { break }
      Write-Output ("$($p.ProcessId)`t$($p.Name)`t$($p.CommandLine)")
      if (-not $p.ParentProcessId -or $p.ParentProcessId -eq $fmPid) { break }
      $fmPid = $p.ParentProcessId
    }
  ' 2>/dev/null
}

# Windows counterpart of the ancestry walk below: same contiguous-run and
# Claude-extends contract, fed by fm_windows_ancestry_rows instead of `ps`.
# Win32_Process names carry a trailing .exe that the shared classifier's exact
# harness-name patterns (^pi$, ^omp$, ...) do not expect, so it is stripped
# before matching.
fm_harness_ancestry_pids_windows() {
  local start rows pid comm args extending=0 printed=0
  start=$(fm_windows_own_pid) || return 1
  rows=$(fm_windows_ancestry_rows "$start") || return 1
  [ -n "$rows" ] || return 1
  while IFS=$'\t' read -r pid comm args; do
    [ -n "$pid" ] || continue
    comm=${comm%.[Ee][Xx][Ee]}
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
  done <<EOF
$rows
EOF
  [ "$printed" -eq 1 ]
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
# On Windows (MSYS/Git Bash/Cygwin) this defers to the Win32_Process-based walk
# above, which alone can see across the POSIX/Windows process boundary; it
# falls back to the `ps`-based walk below only if that native path itself could
# not run (own pid unreadable, or no powershell.exe on PATH), never merely
# because it found no harness match.
fm_harness_ancestry_pids() {
  if fm_windows_env; then
    fm_harness_ancestry_pids_windows && return 0
    fm_windows_own_pid >/dev/null 2>&1 && command -v powershell.exe >/dev/null 2>&1 && return 1
  fi
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
#
# On Windows a lock pid is a real Windows pid (see fm_harness_ancestry_pids
# above), which `kill -0`/`ps -p` cannot resolve - MSYS/Cygwin only recognizes
# pids in its own POSIX-emulation numbering, never arbitrary Windows pids - so
# this asks Win32_Process directly instead.
fm_harness_pid_alive() {
  local pid=$1 comm args row
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_windows_env; then
    command -v powershell.exe >/dev/null 2>&1 || return 1
    row=$(powershell.exe -NoProfile -NonInteractive -Command '
      $ErrorActionPreference = "SilentlyContinue"
      $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + '"$pid"')
      if ($p) { Write-Output ("$($p.Name)`t$($p.CommandLine)") }
    ' 2>/dev/null) || return 1
    [ -n "$row" ] || return 1
    IFS=$'\t' read -r comm args <<EOF
$row
EOF
    comm=${comm%.[Ee][Xx][Ee]}
    fm_harness_process_matches "$comm" "$args"
    return $?
  fi
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
