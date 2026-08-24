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

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Resolved once at source time, mirroring bin/fm-wake-lib.sh: process identity
# runs in hot hook paths and forking uname per call is a measurable cost on the
# platform (Git Bash/MSYS) that already pays the highest fork price. The
# override exists so the platform-specific branches below are testable from any
# host, exactly like FM_PROC_ROOT_OVERRIDE.
_FM_SLOCK_UNAME=${FM_SLOCK_UNAME_OVERRIDE:-$(uname -s 2>/dev/null || echo unknown)}

# True on a Windows bash host (Git Bash/MSYS/Cygwin), where the bundled ps
# rejects -o entirely and only sees MSYS-side processes: the harness itself is
# a NATIVE Windows process (for example claude.exe run from npm), invisible to
# that ps, so the POSIX ancestry walk below can never find it. The Windows
# branches read the native process tree through PowerShell CIM instead.
fm_slock_windows() {
  case "$_FM_SLOCK_UNAME" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print "pid<TAB>name<TAB>command line" for native Windows process $1 and each
# of its native ancestors, innermost first, up to 16 hops, using ONE PowerShell
# child so the walk pays a single interpreter startup. MSYS processes are real
# Windows processes too, so this one native walk covers the whole chain with
# correct Windows parent pids - unlike the MSYS ps view, whose ppid says 1 the
# moment the parent is native. Any failure prints nothing and the callers fail
# closed.
fm_win_ancestry_lines() {  # <start-winpid>
  local start=$1 ps_bin
  case "$start" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ps_bin=$(command -v powershell.exe 2>/dev/null) || ps_bin=$(command -v pwsh 2>/dev/null) || return 1
  # shellcheck disable=SC2016 # the single-quoted $ names are PowerShell variables, not shell expansions
  "$ps_bin" -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "SilentlyContinue"
    $cur = [int]"'"$start"'"
    $seen = @{}
    for ($i = 0; $i -lt 16 -and $cur -gt 0 -and -not $seen.ContainsKey($cur); $i++) {
      $seen[$cur] = $true
      $p = Get-CimInstance Win32_Process -Filter "ProcessId = $cur"
      if (-not $p) { break }
      Write-Output ("{0}`t{1}`t{2}" -f $p.ProcessId, $p.Name, $p.CommandLine)
      $cur = [int]$p.ParentProcessId
    }' 2>/dev/null | tr -d '\r'
}

# Print "name<TAB>command line" for native Windows process $1, or return 1 when
# no such process exists. A returned row is the liveness proof itself.
fm_win_process_line() {  # <winpid>
  local pid=$1 ps_bin out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ps_bin=$(command -v powershell.exe 2>/dev/null) || ps_bin=$(command -v pwsh 2>/dev/null) || return 1
  # shellcheck disable=SC2016 # the single-quoted $ names are PowerShell variables, not shell expansions
  out=$("$ps_bin" -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "SilentlyContinue"
    $p = Get-CimInstance Win32_Process -Filter "ProcessId = '"$pid"'"
    if ($p) { Write-Output ("{0}`t{1}" -f $p.Name, $p.CommandLine) }' 2>/dev/null | tr -d '\r')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

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
# The Windows shape of the same walk, in two segments that meet at the MSYS
# root. The MSYS segment is climbed through the emulated /proc, because MSYS
# fork emulation routinely leaves a DEAD native parent above any script-invoked
# child (the fork copy's Windows process exits when the child execs), so a
# purely native ppid walk from a nested shell dead-ends below the harness. The
# MSYS pid chain survives that emulation intact. The native segment then starts
# from the MSYS root's Windows pid - that root was spawned natively by the
# harness itself, so its native parent chain is whole - and is fetched in one
# PowerShell call. Both segments feed the identical first-match/contiguity/
# Claude-extends decision, with reported pids always NATIVE Windows pids so the
# written lock is checkable from any later process. Backslashes in native
# command lines are normalized to slashes only for matching, so the
# path-component evidence works on Windows install paths.
fm_win_harness_ancestry_pids() {
  local proc_root pid winpid root_winpid='' ppid exe args lines line name cmdline
  local extending=0 printed=0 run_ended=0 hops=0
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  pid=$$
  while [ "$hops" -lt 16 ]; do
    hops=$((hops + 1))
    winpid=$(cat "$proc_root/$pid/winpid" 2>/dev/null | tr -d '[:space:]')
    case "$winpid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    root_winpid=$winpid
    exe=$(cat "$proc_root/$pid/exename" 2>/dev/null || true)
    args=$(tr '\0' ' ' < "$proc_root/$pid/cmdline" 2>/dev/null || true)
    if fm_harness_process_matches "$exe" "$args"; then
      printf '%s\n' "$winpid"
      printed=1
      if [ "$FM_HARNESS_IS_CLAUDE" -ne 1 ]; then
        run_ended=1
        break
      fi
      extending=1
    elif [ "$extending" -eq 1 ]; then
      run_ended=1
      break
    fi
    ppid=$(cat "$proc_root/$pid/ppid" 2>/dev/null | tr -d '[:space:]')
    case "$ppid" in
      ''|*[!0-9]*) break ;;
    esac
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
  done
  if [ "$run_ended" -eq 0 ]; then
    lines=$(fm_win_ancestry_lines "$root_winpid") || lines=''
    while IFS=$'\t' read -r line name cmdline; do
      case "$line" in
        ''|*[!0-9]*) continue ;;
      esac
      # The MSYS root itself was already judged from its /proc evidence.
      [ "$line" = "$root_winpid" ] && continue
      if fm_harness_process_matches "$name" "${cmdline//\\//}"; then
        printf '%s\n' "$line"
        printed=1
        [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
        extending=1
      elif [ "$extending" -eq 1 ]; then
        break
      fi
    done <<EOF
$lines
EOF
  fi
  [ "$printed" -eq 1 ]
}

fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  if fm_slock_windows; then
    fm_win_harness_ancestry_pids
    return
  fi
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
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
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
  local pid=$1 comm args line
  if fm_slock_windows; then
    # The lock holds a NATIVE Windows pid, which MSYS kill and ps cannot see;
    # one CIM row is both the liveness proof and the identity evidence.
    line=$(fm_win_process_line "$pid") || return 1
    comm=${line%%$'\t'*}
    args=${line#*$'\t'}
    fm_harness_process_matches "$comm" "${args//\\//}"
    return
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
