#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# Platforms:
# - Linux/macOS: walk process ancestry with POSIX `ps -o` (8 hops).
# - Windows (MSYS/Git Bash/Cygwin): MSYS `ps` has no `-o` and Cygwin PPIDs
#   break at the Windows boundary (often PPID=1). Resolve the harness via
#   `/proc/$$/winpid` + NtQuery parent walk (and a children-map BFS / env
#   fallback when intermediate parents are dead). Cache the result under
#   state/.session-harness-pid. Liveness uses Win32 process identity, not
#   `kill -0` on a Windows PID from MSYS.
# Claim-lock creation on MSYS uses directory junctions (see fm-wake-lib.sh);
# plain `ln -s` there often creates a directory copy and would spin forever.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|^pi$'

# True on MSYS/Git-Bash/Cygwin environments where POSIX ps -o ancestry fails.
fm_session_lock_is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Windows PID of the current bash (MSYS maps these under /proc/<pid>/winpid).
fm_session_lock_self_winpid() {
  local winpid line
  if [ -r "/proc/$$/winpid" ]; then
    winpid=$(tr -d ' \t\r\n' < "/proc/$$/winpid" 2>/dev/null) || return 1
    case "$winpid" in
      ''|*[!0-9]*) return 1 ;;
      *) printf '%s\n' "$winpid"; return 0 ;;
    esac
  fi
  # Fallback: parse `ps -l` WINPID column for this Cygwin pid.
  line=$(ps -l -p $$ 2>/dev/null | tail -n 1) || return 1
  # Columns: PID PPID PGID WINPID ...
  winpid=$(printf '%s\n' "$line" | awk '{ print $4 }' | tr -d ' \t\r\n')
  case "$winpid" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$winpid"; return 0 ;;
  esac
}

# Run a PowerShell script file. FM_SESSION_LOCK_PS overrides the binary
# (tests inject a stub that reads -File). Non-zero means not found / dead.
fm_session_lock_powershell_file() {
  local script_path="$1"
  local ps_bin="${FM_SESSION_LOCK_PS:-powershell.exe}"
  local win_path="$script_path"
  # PowerShell is a native Windows binary: convert MSYS/Cygwin paths first.
  if command -v cygpath >/dev/null 2>&1; then
    win_path=$(cygpath -w "$script_path" 2>/dev/null) || win_path="$script_path"
  fi
  # -NoProfile keeps this cheap and free of profile side effects.
  # -File avoids multiline -Command quoting pitfalls on Windows.
  "$ps_bin" -NoProfile -File "$win_path"
}

# Write $2 to a temp .ps1 under ${TMPDIR:-/tmp}, run it, delete it.
# Prints stdout. Returns the PowerShell exit status.
fm_session_lock_run_ps1() {
  # Quote $1/$2: the PowerShell body is multiline and must not word-split under
  # `local body=$2` (that was truncating the script to its first line).
  local tag="$1"
  local body="$2"
  local dir tmp out status
  dir="${TMPDIR:-/tmp}"
  mkdir -p "$dir" 2>/dev/null || dir="."
  # mktemp requires the X's at the end of the template on some platforms;
  # rename to .ps1 after create so PowerShell accepts -File.
  tmp=$(mktemp "$dir/fm-session-lock-${tag}.XXXXXX" 2>/dev/null) || {
    tmp="$dir/fm-session-lock-${tag}.$$.$RANDOM"
    : >"$tmp" || return 1
  }
  if ! mv "$tmp" "${tmp}.ps1" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  tmp="${tmp}.ps1"
  # PowerShell on Windows wants a real file path, not a bash -Command string.
  printf '%s\n' "$body" > "$tmp" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  out=$(fm_session_lock_powershell_file "$tmp" 2>/dev/null)
  status=$?
  rm -f "$tmp" 2>/dev/null || true
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  printf '%s' "$out"
  return 0
}

# Optional cache so nested MSYS tool shells with broken Win32 parents can reuse
# a harness pid discovered earlier in this home (see fm_harness_ancestry_pid_windows).
fm_session_lock_harness_cache_path() {
  local home="${FM_HOME:-${FM_STATE_OVERRIDE:-}}"
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s\n' "${FM_STATE_OVERRIDE%/}/.session-harness-pid"
    return 0
  fi
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "${FM_HOME%/}/state/.session-harness-pid"
    return 0
  fi
  return 1
}

fm_session_lock_cache_read() {
  local path pid
  path=$(fm_session_lock_harness_cache_path) || return 1
  [ -f "$path" ] || return 1
  pid=$(tr -d ' \t\r\n' <"$path" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive_windows "$pid" || return 1
  printf '%s\n' "$pid"
}

fm_session_lock_cache_write() {
  local pid=$1 path dir
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  path=$(fm_session_lock_harness_cache_path) || return 0
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$pid" >"$path" 2>/dev/null || true
}

# Walk Win32 parents from $1 (Windows PID). Print the first harness PID.
# Matching mirrors the POSIX path: basename (sans .exe) against FM_HARNESS_RE,
# or node/python whose command line mentions a harness name.
fm_harness_ancestry_pid_windows() {
  local start body out cached
  # Prefer a still-live cache from an earlier successful resolve in this home.
  # Nested Git-Bash tool shells often have a dead intermediate Win32 parent, so
  # parent walk and even children-map BFS can miss the harness; the cache is
  # filled on the first successful discovery (typically a healthier shell).
  if cached=$(fm_session_lock_cache_read); then
    printf '%s\n' "$cached"
    return 0
  fi
  start="${1:-}"
  if [ -z "$start" ]; then
    start=$(fm_session_lock_self_winpid) || return 1
  fi
  case "$start" in
    ''|*[!0-9]*) return 1 ;;
  esac

  # CIM-free ancestry via NtQueryInformationProcess:
  # 1) direct parent walk (fast path when the Win32 chain is intact)
  # 2) if a short-lived MSYS parent is already dead, build a children map from
  #    Get-Process + NtQuery for every live process, then BFS downward from each
  #    harness name until $start is found (repairs broken intermediate parents)
  # 3) env-marker + unique Get-Process name match as last resort
  body=$(cat <<'PSEOF'
$ErrorActionPreference = 'Continue'
$start = [int]__FM_START__
$re = [regex]'__FM_HARNESS_RE__'
if (-not ('FMNativeParent' -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class FMNativeParent {
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_BASIC_INFORMATION {
    public IntPtr Reserved1;
    public IntPtr PebBaseAddress;
    public IntPtr Reserved2_0;
    public IntPtr Reserved2_1;
    public IntPtr UniqueProcessId;
    public IntPtr InheritedFromUniqueProcessId;
  }
  [DllImport("ntdll.dll")]
  private static extern int NtQueryInformationProcess(
    IntPtr processHandle, int processInformationClass,
    ref PROCESS_BASIC_INFORMATION processInformation,
    int processInformationLength, out int returnLength);
  public static int GetParentId(int processId) {
    using (var proc = Process.GetProcessById(processId)) {
      var pbi = new PROCESS_BASIC_INFORMATION();
      int retLen;
      int status = NtQueryInformationProcess(
        proc.Handle, 0, ref pbi,
        Marshal.SizeOf(typeof(PROCESS_BASIC_INFORMATION)), out retLen);
      if (status != 0) throw new InvalidOperationException("NtQuery failed " + status);
      return pbi.InheritedFromUniqueProcessId.ToInt32();
    }
  }
}
"@
}
function Test-HarnessName([string]$name) {
  return $re.IsMatch($name)
}
# 1) direct parent walk
$id = $start
for ($i = 0; $i -lt 24; $i++) {
  try { $proc = [System.Diagnostics.Process]::GetProcessById($id) } catch { break }
  if (Test-HarnessName $proc.ProcessName) { Write-Output $id; exit 0 }
  try { $id = [FMNativeParent]::GetParentId($id) } catch { break }
  if ($id -le 0) { break }
}
# 2) children-map BFS from every harness (repairs dead intermediate parents)
$children = @{}
$harnessPids = New-Object System.Collections.ArrayList
foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
  $procId = 0
  try { $procId = $proc.Id } catch { continue }
  if (Test-HarnessName $proc.ProcessName) { [void]$harnessPids.Add($procId) }
  $parentId = 0
  try { $parentId = [FMNativeParent]::GetParentId($procId) } catch { continue }
  if (-not $children.ContainsKey($parentId)) {
    $children[$parentId] = New-Object System.Collections.ArrayList
  }
  [void]$children[$parentId].Add($procId)
}
foreach ($hp in $harnessPids) {
  $q = New-Object System.Collections.Queue
  $seen = @{}
  $q.Enqueue([int]$hp)
  $seen[[int]$hp] = $true
  $steps = 0
  while ($q.Count -gt 0 -and $steps -lt 4000) {
    $steps++
    $cur = [int]$q.Dequeue()
    if ($cur -eq $start) { Write-Output $hp; exit 0 }
    if (-not $children.ContainsKey($cur)) { continue }
    foreach ($ch in @($children[$cur])) {
      $c = [int]$ch
      if ($seen.ContainsKey($c)) { continue }
      $seen[$c] = $true
      $q.Enqueue($c)
    }
  }
}
# 3) env marker + unique name match
$want = @()
if ($env:GROK_AGENT -eq '1') { $want += 'grok' }
if ($env:CLAUDECODE -or $env:CLAUDE_CODE) { $want += 'claude' }
if ($env:CODEX_CI -or $env:CODEX_THREAD_ID) { $want += 'codex' }
if ($env:OPENCODE -or $env:OPENCODE_CLIENT) { $want += 'opencode' }
if ($env:PI_CODING_AGENT -eq 'true' -or $env:PI_CODING_AGENT -eq '1') { $want += 'pi' }
if ($want.Count -lt 1) { exit 1 }
$matches = @()
foreach ($name in $want) {
  try { $matches += @(Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) } catch {}
}
$matches = @($matches | Select-Object -Unique)
if ($matches.Count -eq 1) { Write-Output $matches[0]; exit 0 }
exit 1
PSEOF
)
  # Inject runtime values without an unquoted heredoc (avoids bash expanding $ps vars).
  body=${body//__FM_START__/${start}}
  body=${body//__FM_HARNESS_RE__/${FM_HARNESS_RE}}

  out=$(fm_session_lock_run_ps1 "ancestry" "$body") || return 1
  out=$(printf '%s\n' "$out" | tr -d ' \t\r' | tail -n 1)
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
    *)
      fm_session_lock_cache_write "$out"
      printf '%s\n' "$out"
      return 0
      ;;
  esac
}

# True if Windows PID $1 is a live process that looks like a verified harness.
fm_harness_pid_alive_windows() {
  local pid=$1 body
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  body=$(cat <<EOF
\$ErrorActionPreference = 'Stop'
\$re = [regex]'${FM_HARNESS_RE}'
try {
  \$p = [System.Diagnostics.Process]::GetProcessById(${pid})
} catch {
  exit 1
}
if (\$re.IsMatch(\$p.ProcessName)) { exit 0 }
exit 1
EOF
)
  fm_session_lock_run_ps1 "alive" "$body" >/dev/null 2>&1
}

# Walk the current process ancestry (up to 8 hops on POSIX, 16 on Win32) and
# print the first pid whose command looks like a verified harness. The harness
# pid lives as long as the session, unlike the transient subshell pid of any
# one tool call.
fm_harness_ancestry_pid() {
  if fm_session_lock_is_windows; then
    fm_harness_ancestry_pid_windows
    return $?
  fi

  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm
  if fm_session_lock_is_windows; then
    fm_harness_pid_alive_windows "$pid"
    return $?
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
