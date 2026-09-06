#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock plus its owner
# record state/.lock-owner; bin/fm-claude-stop-autoarm.sh and
# bin/fm-turnend-guard-cursor.sh use it to prove a turn-end hook fires inside the
# lock-owning primary session before either may arm or rewake.
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

# --- owner record: which harness process holds THIS home's lock --------------
#
# A bare pid cannot answer that question. Every long-lived process carrying a
# verified harness command name satisfies the name tables above - the ChatGPT
# desktop app ships its Codex app-server as exactly such a process, unrelated to
# any firstmate home - and a pid recycled after a reboot lands on whatever came
# next. Either one used to be accepted as a live lock owner, taking a whole home
# read-only with nothing on screen tying the refusal to a real cause.
#
# state/.lock-owner closes that gap. It is written only by an acquire in THIS
# state directory, so a process that never acquired here cannot be an owner, and
# it pins the record to one exact process through fm_pid_identity, so a recycled
# pid fails verification instead of inheriting the lock. The lock file itself
# stays a bare pid: every other reader of state/.lock is unchanged.

# fm_pid_identity is the fleet's one portable process-identity owner and lives in
# the wake library. Load it only when a lock is actually being recorded or
# verified, so sourcing this file keeps having no side effects.
_fm_session_lock_require_identity() {
  command -v fm_pid_identity >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$(dirname -- "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
}

# Print a single-line description of what pid $1 is actually running, for an
# operator who has to go find it. A bare number told the last operator nothing.
fm_session_lock_describe_pid() {  # <pid>
  local pid=$1 text
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  text=$(COLUMNS=10000 LC_ALL=C ps -o args= -p "$pid" 2>/dev/null | sed -n '1p')
  [ -n "$text" ] || text=$(LC_ALL=C ps -o comm= -p "$pid" 2>/dev/null | sed -n '1p')
  printf '%s' "$text" | tr -d '[:cntrl:]' | cut -c1-160
}

# fm_session_lock_record_owner <state> <pid>
# Record <pid> as the verified owner of this home's session lock. Written by
# every acquire and replaced in place; never removed, because a record naming a
# process that is gone already classifies as stale.
#
# An identity that cannot be read records as empty rather than failing the
# acquire. Being unable to describe a process is a reason to be careful about
# taking a home AWAY from a session, never a reason to refuse to give a session
# its own home: a hard failure here would put the whole session read-only with
# no competing lock involved at all. The caution belongs in the verification
# below, which never reclaims from an owner it cannot disprove.
fm_session_lock_record_owner() {  # <state> <pid>
  local state=$1 pid=$2 identity acquired tmp
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "$state" ] || return 1
  _fm_session_lock_require_identity
  identity=$(fm_pid_identity "$pid" 2>/dev/null | tr -d '\n' || true)
  acquired=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  tmp=$(mktemp "$state/.lock-owner.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf 'pid=%s\n' "$pid"
    printf 'acquired=%s\n' "$acquired"
    printf 'identity=%s\n' "$identity"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$state/.lock-owner" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# fm_session_lock_live_owner <state>
# True when state/.lock is held by a firstmate session that is verifiably still
# running here: the pid is live, it is a verified harness, an owner record
# written in THIS home names that same pid, and the process now at that pid is
# still the one that record pinned.
#
# Sets FM_LOCK_OWNER_STATUS to what a caller must tell the operator:
#   free        no lock file at all
#   malformed   the lock is not a regular file, or carries no numeric pid
#   dead        that pid is gone, or is no longer a verified harness
#   unrecorded  no session in this home ever recorded that live pid as owner
#   unverified  this home's owner record names a different pid
#   reused      an unrelated process now occupies that pid
#   live        a verified live owner
# and FM_LOCK_OWNER_PID/COMMAND to the detail a refusal or reclaim needs, plus
# FM_LOCK_OWNER_SINCE only once the record is proven to describe the process
# now at that pid - a record left by a previous owner says nothing about when
# the process that inherited its pid started.
#
# Only a genuine identity MISMATCH demotes an owner. An identity that cannot be
# read at all leaves a recorded, live, harness-named owner holding the lock, so
# an unreadable process table can never hand a live session's home to a second
# one.
#
# unrecorded is missing evidence, NOT evidence of absence: it is exactly what a
# still-running session that acquired its lock before owner records existed
# looks like. It is kept apart from unverified and reused - the two statuses
# that actually prove the process at that pid is not the one that took the lock
# - so a caller can refuse rather than evict a live session it cannot vouch for.
FM_LOCK_OWNER_STATUS=free
FM_LOCK_OWNER_PID=
FM_LOCK_OWNER_COMMAND=
FM_LOCK_OWNER_SINCE=
fm_session_lock_live_owner() {  # <state>
  local state=$1 lock owner lock_pid rec_pid='' rec_identity='' rec_acquired=''
  local live_identity line key value
  lock="$state/.lock"
  owner="$state/.lock-owner"
  FM_LOCK_OWNER_STATUS=free
  FM_LOCK_OWNER_PID=
  FM_LOCK_OWNER_COMMAND=
  FM_LOCK_OWNER_SINCE=
  [ -e "$lock" ] || [ -L "$lock" ] || return 1
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_OWNER_STATUS=malformed
    return 1
  fi
  IFS= read -r lock_pid < "$lock" 2>/dev/null || lock_pid=''
  case "$lock_pid" in
    ''|*[!0-9]*) FM_LOCK_OWNER_STATUS=malformed; return 1 ;;
  esac
  FM_LOCK_OWNER_PID=$lock_pid
  FM_LOCK_OWNER_COMMAND=$(fm_session_lock_describe_pid "$lock_pid")
  fm_harness_pid_alive "$lock_pid" || { FM_LOCK_OWNER_STATUS=dead; return 1; }
  if [ -f "$owner" ] && [ ! -L "$owner" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      key=${line%%=*}
      value=${line#*=}
      case "$key" in
        pid) rec_pid=$value ;;
        acquired) rec_acquired=$value ;;
        identity) rec_identity=$value ;;
      esac
    done < "$owner"
  fi
  if [ -n "$rec_pid" ] && [ "$rec_pid" != "$lock_pid" ]; then
    FM_LOCK_OWNER_STATUS=unverified
    return 1
  fi
  if [ -z "$rec_pid" ]; then
    FM_LOCK_OWNER_STATUS=unrecorded
    return 1
  fi
  _fm_session_lock_require_identity
  live_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null | tr -d '\n' || true)
  if [ -n "$rec_identity" ] && [ -n "$live_identity" ] && [ "$rec_identity" != "$live_identity" ]; then
    FM_LOCK_OWNER_STATUS=reused
    return 1
  fi
  FM_LOCK_OWNER_SINCE=$rec_acquired
  FM_LOCK_OWNER_STATUS=live
  return 0
}
