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

# --- Windows (Git Bash/MSYS) native ancestry --------------------------------
#
# The POSIX walk below reads the process tree with `ps -o comm= -p` and climbs by
# `ps -o ppid= -p`. Neither works under Git Bash/MSYS: its Cygwin `ps` rejects the
# `-o` fields outright, and even where a process listing is available its parent
# chain dead-ends at the MSYS boundary (the outermost shell reports ppid 1), so it
# can never reach the native harness process such as claude.exe that actually owns
# the session. The result was that fm_harness_ancestry_pid always failed and every
# Windows session refused the fleet lock as read-only.
#
# On Windows these helpers walk the REAL Windows process tree instead, keyed on
# Windows PIDs throughout, and hand the same (comm, args) evidence to
# fm_harness_process_matches so the identity contract is exactly the one the POSIX
# path uses. The current shell's Windows PID is read from /proc/<pid>/winpid, which
# Git Bash exposes. The process table comes from a single Win32_Process query (a
# stable WMI/kernel fact, not a release-note-fragile string), captured once per
# invocation. FM_WIN_PROCTABLE_CMD and FM_WIN_SELF_WINPID override the two sources
# so the walk is testable against a deterministic tree on any host, and
# FM_FORCE_WINDOWS forces this path for that test.
fm_is_windows() {
  case "${FM_FORCE_WINDOWS:-${OSTYPE:-}}" in
    1|msys*|mingw*|cygwin*) return 0 ;;
  esac
  return 1
}

# Print the current shell's Windows PID - the pid whose ancestry is walked.
fm_win_self_winpid() {
  local wp
  if [ -n "${FM_WIN_SELF_WINPID:-}" ]; then
    printf '%s\n' "$FM_WIN_SELF_WINPID"
    return 0
  fi
  wp=$(cat "/proc/$$/winpid" 2>/dev/null) || return 1
  case "$wp" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$wp"
}

# Query the native process table once and emit it as
# "<pid><TAB><ppid><TAB><name><TAB><commandline>" lines. Command-line tabs and
# newlines are flattened to spaces so every process stays one parseable line.
fm_win_proctable_native() {
  local out
  # shellcheck disable=SC2016 # single quotes are deliberate: $_/$cl/$t are PowerShell variables, not shell
  out=$(powershell.exe -NoProfile -NonInteractive -Command '
$t = [char]9
Get-CimInstance Win32_Process | ForEach-Object {
  $cl = $_.CommandLine
  if ($cl) { $cl = $cl -replace "[\r\n\t]", " " }
  ($_.ProcessId, $_.ParentProcessId, $_.Name, $cl) -join $t
}
' 2>/dev/null) || return 1
  printf '%s\n' "$out" | tr -d '\r'
}

FM_WIN_PROCTABLE_CACHE=
fm_win_proctable() {
  if [ -n "${FM_WIN_PROCTABLE_CMD:-}" ]; then
    eval "$FM_WIN_PROCTABLE_CMD"
    return
  fi
  if [ -n "$FM_WIN_PROCTABLE_CACHE" ]; then
    printf '%s\n' "$FM_WIN_PROCTABLE_CACHE"
    return 0
  fi
  FM_WIN_PROCTABLE_CACHE=$(fm_win_proctable_native) || return 1
  [ -n "$FM_WIN_PROCTABLE_CACHE" ] || return 1
  printf '%s\n' "$FM_WIN_PROCTABLE_CACHE"
}

# A trusted harness anchor for the Windows walk, or return 1.
#
# MSYS emulates fork() by spawning through a helper that then exits, so a script
# launched as a child (fm-session-start.sh spawns fm-lock.sh, which spawns the
# walk) is routinely orphaned: its recorded Win32 parent pid names an already-dead
# launcher, and the parent-chain walk cannot climb from it to the harness. Claude
# Code exports its own pid as CLAUDE_PID into every descendant's environment, which
# survives that orphaning because it is inherited, not derived from the live tree.
# When CLAUDE_PID names a process the table still confirms as a live harness we
# anchor the walk there; a missing, stale, or non-harness value fails closed to the
# honest parent-chain walk from this shell's own Windows PID.
fm_win_harness_anchor_pid() {
  local pid=${CLAUDE_PID:-}
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

# Windows counterpart of fm_harness_ancestry_pids: the same contiguous-run and
# stop-at-first-gap semantics, walked over the native Windows process tree, but
# seeded from the trusted harness anchor when one is available.
fm_win_harness_ancestry_pids() {
  local pid comm args ppid line table extending=0 printed=0
  pid=$(fm_win_harness_anchor_pid) || pid=$(fm_win_self_winpid) || return 1
  table=$(fm_win_proctable) || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    line=$(printf '%s\n' "$table" | awk -F '\t' -v p="$pid" '$1 == p { print; exit }')
    [ -n "$line" ] || break
    comm=$(printf '%s' "$line" | cut -f3)
    args=$(printf '%s' "$line" | cut -f4-)
    ppid=$(printf '%s' "$line" | cut -f2)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    case "$ppid" in
      ''|*[!0-9]*) break ;;
    esac
    [ "$ppid" -gt 0 ] || break
    pid=$ppid
  done
  [ "$printed" -eq 1 ]
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
  if fm_is_windows; then
    fm_win_harness_ancestry_pids
    return
  fi
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
  local pid=$1 comm args line
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if fm_is_windows; then
    line=$(fm_win_proctable | awk -F '\t' -v p="$pid" '$1 == p { print; exit }')
    [ -n "$line" ] || return 1
    comm=$(printf '%s' "$line" | cut -f3)
    args=$(printf '%s' "$line" | cut -f4-)
    fm_harness_process_matches "$comm" "$args"
    return
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
