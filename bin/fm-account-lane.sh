#!/usr/bin/env bash
# Resolve declared native subscription account lanes without inspecting credentials.
# Operator schema: docs/configuration.md "Native account lanes".
# Usage: fm-account-lane.sh validate [FILE]
#        fm-account-lane.sh resolve|harness|env-name|config-dir ACCOUNT_ID [FILE]
set -eu

CONFIG=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$(pwd)}/config}
COMMAND=${1:-}
ACCOUNT=${2:-}
FILE=${3:-$CONFIG/crew-accounts.json}

read_snapshot() {
  SNAPSHOT=$(cat -- "$FILE" 2>/dev/null) || {
    echo "invalid account-lane schema" >&2
    return 1
  }
}

validate_snapshot() {
  local snapshot=$1 reason
  if ! reason=$(jq -r '
    def forbidden: ["apiKey","token","secret","password","cookie","authorization"];
    def forbidden_key:
      [ (., (paths(objects) as $path
            | select($path != ["accounts"])
            | getpath($path)))
        | select(type == "object")
        | keys_unsorted[]
        | select(. as $key | forbidden | index($key))
      ][0] // null;
    if type != "object" or .version != 1 or (.accounts|type) != "object" then "invalid account-lane schema"
    elif forbidden_key != null then "forbidden credential field: \(forbidden_key)"
    elif [.accounts|to_entries[]|select(.key|test("^[a-z0-9][a-z0-9-]*$")|not)]|length > 0 then "invalid account id"
    elif [.accounts[]|select(type != "object" or ((keys|sort) != ["configDir","envName","harness"]))]|length > 0 then "account fields must be harness, envName, and configDir"
    elif [.accounts[]|select(.harness != "claude" and .harness != "codex")]|length > 0 then "account harness must be claude or codex"
    elif [.accounts[]|select(.harness == "claude" and .envName != "CLAUDE_CONFIG_DIR")]|length > 0 then "claude accounts require CLAUDE_CONFIG_DIR"
    elif [.accounts[]|select(.harness == "codex" and .envName != "CODEX_HOME")]|length > 0 then "codex accounts require CODEX_HOME"
    elif [.accounts[]|select((.configDir|type) != "string" or (.configDir|startswith("/")|not))]|length > 0 then "configDir must be absolute"
    else empty end
  ' <<<"$snapshot" 2>/dev/null); then
    echo "invalid account-lane schema" >&2
    return 1
  fi
  if [ -n "$reason" ]; then
    echo "$reason" >&2
    return 1
  fi
}

selected_account() {
  jq -cer --arg id "$ACCOUNT" '.accounts[$id] | {harness,envName,configDir}' <<<"$1" 2>/dev/null
}

selected_config_dir() {
  local account=$1 dir
  dir=$(jq -er '.configDir' <<<"$account" 2>/dev/null) || return 1
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
    echo "configDir must be an existing readable directory" >&2
    exit 1
  fi
  printf '%s\n' "$dir"
}

case "$COMMAND" in
  validate)
    FILE=${2:-$FILE}
    read_snapshot
    validate_snapshot "$SNAPSHOT"
    ;;
  resolve|harness|env-name|config-dir)
    read_snapshot
    validate_snapshot "$SNAPSHOT"
    SELECTED=$(selected_account "$SNAPSHOT") || { echo "account id is not configured" >&2; exit 1; }
    selected_config_dir "$SELECTED" >/dev/null
    case "$COMMAND" in
      resolve) printf '%s\n' "$SELECTED" ;;
      harness) jq -er '.harness' <<<"$SELECTED" ;;
      env-name) jq -er '.envName' <<<"$SELECTED" ;;
      config-dir) jq -er '.configDir' <<<"$SELECTED" ;;
    esac
    ;;
  *) echo 'usage: fm-account-lane.sh validate|resolve|harness|env-name|config-dir ...' >&2; exit 2 ;;
esac
