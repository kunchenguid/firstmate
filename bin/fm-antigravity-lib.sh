#!/usr/bin/env bash
# Antigravity executable resolution and Antigravity process identity.
# Sourced by bin/fm-spawn.sh, bin/fm-harness.sh, and bin/fm-session-lock-lib.sh.
# This file is sourced by scripts and has no side effects on source.

SCRIPT_DIR_AGY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT_AGY="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR_AGY/.." && pwd)}"

# Resolves the antigravity / agy binary path
fm_antigravity_resolve_binary() {
  local candidate
  for candidate in agy agy.exe antigravity antigravity.exe; do
    if command -v "$candidate" >/dev/null 2>&1; then
      type -P "$candidate"
      return 0
    fi
  done
  for candidate in /usr/local/bin/agy /usr/local/bin/antigravity "${HOME:-}/.local/bin/agy" "${HOME:-}/.local/bin/antigravity"; do
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
  [ "${ANTIGRAVITY_AGENT:-0}" = "1" ] && return 0
  [ "${AGY_AGENT:-0}" = "1" ] && return 0
  local config_dir="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_ROOT_AGY}/config}"
  local config_harness=""
  if [ -f "$config_dir/harness" ]; then
    config_harness=$(tr -d '[:space:]' < "$config_dir/harness" 2>/dev/null || true)
  fi
  if [ "$config_harness" = "antigravity" ] || [ "$config_harness" = "agy" ]; then
    return 0
  fi
  return 1
}
