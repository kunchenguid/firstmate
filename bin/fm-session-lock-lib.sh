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

# Native Windows process facts, for the MSYS case where this process tree cannot
# reach its own harness. Every entry point in it gates on fm_winproc_available,
# so a Linux or macOS home is unaffected whether or not the file is here.
#
# Sourced only when present, because eighteen test fixtures build a partial bin/
# holding just the scripts under test, and a hard source turns this library's
# own absence of a sibling into an unrelated failure inside those cases. A home
# with no bridge simply has no Windows process facts to offer, which is the
# state every non-Windows home is already in. This cannot mask a broken install
# on an MSYS host either: the callers below fall through to the POSIX walk,
# which still refuses with its original "cannot locate harness process in
# ancestry" diagnostic. tests/fm-winproc-lib.test.sh pins the absent case.
# shellcheck source=bin/fm-winproc-lib.sh
if [ -r "$(dirname -- "${BASH_SOURCE[0]}")/fm-winproc-lib.sh" ]; then
  . "$(dirname -- "${BASH_SOURCE[0]}")/fm-winproc-lib.sh"
else
  fm_winproc_available() { return 1; }
fi

# Print a Windows image path in the form the harness matcher expects.
#
# fm_harness_process_matches and fm_harness_path_name below both reason about
# path COMPONENTS, and a Windows image path separates them with backslashes.
# Converting to forward slashes first is what makes those two functions see the
# same structure on Windows that they see on Linux, so the harness decision
# stays in one owner rather than growing a second, platform-specific rule.
#
# Without the conversion the verdict would rest on basename's platform
# behaviour, which differs: MSYS basename splits on backslashes while GNU
# basename does not, so the same string identifies a different thing depending
# on which coreutils answered.
#
# Note this deliberately does NOT narrow fm_harness_path_name's documented
# component match. A path with a "claude" directory in it resolves as a harness
# here exactly as "/home/claude/proj/node" already does on Linux; that widening
# is upstream's trade-off for a version-named Claude Code binary, and narrowing
# it on one platform only would be the real defect.
_fm_harness_native_comm() {  # <windows-path>
  local path=$1 backslash=$'\\' slash='/'
  [ -n "$path" ] || return 1
  # Pattern and replacement both go through quoted variables on purpose.
  # Writing the backslash inline in the brace expansion does not survive
  # bash's parsing here: it silently leaves the string untouched, which is
  # how a no-op conversion shipped once already.
  # tests/fm-winproc-lib.test.sh pins the conversion so that cannot recur.
  printf '%s' "${path//"$backslash"/"$slash"}"
}

# Print this session's verified-harness ancestry from Windows process facts, or
# return 1. Same contiguous-run contract as fm_harness_ancestry_pids, whose
# comment owns the reasoning; this is only a different evidence source.
#
# Two independent sources, so no single vendor string is load-bearing:
#
#   1. CLAUDE_PID, which Claude Code exports into every hook environment and
#      which names the claude.exe Windows pid directly. Costs one `ps -W`
#      (~240ms) to confirm the pid is live and is really a harness image.
#   2. A walk up the real Windows parent chain. This is the structural source
#      and the only one that works for a harness exporting no pid at all, but
#      it costs one PowerShell CIM snapshot (~1.5s) and it breaks if an
#      intermediate shell has already exited, since Windows does not reparent.
#
# Either source alone is sufficient for a positive verdict. Both are tried
# because they fail for unrelated reasons.
_fm_harness_ancestry_pids_native_uncached() {
  local pid comm extending=0 printed=0
  fm_winproc_available || return 1

  # Source 1: the harness-exported pid.
  case "${CLAUDE_PID:-}" in
    ''|*[!0-9]*) ;;
    *)
      if comm=$(fm_winproc_command "$CLAUDE_PID" 2>/dev/null) \
        && comm=$(_fm_harness_native_comm "$comm") \
        && fm_harness_process_matches "$comm" ""; then
        printf '%s\n' "$CLAUDE_PID"
        return 0
      fi
      ;;
  esac

  # Source 2: the Windows parent chain.
  pid=$(fm_winproc_self) || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(fm_winproc_table_command "$pid" 2>/dev/null) || comm=
    comm=$(_fm_harness_native_comm "$comm" 2>/dev/null) || comm=
    if [ -n "$comm" ] && fm_harness_process_matches "$comm" ""; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(fm_winproc_ppid "$pid" 2>/dev/null) || break
    [ "$pid" -gt 1 ] 2>/dev/null || break
  done
  [ "$printed" -eq 1 ]
}

_FM_HARNESS_NATIVE_ANCESTRY=
_FM_HARNESS_NATIVE_ANCESTRY_DONE=0

# Memoizing front for the resolver above.
#
# The turn-end path asks this three times through fm_session_lock_owned_by_self,
# and each miss costs a process table read - measured at 0.6s for the ps -W
# snapshot and 3.1s for the CIM one on this host. The answer cannot change
# inside a single process either, because the harness that owns this session
# outlives it by definition, so caching it is free correctness rather than a
# trade. An empty cached value records a resolved failure, so a second call
# does not re-pay for the same negative answer.
_fm_harness_ancestry_pids_native() {
  if [ "$_FM_HARNESS_NATIVE_ANCESTRY_DONE" = 1 ]; then
    [ -n "$_FM_HARNESS_NATIVE_ANCESTRY" ] || return 1
    printf '%s
' "$_FM_HARNESS_NATIVE_ANCESTRY"
    return 0
  fi
  _FM_HARNESS_NATIVE_ANCESTRY_DONE=1
  _FM_HARNESS_NATIVE_ANCESTRY=$(_fm_harness_ancestry_pids_native_uncached) || {
    _FM_HARNESS_NATIVE_ANCESTRY=
    return 1
  }
  [ -n "$_FM_HARNESS_NATIVE_ANCESTRY" ] || return 1
  printf '%s
' "$_FM_HARNESS_NATIVE_ANCESTRY"
}

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
  # On a host where this process tree cannot reach its own harness, Windows
  # process facts are the only usable evidence. Inert everywhere else.
  _fm_harness_ancestry_pids_native && return 0
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
  # MSYS pids and Windows pids are different number spaces, so kill -0 on a
  # live Windows pid reports "No such process". Ask Windows first.
  #
  # A pid Windows does not describe is NOT reported dead here, it falls through
  # to the check below. On a Git Bash host a recorded pid can belong to either
  # space - the native resolver writes a Windows pid, while an MSYS-side process
  # writes an MSYS one - and answering only for the Windows space would call a
  # live MSYS process dead. The fall-through cannot invent a live process: a
  # genuinely dead pid fails both checks.
  if fm_winproc_available; then
    if comm=$(fm_winproc_command "$pid" 2>/dev/null); then
      comm=$(_fm_harness_native_comm "$comm") || return 1
      fm_harness_process_matches "$comm" ""
      return
    fi
  fi
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
