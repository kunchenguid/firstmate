#!/usr/bin/env bash
# Task startup environment support for fm-spawn.sh.
#
# Source path: ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/dev_startup.env, passed to
# fm_dev_startup_env_validate by the caller after normal home resolution.
# A missing source is an exact no-op.
#
# The source is parsed as data and is never sourced or executed.
# Supported records are blank lines, full-line # comments, an optional leading
# export token, KEY=value assignments, one matching layer of single or double
# quotes, empty values, and duplicate keys whose last assignment wins.
# Keys must match [A-Za-z_][A-Za-z0-9_]* and values are otherwise literal.
# Ambient variables win, including variables that are present with empty values.
#
# fm_dev_startup_env_validate reads and validates the source once, before spawn
# allocation, and retains parsed values in process-local arrays.
# fm_dev_startup_env_prepare writes a mode-0600 generated export artifact below
# the task-private temp directory after that directory exists.
# fm_dev_startup_env_wrap_launch prefixes the common harness launch with loading
# and immediate removal of that generated artifact.
# The generated artifact is safe to source because it contains only generated,
# shell-quoted conditional exports; source values never enter launch output,
# task metadata, status, or the worktree.
#
# Usage:
#   . bin/fm-dev-startup-env-lib.sh
#   fm_dev_startup_env_validate "$CONFIG/dev_startup.env"
#   fm_dev_startup_env_prepare "$TASK_TMP"
#   LAUNCH=$(fm_dev_startup_env_wrap_launch "$LAUNCH")

FM_DEV_STARTUP_ENV_ACTIVE=0
FM_DEV_STARTUP_ENV_ARTIFACT=
FM_DEV_STARTUP_ENV_KEYS=()
FM_DEV_STARTUP_ENV_VALUES=()

fm_dev_startup_env_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_dev_startup_env_key_protected() {
  local key=$1
  case "$key" in
    FM_HOME|FM_ROOT_OVERRIDE|FM_STATE_OVERRIDE|FM_DATA_OVERRIDE|FM_PROJECTS_OVERRIDE|FM_CONFIG_OVERRIDE|\
    FM_BACKEND|FM_BACKEND_*|FM_SUPERVISOR_BACKEND|FM_SUPERVISOR_TARGET|\
    HOME|PATH|SHELL|PWD|OLDPWD|GOTMPDIR|TMUX|TMUX_PANE|BASH_ENV|ENV|IFS|CDPATH|BASHOPTS|SHELLOPTS|\
    HERDR_*|ZELLIJ_*|CMUX_*|ORCA_*|FM_HERDR_*|FM_ZELLIJ_*|FM_CMUX_*|FM_ORCA_*) return 0 ;;
  esac
  return 1
}

fm_dev_startup_env_store() {
  local key=$1 value=$2 i
  for i in "${!FM_DEV_STARTUP_ENV_KEYS[@]}"; do
    if [ "${FM_DEV_STARTUP_ENV_KEYS[$i]}" = "$key" ]; then
      FM_DEV_STARTUP_ENV_VALUES[i]=$value
      return 0
    fi
  done
  FM_DEV_STARTUP_ENV_KEYS+=("$key")
  FM_DEV_STARTUP_ENV_VALUES+=("$value")
}

fm_dev_startup_env_validate() {
  local source=$1 line declaration key value first last line_no
  FM_DEV_STARTUP_ENV_ACTIVE=0
  FM_DEV_STARTUP_ENV_ARTIFACT=
  FM_DEV_STARTUP_ENV_KEYS=()
  FM_DEV_STARTUP_ENV_VALUES=()
  [ -e "$source" ] || [ -L "$source" ] || return 0
  if [ ! -f "$source" ] || [ ! -r "$source" ]; then
    echo "error: dev_startup.env is not a readable file" >&2
    return 1
  fi

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      *$'\r'*)
        echo "error: invalid dev_startup.env syntax at line $line_no" >&2
        return 1
        ;;
    esac
    if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    declaration=$line
    if [[ "$declaration" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
      declaration=${declaration:${#BASH_REMATCH[0]}}
    elif [[ "$declaration" =~ ^[[:space:]]+ ]]; then
      declaration=${declaration:${#BASH_REMATCH[0]}}
    fi
    if [[ ! "$declaration" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "error: invalid dev_startup.env syntax at line $line_no" >&2
      return 1
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if fm_dev_startup_env_key_protected "$key"; then
      echo "error: protected dev_startup.env key: $key" >&2
      return 1
    fi
    if [ -n "$value" ]; then
      first=${value:0:1}
      last=${value: -1}
      case "$first" in
        "'"|'"')
          if [ "${#value}" -lt 2 ] || [ "$last" != "$first" ]; then
            echo "error: invalid dev_startup.env syntax at line $line_no" >&2
            return 1
          fi
          value=${value:1:${#value}-2}
          ;;
        *)
          case "$last" in
            "'"|'"')
              echo "error: invalid dev_startup.env syntax at line $line_no" >&2
              return 1
              ;;
          esac
          ;;
      esac
    fi
    fm_dev_startup_env_store "$key" "$value"
  done < "$source"
  FM_DEV_STARTUP_ENV_ACTIVE=1
}

fm_dev_startup_env_prepare() {
  local tasktmp=$1 artifact old_umask i key value quoted
  FM_DEV_STARTUP_ENV_ARTIFACT=
  [ "$FM_DEV_STARTUP_ENV_ACTIVE" = 1 ] || return 0
  [ -d "$tasktmp" ] || {
    echo "error: task-private temp directory is unavailable for dev_startup.env" >&2
    return 1
  }
  artifact="$tasktmp/dev-startup-env.sh"
  old_umask=$(umask)
  umask 077
  : > "$artifact" || {
    umask "$old_umask"
    echo "error: could not prepare task startup environment" >&2
    return 1
  }
  umask "$old_umask"
  chmod 0600 "$artifact" || {
    rm -f "$artifact" 2>/dev/null || true
    echo "error: could not secure task startup environment" >&2
    return 1
  }
  for i in "${!FM_DEV_STARTUP_ENV_KEYS[@]}"; do
    key=${FM_DEV_STARTUP_ENV_KEYS[i]}
    value=${FM_DEV_STARTUP_ENV_VALUES[i]}
    quoted=$(fm_dev_startup_env_shell_quote "$value")
    # shellcheck disable=SC2016  # ${KEY+x} is generated for the launched shell.
    printf 'if [ "${%s+x}" != x ]; then export %s=%s; fi\n' "$key" "$key" "$quoted" >> "$artifact" || {
      rm -f "$artifact" 2>/dev/null || true
      echo "error: could not prepare task startup environment" >&2
      return 1
    }
  done
  FM_DEV_STARTUP_ENV_ARTIFACT=$artifact
}

fm_dev_startup_env_wrap_launch() {
  local launch=$1 quoted
  if [ -z "$FM_DEV_STARTUP_ENV_ARTIFACT" ]; then
    printf '%s' "$launch"
    return 0
  fi
  quoted=$(fm_dev_startup_env_shell_quote "$FM_DEV_STARTUP_ENV_ARTIFACT")
  printf '. %s; rm -f -- %s; %s' "$quoted" "$quoted" "$launch"
}
