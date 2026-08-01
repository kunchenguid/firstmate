#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process belong to that same harness session?"
# decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'
FM_CODEX_THREAD_LOCK_PREFIX='codex-thread:'

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

fm_codex_thread_id_valid() {
  printf '%s' "${1:-}" \
    | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

fm_codex_thread_identity() {
  [ "${CODEX_CI:-}" = 1 ] || return 1
  fm_codex_thread_id_valid "${CODEX_THREAD_ID:-}" || return 1
  printf '%s%s\n' "$FM_CODEX_THREAD_LOCK_PREFIX" "$CODEX_THREAD_ID"
}

fm_codex_thread_lock_valid() {
  local id=${1:-}
  case "$id" in
    "$FM_CODEX_THREAD_LOCK_PREFIX"*) ;;
    *) return 1 ;;
  esac
  fm_codex_thread_id_valid "${id#"$FM_CODEX_THREAD_LOCK_PREFIX"}"
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
  local pid=$$ comm args ppid extending=0 printed=0
  FM_HARNESS_ANCESTRY_BLOCKED=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    if ! comm=$(ps -o comm= -p "$pid" 2>/dev/null); then
      FM_HARNESS_ANCESTRY_BLOCKED=1
      break
    fi
    if ! args=$(ps -o args= -p "$pid" 2>/dev/null); then
      FM_HARNESS_ANCESTRY_BLOCKED=1
      args=
    fi
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    if ! ppid=$(ps -o ppid= -p "$pid" 2>/dev/null); then
      FM_HARNESS_ANCESTRY_BLOCKED=1
      break
    fi
    pid=$(printf '%s' "$ppid" | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the identity that identifies this session when the session lock is being
# WRITTEN: normally the outermost pid of the contiguous run. That is the pid that
# lives as long as the session - a Claude worker several levels in is reaped when
# its hook returns, and a lock naming it would look stale moments later while the
# session is still running. Every non-Claude harness reports a single pid, so
# this is its innermost match unchanged. Codex 0.146.0 can deny `ps` inside its
# seatbelt; when ancestry cannot be inspected, fall back to Codex's verified
# per-thread marker and publish a codex-thread identity instead of a numeric pid.
fm_harness_ancestry_pid() {
  local pids pid outermost='' identity
  if pids=$(fm_harness_ancestry_pids); then
    while IFS= read -r pid; do
      [ -n "$pid" ] && outermost=$pid
    done <<EOF
$pids
EOF
    [ -n "$outermost" ] && { printf '%s\n' "$outermost"; return 0; }
  fi
  if [ "${FM_HARNESS_ANCESTRY_BLOCKED:-0}" -eq 1 ]; then
    identity=$(fm_codex_thread_identity 2>/dev/null) && { printf '%s\n' "$identity"; return 0; }
  fi
  return 1
}

# True if $1 is a live process, or a fail-closed non-process session identity,
# that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  case "$pid" in
    "$FM_CODEX_THREAD_LOCK_PREFIX"*)
      fm_codex_thread_lock_valid "$pid"
      return
      ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds the current process's harness-session identity:
# numeric locks may be ANY harness ancestor of the current process, while a
# codex-thread lock must match Codex's verified thread marker. A missing lock, a
# malformed lock, a lock held by a harness outside this ancestry, or an identity
# that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_identity my_identity
  lock_identity=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_identity" in
    ''|1) return 1 ;;
    "$FM_CODEX_THREAD_LOCK_PREFIX"*)
      my_identity=$(fm_codex_thread_identity 2>/dev/null) || return 1
      [ "$my_identity" = "$lock_identity" ]
      return
      ;;
    *[!0-9]*) return 1 ;;
  esac
  local pids pid
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_identity" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
