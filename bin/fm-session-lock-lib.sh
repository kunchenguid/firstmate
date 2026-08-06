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

# --- Windows (Git Bash / MSYS) ancestry -------------------------------------
# Git Bash's ps supports no -o format (exits 1) and cannot see native Windows
# processes at all: a shell spawned by claude.exe reports PPID 1, so the POSIX
# walk below can never reach the harness. On Windows the real process tree is
# walked through PowerShell/CIM instead, starting from this shell's WINPID.
# The session lock therefore stores Windows pids on this platform, and holder
# liveness goes through CIM as well (kill -0 does not accept Windows pids).

fm_session_lock_on_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print "pid|name|commandline" for each Windows ancestor of this shell,
# innermost first, up to 16 MSYS hops plus 16 native hops, in one PowerShell
# invocation.
#
# The walk is hybrid because MSYS fork emulation severs the native parent
# chain: a bash forked by another bash records a transient stub as its Windows
# parent, dead by the time anyone looks, so a pure CIM walk from this shell
# stops one hop up. The MSYS pid table (ps PID/PPID/WINPID columns, stable
# positions before the variable-width STIME) bridges exactly those gaps: climb
# it to the MSYS root, collect every ancestor's WINPID, then resolve them all
# through CIM and continue up the native chain from the root - whose Windows
# parent (the harness that CreateProcess'd it) really is alive.
#
# The PowerShell script is fed on stdin as a single line because PowerShell's
# stdin command mode silently drops multi-line blocks. CommandLine newlines
# are flattened so each ancestor stays one parseable line; only the first two
# | are separators, a command line containing | lands intact in the args field.
fm_win_ancestry_chain() {
  local table pid=$$ row ppid winpid winpids='' guard=0
  table=$(ps 2>/dev/null) || return 1
  while [ "$guard" -lt 16 ]; do
    guard=$((guard + 1))
    row=$(printf '%s\n' "$table" | awk -v p="$pid" '$1==p {print $2" "$4; exit}')
    [ -n "$row" ] || break
    ppid=${row% *}
    winpid=${row#* }
    case "$winpid" in ''|*[!0-9]*) break ;; esac
    winpids="$winpids,$winpid"
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
  done
  winpids=${winpids#,}
  [ -n "$winpids" ] || return 1
  FM_WIN_WALK_PIDS=$winpids powershell.exe -NoProfile -NonInteractive -Command - <<'PSEOF' 2>/dev/null | tr -d '\r'
$ErrorActionPreference='SilentlyContinue'; $last=$null; foreach($q in ($env:FM_WIN_WALK_PIDS -split ',')){ $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$q)"; if($proc){ Write-Output ("{0}|{1}|{2}" -f $proc.ProcessId,$proc.Name,($proc.CommandLine -replace "[\r\n]+"," ")); $last=$proc } }; if($last){ $p=$last.ParentProcessId; for($i=0; $i -lt 16 -and $p -gt 4; $i++){ $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$p"; if(-not $proc){break}; Write-Output ("{0}|{1}|{2}" -f $proc.ProcessId,$proc.Name,($proc.CommandLine -replace "[\r\n]+"," ")); $p=$proc.ParentProcessId } }
PSEOF
}

# Windows variant of fm_harness_ancestry_pids: identical contiguity contract
# and fm_harness_process_matches evidence, applied to the CIM chain.
fm_win_harness_ancestry_pids() {
  local chain pid name args extending=0 printed=0
  chain=$(fm_win_ancestry_chain) || return 1
  [ -n "$chain" ] || return 1
  while IFS='|' read -r pid name args; do
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
$chain
EOF
  [ "$printed" -eq 1 ]
}

# Print "name|commandline" for live Windows pid $1, or fail when it is gone.
fm_win_process_info() {
  local pid=$1 info
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  info=$(FM_WIN_QUERY_PID=$pid powershell.exe -NoProfile -NonInteractive -Command - <<'PSEOF' 2>/dev/null | tr -d '\r'
$ErrorActionPreference='SilentlyContinue'; $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$env:FM_WIN_QUERY_PID)"; if($proc){ Write-Output ("{0}|{1}" -f $proc.Name,($proc.CommandLine -replace "[\r\n]+"," ")) }
PSEOF
)
  [ -n "$info" ] || return 1
  printf '%s\n' "$info"
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
  if fm_session_lock_on_windows; then
    fm_win_harness_ancestry_pids
    return
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
  local pid=$1 comm args
  if fm_session_lock_on_windows; then
    local info
    info=$(fm_win_process_info "$pid") || return 1
    comm=${info%%|*}
    args=${info#*|}
    fm_harness_process_matches "$comm" "$args"
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
