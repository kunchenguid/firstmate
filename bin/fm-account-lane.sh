#!/usr/bin/env bash
# Resolve declared native subscription account lanes without inspecting credentials.
# Usage: fm-account-lane.sh validate [FILE]
#        fm-account-lane.sh harness ACCOUNT_ID [FILE]
#        fm-account-lane.sh env-name ACCOUNT_ID [FILE]
#        fm-account-lane.sh config-dir ACCOUNT_ID [FILE]
set -eu

CONFIG=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$(pwd)}/config}
COMMAND=${1:-}
ACCOUNT=${2:-}
FILE=${3:-$CONFIG/crew-accounts.json}

validate() {
  local reason
  if ! reason=$(jq -r '
    def forbidden: ["apiKey","token","secret","password","cookie","authorization"];
    def forbidden_key:
      [ (., (paths(objects) as $path | getpath($path)))
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
  ' "$1" 2>/dev/null); then
    echo "invalid account-lane schema" >&2
    return 1
  fi
  if [ -n "$reason" ]; then
    echo "$reason" >&2
    return 1
  fi
}

selected_config_dir() {
  local dir
  dir=$(jq -er --arg id "$ACCOUNT" '.accounts[$id].configDir' "$FILE")
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
    echo "configDir must be an existing readable directory" >&2
    exit 1
  fi
  printf '%s\n' "$dir"
}

case "$COMMAND" in
  validate) FILE=${2:-$FILE}; validate "$FILE" ;;
  harness|env-name|config-dir)
    validate "$FILE"
    selected_config_dir >/dev/null
    KEY=$(case "$COMMAND" in harness) echo harness ;; env-name) echo envName ;; config-dir) echo configDir ;; esac)
    jq -er --arg id "$ACCOUNT" --arg key "$KEY" '.accounts[$id][$key]' "$FILE"
    ;;
  *) echo 'usage: fm-account-lane.sh validate|harness|env-name|config-dir ...' >&2; exit 2 ;;
esac
