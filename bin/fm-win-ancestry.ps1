# fm-win-ancestry.ps1 - Windows process-ancestry source for fm-session-lock-lib.sh.
#
# Git Bash / MSYS ps cannot see native Windows processes, so firstmate's session
# lock reads the true parent chain here instead. Given a start Windows pid, walk
# up the Win32_Process tree and print one tab-separated row per hop, innermost
# first:
#
#   <pid>\t<name>\t<commandline>
#
# name plays the role of `ps -o comm=` and commandline the role of `ps -o args=`
# for the harness matcher. Bounded to 16 hops; stops at the first parent that is
# not a live process (or a self/zero parent). All processes are fetched once so a
# single CIM query serves the whole walk.

param([Parameter(Mandatory = $true)][int]$Start)

$ErrorActionPreference = 'Stop'

$byPid = @{}
Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
  $byPid[[int]$_.ProcessId] = $_
}

$TAB = [char]9
$cur = $Start
for ($hop = 0; $hop -lt 16; $hop++) {
  $p = $byPid[$cur]
  if (-not $p) { break }
  $name = $p.Name
  $cmd = $p.CommandLine
  # A tab or newline inside a value would corrupt the row the bash side splits on.
  if ($name) { $name = ($name -replace "[`t`r`n]", ' ') } else { $name = '' }
  if ($cmd)  { $cmd  = ($cmd  -replace "[`t`r`n]", ' ') } else { $cmd  = '' }
  # Emit a bare LF, not the platform CRLF, so the bash reader sees clean rows.
  [Console]::Out.Write(('{0}{1}{2}{1}{3}' -f $p.ProcessId, $TAB, $name, $cmd) + "`n")
  $parent = [int]$p.ParentProcessId
  if ($parent -le 0 -or $parent -eq $cur) { break }
  $cur = $parent
}
