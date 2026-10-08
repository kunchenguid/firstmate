#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# Claude session id below matches the id recorded beside a live lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

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
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
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

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted Claude session and its recorded pid is still
# a live harness. Membership is the honest ancestry test, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
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
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when state dir $1 records a live verified harness outside this process's
# contiguous harness ancestry that was not recorded by this same trusted Claude
# session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, and ancestry-uncertain locks are not foreign-owner
# evidence.
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
  fm_session_lock_same_session "$state" "$pids" && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: the recorded pid is a live verified harness.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness. Existence of a lock file, a
# session record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  case "$pid" in
    ''|*[!0-9]*)
      FM_LOCK_INSPECT_STATE=unknown
      return 0
      ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}

# --- fresh-launch reservation identity -------------------------------------
#
# A startup pull runs before a harness exists, so it cannot manufacture the
# session lock above.  It instead records a short-lived reservation beside that
# lock while holding the same state/.lock.acquire mutex.  The record binds the
# physical home, its directory identity, the launcher's kernel process
# identity, and a random invocation token.  bin/fm-prelaunch.sh is the only
# reservation writer; bin/fm-lock.sh is the only reservation-to-session-lock
# handoff writer.  The helpers here own their shared parsing and identity rules.

FM_PRELAUNCH_RESERVATION_FILE='.prelaunch-reservation'
FM_PRELAUNCH_HANDOFF_FILE='.prelaunch-handoff'

# Run a reservation identity read against the named checkout, never a Git
# directory, index, object store, namespace, or config injected by the
# launcher's ambient shell and inherited by its child harness.
fm_prelaunch_git() {
  (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_ATTR_SOURCE
    unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    command git "$@"
  )
}

fm_prelaunch_hash_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk 'NF {print $1; exit}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk 'NF {print $1; exit}'
  else
    return 1
  fi
}

# Print the device:inode identity of a physical directory.
fm_prelaunch_directory_identity() {  # <directory>
  local dir=$1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%d:%i' "$dir" 2>/dev/null
  else
    LC_ALL=C stat -c '%d:%i' "$dir" 2>/dev/null
  fi
}

# Print the device:inode identity of a standalone checkout's own git directory.
# A linked worktree has distinct git-dir/common-dir paths and is refused before
# any reservation can be written.
fm_prelaunch_source_identity() {  # <physical-home>
  local home=$1 top git_dir common_dir git_dir_physical common_physical
  local directory_identity default_ref default_branch remote_url remote_hash branch
  top=$(fm_prelaunch_git -C "$home" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(CDPATH='' cd -- "$top" 2>/dev/null && pwd -P) || return 1
  [ "$top" = "$home" ] || return 1
  git_dir=$(fm_prelaunch_git -C "$home" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common_dir=$(fm_prelaunch_git -C "$home" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  git_dir_physical=$(CDPATH='' cd -- "$git_dir" 2>/dev/null && pwd -P) || return 1
  common_physical=$(CDPATH='' cd -- "$common_dir" 2>/dev/null && pwd -P) || return 1
  [ "$git_dir_physical" = "$common_physical" ] || return 1
  directory_identity=$(fm_prelaunch_directory_identity "$common_physical") || return 1
  default_ref=$(fm_prelaunch_git -C "$home" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$default_ref" ]; then
    default_branch=${default_ref#origin/}
  else
    default_branch=
    for branch in main master; do
      if fm_prelaunch_git -C "$home" show-ref --verify --quiet "refs/heads/$branch"; then
        default_branch=$branch
        break
      fi
    done
  fi
  [ -n "$default_branch" ] || return 1
  case "$default_branch" in *$'\n'*|*$'\r'*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  remote_url=$(fm_prelaunch_git -C "$home" remote get-url origin 2>/dev/null) || return 1
  remote_hash=$(fm_prelaunch_hash_text "$remote_url") || return 1
  printf '%s:default=%s:origin-sha256=%s\n' "$directory_identity" "$default_branch" "$remote_hash"
}

# Require the caller's spelling to be the exact absolute physical home.
fm_prelaunch_physical_home() {  # <home>
  local home=$1 physical
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$home" in *[[:cntrl:]]*) return 1 ;; esac
  physical=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  [ "$home" = "$physical" ] || return 1
  printf '%s\n' "$physical"
}

fm_prelaunch_token_valid() {  # <token>
  local token=$1 length=${#1}
  [ "$length" -ge 32 ] && [ "$length" -le 256 ] || return 1
  case "$token" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}

# True when process $1 is this shell or an ancestor of it.  This is generic
# process ancestry, not harness ancestry: reserve/update/release run before the
# child harness exists, while fm-lock.sh runs below that child.  The kernel
# identity check below separately prevents a recycled ancestor PID from
# satisfying ownership.
fm_prelaunch_owner_is_ancestor() {  # <owner-pid>
  local owner=$1 pid parent
  case "$owner" in ''|*[!0-9]*|0) return 1 ;; esac
  if command -v fm_current_pid >/dev/null 2>&1; then
    fm_current_pid pid || return 1
  else
    pid=$$
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 \
    17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 \
    33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 \
    49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64; do
    [ "$pid" = "$owner" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$parent" in ''|*[!0-9]*|0) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
  done
  return 1
}

# True when $2 is $1 or a descendant of it.  attach uses this from the launcher
# side, where the blocked child is a sibling of the helper process rather than
# an ancestor of it.
fm_prelaunch_pid_is_descendant() {  # <ancestor-pid> <descendant-pid>
  local ancestor=$1 pid=$2 parent
  case "$ancestor:$pid" in *[!0-9:]*|:*|*:) return 1 ;; esac
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 \
    17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 \
    33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 \
    49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64; do
    [ "$pid" = "$ancestor" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$parent" in ''|*[!0-9]*|0) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
  done
  return 1
}

# Print the kernel process generation that survives exec.  fm_pid_identity also
# binds argv, which is correct for the launcher but intentionally changes when
# the blocked bootstrap execs the vendor.  The attached child therefore records
# only start time/generation plus PID, then verifies harness identity separately
# during the native lock handoff.
fm_prelaunch_pid_generation() {  # <pid>
  local pid=$1 proc_root stat_line starttime out
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  out=${out#"${out%%[![:space:]]*}"}
  [ -n "$out" ] || return 1
  printf 'lstart=%s\n' "$out"
}

# Reservation parser output.  The record is deliberately an exact ordered
# format rather than shell source, so hostile bytes are data and extra fields
# make the state unknown instead of being silently ignored.
FM_PRELAUNCH_RECORD_HOME=
FM_PRELAUNCH_RECORD_HOME_IDENTITY=
FM_PRELAUNCH_RECORD_SOURCE_IDENTITY=
FM_PRELAUNCH_RECORD_OWNER_PID=
FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH=
FM_PRELAUNCH_RECORD_TOKEN_HASH=
FM_PRELAUNCH_RECORD_CHILD_PID=
FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH=
FM_PRELAUNCH_RECORD_SOURCE_COMMIT=
FM_PRELAUNCH_RECORD_TARGET_COMMIT=
FM_PRELAUNCH_RECORD_UPDATE_STATUS=
FM_PRELAUNCH_RECORD_CREATED_AT=
fm_prelaunch_reservation_read() {  # <state>
  local file="$1/$FM_PRELAUNCH_RESERVATION_FILE" l1 l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12 l13 _extra
  FM_PRELAUNCH_RECORD_HOME=
  FM_PRELAUNCH_RECORD_HOME_IDENTITY=
  FM_PRELAUNCH_RECORD_SOURCE_IDENTITY=
  FM_PRELAUNCH_RECORD_OWNER_PID=
  FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH=
  FM_PRELAUNCH_RECORD_TOKEN_HASH=
  FM_PRELAUNCH_RECORD_CHILD_PID=
  FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH=
  FM_PRELAUNCH_RECORD_SOURCE_COMMIT=
  FM_PRELAUNCH_RECORD_TARGET_COMMIT=
  FM_PRELAUNCH_RECORD_UPDATE_STATUS=
  FM_PRELAUNCH_RECORD_CREATED_AT=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  {
    IFS= read -r l1 && IFS= read -r l2 && IFS= read -r l3 \
      && IFS= read -r l4 && IFS= read -r l5 && IFS= read -r l6 \
      && IFS= read -r l7 && IFS= read -r l8 && IFS= read -r l9 \
      && IFS= read -r l10 && IFS= read -r l11 && IFS= read -r l12 \
      && IFS= read -r l13 && ! IFS= read -r _extra
  } < "$file" || return 1
  [ "$l1" = 'schema=fm-prelaunch-reservation.v1' ] || return 1
  case "$l2" in home=*) FM_PRELAUNCH_RECORD_HOME=${l2#home=} ;; *) return 1 ;; esac
  case "$l3" in home_identity=*) FM_PRELAUNCH_RECORD_HOME_IDENTITY=${l3#home_identity=} ;; *) return 1 ;; esac
  case "$l4" in source_identity=*) FM_PRELAUNCH_RECORD_SOURCE_IDENTITY=${l4#source_identity=} ;; *) return 1 ;; esac
  case "$l5" in owner_pid=*) FM_PRELAUNCH_RECORD_OWNER_PID=${l5#owner_pid=} ;; *) return 1 ;; esac
  case "$l6" in owner_identity_sha256=*) FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH=${l6#owner_identity_sha256=} ;; *) return 1 ;; esac
  case "$l7" in token_sha256=*) FM_PRELAUNCH_RECORD_TOKEN_HASH=${l7#token_sha256=} ;; *) return 1 ;; esac
  case "$l8" in child_pid=*) FM_PRELAUNCH_RECORD_CHILD_PID=${l8#child_pid=} ;; *) return 1 ;; esac
  case "$l9" in child_generation_sha256=*) FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH=${l9#child_generation_sha256=} ;; *) return 1 ;; esac
  case "$l10" in source_commit=*) FM_PRELAUNCH_RECORD_SOURCE_COMMIT=${l10#source_commit=} ;; *) return 1 ;; esac
  case "$l11" in target_commit=*) FM_PRELAUNCH_RECORD_TARGET_COMMIT=${l11#target_commit=} ;; *) return 1 ;; esac
  case "$l12" in update_status=*) FM_PRELAUNCH_RECORD_UPDATE_STATUS=${l12#update_status=} ;; *) return 1 ;; esac
  case "$l13" in created_at=*) FM_PRELAUNCH_RECORD_CREATED_AT=${l13#created_at=} ;; *) return 1 ;; esac
  case "$FM_PRELAUNCH_RECORD_OWNER_PID" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$FM_PRELAUNCH_RECORD_HOME_IDENTITY" in *:* ) ;; *) return 1 ;; esac
  case "$FM_PRELAUNCH_RECORD_SOURCE_IDENTITY" in *:* ) ;; *) return 1 ;; esac
  case "$FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH$FM_PRELAUNCH_RECORD_TOKEN_HASH" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH}" -eq 64 ] || return 1
  [ "${#FM_PRELAUNCH_RECORD_TOKEN_HASH}" -eq 64 ] || return 1
  if [ -n "$FM_PRELAUNCH_RECORD_CHILD_PID$FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH" ]; then
    case "$FM_PRELAUNCH_RECORD_CHILD_PID" in ''|*[!0-9]*|0) return 1 ;; esac
    case "$FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH" in *[!0-9a-f]*) return 1 ;; esac
    [ "${#FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH}" -eq 64 ] || return 1
  fi
  case "$FM_PRELAUNCH_RECORD_SOURCE_COMMIT" in ''|*[!0-9a-f]*) return 1 ;; esac
  case "$FM_PRELAUNCH_RECORD_TARGET_COMMIT" in ''|*[!0-9a-f]*)
    [ -z "$FM_PRELAUNCH_RECORD_TARGET_COMMIT" ] || return 1 ;;
  esac
  case "$FM_PRELAUNCH_RECORD_UPDATE_STATUS" in pending|current|updated) ;; *) return 1 ;; esac
  case "$FM_PRELAUNCH_RECORD_CREATED_AT" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# shellcheck disable=SC2034 # Output globals, read by reservation callers.
FM_PRELAUNCH_INSPECT_STATE=unknown
# shellcheck disable=SC2034 # Output global, useful in fail-closed diagnostics/tests.
FM_PRELAUNCH_INSPECT_REASON=unknown
FM_PRELAUNCH_CHILD_STATE=absent
fm_prelaunch_attached_child_inspect() {
  local generation generation_hash
  FM_PRELAUNCH_CHILD_STATE=absent
  [ -n "$FM_PRELAUNCH_RECORD_CHILD_PID" ] || return 0
  if kill -0 "$FM_PRELAUNCH_RECORD_CHILD_PID" 2>/dev/null; then
    generation=$(fm_prelaunch_pid_generation "$FM_PRELAUNCH_RECORD_CHILD_PID" 2>/dev/null) || {
      FM_PRELAUNCH_CHILD_STATE=unknown
      return 0
    }
    generation_hash=$(fm_prelaunch_hash_text "$generation") || {
      FM_PRELAUNCH_CHILD_STATE=unknown
      return 0
    }
    if [ "$generation_hash" = "$FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH" ]; then
      FM_PRELAUNCH_CHILD_STATE=live
    else
      FM_PRELAUNCH_CHILD_STATE=stale
    fi
    return 0
  fi
  if ps -o comm= -p "$FM_PRELAUNCH_RECORD_CHILD_PID" >/dev/null 2>&1; then
    FM_PRELAUNCH_CHILD_STATE=unknown
  else
    FM_PRELAUNCH_CHILD_STATE=stale
  fi
}

fm_prelaunch_owner_gone_state() {
  fm_prelaunch_attached_child_inspect
  case "$FM_PRELAUNCH_CHILD_STATE" in
    live)
      FM_PRELAUNCH_INSPECT_STATE=live
      FM_PRELAUNCH_INSPECT_REASON='verified-live-attached-child'
      ;;
    unknown)
      FM_PRELAUNCH_INSPECT_STATE=unknown
      FM_PRELAUNCH_INSPECT_REASON='attached-child-identity-unknown'
      ;;
    absent|stale)
      FM_PRELAUNCH_INSPECT_STATE=stale
      FM_PRELAUNCH_INSPECT_REASON='owner-and-attached-child-dead'
      ;;
  esac
}

fm_prelaunch_reservation_inspect() {  # <state> <physical-home>
  local state=$1 home=$2 file="$1/$FM_PRELAUNCH_RESERVATION_FILE"
  local home_identity source_identity current_identity current_hash
  FM_PRELAUNCH_INSPECT_STATE=unknown
  FM_PRELAUNCH_INSPECT_REASON='unknown'
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    FM_PRELAUNCH_INSPECT_STATE=free
    FM_PRELAUNCH_INSPECT_REASON=absent
    return 0
  fi
  if ! fm_prelaunch_reservation_read "$state"; then
    FM_PRELAUNCH_INSPECT_REASON='unreadable-or-malformed'
    return 0
  fi
  home_identity=$(fm_prelaunch_directory_identity "$home") || {
    FM_PRELAUNCH_INSPECT_REASON='home-identity-unreadable'
    return 0
  }
  if [ "$FM_PRELAUNCH_RECORD_HOME" != "$home" ] \
    || [ "$FM_PRELAUNCH_RECORD_HOME_IDENTITY" != "$home_identity" ]; then
    FM_PRELAUNCH_INSPECT_REASON='home-identity-mismatch'
    return 0
  fi
  source_identity=$(fm_prelaunch_source_identity "$home") || {
    FM_PRELAUNCH_INSPECT_REASON='source-identity-unreadable'
    return 0
  }
  if [ "$FM_PRELAUNCH_RECORD_SOURCE_IDENTITY" != "$source_identity" ]; then
    FM_PRELAUNCH_INSPECT_REASON='source-identity-mismatch'
    return 0
  fi
  if kill -0 "$FM_PRELAUNCH_RECORD_OWNER_PID" 2>/dev/null; then
    current_identity=$(fm_pid_identity "$FM_PRELAUNCH_RECORD_OWNER_PID" 2>/dev/null) || {
      FM_PRELAUNCH_INSPECT_REASON='owner-identity-unreadable'
      return 0
    }
    current_hash=$(fm_prelaunch_hash_text "$current_identity") || {
      FM_PRELAUNCH_INSPECT_REASON='hash-unavailable'
      return 0
    }
    if [ "$current_hash" = "$FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH" ]; then
      FM_PRELAUNCH_INSPECT_STATE=live
      FM_PRELAUNCH_INSPECT_REASON='verified-live-owner'
    else
      # The recorded owner is gone and its PID has been reused.  The kernel
      # identity mismatch is positive stale-owner evidence, never authorization
      # for the process currently carrying that number.
      fm_prelaunch_owner_gone_state
    fi
    return 0
  fi
  if ps -o comm= -p "$FM_PRELAUNCH_RECORD_OWNER_PID" >/dev/null 2>&1; then
    # shellcheck disable=SC2034 # Output global, useful to diagnostics/tests.
    FM_PRELAUNCH_INSPECT_REASON='owner-liveness-unknown'
    return 0
  fi
  fm_prelaunch_owner_gone_state
  return 0
}

fm_prelaunch_reservation_authenticated() {  # <state> <physical-home> <owner-pid> <token>
  local state=$1 home=$2 owner=$3 token=$4 token_hash current_identity current_hash
  fm_prelaunch_token_valid "$token" || return 1
  fm_prelaunch_reservation_inspect "$state" "$home"
  [ "$FM_PRELAUNCH_INSPECT_STATE" = live ] || return 1
  [ "$FM_PRELAUNCH_RECORD_OWNER_PID" = "$owner" ] || return 1
  current_identity=$(fm_pid_identity "$owner" 2>/dev/null) || return 1
  current_hash=$(fm_prelaunch_hash_text "$current_identity") || return 1
  [ "$FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH" = "$current_hash" ] || return 1
  token_hash=$(fm_prelaunch_hash_text "$token") || return 1
  [ "$FM_PRELAUNCH_RECORD_TOKEN_HASH" = "$token_hash" ] || return 1
  fm_prelaunch_owner_is_ancestor "$owner"
}

# Authenticate the attached child after its bootstrap exec.  Its PID generation
# is exec-stable; the caller still has to prove genuine harness ancestry before
# fm-lock exchanges the reservation for a session lock.
fm_prelaunch_attached_child_authenticated() {  # <state> <physical-home> <token>
  local state=$1 home=$2 token=$3 token_hash
  fm_prelaunch_token_valid "$token" || return 1
  fm_prelaunch_reservation_inspect "$state" "$home"
  [ "$FM_PRELAUNCH_INSPECT_STATE" = live ] || return 1
  token_hash=$(fm_prelaunch_hash_text "$token") || return 1
  [ "$FM_PRELAUNCH_RECORD_TOKEN_HASH" = "$token_hash" ] || return 1
  fm_prelaunch_attached_child_inspect
  [ "$FM_PRELAUNCH_CHILD_STATE" = live ] || return 1
  fm_prelaunch_owner_is_ancestor "$FM_PRELAUNCH_RECORD_CHILD_PID"
}

fm_prelaunch_reservation_write() {  # <state> <home> <home-id> <source-id> <owner> <owner-id-hash> <token-hash> <child-pid> <child-generation-hash> <source> <target> <status> <created-at>
  local state=$1 home=$2 home_identity=$3 source_identity=$4 owner=$5 owner_hash=$6 token_hash=$7
  local child_pid=$8 child_generation_hash=$9 source=${10} target=${11}
  local update_status=${12} created_at=${13} file tmp
  file="$state/$FM_PRELAUNCH_RESERVATION_FILE"
  [ ! -L "$file" ] || return 1
  tmp=$(umask 077; mktemp "$state/.prelaunch-reservation.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf 'schema=fm-prelaunch-reservation.v1\n'
    printf 'home=%s\n' "$home"
    printf 'home_identity=%s\n' "$home_identity"
    printf 'source_identity=%s\n' "$source_identity"
    printf 'owner_pid=%s\n' "$owner"
    printf 'owner_identity_sha256=%s\n' "$owner_hash"
    printf 'token_sha256=%s\n' "$token_hash"
    printf 'child_pid=%s\n' "$child_pid"
    printf 'child_generation_sha256=%s\n' "$child_generation_hash"
    printf 'source_commit=%s\n' "$source"
    printf 'target_commit=%s\n' "$target"
    printf 'update_status=%s\n' "$update_status"
    printf 'created_at=%s\n' "$created_at"
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Publish the verified child handoff before removing the reservation.  A crash
# between these operations leaves both records, which the same child can finish
# idempotently while holding the claim mutex; it never opens a takeover window.
fm_prelaunch_handoff_publish() {  # <state> <lock-pid>
  local state=$1 lock_pid=$2 file="$1/$FM_PRELAUNCH_HANDOFF_FILE" reservation tmp handed_at
  reservation="$state/$FM_PRELAUNCH_RESERVATION_FILE"
  [ ! -L "$file" ] || return 1
  case "$lock_pid" in ''|*[!0-9]*|0) return 1 ;; esac
  handed_at=$(date +%s) || return 1
  tmp=$(umask 077; mktemp "$state/.prelaunch-handoff.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf 'schema=fm-prelaunch-handoff.v1\n'
    printf 'home=%s\n' "$FM_PRELAUNCH_RECORD_HOME"
    printf 'home_identity=%s\n' "$FM_PRELAUNCH_RECORD_HOME_IDENTITY"
    printf 'source_identity=%s\n' "$FM_PRELAUNCH_RECORD_SOURCE_IDENTITY"
    printf 'owner_pid=%s\n' "$FM_PRELAUNCH_RECORD_OWNER_PID"
    printf 'owner_identity_sha256=%s\n' "$FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH"
    printf 'token_sha256=%s\n' "$FM_PRELAUNCH_RECORD_TOKEN_HASH"
    printf 'child_pid=%s\n' "$FM_PRELAUNCH_RECORD_CHILD_PID"
    printf 'child_generation_sha256=%s\n' "$FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH"
    printf 'lock_pid=%s\n' "$lock_pid"
    printf 'source_commit=%s\n' "$FM_PRELAUNCH_RECORD_SOURCE_COMMIT"
    printf 'target_commit=%s\n' "$FM_PRELAUNCH_RECORD_TARGET_COMMIT"
    printf 'update_status=%s\n' "$FM_PRELAUNCH_RECORD_UPDATE_STATUS"
    printf 'handed_at=%s\n' "$handed_at"
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$reservation" || return 1
}

FM_PRELAUNCH_HANDOFF_HOME=
FM_PRELAUNCH_HANDOFF_HOME_IDENTITY=
FM_PRELAUNCH_HANDOFF_SOURCE_IDENTITY=
FM_PRELAUNCH_HANDOFF_OWNER_PID=
FM_PRELAUNCH_HANDOFF_OWNER_IDENTITY_HASH=
FM_PRELAUNCH_HANDOFF_TOKEN_HASH=
FM_PRELAUNCH_HANDOFF_CHILD_PID=
FM_PRELAUNCH_HANDOFF_CHILD_GENERATION_HASH=
FM_PRELAUNCH_HANDOFF_LOCK_PID=
FM_PRELAUNCH_HANDOFF_SOURCE_COMMIT=
FM_PRELAUNCH_HANDOFF_TARGET_COMMIT=
FM_PRELAUNCH_HANDOFF_UPDATE_STATUS=
FM_PRELAUNCH_HANDOFF_HANDED_AT=
fm_prelaunch_handoff_read() {  # <state>
  local file="$1/$FM_PRELAUNCH_HANDOFF_FILE"
  local l1 l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12 l13 l14 _extra
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  {
    IFS= read -r l1 && IFS= read -r l2 && IFS= read -r l3 \
      && IFS= read -r l4 && IFS= read -r l5 && IFS= read -r l6 \
      && IFS= read -r l7 && IFS= read -r l8 && IFS= read -r l9 \
      && IFS= read -r l10 && IFS= read -r l11 && IFS= read -r l12 \
      && IFS= read -r l13 && IFS= read -r l14 \
      && ! IFS= read -r _extra
  } < "$file" || return 1
  [ "$l1" = 'schema=fm-prelaunch-handoff.v1' ] || return 1
  case "$l2" in home=*) FM_PRELAUNCH_HANDOFF_HOME=${l2#home=} ;; *) return 1 ;; esac
  case "$l3" in home_identity=*) FM_PRELAUNCH_HANDOFF_HOME_IDENTITY=${l3#home_identity=} ;; *) return 1 ;; esac
  case "$l4" in source_identity=*) FM_PRELAUNCH_HANDOFF_SOURCE_IDENTITY=${l4#source_identity=} ;; *) return 1 ;; esac
  case "$l5" in owner_pid=*) FM_PRELAUNCH_HANDOFF_OWNER_PID=${l5#owner_pid=} ;; *) return 1 ;; esac
  case "$l6" in owner_identity_sha256=*) FM_PRELAUNCH_HANDOFF_OWNER_IDENTITY_HASH=${l6#owner_identity_sha256=} ;; *) return 1 ;; esac
  case "$l7" in token_sha256=*) FM_PRELAUNCH_HANDOFF_TOKEN_HASH=${l7#token_sha256=} ;; *) return 1 ;; esac
  case "$l8" in child_pid=*) FM_PRELAUNCH_HANDOFF_CHILD_PID=${l8#child_pid=} ;; *) return 1 ;; esac
  case "$l9" in child_generation_sha256=*) FM_PRELAUNCH_HANDOFF_CHILD_GENERATION_HASH=${l9#child_generation_sha256=} ;; *) return 1 ;; esac
  case "$l10" in lock_pid=*) FM_PRELAUNCH_HANDOFF_LOCK_PID=${l10#lock_pid=} ;; *) return 1 ;; esac
  case "$l11" in source_commit=*) FM_PRELAUNCH_HANDOFF_SOURCE_COMMIT=${l11#source_commit=} ;; *) return 1 ;; esac
  case "$l12" in target_commit=*) FM_PRELAUNCH_HANDOFF_TARGET_COMMIT=${l12#target_commit=} ;; *) return 1 ;; esac
  case "$l13" in update_status=*) FM_PRELAUNCH_HANDOFF_UPDATE_STATUS=${l13#update_status=} ;; *) return 1 ;; esac
  case "$l14" in handed_at=*) FM_PRELAUNCH_HANDOFF_HANDED_AT=${l14#handed_at=} ;; *) return 1 ;; esac
  case "$FM_PRELAUNCH_HANDOFF_OWNER_PID:$FM_PRELAUNCH_HANDOFF_LOCK_PID" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  case "$FM_PRELAUNCH_HANDOFF_OWNER_IDENTITY_HASH$FM_PRELAUNCH_HANDOFF_TOKEN_HASH" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#FM_PRELAUNCH_HANDOFF_OWNER_IDENTITY_HASH}" -eq 64 ] || return 1
  [ "${#FM_PRELAUNCH_HANDOFF_TOKEN_HASH}" -eq 64 ] || return 1
  case "$FM_PRELAUNCH_HANDOFF_CHILD_PID" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$FM_PRELAUNCH_HANDOFF_CHILD_GENERATION_HASH" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#FM_PRELAUNCH_HANDOFF_CHILD_GENERATION_HASH}" -eq 64 ] || return 1
  case "$FM_PRELAUNCH_HANDOFF_SOURCE_COMMIT$FM_PRELAUNCH_HANDOFF_TARGET_COMMIT" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  case "$FM_PRELAUNCH_HANDOFF_UPDATE_STATUS" in current|updated) ;; *) return 1 ;; esac
  case "$FM_PRELAUNCH_HANDOFF_HANDED_AT" in ''|*[!0-9]*) return 1 ;; esac
}

# Authenticate an already-published handoff for hook reporting or idempotent
# release.  Success exposes only commit/status globals, never the token itself.
fm_prelaunch_handoff_authenticated() {  # <state> <physical-home> <owner-pid> <token>
  local state=$1 home=$2 owner=$3 token=$4 home_identity source_identity current_identity current_hash token_hash lock_pid
  local generation generation_hash owner_authenticated=0 child_authenticated=0
  fm_prelaunch_token_valid "$token" || return 1
  fm_prelaunch_handoff_read "$state" || return 1
  [ "$FM_PRELAUNCH_HANDOFF_HOME" = "$home" ] || return 1
  home_identity=$(fm_prelaunch_directory_identity "$home") || return 1
  [ "$FM_PRELAUNCH_HANDOFF_HOME_IDENTITY" = "$home_identity" ] || return 1
  source_identity=$(fm_prelaunch_source_identity "$home") || return 1
  [ "$FM_PRELAUNCH_HANDOFF_SOURCE_IDENTITY" = "$source_identity" ] || return 1
  [ "$FM_PRELAUNCH_HANDOFF_OWNER_PID" = "$owner" ] || return 1
  token_hash=$(fm_prelaunch_hash_text "$token") || return 1
  [ "$FM_PRELAUNCH_HANDOFF_TOKEN_HASH" = "$token_hash" ] || return 1
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null) || return 1
  [ "$FM_PRELAUNCH_HANDOFF_LOCK_PID" = "$lock_pid" ] || return 1

  # The launcher normally stays above its child, so its full PID identity is
  # the strongest receipt authentication and also supports the launcher's
  # idempotent release after handoff.
  if current_identity=$(fm_pid_identity "$owner" 2>/dev/null) \
    && current_hash=$(fm_prelaunch_hash_text "$current_identity") \
    && [ "$FM_PRELAUNCH_HANDOFF_OWNER_IDENTITY_HASH" = "$current_hash" ] \
    && fm_prelaunch_owner_is_ancestor "$owner"; then
    owner_authenticated=1
  fi

  # If the launcher dies after attach, the recorded child generation is the
  # durable recovery identity.  Only that still-live attached harness ancestry
  # may authenticate the receipt; the copied owner hint and token alone remain
  # insufficient from an unrelated process.
  if generation=$(fm_prelaunch_pid_generation "$FM_PRELAUNCH_HANDOFF_CHILD_PID" 2>/dev/null) \
    && generation_hash=$(fm_prelaunch_hash_text "$generation") \
    && [ "$FM_PRELAUNCH_HANDOFF_CHILD_GENERATION_HASH" = "$generation_hash" ] \
    && fm_prelaunch_owner_is_ancestor "$FM_PRELAUNCH_HANDOFF_CHILD_PID"; then
    child_authenticated=1
  fi
  [ "$owner_authenticated" -eq 1 ] || [ "$child_authenticated" -eq 1 ]
}
