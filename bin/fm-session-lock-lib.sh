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
fm_harness_process_matches() {  # <comm> <args> [context]
  local comm=$1 args=$2 context=${3:-} base argv0 name
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
      # Windows npm shim: on MSYS a pi session runs as node.exe with the
      # package bundle in argv, e.g. `node .../pi-coding-agent/dist/bundle/cli.js`,
      # so no bare harness word exists for the anchored rules above. The
      # package-name path component is the structural identity; matching it as a
      # whole component keeps anything shorter (pipe, api) from claiming it.
      if [ "$context" = windows ] \
        && printf '%s' "$args" | grep -qE '(^|[/\\])pi-coding-agent([/\\]|$)'; then
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
# On MSYS the POSIX walk can resolve nothing (see fm_windows_walk_enabled), so
# the windows fallback below answers the same question through PowerShell.

# True when the Windows-native ancestry fallback should be attempted. MSYS and
# its kin (MINGW, CYGWIN) run `ps` with no -o support and no view of native
# Windows processes, so the POSIX walk above finds nothing there and the same
# questions go through PowerShell instead. FM_TEST_WINDOWS_WALK lets the portable
# tests drive this path on hosts that are not MSYS.
fm_windows_walk_enabled() {
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
  esac
  [ "${FM_TEST_WINDOWS_WALK:-}" = 1 ]
}

# Print the Windows-native process chain starting at Windows pid $1, one
# "pid<TAB>name<TAB>commandline" line per hop, innermost first, or return
# nonzero when the query cannot complete. A start pid that is not live yields
# no lines.
fm_win_process_chain() {  # <winpid>
  local out
  # shellcheck disable=SC2016 # the PowerShell script is deliberately single-quoted so bash leaves it for PowerShell to interpret
  out=$(FM_WINPID=$1 powershell -NoProfile -Command '
    $p = [int]$env:FM_WINPID
    for ($i = 0; $i -lt 16 -and $p; $i++) {
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p"
      if (-not $proc) { break }
      Write-Output ($proc.ProcessId.ToString() + "`t" + $proc.Name + "`t" + [string]$proc.CommandLine)
      $p = $proc.ParentProcessId
    }
  ' 2>/dev/null | tr -d '\r') || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Print the WINPID of the topmost MSYS process above this shell. MSYS's own ps
# table is the only reliable parent map inside MSYS space: a forked MSYS child
# reports a short-lived fork helper (already dead by the time anyone asks) as
# its Windows parent, so a native Win32 walk started below the boundary strands
# immediately. The topmost row's WINPID is where Windows parentage becomes real
# again, and that pid starts the native chain walk in fm_windows_ancestry_pids.
fm_win_msys_top_winpid() {
  local ps_list cur row hop=0 ppid winpid boundary=0
  ps_list=$(ps 2>/dev/null) || return 1
  cur=$$
  winpid=
  while [ "$hop" -lt 16 ]; do
    row=$(printf '%s\n' "$ps_list" | awk -v p="$cur" '$1 == p { print $2, $4 }')
    [ -n "$row" ] || break
    ppid=${row%% *}
    winpid=${row##* }
    case "$ppid" in
      0 | 1) boundary=1; break ;;
    esac
    cur=$ppid
    hop=$((hop + 1))
  done
  [ "$boundary" -eq 1 ] && [ -n "$winpid" ] || return 1
  printf '%s\n' "$winpid"
}

# Windows-native fallback for the ancestry walk: same matching rules and same
# contiguous-run semantics, fed by a process table the POSIX walk cannot see.
# Prints matching harness pids (Windows pids) innermost first, or returns 1.
# The MSYS ladder rungs are not matched: every verified harness runs as a native
# Windows process, so the native chain from the topmost MSYS process is the
# part of the ancestry that can hold the session. FM_TEST_WIN_START pins that
# start pid for the portable tests, which cannot reproduce the MSYS ps table.
fm_windows_ancestry_pids() {
  local chain pid comm args extending=0 printed=0 start_winpid
  fm_windows_walk_enabled || return 1
  command -v powershell >/dev/null 2>&1 || return 1
  if [ -n "${FM_TEST_WIN_START:-}" ]; then
    start_winpid=$FM_TEST_WIN_START
  else
    start_winpid=$(fm_win_msys_top_winpid) || return 1
  fi
  case "$start_winpid" in '' | *[!0-9]*) return 1 ;; esac
  chain=$(fm_win_process_chain "$start_winpid") || return 1
  while IFS=$'\t' read -r pid comm args; do
    [ -n "$pid" ] || continue
    if fm_harness_process_matches "$comm" "$args" windows; then
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

# True when Windows pid $1 is live and looks like a verified harness.
fm_windows_pid_harness_alive() {  # <winpid>
  local chain first rest comm args
  fm_windows_walk_enabled || return 1
  command -v powershell >/dev/null 2>&1 || return 1
  chain=$(fm_win_process_chain "$1") || return 1
  first=${chain%%$'\n'*}
  rest=${first#*$'\t'}
  IFS=$'\t' read -r comm args <<EOF
$rest
EOF
  fm_harness_process_matches "$comm" "$args" windows
}

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
  if [ "$printed" -eq 0 ]; then
    fm_windows_ancestry_pids && printed=1
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

# True if $1 is a live process that looks like a verified harness. On MSYS
# neither kill -0 nor `ps -o` can describe native Windows processes, so both
# empty-answer paths fall through to the Windows-native identity query.
fm_harness_pid_alive() {
  local pid=$1 comm args
  if ! kill -0 "$pid" 2>/dev/null; then
    fm_windows_pid_harness_alive "$pid" && return 0
    return 1
  fi
  comm=$(ps -o comm= -p "$pid" 2>/dev/null); comm=${comm:-}
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  if [ -z "$comm" ] && [ -z "$args" ]; then
    fm_windows_pid_harness_alive "$pid" && return 0
    return 1
  fi
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
