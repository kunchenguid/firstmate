#!/usr/bin/env bash
# Shared session-lock session identity.
#
# ONE owner of the "which verified harness session holds this home's session
# lock, and does the current process belong to that same session?" decision.
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

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print Codex's state root, or fail when no absolute-enough root is available.
# CODEX_HOME is Codex's own override; otherwise its state lives below HOME.
fm_codex_state_root() {
  if [ -n "${CODEX_HOME:-}" ]; then
    printf '%s\n' "$CODEX_HOME"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/.codex\n' "$HOME"
  else
    return 1
  fi
}

# Classify Codex's thread-writer lock for $1.
#   0 = held, so that Codex thread is live
#   1 = absent or free, so that thread is stale
#   2 = uncertain, which callers must treat fail-closed
fm_codex_writer_lock_state() {  # <thread-id>
  local thread_id=${1:-} root writer_lock rc
  case "$thread_id" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  root=$(fm_codex_state_root) || return 2
  writer_lock="$root/thread-writer-locks/$thread_id.lock"
  [ -e "$writer_lock" ] || return 1
  [ -f "$writer_lock" ] && [ ! -L "$writer_lock" ] || return 2
  command -v flock >/dev/null 2>&1 || return 2
  (
    exec 9<"$writer_lock" || exit 2
    flock -n -E 75 9
  ) >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 1 ;;
    75) return 0 ;;
    *) return 2 ;;
  esac
}

# Print the first safe Codex thread marker available to a tool subprocess.
fm_codex_thread_id() {
  local thread_id=${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}
  case "$thread_id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$thread_id"
}

# True for every lock identity shape accepted by the current file format.
# Numeric identities retain their historic permissive syntax; their ancestry
# and liveness checks below remain the authority for actual ownership.
fm_session_identity_valid() {  # <identity>
  local identity=${1:-}
  case "$identity" in
    codex:*)
      identity=${identity#codex:}
      case "$identity" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      ;;
    ''|*[!0-9]*) return 1 ;;
  esac
}

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

# Print this session's stable lock identity. A verified Codex writer lock takes
# precedence because Codex's sandbox may hide the harness process ancestry.
# Every other case falls through to the existing harness-PID ancestry path.
fm_session_identity() {
  local thread_id
  if thread_id=$(fm_codex_thread_id) \
    && fm_codex_writer_lock_state "$thread_id"; then
    printf 'codex:%s\n' "$thread_id"
    return 0
  fi
  fm_harness_ancestry_pid
}

# True while a recorded session identity is live. An uncertain Codex writer
# state is deliberately live for contention purposes, so ambiguity can never
# authorize stealing a possibly active session's home lock.
fm_session_identity_alive() {  # <identity>
  local identity=${1:-} state
  case "$identity" in
    codex:*)
      fm_session_identity_valid "$identity" || return 1
      fm_codex_writer_lock_state "${identity#codex:}"
      state=$?
      case "$state" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *) fm_harness_pid_alive "$identity" ;;
  esac
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
  local state=$1 lock_identity pids pid thread_id
  lock_identity=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_identity" in
    codex:*)
      fm_session_identity_valid "$lock_identity" || return 1
      thread_id=$(fm_codex_thread_id) || return 1
      [ "$lock_identity" = "codex:$thread_id" ] || return 1
      fm_codex_writer_lock_state "$thread_id"
      return
      ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_identity" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
