#!/usr/bin/env bash
# Shared home-local Calm preference reader.
#
# The effective config directory is caller-owned. An exact `on\n` file enables
# presentation changes; absent, unreadable, or any other content is off.
# Callers keep their ordinary output byte-for-byte unchanged while off.
# Claude-only callers additionally use fm_claude_calm_enabled so the shared Pi
# preference does not change another primary harness's shell presentation.

fm_calm_enabled() {  # [config-dir]
  local config=${1:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-.}}/config}} value bytes
  [ -f "$config/calm" ] || return 1
  bytes=$({ LC_ALL=C wc -c < "$config/calm"; } 2>/dev/null) || return 1
  bytes=${bytes//[[:space:]]/}
  [ "$bytes" = 3 ] || return 1
  value=$(cat "$config/calm" 2>/dev/null) || return 1
  [ "$value" = on ]
}

fm_claude_calm_enabled() {  # [config-dir]
  [ "${CLAUDECODE:-}" = 1 ] && fm_calm_enabled "${1:-}"
}
