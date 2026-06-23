#!/usr/bin/env bash
# Portable process introspection for Linux, macOS, and Git Bash / MSYS on Windows.
#
# Two MSYS realities break the Unix approach used elsewhere:
#   1. MSYS `ps` does NOT support `ps -o <fmt> -p <pid>` (only -p/-f/-l), so the
#      `ps -o comm=/ppid=/args=` calls return "unknown option -- o".
#   2. MSYS `ps` PPID stops at the MSYS boundary: a bash launched directly by a
#      native Windows process shows PPID 1, so Unix ancestry walking can never
#      reach the native harness (claude/codex/...) that started it.
# On MSYS we therefore walk the *Windows* process tree with a Win32_Process CIM
# query via PowerShell, invoked as a temp `-File` script (the `-Command -` stdin
# form silently mis-parses multi-line `for` blocks).
#
# Sourced by fm-harness.sh and fm-lock.sh. Emits TAB-separated records.

fm_proc_is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MSYS*|MINGW*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

_fm_proc_pwsh() {
  command -v powershell.exe 2>/dev/null \
    || command -v powershell 2>/dev/null \
    || command -v pwsh.exe 2>/dev/null \
    || command -v pwsh 2>/dev/null
}

# Windows PID of an MSYS pid (default $$). MSYS `ps` long columns are positional
# and numeric through WINPID: PID(1) PPID(2) PGID(3) WINPID(4) ...
_fm_proc_winpid() {
  local mpid=${1:-$$}
  ps -p "$mpid" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Run a PowerShell script (read from stdin) via a temp -File, forwarding any
# args to the script. -File reliably executes the whole script, unlike the
# -Command - stdin form. Returns the script's exit status.
_fm_proc_run_ps() {
  local ps tmp winpath rc
  ps=$(_fm_proc_pwsh) || return 1
  tmp=$(mktemp 2>/dev/null) || tmp="${TMPDIR:-/tmp}/fm-proc-$$-$RANDOM"
  tmp="$tmp.ps1"
  cat > "$tmp"
  winpath="$tmp"
  command -v cygpath >/dev/null 2>&1 && winpath=$(cygpath -w "$tmp" 2>/dev/null || printf '%s' "$tmp")
  "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$winpath" "$@"
  rc=$?
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# Print the ancestry chain from <pid> (default current) upward, one per line:
#   <pid>\t<comm>\t<args>
# Pids are Windows PIDs on MSYS, OS pids elsewhere. Bounded depth; stops at the
# process tree root.
fm_proc_ancestry() {
  local start=${1:-$$}
  if fm_proc_is_windows; then
    local win
    win=$(_fm_proc_winpid "$start")
    case "$win" in ''|*[!0-9]*) return 1 ;; esac
    _fm_proc_run_ps "$win" <<'PSEOF'
param([int]$Start)
$cur = $Start
$map = @{}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object { $map[[int]$_.ProcessId] = $_ }
for ($i = 0; $i -lt 16 -and $cur -gt 0; $i++) {
  $p = $map[[int]$cur]
  if (-not $p) { break }
  $cmd = $p.CommandLine
  if ($null -eq $cmd) { $cmd = "" }
  $cmd = $cmd -replace "[`t`r`n]", " "
  "{0}`t{1}`t{2}" -f $p.ProcessId, $p.Name, $cmd
  $cur = [int]$p.ParentProcessId
}
PSEOF
  else
    local pid=$start comm args n=0
    while [ "$n" -lt 12 ]; do
      n=$((n + 1))
      comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s\t%s\t%s\n' "$pid" "$comm" "$args"
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      if [ -z "$pid" ] || [ "$pid" -le 1 ]; then break; fi
    done
  fi
}

# Print "<comm>\t<args>" for a specific pid (Windows pid on MSYS), or fail.
fm_proc_info() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_proc_is_windows; then
    _fm_proc_run_ps "$pid" <<'PSEOF'
param([int]$Id)
$p = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
if ($p) {
  $cmd = $p.CommandLine
  if ($null -eq $cmd) { $cmd = "" }
  $cmd = $cmd -replace "[`t`r`n]", " "
  "{0}`t{1}" -f $p.Name, $cmd
}
PSEOF
  else
    local comm args
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    printf '%s\t%s\n' "$comm" "$args"
  fi
}

# Is <pid> a live process? (Windows pid on MSYS, OS pid elsewhere.)
fm_proc_alive() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_proc_is_windows; then
    _fm_proc_pwsh >/dev/null 2>&1 || return 0   # cannot check -> assume alive (conservative)
    _fm_proc_run_ps "$pid" <<'PSEOF'
param([int]$Id)
if (Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }
PSEOF
  else
    kill -0 "$pid" 2>/dev/null
  fi
}
