#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness identity holds this home's session
# lock, and does the current session prove that same ownership?" decision.
# A session owner identity is a numeric local pid, a tagged Windows pid, or an
# opaque native:<generation> value; process-introspection helpers remain numeric.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Native ownership delegates to its verifier. Otherwise, ownership is
# ancestry membership or a trusted Claude session id beside a live lock. No id,
# no sidecar, an untrusted id, or a different recorded id leaves the ancestry
# verdict unchanged.
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
# Native routing is selected by durable home records, never an inherited role.
FM_NATIVE_OWNER_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-native-owner.exe"
fm_native_owner_selected() {
  local state="${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}" probe value
  probe="${state%/state}/owner-probe.json"
  if [ -e "$probe" ] || [ -L "$probe" ]; then return 0; fi
  value=$(cat "$state/.lock" 2>/dev/null || true)
  case "$value" in native:*) return 0 ;; esac
  return 1
}
fm_native_owner_call() {
  local native_state
  native_state=$(cygpath -w "${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}") || return 2
  case "$1" in
    alive) MSYS2_ARG_CONV_EXCL='*' "$FM_NATIVE_OWNER_BIN" owner "$1" "$native_state" "${2:?}" ;;
    identity|owns|harness) MSYS2_ARG_CONV_EXCL='*' "$FM_NATIVE_OWNER_BIN" owner "$1" "$native_state" ;;
    *) return 2 ;;
  esac
}
# Three states: 0 is live, 1 proven dead, 2 unknown. Do not turn exclusion
# (unknown must preserve occupancy) into a positive health assertion.
fm_native_owner_state() {
  local rc
  if fm_native_owner_call alive "$1"; then return 0; else rc=$?; fi
  [ "$rc" -eq 1 ] && return 1
  return 2
}


# True on a Cygwin-family userspace, where the boundary above applies.
fm_win_boundary_applies() {
  case "$(uname -s 2>/dev/null)" in
    CYGWIN*|MINGW*|MSYS*) return 0 ;;
  esac
  return 1
}

# Strip the namespace tag from $1, or return 1 when $1 is not a tagged pid.
fm_win_untag_pid() {  # <pid>
  local winpid
  case "$1" in
    "$FM_WIN_PID_PREFIX"*) winpid=${1#"$FM_WIN_PID_PREFIX"} ;;
    *) return 1 ;;
  esac
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$winpid"
}

# True when $1 is a well-formed session-lock identity: a local pid, a tagged
# Windows pid, or an explicitly registered native generation. This validates a
# lock identity, not a process-id argument; PID-only interfaces keep their own
# numeric validation. Every reader of state/.lock decides "is this value usable
# at all" through this one predicate, because the readers are spread across
# several scripts and a private numeric test in any one of them silently rejects
# a valid holder - which reads as "startup never completed" and repeats the
# whole sequence on every clear or compact.
fm_session_pid_valid() {  # <value>
  local native_id
  case "$1" in
    native:*)
      native_id=${1#native:}
      [ "${#native_id}" -eq 32 ] || return 1
      case "$native_id" in *[!0-9a-f]*) return 1 ;; esac
      return 0 ;;
    "$FM_WIN_PID_PREFIX"*)
      fm_win_untag_pid "$1" >/dev/null
      return ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
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

# Print the normalized executable path of live Windows process $1.
# Presence in `ps -W` is also this bridge's liveness test, because kill -0 cannot
# answer that question across the namespace boundary.
# Returns 1 when the process is absent and 2 when the table cannot be queried.
fm_win_command() {  # <winpid>
  local winpid=$1 table out
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if ! table=$(ps -W 2>/dev/null); then
    return 2
  fi
  if ! out=$(printf '%s\n' "$table" | awk -v w="$winpid" '$4 == w { for (i = 8; i <= NF; i++) printf "%s%s", (i > 8 ? " " : ""), $i; exit }'); then
    return 2
  fi
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

# Print this session's verified owner identities, innermost first. POSIX and
# tagged-Windows routes walk at most 16 ancestry hops and print pids; the native
# route prints the single opaque native:<generation> identity registered for the
# home instead of treating it as a pid.
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
  if fm_win_boundary_applies && fm_native_owner_selected; then fm_native_owner_call identity; return; fi
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
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
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

# Print the opaque native generation or outermost pid of this session's
# contiguous harness run. This is not necessarily the identity written to the
# session lock: fm_session_lock_anchor_pid uses a trusted Claude session's
# model-loop pid instead. Other routes retain their ancestry identity.
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

# Classify a session-lock owner identity: 0 positively live, 1 proven dead, or 2
# unknown. POSIX and tagged-Windows pid routes can prove only live or dead; the
# native generation route preserves unreadable or ambiguous ownership as unknown.
# A tagged Windows pid is answered from the Windows process table, because
# kill -0 cannot see across that boundary and would report a live harness as
# dead - which would hand a running session's home to a second one.
fm_harness_pid_alive() {
  local pid=$1 comm args winpid owner_rc
  case "$pid" in native:*)
    fm_native_owner_state "$pid"
    return ;;
  esac
  if winpid=$(fm_win_untag_pid "$pid"); then
    if comm=$(fm_win_command "$winpid"); then :; else owner_rc=$?; return "$owner_rc"; fi
    fm_harness_process_matches "$comm" "$comm"
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_ps_comm "$pid") || return 1
  args=$(fm_ps_args "$pid")
  fm_harness_process_matches "$comm" "$args"
}

# Test exclusion rather than positive health: return 0 for a live or unknown
# owner identity, and 1 only when the owner is proven dead.
fm_harness_pid_excludes() {
  local owner_rc
  if fm_harness_pid_alive "$1"; then return 0; else owner_rc=$?; fi
  [ "$owner_rc" -ne 1 ]
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

# Print the owner identity bin/fm-lock.sh records on lock line 1 for this
# session. The native route retains its opaque generation. For a Claude session
# with a trusted id the identity is CLAUDE_PID, the model-loop process: never the
# shared transient daemon and never a front-end that outlives the session, so a
# dead recorded process still means the session is gone instead of wedging a
# home behind a live daemon whose session died. A replaced background helper
# leaves a dead pid that its own session's next hook reclaims, because the
# sidecar still names that session. Every other process-backed session records
# the outermost pid of its verified identity set.
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
# Native-selected homes use their authenticated verifier instead of either
# process-based signal.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  if fm_win_boundary_applies && FM_STATE_OVERRIDE="$state" fm_native_owner_selected; then
    FM_STATE_OVERRIDE="$state" fm_native_owner_call owns
    return
  fi
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$lock_pid" || return 1
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
