#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# Claude session id below matches the id recorded beside a live lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

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

# Print the exact harness name that is a whole word of a path-like argument in
# argument string $1 - words split at / - _ @ and quotes - or return 1.
#
# Windows cannot rename a process image, so a Node- or Python-hosted harness
# that retitles itself elsewhere (Pi sets process.title to "pi") still reports
# as node.exe there, and only its script path names it: .../pi-coding-agent/...
# Whole words keep this safe the same way whole path components do above: api,
# pipeline, and ompd are not pi or omp. A dot does not split, so a dot-directory
# such as .pi or .omp (the fleet's own extension scripts) is never pi or omp.
# Pi alone is too short a word to trust as any component, since an unrelated
# script such as C:/work/pi/tool.js has one, so it is identified only by its own
# package directory, pi-coding-agent.
# Only arguments containing a slash are read, so a prompt word never identifies
# a harness. Windows hosts only: elsewhere every harness retitles its process.
fm_harness_word_name() {  # <args>
  local -a tokens words
  local token word name
  read -ra tokens <<< "$1"
  for token in "${tokens[@]:1}"; do
    case "$token" in */*) ;; *) continue ;; esac
    case "$token/" in */pi-coding-agent/*) printf 'pi'; return 0 ;; esac
    IFS='/-_@"'"'" read -ra words <<< "$token"
    for word in "${words[@]}"; do
      for name in "${FM_HARNESS_NAMES[@]}"; do
        [ "$name" != pi ] || continue
        [ "$word" = "$name" ] && { printf '%s' "$name"; return 0; }
      done
    done
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
#   3. a bare interpreter (node, python) running a harness script path, by the
#      loose regex or, on a Windows host, by an exact harness word in that path.
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
      if fm_win_host && name=$(fm_harness_word_name "$args"); then
        case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
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

# --- process reads -------------------------------------------------------------
# Every per-pid question below goes through fm_proc_read and fm_proc_parent, so
# the Windows host path lives in exactly one place.
#
# Windows hosts (Git Bash, MSYS2, Cygwin). A shell started by a native Win32
# process such as claude.exe is reparented to pid 1 in the POSIX process
# namespace, and MSYS ps rejects -o outright, so a POSIX walk sees no harness in
# its ancestry. The Win32 process table does carry it, so on these hosts every
# read uses that table, and every pid this library prints or accepts - including
# the one written to state/.lock - is a Windows pid. Claude Code's CLAUDE_PID is
# a Windows pid there too, so the trusted same-session check lines up.

# True on a Windows host.
fm_win_host() {
  [ -r "/proc/$$/winpid" ]
}

# Print the Windows pid the walk starts from: the topmost process of this
# shell's POSIX ancestry, the one a native Win32 process started. An exec (hooks
# exec their script) replaces the Windows process behind a POSIX pid and the
# replaced one can exit, which breaks the Win32 parent chain below the topmost
# shell while the POSIX chain in /proc stays intact. Every POSIX ancestor is an
# MSYS program and never a native harness, so skipping them loses no match.
fm_win_self_pid() {
  local pid=$$ ppid w
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    ppid=$(cat "/proc/$pid/ppid" 2>/dev/null) || break
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" -gt 1 ] && [ -r "/proc/$ppid/winpid" ] || break
    pid=$ppid
  done
  w=$(cat "/proc/$pid/winpid" 2>/dev/null) || return 1
  case "$w" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$w"
}

# Print the Win32 process table: one "pid<TAB>ppid<TAB>created<TAB>exe<TAB>cmdline"
# row per process. created is the creation time in FILETIME ticks (0 when
# Windows withholds it); exe falls back to the image name when the path is
# withheld, so that field is never empty.
fm_win_process_table() {
  # shellcheck disable=SC2016 # the $ names are PowerShell's, not the shell's
  powershell.exe -NoProfile -NonInteractive -Command '
    Get-CimInstance Win32_Process | ForEach-Object {
      $exe = if ($_.ExecutablePath) { $_.ExecutablePath } else { $_.Name }
      $created = if ($_.CreationDate) { $_.CreationDate.ToFileTimeUtc() } else { 0 }
      "{0}`t{1}`t{2}`t{3}`t{4}" -f $_.ProcessId, $_.ParentProcessId, $created, $exe, ($_.CommandLine -replace "[\t\r\n]", " ")
    }' 2>/dev/null
}

# Reduce command line $1 (forward slashes) to the harness evidence
# fm_harness_process_matches reads from it, into FM_WIN_EVIDENCE: argv0 and each
# argument that names a harness, every other argument replaced by "-" so each
# verdict is unchanged. Prompts, flags, and secrets never reach memory or the
# cache. A line that names no harness at all skips the per-argument pass.
FM_WIN_EVIDENCE=''
_fm_win_harness_evidence() {  # <cmdline>
  local -a tokens
  local token
  read -ra tokens <<< "$1"
  FM_WIN_EVIDENCE=${tokens[0]:-}
  if [ "${#tokens[@]}" -gt 1 ] && ! [[ $1 =~ $FM_HARNESS_RE ]] \
    && ! fm_harness_word_name "$1" >/dev/null; then
    FM_WIN_EVIDENCE+=' -'
    return 0
  fi
  for token in "${tokens[@]:1}"; do
    if [[ $token =~ $FM_HARNESS_RE ]] || fm_harness_word_name "- $token" >/dev/null; then
      FM_WIN_EVIDENCE+=" $token"
    else
      FM_WIN_EVIDENCE+=' -'
    fi
  done
}

# Load the table once per shell into sparse pid-indexed arrays. comm is the
# executable path with forward slashes and no .exe suffix, so the shared matcher
# sees the same shape it sees on macOS; args is only the command line's harness
# evidence (_fm_win_harness_evidence). An empty or unreadable table fails closed.
# A hot path now needs the file cache: bin/fm-lock.sh's own confirm-own-lock
# check re-walks the ancestry inside $(...), which forks and loses this
# in-memory flag, so every such call paid its own fresh multi-second
# PowerShell round trip - fine alone, but compounding badly when concurrent
# lock confirmations contend for the same CPU/WMI subsystem. $$ stays the
# top-level script's pid even inside a command-substitution subshell (unlike
# BASHPID), so it names one snapshot shared by every subshell of one script
# run without colliding with a concurrent process's own cache file.
FM_WIN_TABLE_LOADED=0
fm_win_table_load() {
  [ "$FM_WIN_TABLE_LOADED" -eq 1 ] && return 0
  local table pid ppid created exe cmd rows=0 fresh=1 snapshot=''
  local cache_dir="${TMPDIR:-/tmp}" cache="${TMPDIR:-/tmp}/.fm-win-table.$$"
  # Sweep stale caches before adding this one: each is a single short-lived
  # script invocation's snapshot, so anything a couple of minutes old is a
  # leftover from a process that already exited, never cleaned up after
  # itself since no single caller here owns the others' lifetimes. Bounds
  # growth without needing coordinated cleanup across every source of this
  # shared library.
  find "$cache_dir" -maxdepth 1 -name '.fm-win-table.*' -mmin +2 -delete 2>/dev/null || true
  # Only a cache this user owns is trusted: in a shared TMPDIR another user
  # could otherwise plant the snapshot this walk decides lock ownership from.
  if [ -s "$cache" ] && [ -O "$cache" ] && [ ! -L "$cache" ]; then
    table=$(cat "$cache" 2>/dev/null)
    fresh=0
  else
    table=$(fm_win_process_table | tr -d '\r') || return 1
  fi
  FM_WIN_PPID=() FM_WIN_CREATED=() FM_WIN_COMM=() FM_WIN_ARGS=()
  while IFS=$'\t' read -r pid ppid created exe cmd; do
    case "$pid:$ppid:$created" in *[!0-9:]*|:*|*::*|*:) continue ;; esac
    [ -n "$exe" ] || continue
    exe=${exe//\\//}
    case "$exe" in *.[eE][xX][eE]) exe=${exe%.*} ;; esac
    _fm_win_harness_evidence "${cmd//\\//}"
    FM_WIN_PPID[pid]=$ppid
    FM_WIN_CREATED[pid]=$created
    FM_WIN_COMM[pid]=$exe
    FM_WIN_ARGS[pid]=$FM_WIN_EVIDENCE
    [ "$fresh" -eq 0 ] || snapshot+="$pid"$'\t'"$ppid"$'\t'"$created"$'\t'"$exe"$'\t'"$FM_WIN_EVIDENCE"$'\n'
    rows=$((rows + 1))
  done <<EOF
$table
EOF
  [ "$rows" -gt 0 ] || return 1
  # The cache holds the parsed columns only, never a raw command line, and is
  # created readable by this user alone.
  if [ "$fresh" -eq 1 ] && [ ! -e "$cache" ]; then
    (umask 077 && printf '%s' "$snapshot" > "$cache") 2>/dev/null || true
  fi
  FM_WIN_TABLE_LOADED=1
}

# Read pid $1's command name and argument string into FM_PROC_COMM and
# FM_PROC_ARGS, or return 1 when it is not a readable process. A Windows pid is
# checked to be digits first, because bash evaluates an array subscript as
# arithmetic and a corrupt lock file must never reach one.
FM_PROC_COMM=''
FM_PROC_ARGS=''
fm_proc_read() {  # <pid>
  local pid=$1
  if fm_win_host; then
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    fm_win_table_load || return 1
    [ -n "${FM_WIN_COMM[pid]:-}" ] || return 1
    FM_PROC_COMM=${FM_WIN_COMM[pid]}
    FM_PROC_ARGS=${FM_WIN_ARGS[pid]}
    return 0
  fi
  FM_PROC_COMM=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  FM_PROC_ARGS=$(ps -o args= -p "$pid" 2>/dev/null)
}

# Print pid $1's parent, or return 1 when there is none worth following.
#
# POSIX: examine the top of the chain before stopping. Inside a PID namespace
# the harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
# very process the walk exists to find. A host's real pid 1 (init, systemd,
# launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
#
# Windows reuses pids, so a parent that exited can leave its id to an unrelated
# newer process. The parent must provably predate its child: a recorded parent
# created after its child is that reuse, and a withheld creation time on either
# side (stored as 0) proves nothing, so both end the walk rather than crossing
# into a stranger's tree. Call fm_proc_read on $1 first so the table is loaded.
fm_proc_parent() {  # <pid>
  local pid=$1 ppid pc cc
  if fm_win_host; then
    ppid=${FM_WIN_PPID[pid]:-}
    [ -n "$ppid" ] && [ "$ppid" -gt 1 ] && [ -n "${FM_WIN_COMM[ppid]:-}" ] || return 1
    pc=${FM_WIN_CREATED[ppid]} cc=${FM_WIN_CREATED[pid]}
    [ "$pc" -gt 0 ] && [ "$cc" -gt 0 ] && [ "$pc" -le "$cc" ] || return 1
    printf '%s\n' "$ppid"
    return 0
  fi
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$ppid" in '' | *[!0-9]*) return 1 ;; esac
  [ "$ppid" -ge 1 ] || return 1
  printf '%s\n' "$ppid"
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
  local pid=$$ extending=0 printed=0
  if fm_win_host; then
    pid=$(fm_win_self_pid) || return 1
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    fm_proc_read "$pid" || break
    if fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(fm_proc_parent "$pid") || break
  done
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
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

# True if $1 is a live process that looks like a verified harness.
# A Windows pid is not in the POSIX namespace kill -0 probes, so on a Windows
# host the process table alone decides.
fm_harness_pid_alive() {
  local pid=$1
  fm_win_host || kill -0 "$pid" 2>/dev/null || return 1
  fm_proc_read "$pid" || return 1
  fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"
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
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    fm_proc_read "$pid" || return 1
    fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS" || return 1
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

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
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

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: the recorded pid is a live verified harness.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness. Existence of a lock file, a
# session record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  case "$pid" in
    ''|*[!0-9]*)
      FM_LOCK_INSPECT_STATE=unknown
      return 0
      ;;
  esac
  # A Windows host has no kill -0 or ps view of a Windows pid. A table that
  # cannot be read leaves the lock unknown, never stale; a pid absent from a
  # readable table is gone.
  if fm_win_host; then
    fm_win_table_load || return 0
    if [ -z "${FM_WIN_COMM[pid]:-}" ]; then
      # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
      FM_LOCK_INSPECT_STATE=stale
      # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    elif fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}
