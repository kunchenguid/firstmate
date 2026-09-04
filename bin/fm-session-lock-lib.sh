#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision,
# and of the durable session-identity binding that answers the same ownership
# question when ancestry cannot - a call served by a reparented worker pool
# never reaches its own session. See fm_session_lock_owned_by_current_session.
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

# True when pid $1 is a member of that contiguous harness ancestry: the ONE
# owner of "is this pid a harness process the current run genuinely sits inside".
# Both membership questions in this file ask it - of the pid the lock records,
# and of the served-session pid the harness reports. An ancestry that cannot be
# resolved answers false, so every caller stays fail-closed.
fm_harness_ancestry_contains() {  # <pid>
  local want=$1 pids pid
  [ -n "$want" ] || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$want" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  printf '%s\n' "${pids##*$'\n'}"
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
  local state=$1 lock_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_ancestry_contains "$lock_pid"
}

# Path of the durable session-identity binding that sits beside state dir $1's
# session lock. It is a SEPARATE file on purpose: `state/.lock` itself must stay
# a bare numeric pid, because several readers parse it as exactly that.
fm_session_lock_identity_path() {  # <state-dir>
  printf '%s/.lock.session\n' "$1"
}

# Print the harness session identity of the CURRENT process, or return 1 when
# the harness exposes none.
#
# Claude Code is currently the only verified harness that exports one. The value
# is the session's own id, which is why it is stable across a compaction and,
# unlike process ancestry, identical whichever worker pool serves the call.
# Anything that is not a plain identifier is refused rather than sanitized, so a
# surprising value can only withhold the proof, never widen it.
fm_harness_session_identity() {
  local id=${CLAUDE_CODE_SESSION_ID:-}
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# True when the session identity this process carries actually describes THIS
# process, rather than one it merely inherited through the environment.
#
# A session identity travels down every child of a tool call, so the string
# alone proves nothing: a crewmate launched on a harness that does not overwrite
# these variables would carry its launching session's identity, and any number of
# unrelated processes started from one environment would carry the same one. That
# is a false-success path, not a theoretical one.
#
# The corroboration is structural: the harness reports the session process it is
# serving this call for, and a call genuinely served by that session has that
# very process inside its own contiguous harness ancestry. Inheritance cannot
# fake it, because an unrelated process's ancestry contains its own harness
# instead. Note this is membership, NOT equality with the lock pid: the whole
# point is that the ancestry reaches the pool process serving the call while
# never reaching the pid the lock records.
fm_harness_session_is_ours() {
  local claimed=${CLAUDE_PID:-}
  case "$claimed" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$claimed" || return 1
  fm_harness_ancestry_contains "$claimed"
}

# Record, beside state dir $1's session lock, that lock pid $2 was acquired by
# THIS process's session. Best effort by contract: every failure leaves the home
# on the ancestry proof alone, which is exactly today's behavior.
#
# The stale record is discarded BEFORE the new one is written, so a home whose
# harness exposes no session identity is left with no binding at all rather than
# a previous owner's. That ordering is what stops a recycled lock pid from ever
# meeting a foreign session id in the same record.
fm_session_lock_publish_identity() {  # <state-dir> <lock-pid>
  local state=$1 pid=$2 id path tmp
  path=$(fm_session_lock_identity_path "$state")
  command rm -f -- "$path" 2>/dev/null || return 1
  id=$(fm_harness_session_identity) || return 0
  # Never bind a lock to an identity this process only inherited: that would
  # hand the home to whichever session the environment happens to name.
  fm_harness_session_is_ours || return 0
  tmp=$(mktemp "$state/.lock.session.XXXXXX" 2>/dev/null) || return 1
  if ! { printf 'pid=%s\nsession=%s\n' "$pid" "$id" > "$tmp"; } 2>/dev/null; then
    command rm -f -- "$tmp" 2>/dev/null
    return 1
  fi
  mv -f "$tmp" "$path" 2>/dev/null || {
    command rm -f -- "$tmp" 2>/dev/null
    return 1
  }
}

# True when state dir $1's session lock was acquired by the very session this
# process belongs to, proven by recorded identity instead of process ancestry.
#
# This exists because ancestry is not a stable session identity. Claude Code
# serves a session's hooks and tool calls from more than one worker pool, and a
# pool whose top process has been reparented to init yields a contiguous harness
# run that never reaches the session's own lineage. The same session therefore
# presents one ancestry through one pool and a different one through another, and
# once the pool that could reach it is gone it can never again prove it owns its
# own lock.
#
# The proof is a conjunction, and every part is required:
#   1. this process carries a harness session identity at all;
#   2. that identity is CORROBORATED by this process's own ancestry, not merely
#      inherited as an environment string - see fm_harness_session_is_ours;
#   3. the lock holds a plain numeric pid;
#   4. the binding beside it is a regular file naming exactly that pid, so a
#      record left by a previous owner can never speak for the current lock;
#   5. the session it names is exactly this process's session;
#   6. the lock pid is still a live harness process.
#
# A foreign session fails at 5 because it carries its own id, and a process that
# merely inherited another session's environment fails at 2. An absent or
# malformed lock fails at 3, an absent or stale binding at 4, and a dead owner at
# 6. Two firstmate homes on one machine stay independent because each reads its
# own state dir. An old lock carrying only a pid has no binding, so it fails at 4
# and that home keeps exactly today's ancestry-only behavior.
fm_session_lock_owned_by_session_identity() {  # <state-dir>
  local state=$1 id lock_pid path recorded_pid recorded_session
  id=$(fm_harness_session_identity) || return 1
  fm_harness_session_is_ours || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  path=$(fm_session_lock_identity_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  recorded_pid=$(sed -n 's/^pid=//p' "$path" 2>/dev/null | sed -n '1p')
  recorded_session=$(sed -n 's/^session=//p' "$path" 2>/dev/null | sed -n '1p')
  [ "$recorded_pid" = "$lock_pid" ] || return 1
  [ -n "$recorded_session" ] && [ "$recorded_session" = "$id" ] || return 1
  fm_harness_pid_alive "$lock_pid" || return 1
}

# True when the session behind the current run owns state dir $1's fleet lock,
# proven by harness ancestry OR by the durable identity the lock records. This
# disjunction is the ONE owner of "may this run mutate this home", so the gate
# that admits a session start and the sweeps it authorizes cannot drift apart.
#
# Ancestry is tried first and left exactly as it was, because it is the only
# proof available for a harness that exposes no session identity. The recorded
# identity is required because ancestry alone cannot answer the question from a
# reparented worker pool. Neither member is a fallback for the other, and a
# caller that needs only one of them still calls that one directly.
fm_session_lock_owned_by_current_session() {  # <state-dir>
  fm_session_lock_owned_by_self "$1" && return 0
  fm_session_lock_owned_by_session_identity "$1"
}
