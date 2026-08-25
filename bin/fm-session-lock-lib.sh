#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

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
  # Builtin parameter expansion and [[ =~ ]] (the same ERE class grep -E
  # used) instead of basename/grep subprocesses: this runs once per ancestry
  # hop, and on Windows MSYS every fork costs ~100ms.
  base=${comm##*/}
  if [[ $base =~ $FM_HARNESS_RE ]]; then
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
      if [[ $args =~ $FM_HARNESS_RE ]]; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# --- Windows (Git Bash/MSYS) native-process support --------------------------
# On Windows the harness is a NATIVE process (claude.exe under a terminal),
# and MSYS tooling cannot reach it: MSYS ps lists only MSYS processes (a
# native parent reads as ppid 1), supports no -o fields, and ps -W reports no
# usable parent pid for native rows. ParentProcessId is only exposed through
# WMI/CIM, and the only shipped CLI for that is PowerShell (wmic is gone from
# Windows 11; tasklist has no parent field). So on Windows the walk translates
# the MSYS self pid to its native pid via /proc/<pid>/winpid and reads the
# parent chain from ONE batched PowerShell CIM snapshot; the harness-matching
# policy stays in this file, PowerShell only supplies raw (pid, name,
# command-line) rows. Every pid recorded, printed, or checked on Windows is a
# NATIVE pid: stable for the harness's lifetime and answerable by tasklist.
# Liveness stays off PowerShell on its hot path (the Stop hook runs it every
# turn end): tasklist answers existence+name in tens of milliseconds, and only
# a bare-interpreter name (node/python) pays one scoped CIM query for the
# command line.

fm_harness_platform_is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MSYS*|MINGW*|CYGWIN*) return 0 ;;
  esac
  return 1
}

fm_harness_windows_self_pid() {
  local wp
  wp=$(cat "/proc/$$/winpid" 2>/dev/null) || return 1
  case "$wp" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$wp"
}

# Print up to 16 native ancestors of native pid $1, innermost first, one
# tab-separated "<pid>\t<name>\t<command-line>" row per hop, from one batched
# process-table snapshot. Tabs, CRs and LFs inside a command line are
# flattened to spaces so the row shape stays parseable.
fm_harness_windows_ancestry_snapshot() {  # <native-pid>
  local start=$1
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  # Per-pid filtered queries inside ONE PowerShell process, with the same
  # climb-then-extend boundary applied as an EMISSION bound so the walk stops
  # paying WMI queries once the contiguous harness run has provably ended.
  # This is only an optimization: bash re-applies the real matching policy to
  # every emitted row, and an under-stopped walk merely emits extra rows.
  # Measured ~3s for a full-table snapshot vs a few hundred ms this way.
  # The single quotes are deliberate: the payload is a PowerShell script whose
  # $-variables must reach PowerShell literally, with the two bash values
  # spliced in through the standard '"$var"' quote-break pattern.
  # shellcheck disable=SC2016
  MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command '
    $re="'"$FM_HARNESS_RE"'"
    $p=[int]'"$start"'
    $matched=$false
    for($i=0; $i -lt 16 -and $p -gt 0; $i++){
      $x=Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
      if(-not $x){break}
      $cl="$($x.CommandLine)" -replace "[`r`n`t]"," "
      Write-Output "$($x.ProcessId)`t$($x.Name)`t$cl"
      $n=("$($x.Name)" -replace "\.exe$","")
      if($n -cmatch $re){
        if($n -notmatch "claude"){break}
        $matched=$true
      } elseif($matched){break}
      $p=[int]$x.ParentProcessId
    }' 2>/dev/null | tr -d '\r'
}

# Windows body of fm_harness_ancestry_pids: identical climb-then-extend
# policy, fed by a two-stage native-pid row stream.
#
# Stage 1 climbs the MSYS ancestry via /proc, because a fork/exec'd MSYS
# descendant's NATIVE parent is a transient fork stub that has already
# exited - the Windows parent chain is broken at every MSYS-spawned hop, so
# CIM alone dead-ends one hop up (verified live: a nested bash's
# ParentProcessId named a nonexistent process). MSYS's own /proc ppid chain
# tracks those hops correctly. Each hop is emitted under its NATIVE pid
# (/proc/<pid>/winpid) so everything downstream stays tasklist/CIM-checkable.
#
# Stage 2 continues above the MSYS root (ppid 1) through the CIM snapshot,
# which is valid there because the root was started by a native
# CreateProcess - that is where claude.exe and the terminal chain live.
fm_harness_windows_ancestry_pids() {
  # MSYS fork emulation makes every subprocess cost ~100ms on Windows, so
  # this function reads /proc with bash builtins (read/mapfile, no cat/tr)
  # and parses rows in-shell (no awk); the one PowerShell child is the only
  # unavoidable spawn on the happy path.
  local pid=$$ wp ppid name args rows='' root_wp='' snapshot tab
  local -a argv
  tab=$(printf '\t')
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [ -d "/proc/$pid" ] || break
    # read returns nonzero on EOF-without-newline while still filling the
    # variable, so validate content instead of the read status.
    wp=''
    read -r wp < "/proc/$pid/winpid" 2>/dev/null || true
    case "$wp" in ''|*[!0-9]*) break ;; esac
    name=''
    read -r name < "/proc/$pid/exename" 2>/dev/null || true
    argv=()
    mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || true
    args="${argv[*]-}"
    args=${args//"$tab"/ }
    rows="$rows$wp$tab$name$tab$args
"
    root_wp=$wp
    ppid=''
    read -r ppid < "/proc/$pid/ppid" 2>/dev/null || true
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
  done
  if [ -z "$root_wp" ]; then
    # No MSYS /proc chain at all: fall back to a pure native walk from self.
    root_wp=$(fm_harness_windows_self_pid) || return 1
  fi
  # The snapshot's first row repeats the MSYS root already emitted above.
  # That duplicate is deliberately left in place: a duplicate row changes
  # neither lock-pid membership nor the outermost-of-run selection, and
  # dropping it would cost another subprocess.
  snapshot=$(fm_harness_windows_ancestry_snapshot "$root_wp")
  rows="$rows$snapshot"
  [ -n "$rows" ] || return 1
  local extending=0 printed=0
  while IFS=$tab read -r pid name args; do
    pid=${pid%$'\r'}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if fm_harness_process_matches "$name" "$args"; then
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

# Windows body of fm_harness_pid_alive: kill -0 cannot probe a native pid
# from MSYS, so existence and name come from tasklist (cheap), and only an
# interpreter-named survivor pays one scoped CIM query for its command line.
fm_harness_windows_pid_alive() {
  local pid=$1 row name args
  row=$(MSYS_NO_PATHCONV=1 tasklist.exe /FI "PID eq $pid" /FO CSV /NH 2>/dev/null | tr -d '\r') || return 1
  case "$row" in '"'*) ;; *) return 1 ;; esac  # non-match prints an INFO line, never CSV
  name=${row#\"}
  name=${name%%\"*}
  fm_harness_process_matches "$name" "" && return 0
  case "$name" in
    *node*|*python*)
      args=$(MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -NonInteractive -Command "(Get-CimInstance Win32_Process -Filter \"ProcessId=$pid\").CommandLine" 2>/dev/null | tr -d '\r')
      fm_harness_process_matches "$name" "$args"
      ;;
    *) return 1 ;;
  esac
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
  local pid=$$ comm args extending=0 printed=0
  if fm_harness_platform_is_windows; then
    fm_harness_windows_ancestry_pids && return 0
    fm_harness_env_session_pid
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
  [ "$printed" -eq 1 ] && return 0
  # A walk that resolved nothing is the severed-chain case: fall back to the
  # pid the harness published for this session rather than reporting no
  # ancestry at all, which is what left fm-lock.sh unable to reclaim a dead
  # owner from inside a hook.
  fm_harness_env_session_pid
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
  if fm_harness_platform_is_windows; then
    fm_harness_windows_pid_alive "$pid"
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# Print the session pid the harness itself published to this process, or
# return 1.
#
# Claude Code exports CLAUDE_PID into the environment of every hook command and
# tool call it runs, naming the session process. That is the harness stating its
# own identity, so it answers the ownership question without walking the process
# tree at all - and the walk is exactly what a severed parent chain defeats.
#
# On Windows the chain is severed by an ordinary registration: a hook command
# that is anything other than a single simple command makes MSYS bash replace
# itself for the final command, so the surviving shell is parented to an
# already-exited fork stub and the native parent chain dead-ends at its first
# hop. The Stop-owned auto-arm then failed its identity gate and exited inert on
# every turn end. See docs/verification/claude-stop-autoarm-windows.md.
#
# Keyed on the variable being published AND naming a live verified harness
# process, never on uname: a harness or host that does not publish it leaves
# every caller's walk behavior exactly as it was.
fm_harness_env_session_pid() {
  local pid=${CLAUDE_PID:-}
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session.
# A harness that publishes its own session pid answers the question directly,
# so that pid is accepted when it is the lock holder and is a live verified
# harness; see fm_harness_env_session_pid. A missing lock, a malformed lock, a
# lock held by a harness outside this ancestry, or an ancestry that cannot be
# resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Fast path: when the harness published this session's pid and that pid is the
  # lock holder, ownership is settled without walking the process tree - which
  # also spares this predicate a PowerShell CIM spawn on every Claude turn end
  # on Windows. Anything else falls through to the unchanged walk.
  if [ "${CLAUDE_PID:-}" = "$lock_pid" ] && fm_harness_env_session_pid >/dev/null; then
    return 0
  fi
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
