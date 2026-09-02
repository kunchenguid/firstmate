#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of "may this run act for the session that holds this home's lock?",
# over three independent proofs and the disjunctions that arbitrate them.
# Ancestry asks whether the current process descends from the verified harness
# the lock records. The durable session-identity binding beside the lock answers
# the same ownership question when ancestry cannot, because a call served by a
# reparented worker pool never reaches its own session; see
# fm_session_lock_owned_by_current_session. Delivered Claude session identity
# instead asks whether the session that emitted THIS hook event is the one the
# lock names, which a hook can prove from its payload before any binding exists;
# docs/watcher-continuity.md owns that contract.
# bin/fm-lock.sh uses this file to acquire, inspect, and bind state/.lock;
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

# True when the durable binding beside state dir $1's session lock records that
# lock for session $2. This is the shared core of every recorded-identity proof
# below, so the record's own rules are stated once here:
#   1. the lock holds a plain numeric pid;
#   2. the binding beside it is a regular file naming exactly that pid, so a
#      record left by a previous owner can never speak for the current lock;
#   3. the session it names is exactly the session asked about;
#   4. the lock pid is still a live harness process.
#
# A foreign session fails at 3 because it carries its own id. An absent or
# malformed lock fails at 1, an absent or stale binding at 2, and a dead owner at
# 4. Two firstmate homes on one machine stay independent because each reads its
# own state dir. An old lock carrying only a pid has no binding, so it fails at 2
# and that home keeps exactly the ancestry-only behavior it had before.
#
# Each caller supplies the CORROBORATION that the session it asks about is really
# the one behind this run, because the environment string alone proves nothing.
fm_session_lock_binding_names_session() {  # <state-dir> <session-id>
  local state=$1 want=$2 lock_pid path recorded_pid recorded_session
  [ -n "$want" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  path=$(fm_session_lock_identity_path "$state")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  recorded_pid=$(sed -n 's/^pid=//p' "$path" 2>/dev/null | sed -n '1p')
  recorded_session=$(sed -n 's/^session=//p' "$path" 2>/dev/null | sed -n '1p')
  [ "$recorded_pid" = "$lock_pid" ] || return 1
  [ -n "$recorded_session" ] && [ "$recorded_session" = "$want" ] || return 1
  fm_harness_pid_alive "$lock_pid" || return 1
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
# The corroboration here is ancestry: this process carries a harness session
# identity AND that identity is confirmed by its own ancestry rather than merely
# inherited as an environment string (fm_harness_session_is_ours). A caller with
# no hook event has nothing stronger available, so a process that merely
# inherited another session's environment is refused.
fm_session_lock_owned_by_session_identity() {  # <state-dir>
  local state=$1 id
  id=$(fm_harness_session_identity) || return 1
  fm_harness_session_is_ours || return 1
  fm_session_lock_binding_names_session "$state" "$id"
}

# True when state dir $1 holds a session lock the durable binding records for the
# very session that delivered hook payload $2.
#
# This is the third membership proof, and it exists because the second one is
# strictly pid-shaped: it requires the pid the harness exports to BE the pid the
# lock records. Claude Code serves hook and tool commands from a shared per-user
# worker pool, and bin/fm-lock.sh writes the OUTERMOST pid of the contiguous
# harness run that acquired the lock, so the two are not always the same process
# even though they are the same session. When they differ, ancestry cannot reach
# the recorded owner either, and the hook goes permanently inert on a home whose
# lock is alive and genuinely its own - the measured shape reported as "live
# session N owns this home and neither identity proof applies".
#
# The proof is a conjunction, and every part is required:
#   1. the delivered payload names a session id, which no inherited environment
#      can supply - it describes THIS event;
#   2. the session id the delivering session exported matches that payload, so
#      the environment read here belongs to the session that emitted the event
#      rather than to some ancestor session it was inherited from. This is the
#      SAME corroboration the pid proof uses, and it replaces the ancestry
#      corroboration fm_session_lock_owned_by_session_identity needs, because a
#      caller with no hook event has no way to prove its environment describes
#      the call it is making;
#   3. the durable binding beside the lock names exactly the pid the lock
#      records, so a record left by a previous owner can never speak for it;
#   4. the session that binding names is exactly this session;
#   5. the recorded owner is still a live harness process.
#
# A foreign session fails at 4 because it carries its own id, so several
# firstmate homes on one machine stay independent exactly as before. A home whose
# lock carries no binding fails at 3 and keeps the previous two-proof behavior.
fm_session_lock_owned_by_claude_hook_binding() {  # <state-dir> <payload>
  local state=$1 payload=${2-} payload_session
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  payload_session=$(fm_claude_payload_session_id "$payload") || return 1
  [ "$payload_session" = "$CLAUDE_CODE_SESSION_ID" ] || return 1
  fm_session_lock_binding_names_session "$state" "$CLAUDE_CODE_SESSION_ID"
}

# True when the session behind the current run owns state dir $1's fleet lock,
# proven by harness ancestry OR by the durable identity the lock records. This
# disjunction is the ONE owner of "may this run mutate this home" for every
# caller that has NO hook event to reason about, so the gate that admits a
# session start and the sweeps it authorizes cannot drift apart. A hook that
# does carry a payload asks fm_session_lock_owned_by_this_claude_session below.
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

# True when the Claude session behind the current run holds state dir $1's
# session lock, proven either by harness ancestry or by the identity delivered
# with hook payload $2. This disjunction is the ONE owner of "may this HOOK
# EVENT act for this home", so the gate that admits a hook run and any later
# re-verification cannot drift apart.
#
# All three members are load-bearing. Ancestry is tried first and left unchanged,
# because a legitimate claude-launched-by-claude wrapper chain records the
# OUTERMOST pid in the lock while CLAUDE_PID names the inner session, so
# preferring the delivered identity would refuse that case. The delivered pid
# identity is required because a hook served by the shared per-user worker pool
# reparented to init has no ancestry path back to its live session at all. The
# durable binding is required because that same OUTERMOST-pid rule means the pid
# the harness exports and the pid the lock records can be different processes of
# one session, which leaves the first two proofs with nothing to match on. None
# of them is a fallback for the others: a caller that needs only one still calls
# that one directly.
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
  if fm_session_lock_owned_by_claude_hook_binding "$state" "$payload"; then
    FM_SESSION_LOCK_PROOF=claude-session-binding
    return 0
  fi
  return 1
}
