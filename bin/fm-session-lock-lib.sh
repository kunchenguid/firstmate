#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# A numeric harness pid is the normal owner identity. Hosted Codex seatbelt
# sessions can deny process ancestry reads, so they fall back to a stable
# codex:<thread-id> token that is never age-reclaimed or treated as stale.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the stable hosted Codex owner token only in the environment where
# process inspection is known to be denied by the seatbelt sandbox.
fm_codex_owner_token() {
  [ -n "${CODEX_THREAD_ID:-}" ] || return 1
  [ "${CODEX_SANDBOX:-}" = seatbelt ] || return 1
  printf 'codex:%s\n' "$CODEX_THREAD_ID"
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
# innermost match unchanged. Falls back to the hosted Codex owner token when the
# ancestry walk cannot resolve any harness pid at all (seatbelt-denied ps).
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || { fm_codex_owner_token; return; }
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  if [ -n "$outermost" ]; then
    printf '%s\n' "$outermost"
    return 0
  fi
  fm_codex_owner_token
}

fm_session_lock_owner_valid() {  # <owner>
  local owner=$1
  case "$owner" in
    codex:?*) return 0 ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$owner" -gt 1 ]
}

fm_session_lock_owner_read() {  # <state-dir>
  local state=$1 owner trailing=''
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  {
    IFS= read -r owner || return 1
    if IFS= read -r trailing; then return 1; fi
    [ -z "$trailing" ] || return 1
  } < "$state/.lock" 2>/dev/null || return 1
  fm_session_lock_owner_valid "$owner" || return 1
  printf '%s' "$owner"
}

fm_session_lock_owner_matches() {  # <state-dir> <expected-owner>
  local state=$1 expected=$2 current
  fm_session_lock_owner_valid "$expected" || return 1
  current=$(fm_session_lock_owner_read "$state") || return 1
  [ "$current" = "$expected" ]
}

# True if $1 is a live process that looks like a verified harness, or a hosted
# Codex owner token. Sets FM_HARNESS_LIVE_KIND for callers that need to describe
# the owner (codex, uninspectable_pid, or harness_pid).
# A codex:<thread-id> token is deliberately treated as live forever: no clock or
# age heuristic may steal another thread's durable fleet lock. A numeric pid
# that kill -0 confirms alive but ps cannot describe is conservatively treated
# as an uninspectable live holder only inside that same seatbelt environment;
# outside it, an unreadable ps is still evidence the process is not a harness.
FM_HARNESS_LIVE_KIND=
fm_harness_pid_alive() {
  local pid=$1 comm args
  FM_HARNESS_LIVE_KIND=
  fm_session_lock_owner_valid "$pid" || return 1
  case "$pid" in
    codex:*)
      FM_HARNESS_LIVE_KIND=codex
      return 0
      ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || {
    if [ -n "${CODEX_THREAD_ID:-}" ] && [ "${CODEX_SANDBOX:-}" = seatbelt ]; then
      FM_HARNESS_LIVE_KIND=uninspectable_pid
      return 0
    fi
    return 1
  }
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  if fm_harness_process_matches "$comm" "$args"; then
    # shellcheck disable=SC2034 # Read by fm-lock.sh after sourcing this file.
    FM_HARNESS_LIVE_KIND=harness_pid
    return 0
  fi
  return 1
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed. A codex:<thread-id> lock is
# owned by self only when it matches this same hosted Codex thread's own token.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(fm_session_lock_owner_read "$state") || return 1
  case "$lock_pid" in
    codex:*)
      [ "$lock_pid" = "$(fm_codex_owner_token 2>/dev/null)" ]
      return
      ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
