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

# The harness's own declaration of which pid runs THIS session, when it makes
# one. Claude Code exports CLAUDE_PID into every process it spawns - tool calls
# and hooks alike - naming its own session process (verified 2026-09-23, Claude
# Code 2.1.280). It is consulted only for a pid this process already reached by
# walking its own ancestry and already proved to be a live Claude-shaped
# process, so a stale or inherited value can never introduce a pid that is not
# genuinely a harness ancestor of the caller.
fm_harness_declares_session() {  # <pid>
  [ -n "${CLAUDE_PID:-}" ] || return 1
  case "${CLAUDE_PID}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" = "$CLAUDE_PID" ]
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
#
# A "claude daemon run" or "claude bg-spare" pid is normally a shared background
# layer, never the per-session process this walk exists to find, so it is skipped
# rather than printed. The one exception is a layer the harness itself names as
# this session through CLAUDE_PID: Claude Code claims a pre-warmed "bg-spare"
# process to host a background session and never rewrites its argv, so an
# argv-only reading calls the live session a shared layer and skips it
# (verified 2026-09-23, Claude Code 2.1.280: hook shell -> claude bg-spare ->
# claude bg-pty-host -> launchd, where bg-pty-host passes the spare's own
# --bg-spare argument through, so BOTH layers read as skippable and the walk
# reports nothing at all).
# fm_harness_declares_session is that exception.
#
# An ordinary shared layer is PASSED THROUGH rather than treated as the top of
# the walk: Claude Code's process layout has grown a second such layer
# ("bg-spare") below "bg-pty-host", and a build that puts one of these layers
# closer to the hook than any printable pid must not let that layer's own
# match stop the walk before it ever reaches the outermost interactive
# session above it (verified 2026-09-22, Claude Code 2.1.280: hook shell ->
# claude bg-spare -> claude bg-pty-host -> claude daemon run --origin
# transient -> the outermost interactive claude). Skipping still ends the
# contiguous run at the first genuinely non-harness ancestor once printing
# has started, exactly as before.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      if [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] \
        && ! fm_harness_declares_session "$pid" \
        && printf '%s\n' "$args" | grep -qE 'daemon run|bg-spare'; then
        :
      else
        printf '%s\n' "$pid"
        printed=1
        [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
        extending=1
      fi
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
  if fm_harness_process_matches "$comm" "$args"; then
    if [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] && printf '%s\n' "$args" | grep -qE 'daemon run|bg-spare'; then
      return 1
    fi
    return 0
  fi
  return 1
}

# --- stable session identity -------------------------------------------------
#
# A pid alone cannot answer "is this lock mine?" for Claude, because Claude Code
# can MOVE a running session onto a different process: a session launched as a
# child of an interactive claude is re-hosted onto a daemon-owned background
# worker, keeping its conversation but losing every process link to the pid its
# own session start recorded (observed 2026-09-23 on a home whose auto-arm went
# inert at the moment of that move while the old pid stayed alive, so no
# stale-owner recovery could fire either). The lock therefore records the
# harness's stable session identity beside the pid, in the sibling file
# state/.lock-session, and a re-hosted session recognizes its own lock by that
# identity. A different concurrent session carries a different identity and is
# still refused.

# Print this process's stable harness session identity, or return 1 when the
# harness publishes none. Only Claude is covered: every other adapter keeps the
# unchanged pid-ancestry contract below.
fm_harness_session_identity() {
  local id=${CLAUDE_CODE_SESSION_ID:-}
  [ -n "$id" ] || return 1
  [ "${#id}" -le 128 ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s' "$id"
}

# Print the session identity recorded beside state dir $1's lock, or return 1.
# A malformed or oversized record is rejected rather than compared.
fm_session_lock_recorded_identity() {  # <state-dir>
  local id
  [ -f "$1/.lock-session" ] && [ ! -L "$1/.lock-session" ] || return 1
  IFS= read -r id 2>/dev/null < "$1/.lock-session" || return 1
  [ -n "$id" ] || return 1
  [ "${#id}" -le 128 ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s' "$id"
}

# Record this process's session identity beside state dir $1's lock, or remove
# any stale record when this harness publishes none. Called only by
# bin/fm-lock.sh, in the same acquisition that writes the pid, so the two
# identities are always published together. A write that cannot be completed
# leaves no record, which degrades to the unchanged pid-ancestry contract.
fm_session_lock_publish_identity() {  # <state-dir>
  local state=$1 id tmp
  if ! id=$(fm_harness_session_identity); then
    rm -f "$state/.lock-session" 2>/dev/null || true
    return 0
  fi
  tmp=$(mktemp "$state/.lock-session.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$id" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$state/.lock-session" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# True when state dir $1's lock was written by THIS harness session, proved by
# the recorded session identity rather than by any pid.
fm_session_lock_owned_by_session() {  # <state-dir>
  local recorded mine
  recorded=$(fm_session_lock_recorded_identity "$1") || return 1
  mine=$(fm_harness_session_identity) || return 1
  [ "$recorded" = "$mine" ]
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_pid_is_self() {  # <state-dir>
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

# True when this process runs inside the session that owns state dir $1's lock,
# by either identity the lock carries: the recorded session identity, or the
# pid-ancestry membership above. Both fail closed, so an unreadable lock, an
# unresolvable ancestry, and a foreign session all remain unowned.
fm_session_lock_owned_by_self() {  # <state-dir>
  local state=$1
  case "$(cat "$state/.lock" 2>/dev/null || true)" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_session_lock_owned_by_session "$state" && return 0
  fm_session_lock_pid_is_self "$state"
}

# True when $1 is a live process that looks like a verified harness, INCLUDING a
# shared background layer. Used only for a lock that carries a session identity,
# where the recorded pid is known to have been a real session: Claude's
# background-hosted sessions keep the argv of the spare they were claimed from,
# so the stricter predicate above would report a live owner as dead and let a
# competing session take the home.
fm_harness_pid_live_any() {  # <pid>
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when the pid recorded in state dir $1's lock is still a live harness
# session. This is the ONE owner of the "is the recorded lock holder alive?"
# question that every acquisition and recovery path asks.
fm_session_lock_owner_alive() {  # <state-dir>
  local state=$1 pid
  pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$pid" && return 0
  fm_session_lock_recorded_identity "$state" >/dev/null || return 1
  fm_harness_pid_live_any "$pid"
}
