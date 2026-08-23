#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current session own that lock?" decision.
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

# Print the pid of the session the harness itself publishes for lock path $1,
# or return 1.
#
# Ancestry answers "which harness am I running inside" only while the caller is
# actually a descendant of its session. Claude Code serves tool and hook
# commands from a per-user worker pool (claude daemon run -> bg-pty-host ->
# bg-spare) that is reparented to init, so the ancestry of such a call
# terminates at pid 1 inside the pool and never reaches the interactive session
# that acquired this home's lock. CLAUDE_PID is exported into every one of those
# commands and names that session directly, which is why it survives the gap
# that ancestry cannot cross. Claude Code is the only verified harness that
# publishes one today; every other harness has no such variable and keeps the
# ancestry-only behavior below unchanged.
#
# The pid is trusted only while it is still a live Claude Code process that
# strictly predates the lock. The lock's existing mtime is process-generation
# evidence: if an exited session's pid is recycled, the replacement process
# starts at or after the lock the original session published and is rejected
# even when the replacement is another Claude process.
#
# Trust boundary. The variable is inherited by any child, so on its own it says
# "a Claude session named this pid", never "I am that session". That is why
# callers must use it strictly to WIDEN ownership and never to replace the
# ancestry test: the only conclusion drawn from it here is that a lock ALREADY
# recording this exact pid belongs to a live session rather than a competing
# one, which is true however deep the caller sits below that session. It can
# therefore never let a caller take a lock away from another session, and never
# turns an unheld lock into a held one.
fm_harness_session_pid() {  # <lock-path>
  local lock=$1 pid=${CLAUDE_PID:-} started started_epoch lock_epoch
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  fm_harness_pid_alive "$pid" || return 1
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
  started=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  started=$(printf '%s' "$started" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$started" ] || return 1
  started_epoch=$(LC_ALL=C date -d "$started" +%s 2>/dev/null) \
    || started_epoch=$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null) \
    || return 1
  lock_epoch=$(stat -f %m "$lock" 2>/dev/null) \
    || lock_epoch=$(stat -c %Y "$lock" 2>/dev/null) \
    || return 1
  case "$started_epoch:$lock_epoch" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  # A session already running when this change landed cannot prove ownership if
  # its existing lock was published during its process-start second. That is the
  # same behavior the session already had, not a regression: the old writer
  # recorded no generation evidence that could distinguish the original process
  # from a pid recycled within that second, so this path declines to widen rather
  # than inventing evidence. The gap lasts at most that session's lifetime and
  # self-heals when the next session publishes after the bounded wait below.
  [ "$started_epoch" -lt "$lock_epoch" ] || return 1
  printf '%s\n' "$pid"
}

# Wait until a new lock for harness pid $1 can carry unambiguous whole-second
# generation evidence when the verified Claude signals are available. Claude's
# published session pid is the only identity that uses lock mtime, so every
# other harness and every unverified environment return immediately. ps exposes
# process start only to whole-second precision on both supported platforms;
# publishing during that same second would make a recycled pid indistinguishable
# from the original process. The bounded wait moves the one initial lock
# publication past that boundary so the strict comparison above can reject
# equality without making a normal just-started session read-only.
fm_session_lock_wait_until_publishable() {  # <harness-pid>
  local pid=$1 started started_epoch now i=0
  [ "${CLAUDE_PID:-}" = "$pid" ] || return 0
  fm_harness_pid_alive "$pid" || return 0
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 0
  started=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 0
  started=$(printf '%s' "$started" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$started" ] || return 0
  started_epoch=$(LC_ALL=C date -d "$started" +%s 2>/dev/null) \
    || started_epoch=$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null) \
    || return 0
  case "$started_epoch" in
    ''|*[!0-9]*) return 0 ;;
  esac
  while [ "$i" -lt 40 ]; do
    now=$(date +%s 2>/dev/null) || return 0
    case "$now" in
      ''|*[!0-9]*) return 0 ;;
    esac
    [ "$now" -gt "$started_epoch" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 0
}

# True when state dir $1 holds a session lock owned by the current session.
# Ancestry membership is the ordinary test of that question, because the lock
# owner sits at an unknown depth in a contiguous Claude run - it is the outermost
# pid when the hook fires inside the session's own nested worker chain, and an
# inner pid when a harness-named daemon parents the session. A missing lock, a
# malformed lock, a lock held by a harness outside this ancestry, or an ancestry
# that cannot be resolved all fail closed unless the published-session check
# below establishes the worker-pool case.
#
# Membership proves ownership when it holds, but its absence proves nothing: a
# call served by a reparented worker pool has no ancestry path to its own
# session at all, so a session that genuinely holds this lock would be refused
# its own home and forced read-only. The published session pid answers exactly
# that case and is checked first. It only ever widens acceptance - a lock this
# session does not already hold is still decided by the ancestry walk below.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid session_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if session_pid=$(fm_harness_session_pid "$state/.lock") && [ "$session_pid" = "$lock_pid" ]; then
    return 0
  fi
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
