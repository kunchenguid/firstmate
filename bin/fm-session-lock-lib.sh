#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

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

# Claude Code subcommands that are shared INFRASTRUCTURE, never a firstmate
# session: the per-user daemon and the background worker processes it hosts.
# They carry the same "claude" branding in argv[0] and in their install path, so
# the harness-identity evidence below matches them exactly like a session - but
# the daemon is one long-lived process shared by every session and every home,
# and a bg-pty-host/bg-spare worker is a transient host for background work.
# Treating either as a session owner is what lets one of them pin a home's
# session lock forever, and lets an async hook hosted inside that worker chain
# report a "harness ancestry" that provably excludes the session that fired it.
FM_HARNESS_INFRA_SUBCOMMANDS='daemon bg-pty-host bg-spare'

# The subset of those that is also a hard BOUNDARY for the ancestry walk below,
# rather than merely transparent to it. A session-hosted hook chain legitimately
# passes THROUGH a bg-pty-host or bg-spare worker on its way up to its own
# session, so those must stay transparent or a real session would stop being
# found. The per-user daemon is different: it is one process shared by every
# session and every home, and nothing above it is below any session. Reaching it
# without having already matched a session therefore proves the caller is in the
# shared infrastructure chain, so the walk must stop there UNRESOLVED instead of
# climbing on and latching onto whatever harness happens to sit above the daemon
# and reporting it as this session's own ancestry - the exact gap-crossing the
# walk otherwise forbids, and the one that would let a hook arm a home it cannot
# prove it owns.
FM_HARNESS_INFRA_BOUNDARY_SUBCOMMANDS='daemon'

# Print the FIRST argument after argv[0] in full argument string $1, or return 1
# when there is none. Anchoring on that one token is what keeps the infrastructure
# tests below safe: a real session can never be misread as infrastructure because
# its prompt text happens to contain one of these words - a crewmate launch brief
# is passed as argv.
fm_harness_subcommand() {  # <args>
  local args=$1 rest
  rest=${args#* }
  [ "$rest" != "$args" ] || return 1
  printf '%s' "${rest%% *}"
}

# True when full argument string $1 is one of those shared infrastructure
# processes.
fm_harness_is_infra() {  # <args>
  local sub name
  sub=$(fm_harness_subcommand "$1") || return 1
  for name in $FM_HARNESS_INFRA_SUBCOMMANDS; do
    [ "$sub" = "$name" ] && return 0
  done
  return 1
}

# True when full argument string $1 is an infrastructure process the pre-match
# ancestry climb must terminate on rather than pass through.
fm_harness_is_infra_boundary() {  # <args>
  local sub name
  sub=$(fm_harness_subcommand "$1") || return 1
  for name in $FM_HARNESS_INFRA_BOUNDARY_SUBCOMMANDS; do
    [ "$sub" = "$name" ] && return 0
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
  fm_harness_is_infra "$args" && return 1
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
# The pre-match climb has one hard stop of its own: the shared per-user daemon.
# Excluding infrastructure from fm_harness_process_matches makes it transparent
# to that climb rather than a boundary, so without this the walk would pass
# straight through a bg-spare/bg-pty-host/daemon chain and report whatever sits
# ABOVE the daemon as this session's ancestry - the same gap crossing, reached
# from a different direction. Reaching the daemon before any session has matched
# proves the caller is in the shared infrastructure chain, where this session is
# simply not visible, so the walk terminates UNRESOLVED.
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
    elif fm_harness_is_infra_boundary "$args"; then
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

# True when $1 is a live process that is one of Claude Code's shared
# infrastructure processes rather than a session.
#
# This exists for the MIGRATION window, and a session lock is the one place that
# window must not be waved through. Before infrastructure was excluded from
# harness identity, the daemon was itself a valid contiguous match, so
# fm_harness_ancestry_pid could return the shared daemon's pid and a home's
# state/.lock could legitimately hold it. After the exclusion that recorded pid
# fails fm_harness_pid_alive, which alone would make the lock read as a dead
# owner - and a dead owner is claimable. A fleet self-update lands on every home
# at once, so that would open the same window everywhere simultaneously, and the
# failure it permits is the exact one this lock exists to prevent: two live
# sessions both believing they own one home. So an infrastructure pid is
# recognized as STALE BUT NOT CLAIMABLE - not a valid session owner, and not
# evidence any hook may arm on. The record is left for the ordinary session-start
# lock acquisition to replace with a real session pid.
fm_harness_pid_is_infra() {  # <pid>
  local pid=$1 comm args base argv0
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_is_infra "$args" || return 1
  base=$(basename -- "$comm")
  printf '%s' "$base" | grep -qE "$FM_HARNESS_RE" && return 0
  argv0=${args%% *}
  fm_harness_path_name "$comm" >/dev/null && return 0
  fm_harness_path_name "$argv0" >/dev/null && return 0
  return 1
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
