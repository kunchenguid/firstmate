#!/usr/bin/env bash
# Shared reader for the home brief include and its per-part files.
# config/brief-include.md holds the standing additions every ship and scout
# brief takes; config/brief-include.d/<part>.md holds additions only some
# briefs take. bin/fm-brief.sh appends the part named by the brief's kind
# (ship or scout) when that file exists, then each part requested with
# --brief-part, which must exist. bin/fm-promote.sh appends the ship part to
# the promoted contract, since a scout brief never carried it.
# A part name is lowercase letters, digits, and hyphens.

# fm_brief_include_read <file>: print the file's text, or nothing for a blank
# file. A present path that is not a readable regular file, or text carrying
# its own "Delivery contract: mode=" line, prints an error and returns 1.
fm_brief_include_read() {
  local file=$1 body=
  { [ -f "$file" ] && body=$(cat "$file" 2>/dev/null); } || {
    echo "error: $file must be a readable regular file" >&2
    return 1
  }
  if printf '%s\n' "$body" | grep -q '^Delivery contract: mode='; then
    echo "error: $file must not carry a 'Delivery contract: mode=' line; the delivery mode is a per-task --mode decision" >&2
    return 1
  fi
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || body=
  printf '%s' "$body"
}

# fm_brief_include_part_valid <name>: return 0 for a well-formed part name.
fm_brief_include_part_valid() {
  case "$1" in
    ''|*[!a-z0-9-]*|-*) return 1 ;;
  esac
  return 0
}
