#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

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

# --- Windows / Git Bash (MSYS) harness ancestry ------------------------------
# On Git Bash/MSYS/Cygwin the harness (e.g. claude.exe) is a NATIVE Windows
# process, and the POSIX emulation layer maps a native parent to init: both the
# Cygwin `ps` PPID column and /proc/<pid>/stat report the tool-call shell's
# parent as pid 1, so the shell-side ancestry walk can never reach the harness.
# Additionally that `ps` rejects the `-o`/`-p` fields the POSIX walk uses.
#
# The native Windows parent chain (Win32_Process.ParentProcessId, readable
# WITHOUT admin via CIM and keyed on Windows PIDs / WINPIDs) is only reliable
# from the TOP-LEVEL tool-call shell: MSYS emulates fork() by spawning throwaway
# Windows processes, so a script the shell spawns (e.g. bin/fm-lock.sh) has a
# ParentProcessId pointing at a fork stub that has already exited, severing the
# chain before it reaches the harness. The robust anchor is the harness PID the
# harness itself exports into the environment (CLAUDE_PID), inherited by every
# descendant and therefore immune to that boundary; the CIM walk stays as a
# best-effort fallback for harnesses that do not export one.
#
# So on Windows the lock identity is the harness WINPID. Every helper fails
# CLOSED (non-zero / no output) when the toolchain is missing or the harness
# cannot be resolved, keeping the session read-only rather than ever falsely
# claiming ownership.
_FM_LOCK_UNAME=$(uname -s 2>/dev/null || echo unknown)

_fm_is_windows() {
  case "$_FM_LOCK_UNAME" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Walk the native Windows ancestry from FM_START_WINPID up to the outermost
# harness process. Mirrors fm_harness_ancestry_pid's shape: for a claude-named
# match, keep walking through consecutive claude ancestors (the bg-spare hook
# worker chain) and stop the instant a non-match follows; any other harness
# match wins at its innermost pid.
_FM_PS_ANCESTRY='
$ErrorActionPreference="SilentlyContinue"; $ProgressPreference="SilentlyContinue"
$id=[int]$env:FM_START_WINPID
$h="(claude|codex|opencode|grok|kimi|pi|pi-signed)"
$best=0; $ext=$false
for($i=0;$i -lt 24;$i++){
  $p=Get-CimInstance Win32_Process -Filter "ProcessId=$id"
  if(-not $p){break}
  $n=$p.Name; $hit=$false; $isc=$false
  if($n -match "^$h(\.exe)?$"){ $hit=$true; if($n -match "^claude"){$isc=$true} }
  elseif($n -match "^(node|python|python3)(\.exe)?$" -and $p.CommandLine -match $h){ $hit=$true; if($p.CommandLine -match "claude"){$isc=$true} }
  if($hit){ $best=$p.ProcessId; if($isc){$ext=$true} else {break} }
  elseif($ext){ break }
  $id=[int]$p.ParentProcessId
  if($id -le 0){break}
}
if($best -gt 0){ [Console]::Out.Write($best); exit 0 }
exit 1
'

# True (exit 0) when FM_CHECK_WINPID is a live process whose image looks like a
# verified harness.
_FM_PS_ALIVE='
$ErrorActionPreference="SilentlyContinue"; $ProgressPreference="SilentlyContinue"
$id=[int]$env:FM_CHECK_WINPID
$h="(claude|codex|opencode|grok|kimi|pi|pi-signed)"
$p=Get-CimInstance Win32_Process -Filter "ProcessId=$id"
if(-not $p){exit 1}
$n=$p.Name
if($n -match "^$h(\.exe)?$"){exit 0}
if($n -match "^(node|python|python3)(\.exe)?$" -and $p.CommandLine -match $h){exit 0}
exit 1
'

# Run an inline PowerShell script ($1) via -EncodedCommand: no quoting, no temp
# file. Caller-set env vars are visible to the script. Returns PowerShell's exit
# code, or 127 (fail closed) if the encode/run toolchain is unavailable.
_fm_pwsh() {
  local script=$1 enc
  command -v powershell >/dev/null 2>&1 || return 127
  command -v iconv >/dev/null 2>&1 || return 127
  command -v base64 >/dev/null 2>&1 || return 127
  enc=$(printf '%s' "$script" | iconv -t UTF-16LE 2>/dev/null | base64 -w0 2>/dev/null) || return 127
  [ -n "$enc" ] || return 127
  powershell -NoProfile -NonInteractive -EncodedCommand "$enc" 2>/dev/null
}

# WINPID of the current (sourcing) shell, via the MSYS-exposed /proc file.
_fm_win_self_winpid() {
  local wp
  wp=$(cat "/proc/$$/winpid" 2>/dev/null) || return 1
  case "$wp" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$wp"
}

# Print this session's harness WINPID.
# Preferred source: the harness-exported PID env var, which every descendant
# inherits (extend FM_HARNESS_PID_ENVS as new adapters are verified). It is
# validated as a live harness so a stale value inherited across a re-exec can
# never be published as ownership. Falls back to the CIM ancestry walk.
FM_HARNESS_PID_ENVS='CLAUDE_PID'
_fm_win_harness_winpid() {
  local var val start out
  for var in $FM_HARNESS_PID_ENVS; do
    eval "val=\${$var:-}"
    case "$val" in
      ''|*[!0-9]*) continue ;;
    esac
    if _fm_win_winpid_is_harness "$val"; then
      printf '%s\n' "$val"
      return 0
    fi
  done
  start=$(_fm_win_self_winpid) || return 1
  out=$(FM_START_WINPID="$start" _fm_pwsh "$_FM_PS_ANCESTRY") || return 1
  out=$(printf '%s' "$out" | tr -cd '0-9')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# True when WINPID $1 is a live harness process.
_fm_win_winpid_is_harness() {
  local wp=$1
  case "$wp" in ''|*[!0-9]*) return 1 ;; esac
  FM_CHECK_WINPID="$wp" _fm_pwsh "$_FM_PS_ALIVE" >/dev/null
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# On Windows/MSYS the POSIX walk cannot cross into the native harness process,
# so the whole primitive short-circuits to the harness WINPID resolved from the
# CLAUDE_PID anchor (or the CIM fallback). Both the lock write path
# (fm_harness_ancestry_pid) and the ownership membership check
# (fm_session_lock_owned_by_self) inherit that Windows support from here.
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
  if _fm_is_windows; then
    _fm_win_harness_winpid
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
  local pid=$1 comm args
  if _fm_is_windows; then
    _fm_win_winpid_is_harness "$pid"
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
