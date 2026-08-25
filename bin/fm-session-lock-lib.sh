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

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# omp (Oh My Pi) is deliberately NOT added to the tables above. It is not
# exclusively a Claude Agent SDK harness, so a bare process-name match here
# would misclaim an omp session running a different backend. Its Claude
# identity is instead recognized in fm_harness_process_matches() below, gated
# strictly on the CLAUDECODE=1 marker the same way fm-harness.sh's own
# detect_own() already trusts it (env markers before ancestry), and only while
# identifying the caller's own ancestry - never for an arbitrary foreign pid
# such as a recorded lock holder, whose actual backend the caller's own
# environment cannot describe. Do not widen this to a bare name match.

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
#   3. omp (Oh My Pi), but only when $3 marks this as the caller's own
#      ancestry walk - see the note below.
#   4. a bare interpreter (node, python) running a harness script path.
#   5. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args> [self=0]
  local comm=$1 args=$2 self=${3:-0} base argv0 name
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
  # omp (Oh My Pi), treated as claude 2026-08-23: omp runs on the same
  # underlying Claude Agent SDK and sets CLAUDECODE=1 for downstream
  # compatibility, but its own process name is "omp" with no separate
  # "claude"-named process anywhere in its ancestry - there is no nested
  # worker chain to climb the way native Claude Code has one. Gate strictly on
  # the marker, never the bare name alone (see the FM_HARNESS_NAMES comment
  # above) - AND gate on $self=1. $CLAUDECODE is always read from the CALLING
  # process's environment, never the examined pid's: that is sound evidence
  # only while the examined pid is a verified member of the caller's own
  # ancestry, since env vars are inherited top-down and the caller would then
  # carry the same value that pid set. Every caller is responsible for that
  # verification: fm_harness_ancestry_pids's own walk always passes self=1
  # because it discovers $pid by climbing $$'s kernel-reported ppid chain, and
  # fm_harness_pid_alive checks membership in that same walk before passing
  # self=1 for a lock-file pid, so a pid from a genuinely different session
  # never borrows the caller's marker.
  #
  # Deliberately do NOT set FM_HARNESS_IS_CLAUDE here even though omp is
  # Claude-backed: that flag tells fm_harness_ancestry_pids to keep climbing
  # past this match the way native Claude Code's nested worker chain requires,
  # and the comment above is explicit that omp has no such chain to climb. Omp
  # is its own session boundary, exactly like every other non-Claude harness -
  # setting the flag would let the walk continue into whatever unrelated
  # process happens to be omp's parent (a launcher or daemon) and report that
  # outer pid as the lock identity instead of omp's own.
  if [ "$base" = omp ] && [ "$self" -eq 1 ] && [ "${CLAUDECODE:-}" = "1" ]; then
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
    # self=1: $pid was reached by walking $$'s own kernel-reported ppid chain,
    # so it is a verified ancestor of the caller - the one case where the
    # caller's own $CLAUDECODE is sound evidence about $pid's backend.
    if fm_harness_process_matches "$comm" "$args" 1; then
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

# Path to the sibling record of state dir $1's session lock naming the one
# omp pid, if any, that fm-lock.sh verified as CLAUDECODE=1 at the moment it
# wrote that exact pid into state/.lock. See fm_harness_record_omp_claude and
# fm_harness_pid_alive below for why this exists.
fm_harness_omp_claude_marker_path() {  # <state>
  printf '%s/.lock.omp-claude' "$1"
}

# Process-identity fingerprint for pid $1, immune to the pid being recycled by
# an unrelated later process: prefers /proc's numeric starttime (clock ticks
# since boot, Linux-only) and falls back to `ps -o lstart=` elsewhere. Mirrors
# bin/fm-teardown.sh's task_process_identity and bin/fm-wake-lib.sh's
# fm_pid_identity so all three independently-verified pid-reuse guards agree
# on format; duplicated rather than sourced because this file has no side
# effects on source (see header) and must not adopt fm-wake-lib.sh's
# mkdir -p "$STATE" as a side effect of merely being sourced.
fm_harness_omp_pid_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
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
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

# Record whether $2 - the pid fm-lock.sh just wrote into state dir $1's session
# lock - is an omp process, so a foreign checker can later trust that this
# exact pid was CLAUDECODE-verified without needing to read $2's own
# environment (see fm_harness_pid_alive). Callable only from the writer's own
# context immediately after a successful lock write, because that is the one
# place $CLAUDECODE is sound evidence about $2: fm_harness_ancestry_pid (which
# produced $2) never returns an omp pid unless this same environment's
# CLAUDECODE=1 already gated it in via fm_harness_process_matches's self=1
# path. Always called on every lock write, omp or not, so a later non-omp
# acquisition clears a stale marker rather than leaving it pointing at a pid
# some unrelated future process could reuse.
#
# Returns failure when a genuine omp holder's marker write fails. That case
# is fatal for the caller, not merely logged: without the persisted marker no
# foreign session can ever prove this pid alive (fm_harness_pid_alive has no
# other evidence for a foreign omp pid), so it would treat this live holder
# as stale and overwrite the lock out from under it. fm-lock.sh must fail the
# whole acquisition rather than report success with unverifiable identity.
#
# The marker's second line is $2's fm_harness_omp_pid_identity fingerprint,
# captured in the same breath as the pid so fm_harness_pid_alive can tell this
# exact process apart from an unrelated later process that reused pid $2 -
# see fm_harness_pid_alive for why a bare pid match is not enough.
fm_harness_record_omp_claude() {  # <state> <pid>
  local state=$1 pid=$2 comm marker identity
  marker=$(fm_harness_omp_claude_marker_path "$state")
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=""
  if [ "$(basename -- "$comm")" = omp ] && [ "${CLAUDECODE:-}" = "1" ]; then
    identity=$(fm_harness_omp_pid_identity "$pid") || return 1
    { printf '%s\n' "$pid" && printf '%s\n' "$identity"; } > "$marker" 2>/dev/null
    return $?
  fi
  rm -f "$marker" 2>/dev/null || true
  return 0
}

# True if $1 is a live process that looks like a verified harness. $2 is the
# state dir the lock naming $1 lives in, so a persisted omp record can be
# consulted; pass "" when no such state dir applies (only the non-omp
# evidence in fm_harness_process_matches is then available).
#
# $1 is read from a lock file and may belong to an entirely different session
# than the caller - the whole point of this check is telling a live competing
# session apart from a dead one. fm_harness_process_matches's omp branch trusts
# the caller's own $CLAUDECODE, which is sound only when $1 actually IS a
# verified ancestor of the caller (env vars are inherited top-down, so the
# caller would carry the same value that ancestor set); it says nothing about
# an unrelated pid that merely happens to be recorded in the lock file. So
# self is computed here by checking $1 for membership in this process's own
# fm_harness_ancestry_pids(), the same membership test fm_session_lock_owned_by_self
# already uses to answer the identical question - never assumed from the
# caller's context.
#
# When $1 is a genuinely foreign omp pid (self=0), no amount of local
# evidence can prove it was CLAUDECODE-verified: that marker lives only in
# $1's own environment, which this process cannot read. The lock-writing
# session already did that verification before it ever became the lock
# holder, so trust its persisted fm_harness_record_omp_claude record instead.
# A pid match alone is not enough: the verified session can exit and the
# kernel can hand $1's old pid number to an unrelated later process before
# this marker is ever refreshed, and that reused pid would otherwise pass
# kill -0 and the marker's bare pid line. So the marker's second line - $1's
# fm_harness_omp_pid_identity fingerprint at the moment fm-lock.sh verified
# it - must also match $1's identity right now; a reused pid almost certainly
# has a different start time and fails this second check.
fm_harness_pid_alive() {  # <pid> <state>
  local pid=$1 state=${2:-} comm args self=0 ancestry ap base marker
  local recorded_pid recorded_identity current_identity
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  ancestry=$(fm_harness_ancestry_pids 2>/dev/null) || true
  while IFS= read -r ap; do
    [ "$ap" = "$pid" ] && { self=1; break; }
  done <<EOF
$ancestry
EOF
  fm_harness_process_matches "$comm" "$args" "$self" && return 0
  base=$(basename -- "$comm")
  [ "$base" = omp ] && [ -n "$state" ] || return 1
  marker=$(fm_harness_omp_claude_marker_path "$state")
  recorded_pid=$(sed -n '1p' "$marker" 2>/dev/null) || return 1
  [ "$recorded_pid" = "$pid" ] || return 1
  recorded_identity=$(sed -n '2p' "$marker" 2>/dev/null)
  [ -n "$recorded_identity" ] || return 1
  current_identity=$(fm_harness_omp_pid_identity "$pid") || return 1
  [ "$recorded_identity" = "$current_identity" ]
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
