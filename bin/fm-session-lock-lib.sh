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

# --- process-table portability ----------------------------------------------
#
# ONE owner of "how does this host answer comm/args/ppid for a pid?".
#
# This exists because MSYS2/Cygwin `ps` - the ps a Git Bash session on Windows
# actually runs - implements none of `-o comm=`, `-o args=`, or `-o ppid=`; it
# accepts only [-aefls] [-u UID] [-p PID] [-W]. Every ps-based ancestry walk
# therefore failed outright there, fm_harness_ancestry_pid could never resolve a
# pid, and fm-lock.sh refused the fleet lock on every session start with
# "cannot locate harness process in ancestry". The whole home stayed permanently
# read-only: no spawn, no steer, no merge, no wake drain.
#
# MSYS ps cannot substitute either. It reports MSYS pids whose parent chain is
# severed at the Win32 boundary (a Git Bash child of claude.exe reports ppid 1),
# and `ps -W` lists native processes with ppid 0. The real ancestry exists only
# in the Win32 process table, so on Windows that table is read directly and the
# walk runs in WINDOWS pids end to end - including the pid published in
# state/.lock, which stays self-consistent because every reader of that pid goes
# through these same primitives.
#
# POSIX hosts keep the exact `ps -o` calls they have always used, byte for byte,
# so a fake `ps` on PATH still drives this library deterministically in tests.
# Windows detection is a lazy capability probe, never a uname check: a host whose
# ps answers `-o` is POSIX here by definition.
#
# Everything below is shaped by one fact: on MSYS, forks and large pipe payloads
# are expensive, and a single session start runs dozens of short-lived firstmate
# scripts that each need this table. So the table is produced straight into a
# short-lived cache FILE by PowerShell, and every lookup is one awk pass over
# that file. Nothing carries the table through a command substitution.

# Records are: pid <TAB> ppid <TAB> name <TAB> executable-path <TAB> command-line
#
# The command line is truncated because nothing here reads past its head: the
# evidence this library takes from it is argv[0] and an interpreter's script
# path, both of which sit at the front. Tabs and newlines inside it are flattened
# so one process is always exactly one record.
FM_WIN_PS_CMDLINE_MAX="${FM_WIN_PS_CMDLINE_MAX:-300}"

# One line, deliberately: a -Command string with embedded newlines is read as an
# incomplete statement across the MSYS argument boundary and hangs waiting for
# the rest. Writes to $env:FM_WIN_PS_OUT when that names a file, stdout otherwise.
FM_WIN_PS_QUERY='$ErrorActionPreference="SilentlyContinue"; $m='"$FM_WIN_PS_CMDLINE_MAX"'; $out=$env:FM_WIN_PS_OUT; $rows=Get-CimInstance Win32_Process | ForEach-Object { $c=$_.CommandLine; if ($c -and $c.Length -gt $m) { $c=$c.Substring(0,$m) }; "{0}`t{1}`t{2}`t{3}`t{4}" -f $_.ProcessId,$_.ParentProcessId,$_.Name,$_.ExecutablePath,($c -replace "[`r`n`t]"," ") }; if ($out) { Set-Content -LiteralPath $out -Value $rows -Encoding ASCII } else { $rows }'

# How long a cached table may be reused, in seconds. Deliberately small: the only
# thing a stale table can do is report a process that exited within the window as
# still alive, which at worst delays a lock takeover by that window - a delay the
# surrounding lock protocol already tolerates, because it re-checks rather than
# deciding once.
FM_WIN_PS_CACHE_TTL="${FM_WIN_PS_CACHE_TTL:-5}"

FM_PS_MODE=''
FM_WIN_PS_FILE=''
FM_WIN_PS_CACHE=''

# Decide once whether this host's ps answers the -o field selectors, leaving the
# answer in $FM_PS_MODE for THIS shell.
#
# Callers must use this rather than the printing wrapper below in any hot path.
# `[ "$(fm_ps_mode)" = windows ]` re-probes on every call, because the caching
# assignment happens inside the command substitution's own subshell and dies with
# it - and that probe is a `ps` fork, one of the most expensive things an MSYS
# shell can do.
fm_ps_mode_init() {
  [ -n "$FM_PS_MODE" ] && return 0
  if ps -o comm= -p $$ >/dev/null 2>&1; then FM_PS_MODE=posix; else FM_PS_MODE=windows; fi
  # Resolve the cache path here, once per shell, so the warm lookup path below
  # spends no fork on `id`. Every hot caller already calls this directly.
  if [ "$FM_PS_MODE" = windows ] && [ -z "$FM_WIN_PS_CACHE" ]; then
    FM_WIN_PS_CACHE="${TMPDIR:-/tmp}/fm-win-ps-table.$(id -u 2>/dev/null || echo 0)"
  fi
  return 0
}

# Printing wrapper, for callers that want the value rather than the variable.
fm_ps_mode() {
  fm_ps_mode_init
  printf '%s' "$FM_PS_MODE"
}

# Print the PowerShell to run, or return 1 when this host has none.
fm_win_ps_exe() {
  local exe
  for exe in powershell.exe pwsh.exe pwsh; do
    if command -v "$exe" >/dev/null 2>&1; then printf '%s' "$exe"; return 0; fi
  done
  return 1
}

# Host-wide, per-user cache path. The Win32 process table is a property of the
# machine, not of a firstmate home, so homes may share one copy. It lives in the
# temp dir rather than state/ because it is a throwaway cache, not a fleet record.
fm_win_ps_cache_path() {
  fm_ps_mode_init
  if [ -n "$FM_WIN_PS_CACHE" ]; then printf '%s' "$FM_WIN_PS_CACHE"; return 0; fi
  printf '%s/fm-win-ps-table.%s' "${TMPDIR:-/tmp}" "$(id -u 2>/dev/null || echo 0)"
}

# True when file $1 exists, is non-empty, and is younger than the TTL.
#
# One `find` rather than stat plus date: on MSYS each avoided fork is worth more
# than the clarity of arithmetic, and this runs on every table lookup.
fm_win_ps_file_fresh() {  # <path>
  [ -n "$(find "$1" -maxdepth 0 -size +0c -newermt "-${FM_WIN_PS_CACHE_TTL} seconds" 2>/dev/null)" ]
}

# Print the path of a process-table file no older than the TTL, refreshing it
# first when needed. Returns 1 when the table cannot be produced at all.
#
# PowerShell writes the file itself, addressed by its Windows path, so the table
# never crosses the MSYS boundary as a pipe payload. The write goes to a
# temporary file that is then moved into place, so a concurrent reader never
# observes a half-written table.
fm_win_ps_table_file() {
  local cache exe tmp wtmp
  fm_ps_mode_init
  cache=${FM_WIN_PS_CACHE:-$(fm_win_ps_cache_path)}
  if fm_win_ps_file_fresh "$cache"; then
    printf '%s' "$cache"
    return 0
  fi

  exe=$(fm_win_ps_exe) || return 1
  tmp=$(mktemp "$cache.XXXXXX" 2>/dev/null) || return 1
  # stdin MUST be closed. PowerShell inherits the caller's stdin, and -Command
  # does not stop it waiting on that handle; invoked from a firstmate script
  # whose own stdin is a live terminal or pipe, it simply never returns, and the
  # lock acquire hangs with it. The command is also kept to ONE line: a -Command
  # string carrying embedded newlines across the MSYS argument boundary is read
  # as an incomplete statement and waits for the rest.
  wtmp=$(cygpath -w "$tmp" 2>/dev/null || true)
  if [ -n "$wtmp" ]; then
    # PowerShell names the output file itself, so the table never crosses the
    # MSYS boundary as a pipe payload.
    FM_WIN_PS_OUT="$wtmp" "$exe" -NoProfile -NonInteractive -Command "$FM_WIN_PS_QUERY" \
      </dev/null >/dev/null 2>&1 || true
  else
    # No cygpath to name the file in Win32 terms, so carry the table through the
    # pipe instead. Same result, just slower.
    "$exe" -NoProfile -NonInteractive -Command "$FM_WIN_PS_QUERY" \
      </dev/null > "$tmp" 2>/dev/null || true
  fi

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null || true
    # A refresh that produced nothing must not discard a usable older table.
    [ -s "$cache" ] && { printf '%s' "$cache"; return 0; }
    return 1
  fi
  mv -f "$tmp" "$cache" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; [ -s "$cache" ] || return 1; }
  printf '%s' "$cache"
}

# Warm the table in the CALLER's shell, so the lookups below - which may run in
# command substitutions - do not each re-check freshness. A no-op on POSIX.
fm_ps_preload() {
  fm_ps_mode_init
  [ "$FM_PS_MODE" = windows ] || return 0
  [ -n "$FM_WIN_PS_FILE" ] && [ -s "$FM_WIN_PS_FILE" ] && return 0
  FM_WIN_PS_FILE=$(fm_win_ps_table_file) || return 1
  return 0
}

# Print the current table file path, warming it if this shell has none.
fm_win_ps_file() {
  if [ -n "$FM_WIN_PS_FILE" ] && [ -s "$FM_WIN_PS_FILE" ]; then
    printf '%s' "$FM_WIN_PS_FILE"
    return 0
  fi
  fm_win_ps_table_file
}

# Print field $2 of the record for pid $1, or return 1 when it is not listed.
# Set-Content writes CRLF, so every awk program here drops a trailing CR before
# touching fields.
fm_win_ps_field() {  # <pid> <field-index>
  local pid=$1 field=$2 file
  file=$(fm_win_ps_file) || return 1
  awk -F'\t' -v p="$pid" -v f="$field" '
    { sub(/\r$/, "") }
    $1 == p { printf "%s", $f; found = 1; exit }
    END { exit !found }' "$file"
}

# The pid the Win32 ancestry walk must START from: the Win32 pid of the
# OUTERMOST process in this shell's own MSYS ancestry. On POSIX this is just $$.
#
# Two process namespaces meet here, and neither can answer the whole chain. MSYS
# pids are private to the MSYS runtime, so the Win32 table has never heard of
# them. Win32 parent pointers, meanwhile, are not trustworthy across an MSYS
# fork: MSYS emulates fork() through a helper process that exits immediately,
# leaving the child's recorded ParentProcessId aimed at a dead - and eventually
# recycled - pid. Walking Win32 alone therefore dies at the first forked shell,
# which is exactly the shape every `bash bin/fm-*.sh` call has.
#
# So the MSYS side is climbed with MSYS ps, which does know those parents, and
# the namespace boundary is crossed exactly once at the outermost MSYS process -
# whose WINPID is real and whose Win32 parent is a live native process.
#
# Skipping over the MSYS processes themselves costs nothing: on Windows every
# verified harness is a native executable, never an MSYS process, so no harness
# can hide inside the stretch of chain this jumps.
fm_ps_self_pid() {
  local out
  fm_ps_mode_init
  if [ "$FM_PS_MODE" != windows ]; then
    printf '%s' "$$"
    return 0
  fi
  # MSYS ps default long format: PID PPID PGID WINPID TTY UID STIME COMMAND
  out=$(ps 2>/dev/null </dev/null | awk -v start="$$" '
    NR > 1 { ppid[$1] = $2; win[$1] = $4 }
    END {
      pid = start
      top = ""
      for (i = 0; i < 16; i++) {
        if (!(pid in win) || win[pid] !~ /^[0-9]+$/) break
        top = win[pid]
        parent = ppid[pid]
        # ppid 1 means the parent is outside MSYS: this is the boundary.
        if (parent !~ /^[0-9]+$/ || parent + 0 <= 1 || !(parent in win)) break
        pid = parent
      }
      if (top != "") print top
    }')
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}

# comm/args/ppid for a pid, keeping the exact exit-status contract of the ps
# calls they replace: nonzero when the process is not there.
fm_ps_comm() {  # <pid>
  local pid=$1 path name
  fm_ps_mode_init
  if [ "$FM_PS_MODE" = windows ]; then
    path=$(fm_win_ps_field "$pid" 4) || return 1
    if [ -n "$path" ]; then printf '%s' "$path"; return 0; fi
    name=$(fm_win_ps_field "$pid" 3) || return 1
    printf '%s' "$name"
    return 0
  fi
  ps -o comm= -p "$pid" 2>/dev/null
}

fm_ps_args() {  # <pid>
  local pid=$1 args
  fm_ps_mode_init
  if [ "$FM_PS_MODE" = windows ]; then
    args=$(fm_win_ps_field "$pid" 5) || return 1
    [ -n "$args" ] || args=$(fm_win_ps_field "$pid" 4)
    printf '%s' "$args"
    return 0
  fi
  ps -o args= -p "$pid" 2>/dev/null
}

fm_ps_ppid() {  # <pid>
  local pid=$1
  fm_ps_mode_init
  if [ "$FM_PS_MODE" = windows ]; then
    fm_win_ps_field "$pid" 2 || return 1
    return 0
  fi
  ps -o ppid= -p "$pid" 2>/dev/null
}

# Print this Win32 ancestry as "pid<TAB>comm<TAB>args" lines, innermost first,
# for at most 16 hops. One awk pass over the table file, so a whole walk costs a
# single fork instead of three per hop.
fm_win_ps_chain() {  # <start-pid>
  local start=$1 file
  file=$(fm_win_ps_file) || return 1
  awk -F'\t' -v start="$start" '
    { sub(/\r$/, "") }
    { ppid[$1] = $2; name[$1] = $3; path[$1] = $4; cmd[$1] = $5 }
    END {
      pid = start
      for (i = 0; i < 16; i++) {
        if (!(pid in ppid)) break
        comm = (path[pid] != "" ? path[pid] : name[pid])
        args = (cmd[pid] != "" ? cmd[pid] : comm)
        printf "%s\t%s\t%s\n", pid, comm, args
        parent = ppid[pid]
        if (parent !~ /^[0-9]+$/ || parent + 0 <= 1) break
        pid = parent
      }
    }' "$file"
}

# "<comm><TAB><args>" for a pid, or 1 when it is gone. Bypasses this shell's
# warmed path so a liveness answer is never older than FM_WIN_PS_CACHE_TTL.
fm_win_ps_probe() {  # <pid>
  local pid=$1 file
  file=$(fm_win_ps_table_file) || return 1
  awk -F'\t' -v p="$pid" '
    { sub(/\r$/, "") }
    $1 == p {
      comm = ($4 != "" ? $4 : $3)
      args = ($5 != "" ? $5 : comm)
      printf "%s\t%s\n", comm, args
      found = 1
      exit
    }
    END { exit !found }' "$file"
}

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
  local pid comm args extending=0 printed=0 chain
  fm_ps_preload
  if [ "$FM_PS_MODE" = windows ]; then
    pid=$(fm_ps_self_pid) || return 1
    chain=$(fm_win_ps_chain "$pid") || return 1
    # Fed by heredoc, never a pipe: the loop must run in THIS shell so the
    # matches it finds survive it.
    while IFS=$'\t' read -r pid comm args; do
      [ -n "$pid" ] || continue
      if fm_harness_process_matches "$comm" "$args"; then
        printf '%s\n' "$pid"
        printed=1
        [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
        extending=1
      elif [ "$extending" -eq 1 ]; then
        break
      fi
    done <<EOF
$chain
EOF
    [ "$printed" -eq 1 ]
    return
  fi
  pid=$$
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
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
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
fm_harness_pid_alive() {
  local pid=$1 comm args probe
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_ps_mode_init
  if [ "$FM_PS_MODE" = windows ]; then
    # kill -0 cannot answer for a Win32 pid from MSYS, so presence in a fresh
    # Win32 table IS the liveness test.
    probe=$(fm_win_ps_probe "$pid") || return 1
    comm=${probe%%$'\t'*}
    args=${probe#*$'\t'}
  else
    kill -0 "$pid" 2>/dev/null || return 1
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
  fi
  fm_harness_process_matches "$comm" "$args"
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
