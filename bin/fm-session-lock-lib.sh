#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake;
# bin/fm-sessionstart-nudge.sh borrows only its process backend, keeping its own
# independent ownership loop.
# This file is sourced by scripts and has no side effects on source.
#
# It also owns the process backend the identity questions are read through, so
# that "which pid space is this home's lock written in" has exactly one answer
# per host. See the process backend section below for the Windows case.

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
  return 1
}

# --- process backend --------------------------------------------------------
#
# ONE owner of "how do I read a process's name, arguments and parent on this
# host". POSIX `ps -o <field>= -p <pid>` is the native answer, and the only one
# the harness identity above ever needed - until Windows.
#
# Git Bash / MSYS2 breaks it twice over:
#   1. its `ps` implements none of -o/-p, so every field read fails outright;
#   2. its pid space stops at the MSYS boundary. A shell launched by a NATIVE
#      Windows harness is reported with ppid 1, so the harness is not merely
#      misnamed in MSYS ancestry - it is absent from it. `kill -0` is broken the
#      same way, because an MSYS pid and a Win32 pid are different numbers for
#      different things.
# The Win32 process table has the real chain (bash -> bash -> claude.exe -> ...),
# so on Windows every pid handled below - including the one written to
# state/.lock - is a Win32 pid, which is also the pid space Node-based harnesses
# such as Pi already report as process.pid.
#
# Backend selection is a CAPABILITY probe, not an OS test: a host whose `ps`
# answers `-o ppid= -p` is posix. That keeps the library honest under the test
# suite's fake `ps`, which is a posix `ps` by construction.
FM_PROC_BACKEND=${FM_PROC_BACKEND:-}
FM_WIN_PS_EXE=${FM_WIN_PS_EXE:-}
FM_WIN_PROC_TABLE=
FM_WIN_PROC_TABLE_AT=-1
# Bounded staleness for the Win32 snapshot. One PowerShell round trip costs
# ~0.5s, so a walk must not pay it per hop; a few seconds of staleness cannot
# change a harness liveness verdict that the callers already re-check.
FM_WIN_PROC_TTL=${FM_WIN_PROC_TTL:-3}

# Emits one TAB-separated row per process: pid, ppid, executable path, command
# line. Tabs and newlines are squeezed out of both text fields because a Windows
# command line legitimately contains both and this protocol is line-oriented.
# ExecutablePath and CommandLine are empty for processes the session may not
# open, so each falls back to the next-best identity rather than an empty field.
# shellcheck disable=SC2016 # Single quotes are required: $p and $_ are PowerShell variables and must reach PowerShell unexpanded.
FM_WIN_PROC_SCRIPT='
try { $ps = Get-CimInstance Win32_Process -ErrorAction Stop }
catch { $ps = Get-WmiObject Win32_Process -ErrorAction SilentlyContinue }
foreach ($p in $ps) {
  $e = $p.ExecutablePath; if (-not $e) { $e = $p.Name }
  $c = $p.CommandLine;    if (-not $c) { $c = $e }
  "{0}`t{1}`t{2}`t{3}" -f $p.ProcessId, $p.ParentProcessId,
    ($e -replace "[\r\n\t]", " "), ($c -replace "[\r\n\t]", " ")
}'

# Locate a PowerShell able to read the Win32 process table. Sets FM_WIN_PS_EXE.
fm_win_powershell() {
  [ -n "$FM_WIN_PS_EXE" ] && return 0
  local candidate
  for candidate in powershell.exe pwsh.exe pwsh; do
    if command -v "$candidate" >/dev/null 2>&1; then
      FM_WIN_PS_EXE=$candidate
      return 0
    fi
  done
  return 1
}

# Decide the backend once. Sets FM_PROC_BACKEND to posix, windows, or none.
# "none" is a real outcome, not an error to paper over: it fails every identity
# question closed, which is what leaves a session read-only rather than letting
# it claim a home it cannot prove it owns.
fm_proc_backend_init() {
  [ -n "$FM_PROC_BACKEND" ] && return 0
  local proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if ps -o ppid= -p $$ >/dev/null 2>&1; then
    FM_PROC_BACKEND=posix
  elif [ -r "$proc_root/$$/winpid" ] && fm_win_powershell; then
    FM_PROC_BACKEND=windows
  else
    FM_PROC_BACKEND=none
  fi
  return 0
}

# Refresh the Win32 snapshot when stale. Sets FM_WIN_PROC_TABLE.
#
# MUST be called directly, never inside $( ), or the cache it populates dies
# with the subshell and every field read below pays its own PowerShell startup.
fm_win_proc_table_load() {
  [ -n "$FM_WIN_PROC_TABLE" ] \
    && [ "$FM_WIN_PROC_TABLE_AT" -ge 0 ] \
    && [ "$((SECONDS - FM_WIN_PROC_TABLE_AT))" -lt "$FM_WIN_PROC_TTL" ] \
    && return 0
  fm_win_powershell || return 1
  local table
  table=$("$FM_WIN_PS_EXE" -NoProfile -NonInteractive -Command "$FM_WIN_PROC_SCRIPT" 2>/dev/null) || return 1
  [ -n "$table" ] || return 1
  FM_WIN_PROC_TABLE=$table
  FM_WIN_PROC_TABLE_AT=$SECONDS
  return 0
}

# Prepare whatever the current backend needs before a walk. Same subshell rule.
fm_proc_snapshot() {
  fm_proc_backend_init
  [ "$FM_PROC_BACKEND" = windows ] && { fm_win_proc_table_load || return 1; }
  return 0
}

# Present a Windows executable path the way the harness matcher expects: forward
# slashes, so whole-component matching works at all, and no .exe suffix, so the
# exactly-named harnesses (pi, pi-signed) still match their own names.
fm_win_normalize_path() {  # <path>
  local path=${1//\\//}
  printf '%s' "${path%.[eE][xX][eE]}"
}

# Same, for a full command line. Windows quotes argv[0] whenever it contains a
# space, which would otherwise make ${args%% *} - the argv[0] the matcher reads -
# a fragment like "C:/Program rather than a path.
fm_win_normalize_args() {  # <cmdline>
  local args=${1//\\//} argv0 rest
  if [ "${args#\"}" != "$args" ]; then
    rest=${args#\"}
    argv0=${rest%%\"*}
    rest=${rest#*\"}
    args=$(fm_win_normalize_path "$argv0")$rest
  fi
  printf '%s' "$args"
}

# Print the snapshot row for Win32 pid $1, or return 1 when it holds no such
# live process.
fm_win_proc_row() {  # <pid>
  local pid=$1 row
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$FM_WIN_PROC_TABLE" ] || return 1
  row=$(printf '%s\n' "$FM_WIN_PROC_TABLE" | awk -F'\t' -v p="$pid" '$1 == p { print; exit }')
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# This process's pid in the backend's own pid space.
fm_proc_self_pid() {
  fm_proc_backend_init
  if [ "$FM_PROC_BACKEND" = windows ]; then
    local winpid proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
    winpid=$(cat "$proc_root/$$/winpid" 2>/dev/null) || return 1
    case "$winpid" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$winpid"
    return 0
  fi
  printf '%s' "$$"
}

# --- ancestry cursor --------------------------------------------------------
#
# The walk needs a "parent of" that is correct on both hosts, and on Windows
# that is NOT simply the Win32 parent. MSYS2 emulates fork() through an
# intermediate process that exits immediately, so a forked child - which is what
# every one of these scripts is - records a Win32 parent that is already dead,
# and the chain ends one hop above the child. Windows never reparents orphans,
# so there is nothing above a dangling parent to recover.
#
# MSYS's own /proc bridges precisely that gap: it tracks MSYS parentage across
# its emulated forks, and stops (ppid 1) exactly at the boundary where the
# parent is a native Windows process - which is where the Win32 table takes over
# and stays correct, because native harnesses spawn their children directly.
# So the cursor walks MSYS parentage while it lasts, mapping each hop through
# /proc/<pid>/winpid so every pid it yields is a Win32 pid, then continues up
# the Win32 chain from the last MSYS process.
FM_PROC_CURSOR=
FM_PROC_CURSOR_MSYS=

# Place the cursor on this process. Returns 1 when no backend can locate it.
fm_proc_walk_start() {
  fm_proc_backend_init
  FM_PROC_CURSOR=''
  FM_PROC_CURSOR_MSYS=''
  case "$FM_PROC_BACKEND" in
    posix)
      FM_PROC_CURSOR=$$
      ;;
    windows)
      local proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
      FM_PROC_CURSOR=$(cat "$proc_root/$$/winpid" 2>/dev/null) || return 1
      case "$FM_PROC_CURSOR" in ''|*[!0-9]*) return 1 ;; esac
      FM_PROC_CURSOR_MSYS=$$
      ;;
    *) return 1 ;;
  esac
  return 0
}

# Advance the cursor to the parent of the current hop; return 1 at the top of
# the ancestry. Reads FM_PROC_PPID, so it must follow fm_proc_read on the
# current hop.
fm_proc_walk_next() {
  local msys_ppid winpid proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ "$FM_PROC_BACKEND" = windows ] && [ -n "$FM_PROC_CURSOR_MSYS" ]; then
    msys_ppid=$(cat "$proc_root/$FM_PROC_CURSOR_MSYS/ppid" 2>/dev/null || true)
    case "$msys_ppid" in
      ''|*[!0-9]*|0|1) FM_PROC_CURSOR_MSYS= ;;
      *)
        winpid=$(cat "$proc_root/$msys_ppid/winpid" 2>/dev/null || true)
        case "$winpid" in
          ''|*[!0-9]*) FM_PROC_CURSOR_MSYS= ;;
          *)
            FM_PROC_CURSOR_MSYS=$msys_ppid
            FM_PROC_CURSOR=$winpid
            return 0
            ;;
        esac
        ;;
    esac
  fi
  case "$FM_PROC_PPID" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  FM_PROC_CURSOR=$FM_PROC_PPID
  return 0
}

# Read pid $1 into FM_PROC_COMM / FM_PROC_ARGS / FM_PROC_PPID; return 1 when it
# is not a live process. Reads all three fields at once because on Windows they
# come from one row, and calls no backend refresh of its own, so it is safe to
# use inside a loop that has already snapshotted.
FM_PROC_COMM=
FM_PROC_ARGS=
FM_PROC_PPID=
fm_proc_read() {  # <pid>
  local pid=$1 row
  FM_PROC_COMM=''
  FM_PROC_ARGS=''
  FM_PROC_PPID=''
  case "$FM_PROC_BACKEND" in
    posix)
      FM_PROC_COMM=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
      FM_PROC_ARGS=$(ps -o args= -p "$pid" 2>/dev/null)
      FM_PROC_PPID=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      ;;
    windows)
      row=$(fm_win_proc_row "$pid") || return 1
      FM_PROC_PPID=$(printf '%s' "$row" | cut -f2)
      FM_PROC_COMM=$(fm_win_normalize_path "$(printf '%s' "$row" | cut -f3)")
      FM_PROC_ARGS=$(fm_win_normalize_args "$(printf '%s' "$row" | cut -f4)")
      [ -n "$FM_PROC_COMM" ] || return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

# True when pid $1 is live in the backend's pid space. On Windows presence in
# the process table IS liveness; `kill -0` there answers about MSYS pids, which
# is a different question about a different process.
fm_proc_pid_alive() {  # <pid>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_PROC_BACKEND" in
    posix) kill -0 "$1" 2>/dev/null ;;
    windows) fm_win_proc_row "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
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
  local extending=0 printed=0
  fm_proc_snapshot || return 1
  fm_proc_walk_start || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    fm_proc_read "$FM_PROC_CURSOR" || break
    if fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
      printf '%s\n' "$FM_PROC_CURSOR"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    fm_proc_walk_next || break
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
  fm_proc_snapshot || return 1
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
  local pid=$1
  fm_proc_snapshot || return 1
  fm_proc_pid_alive "$pid" || return 1
  fm_proc_read "$pid" || return 1
  fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"
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
  # Snapshot before the subshell below, so the walk inherits a warm process
  # table instead of building its own and discarding it.
  fm_proc_snapshot || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
