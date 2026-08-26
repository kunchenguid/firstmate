#!/usr/bin/env bash
# Launch a persistent Hermes classic CLI as the Firstmate primary manager.
#
# The launcher supplies project-plugin discovery only after the plugin is
# explicitly enabled in Hermes configuration. Setup leaves the tracked plugin
# linked in Hermes's user plugin directory so the installed Hermes launcher can
# discover it without a profile edit.
# It never writes Hermes configuration during normal launch and refuses options
# that would disable the plugin, leave the trusted checkout, or select a
# non-persistent interface.
#
# Usage:
#   bin/fm-hermes-primary.sh --check
#   bin/fm-hermes-primary.sh --setup
#   bin/fm-hermes-primary.sh [classic-session options]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN=firstmate-primary
HOME_ROOT=${FM_HOME:-$ROOT}
CONFIG=${FM_CONFIG_OVERRIDE:-$HOME_ROOT/config}
STATE=${FM_STATE_OVERRIDE:-$HOME_ROOT/state}
DATA=${FM_DATA_OVERRIDE:-$HOME_ROOT/data}
# shellcheck source=bin/fm-hermes-worker-policy-lib.sh
. "$SCRIPT_DIR/fm-hermes-worker-policy-lib.sh"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
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

require_state_dir() {
  local state=$1
  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -d "$state" ] && [ ! -L "$state" ] || {
      echo "error: Hermes primary requires a safe state directory: $state" >&2
      exit 1
    }
    return 0
  fi
  mkdir -p "$state" || {
    echo "error: Hermes primary could not create state directory: $state" >&2
    exit 1
  }
}

hermes_remote_policy_check() {
  local id=$1
  FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA" \
    "$ROOT/bin/fm-on.sh" "$id" fm-remote-secondmate-control.sh policy-check "$id"
}

require_local_policy() {
  local path value
  for path in crew-harness secondmate-harness; do
    value=$(tr -d '[:space:]' < "$CONFIG/$path" 2>/dev/null || true)
    [ "$value" = pi ] || {
      echo "error: Hermes primary requires $CONFIG/$path to contain 'pi'" >&2
      exit 1
    }
  done
  value=$(tr -d '[:space:]' < "$CONFIG/backend" 2>/dev/null || true)
  [ "$value" = herdr ] || {
    echo "error: Hermes primary requires $CONFIG/backend to contain 'herdr'" >&2
    exit 1
  }
  case "${FM_BACKEND:-herdr}" in
    herdr) ;;
    *)
      echo "error: Hermes primary requires FM_BACKEND=herdr when FM_BACKEND is set" >&2
      exit 1
      ;;
  esac
  fm_hermes_policy_check_home "$HOME_ROOT" "$STATE" hermes_remote_policy_check || exit 1
}

validate_launch_args() {
  local arg
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      -m|--model|--provider|--reasoning|-r|--resume|-s|--skills)
        [ "$#" -gt 0 ] && [ -n "$1" ] || {
          echo "error: option '$arg' requires a value" >&2
          exit 1
        }
        shift
        ;;
      --model=*|--provider=*|--reasoning=*|--resume=*|--skills=*)
        [ -n "${arg#*=}" ] || {
          echo "error: option '${arg%%=*}' requires a value" >&2
          exit 1
        }
        ;;
      -c|--continue)
        if [ "$#" -gt 0 ]; then
          case "$1" in -*) ;; *) shift ;; esac
        fi
        ;;
      --continue=*)
        [ -n "${arg#*=}" ] || {
          echo "error: option '${arg%%=*}' requires a value" >&2
          exit 1
        }
        ;;
      --accept-hooks|--yolo|--pass-session-id) ;;
      *)
        echo "error: option or command '$arg' is incompatible with the persistent Hermes Firstmate primary" >&2
        exit 1
        ;;
    esac
  done
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
    require_state_dir "$STATE"
    require_state_dir "$ROOT/state"
    enable_plugin
    plugin_status || {
      echo "error: Hermes did not report $PLUGIN enabled after setup" >&2
      exit 1
    }
    echo "Hermes Firstmate primary plugin enabled for trusted project launches."
    exit 0
    ;;
esac

require_state_dir "$STATE"
require_state_dir "$ROOT/state"

plugin_status || {
  echo "error: Hermes Firstmate primary plugin is not enabled." >&2
  echo "Run bin/fm-hermes-primary.sh --setup once from this trusted checkout." >&2
  exit 1
}

validate_launch_args "$@"
require_local_policy

export HERMES_ENABLE_PROJECT_PLUGINS=1
export FM_BACKEND=herdr
export FM_HERMES_PRIMARY_POLICY=pi-herdr-v1
export FM_HERMES_PRIMARY_PID=$$
exec env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS \
  -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
  -u GROK_WORKSPACE_ROOT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
  hermes --cli --no-restore-cwd "$@"
