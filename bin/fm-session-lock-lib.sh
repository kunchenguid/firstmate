#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake; bin/backends/tmux.sh
# uses its Claude native-install path check to attribute tmux pane liveness.
# This file is sourced by scripts and has no side effects on source.

# Known exact harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='^(claude|codex|opencode|grok|kimi|pi|pi-signed)$'

# The same harnesses as exact executable names.
# Keep in sync with FM_HARNESS_RE.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# True when executable path $1 has Claude Code's version-named native-install
# shape.
#
# Claude Code's native installer names the executable by its version
# (~/.local/share/claude/versions/2.1.220), so the basename identifies nothing.
# No other verified harness needs path evidence, and accepting an arbitrary
# harness-named directory would attribute unrelated helpers to that harness.
fm_harness_claude_path_matches() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "/$path/" in
    */claude/versions/?*/) return 0 ;;
  esac
  return 1
}

# Print the exact harness name identified by immediate interpreter script path
# $1, or return 1.
#
# A package directory component may carry the identity when its generic entry
# point is named cli.js, while a script basename may carry it as codex.js.
# Whole-component and exact basename matching keep unrelated substrings out.
fm_harness_script_name() {  # <path>
  local path=$1 name base
  [ -n "$path" ] || return 1
  base=${path##*/}
  case "$base" in
    *.js|*.mjs|*.cjs|*.py) base=${base%.*} ;;
  esac
  for name in "${FM_HARNESS_NAMES[@]}"; do
    if [ "$base" = "$name" ]; then
      printf '%s' "$name"
      return 0
    fi
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
#   1. the exact basename of the reported command name, against FM_HARNESS_RE -
#      stripping one leading "-" first, since a login-shell-style invocation
#      (`exec -a -codex ...`) reports comm/argv[0] with that convention-carried
#      dash and is still the same exact harness executable.
#   2. Claude Code's version-named native-install shape in that command path or
#      in argv[0]. Both are needed because macOS reports argv[0] in `ps -o
#      comm=`, while procps on Linux reports the kernel exec name and ignores
#      argv[0] entirely.
#   3. an exact bare interpreter (node or python) whose immediate script
#      argument identifies a harness.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base dashless argv0 rest script name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  dashless=${base#-}
  if printf '%s' "$dashless" | grep -qE "$FM_HARNESS_RE"; then
    [ "$dashless" = claude ] && FM_HARNESS_IS_CLAUDE=1
    return 0
  fi
  argv0=${args%%[[:space:]]*}
  if fm_harness_claude_path_matches "$comm" || fm_harness_claude_path_matches "$argv0"; then
    FM_HARNESS_IS_CLAUDE=1
    return 0
  fi
  if printf '%s' "$base" | grep -qE '^(node|nodejs|python([0-9]+(\.[0-9]+)?)?)$'; then
    rest=${args#"$argv0"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    script=${rest%%[[:space:]]*}
    if name=$(fm_harness_script_name "$script"); then
      if [ "$name" = claude ]; then
        FM_HARNESS_IS_CLAUDE=1
      fi
      return 0
    fi
  fi
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
