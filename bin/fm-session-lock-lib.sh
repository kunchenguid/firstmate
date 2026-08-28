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
FM_HARNESS_RE='claude|codex|opencode|grok|^kimi(\.exe)?$|^pi(\.exe)?$|^pi-signed(\.exe)?$'

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
  path=${path//\\//}
  path=${path#\"}
  path=${path%\"}
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
FM_HARNESS_MATCH_NAME=
fm_harness_process_matches() {  # <comm> <args> [argv0]
  local comm=$1 args=$2 argv0=${3:-} base flat_argv0 name
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_MATCH_NAME=
  base=${comm//\\//}
  base=$(basename -- "$base")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in
      *claude*) FM_HARNESS_MATCH_NAME=claude; FM_HARNESS_IS_CLAUDE=1 ;;
      *codex*) FM_HARNESS_MATCH_NAME=codex ;;
      *opencode*) FM_HARNESS_MATCH_NAME=opencode ;;
      *grok*) FM_HARNESS_MATCH_NAME=grok ;;
      kimi|kimi.exe) FM_HARNESS_MATCH_NAME=kimi ;;
      *pi-signed*) FM_HARNESS_MATCH_NAME=pi-signed ;;
      pi|pi.exe) FM_HARNESS_MATCH_NAME=pi ;;
    esac
    return 0
  fi
  flat_argv0=${args%% *}
  argv0=${argv0:-$flat_argv0}
  if name=$(fm_harness_path_name "$comm") \
    || name=$(fm_harness_path_name "$argv0") \
    || name=$(fm_harness_path_name "$flat_argv0"); then
    FM_HARNESS_MATCH_NAME=$name
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if name=$(fm_harness_path_name "$args"); then
        FM_HARNESS_MATCH_NAME=$name
        case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      case "$args" in
        *claude*) FM_HARNESS_MATCH_NAME=claude; FM_HARNESS_IS_CLAUDE=1; return 0 ;;
        *codex*) FM_HARNESS_MATCH_NAME=codex; return 0 ;;
        *opencode*) FM_HARNESS_MATCH_NAME=opencode; return 0 ;;
        *grok*) FM_HARNESS_MATCH_NAME=grok; return 0 ;;
        *" pi-signed "*|*/pi-signed) FM_HARNESS_MATCH_NAME=pi-signed; return 0 ;;
        *" pi "*|*/pi) FM_HARNESS_MATCH_NAME=pi; return 0 ;;
      esac
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  if fm_cursor_process_matches "$comm" "$args" "$argv0"; then
    FM_HARNESS_MATCH_NAME=cursor
    return 0
  fi
  return 1
}

# Git Bash ships the MSYS process viewer rather than procps. It has no `ps -o`
# fields, and a native Windows parent appears as PPID 1, so the Unix walk cannot
# identify a native Codex process. Resolve that process tree through Windows'
# own process table while preserving the same tabular contract used below.
fm_process_uses_windows_table() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*)
      # A Cygwin installation may provide a full procps implementation. Keep
      # the established Unix provider whenever the exact required query works.
      ps -o comm= -p "$$" >/dev/null 2>&1 && return 1
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_windows_current_pid() {
  local row
  row=$(ps -l -p "$$" 2>/dev/null | sed -n '2p') || return 1
  set -- $row
  case "${4:-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$4"
}

fm_windows_process_rows() {  # <pid> <limit>
  local pid=$1 limit=$2 helper
  case "$pid:$limit" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  helper="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-windows-process.ps1"
  [ -f "$helper" ] || return 1
  command -v powershell.exe >/dev/null 2>&1 || return 1
  powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$helper" ancestry "$pid" "$limit" 2>/dev/null
}

# Print pid<TAB>ppid<TAB>command<TAB>argv0<TAB>arguments for the current process
# and its parents. The optional bound defaults to sixteen hops.
fm_process_ancestry_rows() {  # [limit]
  local limit=${1:-16} pid comm argv0 args ppid winpid
  case "$limit" in ''|*[!0-9]*|0) return 1 ;; esac
  if fm_process_uses_windows_table; then
    winpid=$(fm_windows_current_pid) || return 1
    fm_windows_process_rows "$winpid" "$limit"
    return
  fi
  pid=$$
  while [ "$limit" -gt 0 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid:$ppid" in *[!0-9:]*|:*|*:) break ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$comm" "$argv0" "$args"
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
    limit=$((limit - 1))
  done
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
  local rows pid ppid comm argv0 args extending=0 printed=0
  if [ -n "${FM_SESSION_HARNESS_PID:-}" ] && fm_harness_pid_alive "$FM_SESSION_HARNESS_PID"; then
    printf '%s\n' "$FM_SESSION_HARNESS_PID"
    return 0
  fi
  rows=$(fm_process_ancestry_rows 16) || return 1
  while IFS=$'\t' read -r pid ppid comm argv0 args; do
    [ -n "$pid" ] || continue
    if fm_harness_process_matches "$comm" "$args" "$argv0"; then
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
  local pid=$1 row row_pid ppid comm argv0 args
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_process_uses_windows_table; then
    row=$(fm_windows_process_rows "$pid" 1) || return 1
    IFS=$'\t' read -r row_pid ppid comm argv0 args <<EOF
$row
EOF
    [ "$row_pid" = "$pid" ] || return 1
  else
    kill -0 "$pid" 2>/dev/null || return 1
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
    args=$(ps -o args= -p "$pid" 2>/dev/null)
  fi
  fm_harness_process_matches "$comm" "$args" "$argv0"
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
