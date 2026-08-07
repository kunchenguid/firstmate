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
# Git for Windows bundles a Cygwin `ps` with no `-o` support at all (only
# -aefls/-p/-u/-W), and Cygwin/MSYS2 both report a process's parent as the
# synthetic orphan pid 1 the moment that parent was never spawned through
# their own pid database - which is exactly what happens when a native
# Windows harness such as claude.exe launches a Cygwin bash.exe. The identity
# and ancestry functions below read /proc as a same-host fallback for the
# first problem and fall through to the real Windows process table (via
# powershell.exe) for the second; every fallback triggers only after the
# platform-generic path already failed, so Linux and macOS behavior is
# unchanged.

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
  return 1
}

# Print the real Windows pid backing Cygwin/MSYS2 pid $1, or return 1 when this
# host has no such mapping (native Linux/macOS, or the pid is gone). Both
# emulators expose /proc/<pid>/winpid; native Linux and macOS do not, which is
# what keeps this fallback confined to the platforms that actually need it.
fm_harness_native_winpid() {  # <pid>
  local wp
  wp=$(cat "/proc/$1/winpid" 2>/dev/null) || return 1
  [ -n "$wp" ] || return 1
  printf '%s\n' "$wp"
}

# Print "<winpid>\t<name>\t<commandline>" for Windows pid $1 and every real
# ancestor above it (up to 16 hops), or return 1 when powershell.exe is
# unavailable. CommandLine has embedded whitespace (including any literal
# newline) collapsed to single spaces so each process is exactly one line.
#
# This exists only for the Cygwin/MSYS2 boundary: their own ancestry tracking
# stops at the synthetic orphan pid 1 the moment the real parent was never
# spawned through their pid database (see the file header). Win32_Process is
# the interface that can still read that real ancestry, so one PowerShell call
# walks the whole remaining chain instead of one call per hop.
fm_harness_windows_ancestry_rows() {  # <start-winpid>
  local start=$1
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  command -v powershell.exe >/dev/null 2>&1 || return 1
  powershell.exe -NoProfile -NonInteractive -Command "
    \$wp = $start
    for (\$i = 0; \$i -lt 16; \$i++) {
      \$p = Get-CimInstance Win32_Process -Filter \"ProcessId=\$wp\" -ErrorAction SilentlyContinue
      if (-not \$p) { break }
      \$cmd = (\$p.CommandLine -replace '\s+', ' ')
      \"\$(\$p.ProcessId)\`t\$(\$p.Name)\`t\$cmd\"
      \$wp = \$p.ParentProcessId
      if (-not \$wp -or \$wp -eq 0) { break }
    }
  " 2>/dev/null
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
# `ps -o` is tried first on every pid, unchanged from every other platform;
# /proc is read only when that produced nothing (Cygwin's `ps`, see the file
# header). If the walk still reaches the top with no match at all, and the last
# pid it could read has a real Windows pid behind it, the walk continues into
# the real Windows ancestry above the synthetic boundary.
fm_harness_ancestry_pids() {
  local pid=$$ comm args ppid extending=0 printed=0 prev_pid=$$ last_winpid wpid wcomm wargs
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$comm" ] && [ -r "/proc/$pid/exename" ]; then
      comm=$(cat "/proc/$pid/exename" 2>/dev/null)
      args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
      args=${args% }
      ppid=$(cat "/proc/$pid/ppid" 2>/dev/null | tr -d '[:space:]')
      [ -n "$ppid" ] || ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)
    fi
    [ -n "$comm" ] || break

    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi

    prev_pid=$pid
    case "$ppid" in
      ''|*[!0-9]*) break ;;
    esac
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
  done

  if [ "$printed" -eq 0 ] && last_winpid=$(fm_harness_native_winpid "$prev_pid"); then
    while IFS=$'\t' read -r wpid wcomm wargs; do
      [ -n "$wpid" ] || continue
      wcomm="${wcomm//\\//}"
      wcomm="${wcomm%.exe}"
      wargs="${wargs//\\//}"
      if fm_harness_process_matches "$wcomm" "$wargs"; then
        printf '%s\n' "$wpid"
        printed=1
        [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
        extending=1
      elif [ "$extending" -eq 1 ]; then
        break
      fi
    done < <(fm_harness_windows_ancestry_rows "$last_winpid")
  fi

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

# True if Windows pid $1 is alive and looks like a verified harness, read from
# the real Windows process table. Companion to fm_harness_windows_ancestry_rows:
# a pid that fm_harness_ancestry_pid recorded from that fallback is a real
# Windows pid outside Cygwin/MSYS2's own pid database, so `kill -0` can never
# see it even while the process is alive.
fm_harness_winpid_alive() {  # <winpid>
  local pid=$1 line comm args
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  command -v powershell.exe >/dev/null 2>&1 || return 1
  line=$(powershell.exe -NoProfile -NonInteractive -Command "
    \$p = Get-CimInstance Win32_Process -Filter \"ProcessId=$pid\" -ErrorAction SilentlyContinue
    if (\$p) {
      \$cmd = (\$p.CommandLine -replace '\s+', ' ')
      \"\$(\$p.Name)\`t\$cmd\"
    }
  " 2>/dev/null)
  [ -n "$line" ] || return 1
  IFS=$'\t' read -r comm args <<EOF
$line
EOF
  comm="${comm//\\//}"
  comm="${comm%.exe}"
  args="${args//\\//}"
  fm_harness_process_matches "$comm" "$args"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  if kill -0 "$pid" 2>/dev/null; then
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if [ -z "$comm" ] && [ -r "/proc/$pid/exename" ]; then
      comm=$(cat "/proc/$pid/exename" 2>/dev/null)
      args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
      args=${args% }
    fi
    [ -n "$comm" ] || return 1
    fm_harness_process_matches "$comm" "$args"
    return
  fi
  fm_harness_winpid_alive "$pid"
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
