#!/usr/bin/env bash
# Safely add a Stop hook to a kimi config.toml.
# Usage: fm-kimi-merge-hook.sh <config.toml> <turnend-file>
# Adds a [[hooks]] Stop entry that touches <turnend-file>.
# Defensive behavior:
#   - Ensures the file ends with a newline.
#   - If the file already contains a [[hooks]] section, appends the Stop entry
#     as another array-of-tables element (valid TOML).
#   - If the file contains a bare [hooks] table, errors out (unsupported merge).
#   - If a Stop hook with the same command is already present, does not duplicate it.
set -u

if [ "$#" -ne 2 ]; then
  echo "usage: fm-kimi-merge-hook.sh <config.toml> <turnend-file>" >&2
  exit 2
fi

CONFIG=$1
TURNEND=$2

[ -f "$CONFIG" ] || { echo "error: config file not found: $CONFIG" >&2; exit 1; }

# Ensure the file ends with a newline so the appended TOML is well-formed.
if [ -s "$CONFIG" ]; then
  if [ "$(tail -c 1 "$CONFIG" | od -An -tx1 | tr -d ' ')" != "0a" ]; then
    printf '\n' >> "$CONFIG"
  fi
fi

# A bare [hooks] table conflicts with the [[hooks]] array-of-tables we need.
if grep -qE '^\[hooks\]' "$CONFIG"; then
  echo "error: $CONFIG contains a bare [hooks] table; cannot merge Stop hook" >&2
  exit 1
fi

# Do not duplicate an identical Stop hook command.
# The command is distinctive (touch <turnend>), so its presence is enough.
if grep -qF "command = \"touch $TURNEND\"" "$CONFIG"; then
  exit 0
fi

{
  printf '\n[[hooks]]\n'
  printf 'event = "Stop"\n'
  printf 'command = "touch %s"\n' "$TURNEND"
} >> "$CONFIG"
