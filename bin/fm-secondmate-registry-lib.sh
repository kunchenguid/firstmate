#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared parser for data/secondmates.md records.
#
# A generated record ends with an explicit structured suffix:
#   (home: ...; scope: ...; projects: ...; added YYYY-MM-DD)
# Summary text and scope text are natural language and may contain parentheses
# and semicolons, so field boundaries are anchored to the suffix markers rather
# than to the first incidental punctuation.

SECONDMATE_REGISTRY_ID=
SECONDMATE_REGISTRY_SUMMARY=
SECONDMATE_REGISTRY_HOME=
SECONDMATE_REGISTRY_SCOPE=
SECONDMATE_REGISTRY_PROJECTS=
SECONDMATE_REGISTRY_ADDED=
SECONDMATE_REGISTRY_LINE=

secondmate_registry_parse_line() {
  local line=$1
  local record_re='^- ([A-Za-z0-9._-]+) - (.+) \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  SECONDMATE_REGISTRY_ID=
  SECONDMATE_REGISTRY_SUMMARY=
  SECONDMATE_REGISTRY_HOME=
  SECONDMATE_REGISTRY_SCOPE=
  SECONDMATE_REGISTRY_PROJECTS=
  SECONDMATE_REGISTRY_ADDED=
  if [[ "$line" =~ $record_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
    SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[3]}
    SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[4]}
    SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[5]}
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[6]}
  else
    return 1
  fi
  [ -n "$SECONDMATE_REGISTRY_HOME" ] || return 1
  [ -n "$SECONDMATE_REGISTRY_SCOPE" ] || return 1
  return 0
}

secondmate_registry_line_for_id() {
  local reg=$1 id=$2 line count=0
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "- $id" ] || case "$line" in "- $id "*) ;; *) continue ;; esac
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    SECONDMATE_REGISTRY_LINE=$line
  done < "$reg"
  [ "$count" -eq 1 ] || return 1
  secondmate_registry_parse_line "$SECONDMATE_REGISTRY_LINE"
}

secondmate_registry_field() {
  local reg=$1 id=$2 key=$3
  secondmate_registry_line_for_id "$reg" "$id" || return 1
  case "$key" in
    home) printf '%s\n' "$SECONDMATE_REGISTRY_HOME" ;;
    projects) printf '%s\n' "$SECONDMATE_REGISTRY_PROJECTS" ;;
    *) return 1 ;;
  esac
}
