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
# A codex-thread identity names a Codex conversation, not a process, so no other
# session can probe it for liveness. Ownership is proven by a lease instead: the
# owning session rewrites state/.lock when it acquires the lock and refreshes it
# from every guarded command it runs (bin/fm-guard.sh), and any OTHER session
# must read a lock refreshed inside this window as a live owner it may not
# displace. Only an expired lease is stale-lock recovery. Long enough that a
# live-but-idle Codex primary keeps exclusive control, short enough that a
# crashed session's home frees itself unattended.
FM_CODEX_THREAD_LEASE_SECS_DEFAULT=900

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

fm_codex_thread_lease_secs() {
  local secs=${FM_CODEX_THREAD_LEASE_SECS:-$FM_CODEX_THREAD_LEASE_SECS_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*|0) secs=$FM_CODEX_THREAD_LEASE_SECS_DEFAULT ;;
  esac
  printf '%s\n' "$secs"
}

# Portable mtime in epoch seconds. Kept self-contained so the SessionStart nudge
# keeps sourcing this leaf lib alone.
fm_session_lock_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# True when lock file $1 was refreshed inside the codex-thread lease window.
# A missing path, an unreadable mtime, or an unreadable clock is uncertainty
# about a foreign Codex owner, and uncertainty fails CLOSED as "still live": the
# caller then refuses to mutate and stays read-only, rather than letting two
# simultaneously live Codex primaries trade one home's lock back and forth.
fm_codex_thread_lease_fresh() {
  local lock=${1:-} mtime now
  [ -n "$lock" ] || return 0
  mtime=$(fm_session_lock_mtime "$lock") || return 0
  now=$(date +%s 2>/dev/null) || return 0
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ "$(( now - mtime ))" -lt "$(fm_codex_thread_lease_secs)" ]
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

# True if $1 is a live process, or a non-process session identity that the
# calling environment still resolves to, and that looks like a verified harness.
# $2 is the lock file $1 was read from, needed only to age a codex-thread lease.
# A codex-thread identity has no observable process to probe, so liveness is
# either the caller resolving to that same thread, or - for a FOREIGN thread -
# the lease on the lock file still being fresh. A fresh foreign lease keeps
# mutual exclusion between two simultaneously live Codex primaries; an expired
# one is stale-lock recovery through the unchanged bin/fm-lock.sh path, so the
# first Codex session still cannot poison the home's lock forever.
fm_harness_pid_alive() {
  local pid=$1 lock=${2:-} comm args
  case "$pid" in
    "$FM_CODEX_THREAD_LOCK_PREFIX"*)
      fm_codex_thread_lock_valid "$pid" || return 1
      [ "$(fm_codex_thread_identity 2>/dev/null)" = "$pid" ] && return 0
      fm_codex_thread_lease_fresh "$lock"
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

# Renew this session's codex-thread lease on state dir $1's lock, so a long
# Codex session keeps proving exclusive ownership between session starts. A
# numeric owner proves liveness through its own process and needs no lease, so
# this is a no-op there, as it is for any session that does not own the lock.
fm_session_lock_refresh_self() {
  local state=${1:-} lock_identity
  lock_identity=$(cat "$state/.lock" 2>/dev/null) || return 0
  fm_codex_thread_lock_valid "$lock_identity" || return 0
  [ "$(fm_codex_thread_identity 2>/dev/null)" = "$lock_identity" ] || return 0
  touch "$state/.lock" 2>/dev/null || true
}
