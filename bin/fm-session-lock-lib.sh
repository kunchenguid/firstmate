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
# reported and the callers below decide what they need from it. The run may
# include Claude daemon-infrastructure pids (claude daemon run, --bg-pty-host,
# --bg-spare); those are deliberately left in the printed ancestry so membership
# can still walk through them, and only the election and liveness verdicts below
# skip them.
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

# True when argument string $1 marks Claude Code daemon infrastructure rather
# than a real interactive session process: the `claude daemon run` worker, its
# bg-pty-host, or its bg-spare. These are long-lived PPID-1 processes, so a lock
# naming one can never go stale after the real session dies; neither the election
# nor the liveness verdict may ever select one.
#
# Only the leading command/flag tokens of argv are read: the `daemon run`
# subcommand immediately after the command preamble, or a
# --bg-pty-host/--bg-spare flag inside the leading run of options before the
# first bare word. The preamble is the executable token, plus the script-path
# token when a bare interpreter (node, python) execs Claude Code - the same
# npm-install shape fm_harness_process_matches identifies as Claude. Free-text
# argument content - a prompt or launch brief that merely mentions these
# phrases - sits at or beyond the first bare word past the preamble, so it can
# never mark a real session as infrastructure. The verdict is additionally
# gated on FM_HARNESS_IS_CLAUDE: callers classify the same process with
# fm_harness_process_matches first, and a non-Claude harness never matches even
# when its own argv starts with one of these tokens.
fm_harness_daemon_infra() {  # <args>
  local head rest word
  [ "${FM_HARNESS_IS_CLAUDE:-0}" -eq 1 ] || return 1
  case "$1" in
    *' '*) head=${1%% *} rest=${1#* } ;;
    *) return 1 ;;
  esac
  case "${head##*/}" in
    *node*|*python*)
      case "$rest" in
        *' '*) rest=${rest#* } ;;
        *) return 1 ;;
      esac
      ;;
  esac
  case "$rest" in
    'daemon run'|'daemon run '*) return 0 ;;
  esac
  while :; do
    word=${rest%% *}
    case "$word" in
      --) return 1 ;;
      --bg-pty-host|--bg-pty-host=*|--bg-spare|--bg-spare=*) return 0 ;;
      -*) ;;
      *) return 1 ;;
    esac
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) return 1 ;;
    esac
  done
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run that is not Claude daemon
# infrastructure. That is the pid that lives as long as the session - a Claude
# worker several levels in is reaped when its hook returns, and a lock naming it
# would look stale moments later while the session is still running. Every
# non-Claude harness reports a single pid, so this is its innermost match
# unchanged.
#
# Claude Code's daemon worker chain (hook shell -> claude bg-spare -> claude
# bg-pty-host -> claude daemon run) is long-lived and PPID-1, so a lock naming
# any of those pids can never go stale after the real session dies. The election
# therefore skips every daemon-infrastructure pid and returns the topmost real
# session process below the chain; if the whole contiguous run is daemon
# infrastructure there is no session pid to elect and the election fails rather
# than writing a doomed lock.
fm_harness_ancestry_pid() {
  local pids pid comm args candidate=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || true
    fm_harness_daemon_infra "$args" || candidate=$pid
  done <<EOF
$pids
EOF
  [ -n "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

# True if $1 is a live process that looks like a verified harness and is not
# Claude daemon infrastructure. A live daemon worker (claude daemon run,
# --bg-pty-host, --bg-spare) is long-lived and PPID-1, so it must never count as
# a live session holder: a legacy lock naming the daemon then classifies as stale
# and is recoverable through the normal takeover path.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  fm_harness_daemon_infra "$args" && return 1
  return 0
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
