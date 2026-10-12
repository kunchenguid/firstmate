#!/usr/bin/env bash
# Antigravity executable resolution and Antigravity process identity.
# Sourced by bin/fm-spawn.sh, bin/fm-harness.sh, and bin/fm-session-lock-lib.sh.
# This file is sourced by scripts and has no side effects on source.

SCRIPT_DIR_AGY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT_AGY="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR_AGY/.." && pwd)}"
FM_HOME_AGY="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT_AGY}}"
CONFIG_AGY="${FM_CONFIG_OVERRIDE:-$FM_HOME_AGY/config}"

# Resolves the antigravity / agy binary path
fm_antigravity_resolve_binary() {
  local candidate
  for candidate in agy agy.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then
      type -P "$candidate"
      return 0
    fi
  done
  for candidate in /usr/local/bin/agy /mnt/c/Users/oguz_/AppData/Local/agy/bin/agy.exe; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Checks if a command name or argument list represents an Antigravity process
fm_antigravity_process_matches() {  # <comm> <args> [argv0]
  local comm=$1 args=${2:-} argv0=${3:-} base
  [ -n "$comm" ] || [ -n "$argv0" ] || return 1
  argv0=${argv0:-$comm}
  base=$(basename -- "$comm")
  base=${base#-}
  case "$base" in
    agy|agy.exe|antigravity|antigravity.exe) return 0 ;;
  esac
  case "$argv0" in
    */agy|*/agy.exe|*/antigravity|*/antigravity.exe) return 0 ;;
  esac
  return 1
}

# Checks if Antigravity is active on the host / WSL
fm_antigravity_is_active() {
  [ -n "${FM_TEST_SEAM:-}" ] && return 1
  [ "${ANTIGRAVITY_AGENT:-0}" = "1" ] && return 0
  [ "${AGY_AGENT:-0}" = "1" ] && return 0
  [ "${GEMINI_AGENT:-0}" = "1" ] && return 0
  local config_harness=""
  if [ -f "$CONFIG_AGY/harness" ]; then
    config_harness=$(tr -d '[:space:]' < "$CONFIG_AGY/harness" 2>/dev/null || true)
  elif [ -f "$CONFIG_AGY/primary-harness" ]; then
    config_harness=$(tr -d '[:space:]' < "$CONFIG_AGY/primary-harness" 2>/dev/null || true)
  fi
  if [ "$config_harness" = "antigravity" ] || [ "$config_harness" = "agy" ]; then
    return 0
  fi
  return 1
}

# Finds an active Antigravity session PID
fm_antigravity_session_pid() {
  [ -n "${FM_TEST_SEAM:-}" ] && return 1
  local config_harness=""
  if [ -f "$CONFIG_AGY/harness" ]; then
    config_harness=$(tr -d '[:space:]' < "$CONFIG_AGY/harness" 2>/dev/null || true)
  elif [ -f "$CONFIG_AGY/primary-harness" ]; then
    config_harness=$(tr -d '[:space:]' < "$CONFIG_AGY/primary-harness" 2>/dev/null || true)
  fi

  # Tests setting mock process tables must not see ambient external processes
  [ -n "${TMP_ROOT:-}" ] && return 1
  [ -n "${FM_TEST_PID1_COMM:-}" ] && return 1
  [ -n "${FM_TEST_PATH_SHAPE:-}" ] && return 1
  [ -n "${FM_TEST_CLAUDE_SHAPE:-}" ] && return 1

  # Only resolve if explicitly configured or indicated by env
  if [ "${ANTIGRAVITY_AGENT:-0}" != "1" ] && [ "${AGY_AGENT:-0}" != "1" ] && [ "${GEMINI_AGENT:-0}" != "1" ] && [ "$config_harness" != "antigravity" ] && [ "$config_harness" != "agy" ]; then
    return 1
  fi

  if [ -n "${ANTIGRAVITY_PID:-}" ] && kill -0 "$ANTIGRAVITY_PID" 2>/dev/null; then
    printf '%s\n' "$ANTIGRAVITY_PID"
    return 0
  fi
  if [ -n "${AGY_PID:-}" ] && kill -0 "$AGY_PID" 2>/dev/null; then
    printf '%s\n' "$AGY_PID"
    return 0
  fi
  local pid
  pid=$(pgrep -n -f 'agy(\.exe)?' 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "$pid"
    return 0
  fi
  return 1
}
