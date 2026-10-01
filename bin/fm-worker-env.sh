#!/usr/bin/env bash
# fm-worker-env.sh - the single owner of the intended WORKER environment.
#
# A worker's pane shell is created by a long-lived backend daemon, not by the
# firstmate process that launches the worker, so the environment a worker
# inherits can drift from the primary session's: a PATH where a newer opencode
# build shadows the one the primary runs, XDG config/data roots that are unset
# so the worker finds no stored auth or context, and a startup shell whose own
# dotfiles decide everything else. This script makes the intended environment
# explicit so bin/fm-spawn.sh can establish it on the launch command itself,
# independent of that inheritance.
#
# Configuration: the optional, gitignored config/worker-env declares the
# intended values, one NAME=value per line. Blank lines and lines beginning
# with # are ignored. Recognized names:
#   PATH              colon-separated absolute directories the worker searches
#   XDG_CONFIG_HOME   absolute config root
#   XDG_DATA_HOME     absolute data root
#   OPENCODE_BIN      absolute path to the opencode executable to launch
# Values are literal and never expanded. An absent file leaves every default in
# force; a malformed or unreadable file refuses rather than guessing.
#
# Defaults when a name is not declared: PATH is the launching process's own
# PATH, XDG_CONFIG_HOME and XDG_DATA_HOME are the launching process's own values
# or $HOME/.config and $HOME/.local/share, and the opencode executable is the
# first `opencode` the worker PATH resolves. The launching values come from the
# firstmate process being run, so a primary launched with the correct roots
# hands them down without any per-machine file.
#
# Usage (library): . bin/fm-worker-env.sh; fm_worker_env_load <config-dir>
# After a successful load the FM_WORKER_ENV_* globals hold the declared values
# (empty when undeclared) and the fm_worker_env_resolved_* functions apply the
# defaults above.
#
# Usage (detector):
#   fm-worker-env.sh check [--config <dir>] [--harness <name>]
#                          [--worktree <path>] [--primary <path>]
# Reports whether a worker would resolve the intended harness executable, its
# config and data roots, and its worktree root. Each finding is one ok, warn, or
# drift line, and any drift exits non-zero. --harness defaults to opencode, the
# adapter whose executable and store are resolved from generic PATH and XDG
# values; the binary and store checks apply to it, while the worktree check
# applies to whatever path is given.
set -u

FM_WORKER_ENV_CONFIG_NAME=worker-env
# The declared key set is closed, so a typo refuses instead of being ignored.
FM_WORKER_ENV_KEYS='PATH XDG_CONFIG_HOME XDG_DATA_HOME OPENCODE_BIN'
# Environment credentials that satisfy the opencode auth check without a stored
# login; the list is provider family names, not this home's secrets.
FM_WORKER_ENV_AUTH_ENV_VARS='OPENCODE_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY'

# fm_worker_env_file <config-dir>
fm_worker_env_file() {
  printf '%s/%s\n' "$1" "$FM_WORKER_ENV_CONFIG_NAME"
}

# fm_worker_env_reset
# Clears the declared-value globals so a reload cannot retain a stale key.
fm_worker_env_reset() {
  FM_WORKER_ENV_PATH=
  FM_WORKER_ENV_XDG_CONFIG_HOME=
  FM_WORKER_ENV_XDG_DATA_HOME=
  FM_WORKER_ENV_OPENCODE_BIN=
}

# fm_worker_env_valid_value <name> <value>
# 0 when the value is usable for that name, else 1 with one naming error.
fm_worker_env_valid_value() {
  local name=$1 value=$2 part
  if [ -z "$value" ]; then
    echo "error: config/$FM_WORKER_ENV_CONFIG_NAME: $name must not be empty" >&2
    return 1
  fi
  case "$value" in
  *[[:cntrl:]]*)
    echo "error: config/$FM_WORKER_ENV_CONFIG_NAME: $name must not contain control characters" >&2
    return 1
    ;;
  esac
  if [ "$name" = PATH ]; then
    local IFS=:
    # shellcheck disable=SC2086  # deliberate split on the colon IFS above
    set -- $value
    for part in "$@"; do
      if [ -z "$part" ]; then
        echo "error: config/$FM_WORKER_ENV_CONFIG_NAME: PATH must not contain an empty entry" >&2
        return 1
      fi
      case "$part" in
      /*) ;;
      *)
        echo "error: config/$FM_WORKER_ENV_CONFIG_NAME: PATH entry is not absolute: $part" >&2
        return 1
        ;;
      esac
    done
  else
    case "$value" in
    /*) ;;
    *)
      echo "error: config/$FM_WORKER_ENV_CONFIG_NAME: $name must be an absolute path: $value" >&2
      return 1
      ;;
    esac
  fi
  return 0
}

# fm_worker_env_load <config-dir>
# Loads config/worker-env into the FM_WORKER_ENV_* globals. An absent file
# leaves every global empty and returns 0; a malformed or unreadable file prints
# one error and returns 1.
fm_worker_env_load() {
  local config=$1 file line name value
  if [ -z "$config" ]; then
    echo "error: fm_worker_env_load requires a config directory" >&2
    return 1
  fi
  fm_worker_env_reset
  file=$(fm_worker_env_file "$config")
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/$FM_WORKER_ENV_CONFIG_NAME must be a readable regular file: $file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    '' | '#'*) continue ;;
    esac
    case "$line" in
    *=*) ;;
    *)
      echo "error: config/$FM_WORKER_ENV_CONFIG_NAME must hold NAME=value lines: $line" >&2
      return 1
      ;;
    esac
    name=${line%%=*}
    value=${line#*=}
    case " $FM_WORKER_ENV_KEYS " in
    *" $name "*) ;;
    *)
      echo "error: config/$FM_WORKER_ENV_CONFIG_NAME has unknown name '$name'; expected one of: $FM_WORKER_ENV_KEYS" >&2
      return 1
      ;;
    esac
    fm_worker_env_valid_value "$name" "$value" || return 1
    case "$name" in
    PATH) FM_WORKER_ENV_PATH=$value ;;
    XDG_CONFIG_HOME) FM_WORKER_ENV_XDG_CONFIG_HOME=$value ;;
    XDG_DATA_HOME) FM_WORKER_ENV_XDG_DATA_HOME=$value ;;
    OPENCODE_BIN) FM_WORKER_ENV_OPENCODE_BIN=$value ;;
    esac
  done <"$file"
  return 0
}

# fm_worker_env_default_config_home
fm_worker_env_default_config_home() {
  printf '%s\n' "${XDG_CONFIG_HOME:-${HOME:-}/.config}"
}

# fm_worker_env_default_data_home
fm_worker_env_default_data_home() {
  printf '%s\n' "${XDG_DATA_HOME:-${HOME:-}/.local/share}"
}

# fm_worker_env_resolved_path
fm_worker_env_resolved_path() {
  if [ -n "$FM_WORKER_ENV_PATH" ]; then
    printf '%s\n' "$FM_WORKER_ENV_PATH"
  else
    printf '%s\n' "${PATH:-}"
  fi
}

# fm_worker_env_promote_bindir <path> <binary>
# Prints <path> with the directory of <binary> moved to the front, so a child
# that re-resolves the harness name reaches the same executable.
fm_worker_env_promote_bindir() {
  local path=$1 binary=$2 bindir entry result=
  bindir=${binary%/*}
  case "$binary" in
  */*) ;;
  *) printf '%s\n' "$path"; return 0 ;;
  esac
  local IFS=:
  # shellcheck disable=SC2086  # deliberate split on the colon IFS above
  set -- ${path:-}
  for entry in "$@"; do
    [ "$entry" = "$bindir" ] && continue
    result=${result:+$result:}$entry
  done
  printf '%s\n' "${bindir}${result:+:$result}"
}

# fm_worker_env_resolved_config_home
fm_worker_env_resolved_config_home() {
  if [ -n "$FM_WORKER_ENV_XDG_CONFIG_HOME" ]; then
    printf '%s\n' "$FM_WORKER_ENV_XDG_CONFIG_HOME"
  else
    fm_worker_env_default_config_home
  fi
}

# fm_worker_env_resolved_data_home
fm_worker_env_resolved_data_home() {
  if [ -n "$FM_WORKER_ENV_XDG_DATA_HOME" ]; then
    printf '%s\n' "$FM_WORKER_ENV_XDG_DATA_HOME"
  else
    fm_worker_env_default_data_home
  fi
}

# fm_worker_env_opencode_launch_bin
# Prints the shell-safe token for the opencode command: a quoted absolute pin
# when declared, else the bare name so an undeclared worker PATH decides.
fm_worker_env_opencode_launch_bin() {
  local value
  if [ -n "${FM_WORKER_ENV_OPENCODE_BIN:-}" ]; then
    value=$(printf '%s' "$FM_WORKER_ENV_OPENCODE_BIN" | sed "s/'/'\\\\''/g")
    printf "'%s'\n" "$value"
  else
    printf 'opencode\n'
  fi
}

# --- detector ----------------------------------------------------------------

fm_worker_env_report() {  # <kind> <message>
  printf '%s: %s\n' "$1" "$2"
}

# fm_worker_env_realpath <path>
# Prints the canonical path when it resolves, else the input unchanged.
fm_worker_env_realpath() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# fm_worker_env_binary <harness> <path>
# Prints the executable a worker on <path> would launch for <harness>: a
# declared opencode pin wins, else the first name on <path>.
fm_worker_env_binary() {
  local harness=$1 path=$2
  if [ "$harness" = opencode ] && [ -n "$FM_WORKER_ENV_OPENCODE_BIN" ]; then
    printf '%s\n' "$FM_WORKER_ENV_OPENCODE_BIN"
    return 0
  fi
  PATH=$path command -v "$harness" 2>/dev/null
}

fm_worker_env_check() {
  local config=$1 harness=$2 worktree=$3 primary=$4
  local drift=0 path config_home data_home binary version top want auth_var auth_seen
  fm_worker_env_load "$config" || return 1
  path=$(fm_worker_env_resolved_path)
  config_home=$(fm_worker_env_resolved_config_home)
  data_home=$(fm_worker_env_resolved_data_home)

  fm_worker_env_report ok "worker PATH=$path"
  fm_worker_env_report ok "worker XDG_CONFIG_HOME=$config_home"
  fm_worker_env_report ok "worker XDG_DATA_HOME=$data_home"

  binary=$(fm_worker_env_binary "$harness" "$path") || binary=
  if [ -z "$binary" ]; then
    fm_worker_env_report drift "harness '$harness' is not resolvable on the worker PATH"
    drift=1
  elif [ ! -x "$binary" ]; then
    fm_worker_env_report drift "harness '$harness' resolves to a non-executable: $binary"
    drift=1
  else
    fm_worker_env_report ok "harness '$harness' resolves to $binary"
    if [ "$harness" = opencode ]; then
      version=$("$binary" --version 2>/dev/null | sed -n '1p') || version=
      if [ -n "$version" ]; then
        fm_worker_env_report ok "opencode version: $version"
      else
        fm_worker_env_report warn "opencode did not report a version for $binary"
      fi
      if [ ! -d "$config_home/opencode" ]; then
        fm_worker_env_report warn "no opencode config directory at $config_home/opencode; opencode will use built-in defaults"
      else
        fm_worker_env_report ok "opencode config directory: $config_home/opencode"
      fi
      if [ -s "$data_home/opencode/auth.json" ]; then
        fm_worker_env_report ok "opencode credential: $data_home/opencode/auth.json"
      else
        auth_seen=
        for auth_var in $FM_WORKER_ENV_AUTH_ENV_VARS; do
          if [ -n "${!auth_var:-}" ]; then
            auth_seen=$auth_var
            break
          fi
        done
        if [ -n "$auth_seen" ]; then
          fm_worker_env_report ok "opencode credential: provided by $auth_seen in the environment"
        else
          fm_worker_env_report drift "no opencode credential at $data_home/opencode/auth.json and no provider credential in the environment"
          drift=1
        fi
      fi
    fi
  fi

  if [ -n "$worktree" ]; then
    top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || top=
    if [ -z "$top" ]; then
      fm_worker_env_report drift "worktree is not a readable git worktree root: $worktree"
      drift=1
    else
      want=$(fm_worker_env_realpath "$worktree")
      top=$(fm_worker_env_realpath "$top")
      if [ "$top" != "$want" ]; then
        fm_worker_env_report drift "worktree root resolves to $top instead of $want"
        drift=1
      elif [ -n "$primary" ]; then
        primary=$(fm_worker_env_realpath "$primary")
        if [ "$top" = "$primary" ]; then
          fm_worker_env_report drift "worktree root is the primary checkout: $top"
          drift=1
        else
          fm_worker_env_report ok "worktree root: $top"
        fi
      else
        fm_worker_env_report ok "worktree root: $top"
      fi
    fi
  fi

  [ "$drift" -eq 0 ]
}

# --- command line ------------------------------------------------------------

fm_worker_env_usage() {
  sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_worker_env_main() {
  local command=${1:-}
  if [ "$#" -ge 1 ]; then
    shift
  fi
  if [ "$command" = -h ] || [ "$command" = --help ] || [ -z "$command" ]; then
    fm_worker_env_usage
    [ -n "$command" ] || return 2
    return 0
  fi
  if [ "$command" != check ]; then
    echo "error: fm-worker-env.sh: unknown command '$command'; expected check" >&2
    return 2
  fi

  local script_dir root home config harness=opencode worktree='' primary='' value
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}"
  home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
  config="${FM_CONFIG_OVERRIDE:-$home/config}"

  local want_value=
  for value in "$@"; do
    if [ -n "$want_value" ]; then
      case "$want_value" in
      config) config=$value ;;
      harness) harness=$value ;;
      worktree) worktree=$value ;;
      primary) primary=$value ;;
      esac
      want_value=
      continue
    fi
    case "$value" in
    --config) want_value=config ;;
    --config=*) config=${value#*=} ;;
    --harness) want_value=harness ;;
    --harness=*) harness=${value#*=} ;;
    --worktree) want_value=worktree ;;
    --worktree=*) worktree=${value#*=} ;;
    --primary) want_value=primary ;;
    --primary=*) primary=${value#*=} ;;
    *)
      echo "error: fm-worker-env.sh check: unknown argument '$value'" >&2
      return 2
      ;;
    esac
  done
  if [ -n "$want_value" ]; then
    echo "error: fm-worker-env.sh: --$want_value requires a value" >&2
    return 2
  fi

  fm_worker_env_check "$config" "$harness" "$worktree" "$primary"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_worker_env_main "$@"
  exit $?
fi
