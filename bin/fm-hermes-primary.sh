#!/usr/bin/env bash
# Launch a persistent Hermes classic CLI as the Firstmate primary manager.
#
# The launcher supplies project-plugin discovery only after the plugin is
# explicitly enabled in Hermes configuration. Setup also leaves the checked
# plugin linked in Hermes's user plugin directory, so the normal
# /home/vkarvelas/.local/bin/firstmate wrapper can discover it without a
# wrapper or profile edit.
# It never writes Hermes configuration during normal launch.
#
# Usage:
#   bin/fm-hermes-primary.sh --check
#   bin/fm-hermes-primary.sh --setup
#   bin/fm-hermes-primary.sh [Hermes global options]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN=firstmate-primary

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

require_root() {
  local cwd top
  cwd=$(pwd -P)
  top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ "$cwd" = "$ROOT" ] && [ "$top" = "$ROOT" ] || {
    echo "error: run this launcher from the Firstmate checkout root: $ROOT" >&2
    exit 1
  }
}

plugin_status() {
  hermes config get plugins.enabled 2>/dev/null | grep -Fx -- "- $PLUGIN" >/dev/null
}

enable_plugin() {
  local config_path hermes_home user_plugins link created=0
  config_path=$(hermes config path 2>/dev/null) || return 1
  [ -n "$config_path" ] || {
    echo "error: Hermes did not report its config path" >&2
    return 1
  }
  hermes_home=$(dirname "$config_path")
  user_plugins="$hermes_home/plugins"
  link="$user_plugins/$PLUGIN"
  mkdir -p "$user_plugins"

  if [ -e "$link" ] || [ -L "$link" ]; then
    [ -L "$link" ] && [ "$(readlink "$link")" = "$ROOT/.hermes/plugins/$PLUGIN" ] || {
      echo "error: refusing to replace existing Hermes plugin path: $link" >&2
      return 1
    }
  else
    ln -s "$ROOT/.hermes/plugins/$PLUGIN" "$link"
    created=1
  fi

  if ! HERMES_ENABLE_PROJECT_PLUGINS=1 hermes plugins enable "$PLUGIN"; then
    [ "$created" -eq 0 ] || unlink "$link"
    return 1
  fi
}

require_root

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --check)
    if plugin_status; then
      echo "Hermes Firstmate primary plugin: enabled"
      exit 0
    fi
    echo "Hermes Firstmate primary plugin: not enabled" >&2
    echo "Run bin/fm-hermes-primary.sh --setup once from this trusted checkout." >&2
    exit 1
    ;;
  --setup)
    enable_plugin
    plugin_status || {
      echo "error: Hermes did not report $PLUGIN enabled after setup" >&2
      exit 1
    }
    echo "Hermes Firstmate primary plugin enabled for trusted project launches."
    exit 0
    ;;
esac

plugin_status || {
  echo "error: Hermes Firstmate primary plugin is not enabled." >&2
  echo "Run bin/fm-hermes-primary.sh --setup once from this trusted checkout." >&2
  exit 1
}

export HERMES_ENABLE_PROJECT_PLUGINS=1
exec hermes --cli "$@"
