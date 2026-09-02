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

# Portable single-pid process introspection.
#
# procps/BSD `ps -o comm=/args=/ppid=` custom-format columns are the primary
# path and cover Linux and macOS. Cygwin's ps, which Git for Windows ships, has
# no -o option at all and exits with "unknown option -- o", so the primary path
# fails outright there and the ancestry walk aborts on its first hop. The
# fallbacks parse Cygwin's fixed columns instead:
#   ps -p PID     PID PPID PGID WINPID TTY UID STIME COMMAND   (executable path)
#   ps -f -p PID  UID PID PPID TTY STIME COMMAND               (full argv)
# A genuinely dead or inaccessible pid still fails both paths, so this widens
# nothing: it only stops a supported platform from failing on ps syntax alone.
fm_ps_comm() {  # <pid> -> executable name or path
  local pid=$1 out
  out=$(ps -o comm= -p "$pid" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(ps -p "$pid" 2>/dev/null | awk 'NR == 2 { for (i = 8; i <= NF; i++) printf "%s%s", (i > 8 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

fm_ps_args() {  # <pid> -> full command line
  local pid=$1 out
  out=$(ps -o args= -p "$pid" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(ps -f -p "$pid" 2>/dev/null | awk 'NR == 2 { for (i = 6; i <= NF; i++) printf "%s%s", (i > 6 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

fm_ps_ppid() {  # <pid> -> parent pid
  local pid=$1 out
  out=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  out=$(ps -f -p "$pid" 2>/dev/null | awk 'NR == 2 { print $3; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
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

# --- Windows process-boundary bridge -----------------------------------------
#
# On Cygwin (Git for Windows) the harness is a native Windows process, and the
# parent link from a shell it spawns does NOT cross the Cygwin boundary: Cygwin
# reports that shell's PPID as 1. So no amount of walking ppid can ever reach the
# harness, and the contiguous-run model below cannot be satisfied by the Cygwin
# process table alone. The Windows process table does hold the real parent chain,
# and `ps -W` lists Windows processes keyed by WINPID, so identity is recovered
# from there instead.
#
# Windows pids live in a DIFFERENT namespace from Cygwin pids: `kill -0` on a
# Windows pid reports "No such process" even while that process is running, and a
# Windows pid can collide with an unrelated live Cygwin pid. A bare number is
# therefore ambiguous and unsafe to store. Every pid resolved through this bridge
# is tagged, which makes the namespace explicit for readers and makes the value
# non-numeric so that any consumer treating it as a Cygwin pid - including a
# future `kill` - refuses it instead of acting on the wrong process.
FM_WIN_PID_PREFIX='win:'

# True on a Cygwin-family userspace, where the boundary above applies.
fm_win_boundary_applies() {
  case "$(uname -s 2>/dev/null)" in
    CYGWIN*|MINGW*|MSYS*) return 0 ;;
  esac
  return 1
}

# Strip the namespace tag from $1, or return 1 when $1 is not a tagged pid.
fm_win_untag_pid() {  # <pid>
  case "$1" in
    "$FM_WIN_PID_PREFIX"[0-9]*) printf '%s' "${1#"$FM_WIN_PID_PREFIX"}"; return 0 ;;
  esac
  return 1
}

# Windows command paths are backslash-separated and .exe-suffixed, neither of
# which the path-component matcher above understands. Normalizing here is what
# keeps that matcher's whole-component safety intact: without it the harness
# regex would fall back to matching the entire unsplit path, so an unrelated
# C:\claude-notes\tool.exe would read as a harness process.
fm_win_normalize_command() {  # <windows path>
  local path=${1//\\//}
  printf '%s' "${path%.exe}"
}

# Print the normalized executable path of live Windows process $1, or return 1.
# Presence in `ps -W` is also this bridge's liveness test, because kill -0 cannot
# answer that question across the namespace boundary.
fm_win_command() {  # <winpid>
  local winpid=$1 out
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  out=$(ps -W 2>/dev/null | awk -v w="$winpid" '$4 == w { for (i = 8; i <= NF; i++) printf "%s%s", (i > 8 ? " " : ""), $i; exit }')
  [ -n "$out" ] || return 1
  fm_win_normalize_command "$out"
}

# Environment variables through which a verified harness publishes the pid of
# its own session process. Extend only with a variable confirmed to name the
# session-long harness process on Windows, because the identity check below is
# only as narrow as this table.
#
# Walking the real Windows parent chain is deliberately NOT the fallback here.
# Two properties of this platform make it unusable for identity:
#   - MSYS emulates exec by spawning a fresh Windows process and exiting the old
#     one, so intermediate shells vanish constantly and a child's recorded parent
#     is routinely a pid that no longer exists. The chain simply breaks.
#   - Windows never reparents an orphan, so that dangling parent id stays on the
#     child and Windows is free to reissue it. Following it can therefore land on
#     an unrelated live process and bind a home's session lock to it, which is
#     the wrong-process-binding failure this file exists to prevent.
# A harness that publishes nothing is reported as unresolved instead, which
# leaves the session read-only exactly as before - the safe direction.
FM_WIN_HARNESS_PID_VARS=(CLAUDE_PID)

# Print this session's harness as one tagged Windows pid, or return 1.
#
# The published pid is a claim, not evidence, so it is never trusted on its own:
# it is confirmed against the Windows process table, and accepted only when that
# pid is still live AND its executable independently identifies a verified
# harness by the same rules every other platform uses. A value that is absent,
# malformed, stale, or naming a non-harness process is discarded rather than
# used, so a wrong or recycled pid fails closed instead of binding the lock.
fm_win_harness_ancestry_pids() {
  local var winpid comm
  for var in "${FM_WIN_HARNESS_PID_VARS[@]}"; do
    winpid=${!var:-}
    case "$winpid" in
      ''|*[!0-9]*) continue ;;
    esac
    comm=$(fm_win_command "$winpid") || continue
    fm_harness_process_matches "$comm" "$comm" || continue
    printf '%s%s\n' "$FM_WIN_PID_PREFIX" "$winpid"
    return 0
  done
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
    comm=$(fm_ps_comm "$pid") || break
    args=$(fm_ps_args "$pid")
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(fm_ps_ppid "$pid")
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  # A harness living in the same process table is always preferred, so an
  # ordinary POSIX ancestry keeps resolving to plain pids and nothing about the
  # existing platforms changes. The Windows bridge is consulted only after that
  # walk finds nothing, which on Cygwin is what the severed parent link
  # guarantees it will do.
  if [ "$printed" -eq 0 ] && fm_win_boundary_applies; then
    fm_win_harness_ancestry_pids && return 0
  fi
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
# A tagged Windows pid is answered from the Windows process table, because
# kill -0 cannot see across that boundary and would report a live harness as
# dead - which would hand a running session's home to a second one.
fm_harness_pid_alive() {
  local pid=$1 comm args winpid
  if winpid=$(fm_win_untag_pid "$pid"); then
    comm=$(fm_win_command "$winpid") || return 1
    fm_harness_process_matches "$comm" "$comm"
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_ps_comm "$pid") || return 1
  args=$(fm_ps_args "$pid")
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
    "$FM_WIN_PID_PREFIX"[0-9]*) : ;;
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
