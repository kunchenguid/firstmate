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
# The tag is only meaningful where the boundary applies; anywhere else it is
# rejected exactly like any other non-numeric lock value.
fm_win_untag_pid() {  # <pid>
  local winpid
  case "$1" in
    "$FM_WIN_PID_PREFIX"*) winpid=${1#"$FM_WIN_PID_PREFIX"} ;;
    *) return 1 ;;
  esac
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_win_boundary_applies || return 1
  printf '%s' "$winpid"
}

# True when $1 is a well-formed session-lock identity: a local pid, or a tagged
# Windows pid. Every reader of state/.lock decides "is this value usable at all"
# through this one predicate, because the readers are spread across several
# scripts and a private numeric test in any one of them silently rejects a valid
# holder - which reads as "startup never completed" and repeats the whole
# sequence on every clear or compact.
fm_session_pid_valid() {  # <value>
  fm_win_untag_pid "$1" >/dev/null && return 0
  case "$1" in
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

# Print the normalized executable path of live Windows process $1, or return 1.
# Presence in `ps -W` is also this bridge's liveness test, because kill -0 cannot
# answer that question across the namespace boundary.
fm_win_command() {  # <winpid>
  local winpid=$1 table out
  case "$winpid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  # Return 1 only when a readable table proves the pid absent, and 2 when the
  # table itself could not be read, so a caller can tell gone from unknown.
  table=$(ps -W 2>/dev/null) || return 2
  case "$table" in
    *WINPID*) ;;
    *) return 2 ;;
  esac
  out=$(printf '%s\n' "$table" | awk -v w="$winpid" '$4 == w { for (i = 8; i <= NF; i++) printf "%s%s", (i > 8 ? " " : ""), $i; exit }')
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
#
# CLAUDE_PID is inherited by every process a Claude pane starts, so it is taken
# only together with the CLAUDE_CODE_SESSION_ID Claude publishes beside it. That
# id is then trusted and recorded beside the lock, and a /clear re-key under the
# same pid refreshes it as on POSIX. A non-Claude primary hand-started from a
# Claude pane inherits both values and still resolves as that Claude session; no
# environment signal tells the two apart there.
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
    if [ "$var" = CLAUDE_PID ]; then
      case "${CLAUDE_CODE_SESSION_ID:-}" in ''|*$'\n'*|*$'\r'*) continue ;; esac
    fi
    comm=$(fm_win_command "$winpid") || continue
    fm_harness_process_matches "$comm" "$comm" || continue
    printf '%s%s\n' "$FM_WIN_PID_PREFIX" "$winpid"
    return 0
  done
  return 1
}

# --- one field reader, ps primary, ps-free route as fallback -----------------
# Every identity read of a live process in THIS FILE (comm, args, ppid)
# goes through fm_proc_info below, so the denied-ps fallback has exactly
# one place to apply here. The verdict rules never change: the fallback
# changes only which route the same kernel facts arrive by, and both
# routes report the same fields - macOS identity comes from the argv
# region because that is what `ps -o comm=` and `ps -o args=` report
# there, and a route that read a different fact would let the two
# routes hand one process two different verdicts.
#
# This guarantee is per-file on purpose. The sibling walkers in
# bin/fm-harness.sh, bin/fm-backend.sh, bin/fm-sessionstart-nudge.sh,
# and bin/fm-branch-outcome.sh own their own ancestry reads and still
# require an executable ps; a denied-ps host stays degraded there
# until they route through a shared provider (follow-up, issue #1).

# One stderr line per process run when the denied-ps route cannot
# answer. AGENTS.md session-start contract: a lock refusal owes its
# exact diagnostic - but a 16-hop walk over a dead provider must not
# print 48 lines, so the first cause wins and the rest stay silent.
FM_OS_PROC_DIAG_SHOWN=''
fm_os_proc_diag_once() {  # <message>
  if [ -z "$FM_OS_PROC_DIAG_SHOWN" ]; then
    FM_OS_PROC_DIAG_SHOWN=1
    printf 'fm-session-lock: %s\n' "$1" >&2
  fi
  return 0
}

# Parse one Linux "/proc/<pid>/stat" line ($1, format "<pid> (<comm>)
# <state> <ppid> ...") plus its already-NUL-flattened cmdline ($2) into
# "<ppid>TAB<comm>TAB<args>". Pure seam: a saved stat line drives it
# identically on any host, which is why the parsing lives here.
fm_linux_stat_triple() {  # <stat-line> <cmdline-args>
  local line=$1 args=$2 rest comm ppid
  case $line in
    *"("*") "*) ;;
    *) return 1 ;;
  esac
  # comm may contain spaces and parentheses, so cut the rest off the
  # LAST ") ", not the first. TAB/CR/LF are the record's delimiters,
  # so flatten them out of the field the kernel lets name anything.
  comm=${line#*(}
  comm=${comm%*) *}
  comm=$(printf '%s' "$comm" | LC_ALL=C tr '\012' ' ' | LC_ALL=C tr -c '\040-\176' '?')
  rest=${line##*") "}
  local -a fields
  IFS=' ' read -r -a fields <<< "$rest"
  ppid=${fields[1]:-}
  case $ppid in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\t%s\t%s\n' "$ppid" "$comm" "$args"
}

# OS provider for one pid: prints "<ppid>TAB<comm>TAB<args>", or returns 1.
# Called only when the ps binary itself cannot execute. Tests override this
# whole function to drive a deterministic table.
fm_os_proc_triple() {  # <pid>
  local proc_root stat_line args element count rc=0
  local -a argv
  case "$(uname -s 2>/dev/null)" in
    Linux)
      # The repo's other /proc readers (bin/fm-cursor-lib.sh,
      # bin/fm-wake-lib.sh, bin/fm-teardown.sh) all take
      # FM_PROC_ROOT_OVERRIDE so a fixture tree can drive them; this
      # reader honors the same hook for the same reason.
      proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
      [ -r "$proc_root/$1/stat" ] || return 1
      stat_line=$(cat "$proc_root/$1/stat" 2>/dev/null) || return 1
      [ -r "$proc_root/$1/cmdline" ] || return 1
      args=$(
        argv=()
        count=0
        while IFS= read -r -d '' element; do
          argv[count]=$element
          count=$((count + 1))
        done < "$proc_root/$1/cmdline" || exit 1
        while [ "$count" -gt 0 ] && [ -z "${argv[$((count - 1))]}" ]; do
          unset 'argv[count - 1]'
          count=$((count - 1))
        done
        if [ "$count" -gt 0 ]; then
          IFS=' '
          printf '%s' "${argv[*]}" | LC_ALL=C tr '\012' ' ' | LC_ALL=C tr -c '\040-\176' '?'
        fi
      ) || return 1
      fm_linux_stat_triple "$stat_line" "$args"
      ;;
    Darwin)
      # bin/fm-procinfo.py reads ppid through a self-verified
      # KERN_PROC_PID chain and identity (comm/args) through the
      # KERN_PROCARGS2 argv region - the same region ps reports, which
      # is what keeps the two routes one fact per field. python3 is an
      # optional toolchain member (Herdr ordering already depends on
      # it); without it the denied-ps route degrades to today's
      # fail-closed refusal rather than to a guess.
      if ! command -v python3 >/dev/null 2>&1; then
        fm_os_proc_diag_once 'ps cannot execute and no python3 is available for the ps-free identity provider; identity reads fail closed'
        return 1
      fi
      python3 "$(dirname -- "${BASH_SOURCE[0]}")/fm-procinfo.py" "$1" 2>/dev/null || rc=$?
      if [ "$rc" -ne 0 ]; then
        fm_os_proc_diag_once "ps cannot execute and the ps-free identity provider exited $rc; identity reads fail closed. Reproduce with: python3 $(dirname -- "${BASH_SOURCE[0]}")/fm-procinfo.py $1"
      fi
      return "$rc"
      ;;
    *)
      return 1
      ;;
  esac
}

# Confirm once per process run that the ps BINARY cannot execute, the
# only environment this fallback exists for. A lone call's 126/127 can
# also come from a sandbox acting on that single call, and an actual
# binary block refuses every call including `ps -V`; only the second
# justifies routing identity off ps. The probe result is cached, so a
# refused walk of 16 pids costs one probe. (Busybox-era ps -V failures
# would read as "ps works" and keep the stop - the price of requiring
# positive proof of the denial.)
_fm_ps_exec_denied() {
  local rc=0
  if [ -n "${_FM_PS_EXEC_DENIED+x}" ]; then
    if [ "$_FM_PS_EXEC_DENIED" = 1 ]; then
      return 0
    fi
    return 1
  fi
  ps -V >/dev/null 2>&1 || rc=$?
  case $rc in
    126 | 127) _FM_PS_EXEC_DENIED=1 ;;
    *) _FM_PS_EXEC_DENIED=0 ;;
  esac
  if [ "$_FM_PS_EXEC_DENIED" = 1 ]; then
    return 0
  fi
  return 1
}

# Read the identity fields of pid $1 into FM_PROC_COMM, FM_PROC_ARGS, and
# FM_PROC_PPID.
#
# ps stays primary everywhere it runs: while it executes, its output is
# used verbatim, so behavior is byte-identical to every session that ever
# worked. Only a ps that cannot execute at all - bash exits 126 for a
# refused exec, 127 for a missing binary - routes one read to the OS provider.
# Status 1 is platform-specific: Linux/macOS mean ps ran and named nothing;
# on Cygwin-family hosts it means ps refused the unsupported -o option and the
# fixed-column readers below are used instead. This exists because an
# EDR-style policy can deny the ps binary's exec itself (observed:
# /bin/ps refused even for `ps -V`, while kill, head, sysctl, pgrep, and
# lsof all ran) while every fact the identity walk needs remains readable
# through /proc or the kernel syscalls.
#
# Returning 1 means "no route can read this pid", which stops a walk
# exactly as a dead pid always has: nothing here ever fabricates a field.
fm_proc_info() {  # <pid>
  local pid=$1 rc=0 out comm args ppid
  FM_PROC_COMM='' FM_PROC_ARGS='' FM_PROC_PPID=''
  out=$(ps -o comm= -p "$pid" 2>/dev/null) || rc=$?
  case $rc in
    0) ;;
    1)
      # Linux/macOS: ps ran and named nothing. Cygwin-family: ps refused
      # -o, so use its fixed-column readers only on that platform route.
      fm_win_boundary_applies || return 1
      comm=$(fm_ps_comm "$pid") || return 1
      args=$(fm_ps_args "$pid") || return 1
      ppid=$(fm_ps_ppid "$pid") || return 1
      case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
      FM_PROC_COMM=$comm FM_PROC_ARGS=$args FM_PROC_PPID=$ppid
      return 0
      ;;
    126 | 127)
      # Confirmed, once per process: only a ps binary that cannot
      # execute at all justifies the second provider.
      _fm_ps_exec_denied || return 1
      local triple f1 f2 f3 rest tab
      tab=$'\t'
      triple=$(fm_os_proc_triple "$pid") || return 1
      # The provider record is one line with exactly three TAB-separated
      # fields: <ppid> <comm> <args>. The field count is proved by
      # rebuilding the record from the parsed fields and comparing it to
      # the original, because a TAB is IFS whitespace: a record with a
      # MISSING field would otherwise parse exactly like a record whose
      # field is legitimately empty, and a truncated record would be
      # half-parsed into a plausible but wrong identity.
      #
      # A comm or args field that is legitimately empty is a real answer
      # and is reported as one. A live process whose comm was emptied, and
      # a kernel thread with no cmdline, are both PRESENT processes; the
      # routes must agree about that, because a present pid that reads as
      # gone is a reclaimable lock.
      case $triple in
        *$'\n'*) return 1 ;;
      esac
      # The TAB is a literal, so it is matched through a quoted expansion
      # rather than an unquoted one: an unquoted $tab inside ${...} is a
      # pattern, and a TAB is a glob character that would match any
      # character. The record is split on literal TABs, and the rebuild
      # below compares literal strings.
      f1=${triple%%"$tab"*}
      rest=${triple#*"$tab"}
      f2=${rest%%"$tab"*}
      f3=${rest#*"$tab"}
      case $f3 in
        *"$tab"*) return 1 ;;
      esac
      if [ "$triple" = "$f1$tab$f2$tab$f3" ]; then
        :
      else
        return 1
      fi
      case $f1 in
        '' | *[!0-9]*) return 1 ;;
      esac
      FM_PROC_PPID=$f1 FM_PROC_COMM=$f2 FM_PROC_ARGS=$f3
      return 0
      ;;
    *)
      # 126/127 above are the statuses that prove "ps could not
      # execute at all". Anything else, including signal-killed 137,
      # means ps gave no answer, and callers read
      # a non-zero exactly as "this pid cannot be verified".
      return 1
      ;;
  esac
  # ps ran and named nothing. That is a real answer about a real
  # process - a live process whose comm was emptied is still a live
  # process - so it must NOT read as "the pid is gone". The callers
  # below each need this distinction: the ancestry walk stops either
  # way, but fm_session_lock_inspect separates "gone" (stale) from
  # "present but not classifiable" (unknown), and collapsing the two
  # here would report a live, unreadable pid as reclaimable and let a
  # fresh process take over a lock whose owner is still running.
  #
  # The empty comm is still reported, not invented: FM_PROC_COMM stays
  # empty and the matcher below rejects it, exactly as it rejects a
  # comm it does not recognise.
  comm=$out
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  # The ppid is a walk input, not an identity field. The identity the
  # matcher reads is comm and args, and both of those are fail-closed
  # above; a ppid that cannot be read only ends the ancestry walk one
  # hop early, which is the conservative direction - the walk finds no
  # harness and the session refuses the lock rather than taking one it
  # cannot prove.
  #
  # The base read the ppid the same tolerant way, and the repository's
  # grok and kimi harness suites pin that: their stubbed ps answers
  # comm= and args= and refuses every other question, so a ppid read
  # that failed had to leave the identity intact.
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$ppid" in ''|*[!0-9]*) ppid='' ;; esac
  FM_PROC_COMM=$comm FM_PROC_ARGS=$args FM_PROC_PPID=$ppid
  return 0
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
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    fm_proc_info "$pid" || break
    if fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$FM_PROC_PPID
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

# True when pid $1 is one of the lines of ancestry list $2.
fm_harness_pid_listed() {  # <pid> <ancestry-pids>
  local pid
  while IFS= read -r pid; do
    [ "$pid" = "$1" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

# True if $1 is a live process that looks like a verified harness.
# A tagged Windows pid uses the Windows process table; numeric pids use the
# shared identity provider and kill probe to distinguish dead from unreadable.
fm_session_lock_pid_verdict() {
  local pid=$1 winpid rc=0 comm
  FM_SESSION_LOCK_PID_VERDICT=unreadable
  if winpid=$(fm_win_untag_pid "$pid"); then
    comm=$(fm_win_command "$winpid") || rc=$?
    case $rc in
      0) FM_PROC_COMM=$comm FM_PROC_ARGS=$comm FM_PROC_PPID=; FM_SESSION_LOCK_PID_VERDICT=readable ;;
      1) FM_SESSION_LOCK_PID_VERDICT=dead ;;
    esac
    return 0
  fi
  case "$pid" in ''|*[!0-9]*|0) return 0 ;; esac
  # Liveness first, identity second. A pid this session cannot signal is
  # not a live owner it may reclaim over; a pid it CAN signal is alive,
  # and only then is its identity worth reading. Asking the identity
  # first would let a stale process-table entry report a dead owner as
  # live and keep a stale lock from ever being reclaimed - the same
  # permanent read-only wedge this change exists to remove.
  if kill -0 "$pid" 2>/dev/null; then
    # Alive. Its identity may still be unreadable, and that is the case
    # this verdict exists for: the owner is live, so its lock must not
    # be reclaimed.
    if fm_proc_info "$pid"; then
      FM_SESSION_LOCK_PID_VERDICT=readable
    fi
  elif fm_proc_info "$pid"; then
    # The process exists - this session simply may not signal it - so
    # it is not a dead owner, but it is not a harness this session can
    # prove either. The base contract treats that as "no live harness
    # owner", and the lock stays reclaimable.
    FM_SESSION_LOCK_PID_VERDICT=unknown
  else
    # Nothing can see the pid: it is gone.
    FM_SESSION_LOCK_PID_VERDICT=dead
  fi
  return 0
}

fm_harness_pid_alive() {
  fm_session_lock_pid_verdict "$1"
  [ "$FM_SESSION_LOCK_PID_VERDICT" = readable ] || return 1
  fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"
}

fm_session_lock_pid_blocks_reclaim() {
  fm_session_pid_valid "$1" || return 1
  case "$1" in
    "$FM_WIN_PID_PREFIX"*) ;;
    *[1-9]*) ;;
    *) return 1 ;;
  esac
  fm_session_lock_pid_verdict "$1"
  case "$FM_SESSION_LOCK_PID_VERDICT" in
    dead) return 1 ;;
    unreadable) return 0 ;;
    unknown) return 1 ;;
    readable) fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS" ;;
  esac
}

# Liveness and identity of a session-lock pid for readers outside this file:
# the supervision host's main-session key and the Claude auto-arm. A tagged
# Windows pid is answered from the Windows process table, as above; any other
# value goes to the generic fm_pid_alive and fm_pid_identity in
# bin/fm-wake-lib.sh, which those readers already have sourced.
fm_session_pid_alive() {  # <value>
  local winpid
  if winpid=$(fm_win_untag_pid "$1"); then
    fm_win_command "$winpid" >/dev/null
    return
  fi
  fm_pid_alive "$1"
}

# A tagged pid's identity is its Windows pid and executable path rather than a
# start time. Every reader pairs it with the session sidecar id, which a new
# session always changes, so a reused Windows pid still reads as a different
# session.
fm_session_pid_identity() {  # <value>
  local winpid comm
  if winpid=$(fm_win_untag_pid "$1"); then
    comm=$(fm_win_command "$winpid") || return 1
    printf 'win-pid=%s command=%s\n' "$winpid" "$comm"
    return 0
  fi
  fm_pid_identity "$1"
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
# and must never own a lock with them. On Windows the ancestry is that tagged
# CLAUDE_PID itself, so this membership is no secondary check there; the
# FM_WIN_HARNESS_PID_VARS comment owns that limitation. Ids are read from the
# environment only, never from ps argv, where prompts and briefs are visible.
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
    # On Windows the ancestry is the tagged pid the bridge already confirmed
    # from CLAUDE_PID and this same id, so it is matched in that form.
    case "$pid" in
      "$claude_pid")
        fm_proc_info "$pid" || return 1
        fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS" || return 1
        ;;
      "$FM_WIN_PID_PREFIX$claude_pid")
        fm_harness_pid_alive "$pid" || return 1
        ;;
      *) continue ;;
    esac
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
# outermost pid of its contiguous run, exactly as before; a trusted Windows
# session's run is its tagged CLAUDE_PID alone, so it records that tagged pid.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null \
    && fm_harness_pid_listed "$CLAUDE_PID" "$pids"; then
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
  local state=$1 lock_pid pids
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  fm_harness_pid_listed "$lock_pid" "$pids" && return 0
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
  local state=$1 lock_pid pids
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$lock_pid" || return 1
  fm_session_lock_pid_blocks_reclaim "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  fm_harness_pid_listed "$lock_pid" "$pids" && return 1
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
  local state=$1 lock pid winpid win_rc
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
  fm_session_pid_valid "$pid" || return 0
  if winpid=$(fm_win_untag_pid "$pid"); then
    # The same verdicts as a local pid below, read from the Windows table.
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
      return 0
    fi
  fi
  fm_session_lock_pid_verdict "$pid"
  case "$FM_SESSION_LOCK_PID_VERDICT" in
    dead)
      # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
      FM_LOCK_INSPECT_STATE=stale
      # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
      FM_LOCK_INSPECT_LIVE_HARNESS=false
      ;;
    readable)
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
      ;;
  esac
}
