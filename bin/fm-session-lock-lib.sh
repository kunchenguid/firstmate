#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of "may this run act for the session that holds this home's lock?",
# over two independent proofs and the disjunction that arbitrates them. Ancestry
# asks whether the current process descends from the verified harness the lock
# records. Delivered Claude session identity instead asks whether the session
# that emitted this hook event is the one the lock names, which is needed
# because Claude Code serves hook commands from a shared per-user worker pool
# whose top process is reparented to init, leaving a hook with no ancestry path
# back to its own live session; docs/watcher-continuity.md owns that contract.
# bin/fm-lock.sh uses this file to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires for the
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

# Print the session id carried by Claude Code hook payload $1, or return 1.
#
# The extractor is deliberately plain text and takes no jq dependency, because
# the value is never trusted on its own. Its only consumer compares it to the
# session id the delivering session exported into this process's environment, so
# a mis-parse can withhold the proof but can never manufacture one.
fm_claude_payload_session_id() {  # <payload>
  local payload=${1-} id
  [ -n "$payload" ] || return 1
  id=$(printf '%s' "$payload" \
    | tr ',{}' '\n' \
    | sed -n 's/^[[:space:]]*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._-]\{1,\}\)"[[:space:]]*$/\1/p' \
    | sed -n '1p')
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# True when state dir $1 holds a session lock owned by the very Claude Code
# session that delivered hook payload $2.
#
# This is the second, ancestry-independent membership proof, and it exists
# because a Claude Code hook does not reliably run under its own session. Claude
# Code serves hook and tool commands from a shared per-user worker pool
# (claude bg-spare -> claude bg-pty-host -> claude daemon run) whose top process
# is reparented to init once the session that first started it exits. A hook
# served by such a pool has a contiguous claude ancestry that does not contain
# the live session at all, so the ancestry proof fails through no fault of the
# session and the hook goes inert (docs/watcher-continuity.md).
#
# The proof is a conjunction, and every part is required:
#   1. the delivered payload names a session id, which no inherited environment
#      can supply - it describes THIS event;
#   2. the session id the delivering session exported matches that payload, so
#      the environment read below belongs to the session that emitted the event
#      rather than to some ancestor session it was inherited from;
#   3. the exported session pid is EXACTLY the pid recorded in this home's lock,
#      which is stricter than ancestry membership rather than weaker;
#   4. that pid is still a live Claude process, so a recycled or dead pid never
#      passes.
#
# A foreign session therefore still fails: it exports its own pid, which is not
# the pid this home's lock records. A missing, malformed, or foreign-owned lock
# fails closed, and so does every home whose lock names another session, which
# is what keeps several firstmate homes on one machine independent.
fm_session_lock_owned_by_claude_hook() {  # <state-dir> <payload>
  local state=$1 payload=${2-} lock_pid payload_session
  case "${CLAUDE_PID:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  payload_session=$(fm_claude_payload_session_id "$payload") || return 1
  [ "$payload_session" = "$CLAUDE_CODE_SESSION_ID" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$lock_pid" = "$CLAUDE_PID" ] || return 1
  fm_harness_pid_alive "$lock_pid" || return 1
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
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

# True when the Claude session behind the current run holds state dir $1's
# session lock, proven either by harness ancestry or by the identity delivered
# with hook payload $2. This disjunction is the ONE owner of "may this run act
# for this home", so the gate that admits a run and any later re-verification
# cannot drift apart.
#
# Both members are load-bearing. Ancestry is tried first and left unchanged,
# because a legitimate claude-launched-by-claude wrapper chain records the
# OUTERMOST pid in the lock while CLAUDE_PID names the inner session, so
# preferring the delivered identity would refuse that case. The delivered
# identity is required because a hook served by the shared per-user worker pool
# reparented to init has no ancestry path back to its live session at all.
# Neither member is a fallback for the other: a caller that needs only one of
# them still calls that one directly.
#
# FM_SESSION_LOCK_PROOF names the member that carried the verdict, so a caller
# can report which proof applied; it is empty when neither holds.
# shellcheck disable=SC2034 # Read by sourcing callers, not inside this file.
FM_SESSION_LOCK_PROOF=''
# shellcheck disable=SC2034 # FM_SESSION_LOCK_PROOF is a caller-read output.
fm_session_lock_owned_by_this_claude_session() {  # <state-dir> <payload>
  local state=$1 payload=${2-}
  FM_SESSION_LOCK_PROOF=''
  if fm_session_lock_owned_by_self "$state"; then
    FM_SESSION_LOCK_PROOF=ancestry
    return 0
  fi
  if fm_session_lock_owned_by_claude_hook "$state" "$payload"; then
    FM_SESSION_LOCK_PROOF=claude-session
    return 0
  fi
  return 1
}
