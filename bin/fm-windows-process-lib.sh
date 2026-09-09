#!/usr/bin/env bash
# Shared Windows process-chain enumeration for MSYS-style hosts (Git Bash).
#
# ONE owner of "walk the native Windows parent chain above this shell". Two
# platform facts make the naive walk unusable there:
#
#   1. MSYS ps cannot see native Windows processes at all, so a Unix `ps` walk
#      stops at the first native boundary - exactly where the agent engine (a
#      node bundle, a compiled CLI) sits.
#   2. A pure Windows walk (CIM Win32_Process ParentProcessId) dies just as
#      fast: an MSYS fork child is a copy of its forking shell whose Win32
#      parent pid goes stale the moment the fork helper's intermediate exits,
#      so the first MSYS-internal boundary already breaks the chain.
#
# The walk below is therefore hybrid: climb the MSYS /proc chain, which tracks
# those parents reliably, then hand off to one CIM walk anchored at the last
# MSYS process - its parent is a native CreateProcess child of the engine, and
# native-to-native Win32 parent pids are stable. The walks in
# bin/fm-session-lock-lib.sh and bin/fm-harness.sh delegate to this lib on such
# hosts. This file is sourced by scripts and has no side effects on source.

# True when the host shell is an MSYS-style Windows environment, where the Unix
# ps walks cannot cross into the native Windows processes above the shell.
fm_host_is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print "pid<US>comm<US>args" lines (US = byte 0x1f) for the calling shell's
# Windows ancestry, innermost first, up to 16 MSYS hops plus 16 CIM hops.
# Never interprets process identity; callers own matching. A multiline args
# field (a shell running an embedded script) fragments into continuation lines
# on the consumer side; those never match a harness identity, so they are inert.
# The start pid is the calling shell's own Windows pid, read with `read`
# redirection rather than a command substitution: $(cat /proc/self/winpid)
# would report the transient subshell running cat.
# FM_WINDOWS_ANCESTRY_PS overrides the powershell executable for tests.
fm_windows_ancestry_lines() {
  local us pid rest stat comm ppid winpid args
  local -a recs=()
  local i lastidx anchor
  us=$(printf '\037')
  read -r pid rest < /proc/self/stat 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || break
    rest=${stat#*(}
    comm=${rest%%)*}
    rest=${rest#*) }
    ppid=${rest#* }
    ppid=${ppid%% *}
    winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || winpid=''
    case $winpid in
      ''|*[!0-9]*) break ;;
    esac
    args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    recs+=("$winpid$us$comm$us$args")
    case $ppid in
      ''|0|1) break ;;
    esac
    [ -r "/proc/$ppid/stat" ] || break
    pid=$ppid
  done
  lastidx=$((${#recs[@]} - 1))
  for ((i = 0; i < lastidx; i++)); do
    printf '%s\n' "${recs[$i]}"
  done
  anchor=${recs[$lastidx]%%"$us"*}
  # A CIM snapshot intermittently comes back empty under host load, which
  # would strand a live session as unidentified (and the fleet lock as
  # read-only); retry once before accepting the miss.
  local out=''
  for _ in 1 2; do
    out=$(FM_LOCK_WINPID=$anchor "${FM_WINDOWS_ANCESTRY_PS:-powershell}" -NoProfile -NonInteractive -Command '
      $all = @{}
      Get-CimInstance Win32_Process | ForEach-Object { $all[[uint32]$_.ProcessId] = $_ }
      $id = [uint32]$env:FM_LOCK_WINPID
      $us = [string][char]31
      for ($i = 0; $i -lt 16; $i++) {
        $p = $all[$id]
        if (-not $p) { break }
        Write-Output (([string]$p.ProcessId) + $us + $p.Name + $us + $p.CommandLine)
        $id = [uint32]$p.ParentProcessId
        if (-not $id -or $id -eq 0) { break }
      }
    ' 2>/dev/null) && [ -n "$out" ] && break
    out=''
    sleep 0.3
  done
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Print the identity line of one Windows pid, or return 1 when no live process
# carries it. Same line format and test override as fm_windows_ancestry_lines;
# CIM sees MSYS processes too, so a lock pid from either side of the hybrid
# walk resolves here. Retried once for the same transient-empty reason.
fm_windows_process_line() {  # <pid>
  local pid=$1 out
  case $pid in
    ''|*[!0-9]*) return 1 ;;
  esac
  for out in 1 2; do
    out=$(FM_LOCK_WINPID=$pid "${FM_WINDOWS_ANCESTRY_PS:-powershell}" -NoProfile -NonInteractive -Command '
      $p = Get-CimInstance Win32_Process -Filter ("ProcessId = " + [uint32]$env:FM_LOCK_WINPID)
      if (-not $p) { exit 1 }
      $us = [string][char]31
      Write-Output (([string]$p.ProcessId) + $us + $p.Name + $us + $p.CommandLine)
    ' 2>/dev/null) && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    sleep 0.3
  done
  return 1
}
