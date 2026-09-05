#!/usr/bin/env bash
# Shared harness process-identity helpers.
#
# ONE side-effect-free owner of the "which verified harness does this process
# represent?" decision, shared by harness detection, hook-host stand-down,
# tmux liveness/composer identity, and session-lock ancestry.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cursor process identity is structurally narrower than the generic harness-name
# table. Source its owner when present; hermetic fixture roots that do not copy
# Cursor's helper simply get a no-match stub instead of pulling unrelated lock
# machinery into the fixture.
if [ -f "$SCRIPT_DIR/fm-cursor-lib.sh" ]; then
  # shellcheck source=bin/fm-cursor-lib.sh
  . "$SCRIPT_DIR/fm-cursor-lib.sh"
elif ! command -v fm_cursor_process_matches >/dev/null 2>&1; then
  fm_cursor_process_matches() {  # <comm> <args> [argv0]
    return 1
  }
fi

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|^copilot$|opencode|grok|kimi|^pi$|^pi-signed$'

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

fm_harness_copilot_path_matches() {  # <path>
  [ "${1##*/}" = copilot ]
}

fm_harness_interpreter_script_path() {  # <comm> <args>
  local comm=$1 args=$2 argv0 rest token
  [ -n "$args" ] || return 1
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  case "${comm##*/}:${argv0##*/}" in
    MainThread:*|*:node|*:node-*|*:node[0-9]*|*:python|*:python[0-9]*|*:python[0-9].[0-9]*) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  while [ -n "$rest" ]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in -*) continue ;; esac
    printf '%s\n' "$token"
    return 0
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
#   3. a bare interpreter (node, python, MainThread) running a harness script
#      path in its first non-flag script token.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
FM_HARNESS_MATCH_NAME=
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name script
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_MATCH_NAME=
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in
      *claude*) name=claude; FM_HARNESS_IS_CLAUDE=1 ;;
      *codex*) name=codex ;;
      copilot) name=copilot ;;
      *opencode*) name=opencode ;;
      *grok*) name=grok ;;
      kimi) name=kimi ;;
      pi-signed) name=pi-signed ;;
      pi) name=pi ;;
    esac
    [ -n "$name" ] || return 1
    FM_HARNESS_MATCH_NAME=$name
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm"); then
    :
  elif fm_harness_copilot_path_matches "$argv0"; then
    name=copilot
  elif name=$(fm_harness_path_name "$argv0"); then
    :
  fi
  if [ -n "$name" ]; then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    FM_HARNESS_MATCH_NAME=$name
    return 0
  fi
  if script=$(fm_harness_interpreter_script_path "$comm" "$args"); then
    if [ "${script##*/}" = copilot ]; then
      name=copilot
    elif name=$(fm_harness_path_name "$script"); then
      [ "$name" != copilot ] || name=
    fi
    if [ -n "$name" ]; then
      case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
      FM_HARNESS_MATCH_NAME=$name
      return 0
    fi
  fi
  if fm_cursor_process_matches "$comm" "$args" "$argv0"; then
    FM_HARNESS_MATCH_NAME=cursor
    return 0
  fi
  return 1
}

fm_harness_process_name() {  # <comm> <args>
  fm_harness_process_matches "$1" "$2" || return 1
  [ -n "$FM_HARNESS_MATCH_NAME" ] || return 1
  printf '%s\n' "$FM_HARNESS_MATCH_NAME"
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
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
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run.
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
