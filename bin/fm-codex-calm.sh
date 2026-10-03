#!/usr/bin/env bash
# Run native Codex with the one presentation-only Calm fallback it supports.
#
# This wrapper is intentionally opt-in and is not wired into fm-spawn.sh.  It
# reads the existing home-local config/calm preference and, when Calm is on,
# asks native Codex to hide reasoning rows while keeping raw reasoning hidden.
# Native Codex exposes no supported tool-row, working-row, or transcript
# renderer, so this wrapper never filters output, prompts, hooks, history, or
# execution.  Caller-supplied arguments are appended after Calm's defaults so
# an explicit caller setting remains authoritative.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
  CONFIG_DIR=$FM_CONFIG_OVERRIDE
elif [ -n "${FM_HOME:-}" ]; then
  CONFIG_DIR="$FM_HOME/config"
elif [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
  CONFIG_DIR="$FM_ROOT_OVERRIDE/config"
else
  CONFIG_DIR="$FM_ROOT/config"
fi

calm=off
if [ -f "$CONFIG_DIR/calm" ] && [ -r "$CONFIG_DIR/calm" ]; then
  value=
  if ! value=$(<"$CONFIG_DIR/calm"); then
    value=
  fi
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$value" in
    on|max) calm=on ;;
  esac
fi

codex_bin=$(command -v codex) || {
  printf '%s\n' 'fm-codex-calm: codex executable not found' >&2
  exit 127
}

if [ "$calm" = on ]; then
  exec "$codex_bin" \
    -c 'hide_agent_reasoning=true' \
    -c 'show_raw_agent_reasoning=false' \
    "$@"
fi

exec "$codex_bin" "$@"
