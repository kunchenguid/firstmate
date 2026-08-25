#!/usr/bin/env bash
# Read and write the compact captain-style preferences behind /helm.
# Usage:
#   fm-helm.sh show
#   fm-helm.sh set [--language <lang>] [--response-tone <text>]
#
# Storage: gitignored config/captain-style.json, a JSON object with two
# optional string keys, "language" and "response_tone". A key absent from the
# file means firstmate's built-in default for that axis; `set` merges its
# given flags into any existing file rather than replacing it, so setting one
# field never clobbers the other. `language` governs only firstmate's own
# chat and captain-facing artifacts (this conversation, reports, backlog
# notes, briefs, status digests) - it never changes a project's tracked code,
# comments, commit messages, PR descriptions, or checked-in documentation,
# and never changes what language a crewmate uses in its own work.
# `response_tone` is free text describing the desired vibe, interpreted the
# same way as data/captain.md's own "Address and tone" narrative.
# Both fields must be non-empty (after trimming leading/trailing whitespace)
# when set; `set` with neither flag is a usage error. An existing file must
# be a JSON object whose "language"/"response_tone" keys, if present, are
# strings; a non-object root or a structured (non-string) field value is
# refused by both `show` and `set` even though it is syntactically valid
# JSON. The write is atomic: a temp file in the same directory is renamed
# into place, so a failed write never leaves a partial
# config/captain-style.json behind.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STYLE_FILE="$CONFIG/captain-style.json"

usage() {
  sed -n '2,25{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'fm-helm: %s\n' "$1" >&2
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    print_error "jq is required and was not found on PATH"
    return 1
  }
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# validate_shape <file>: true only when the file is a JSON object and any
# present "language"/"response_tone" keys are strings. Rejects a non-object
# root (array, number, string, null) and structured (non-string) field
# values, both of which are syntactically valid JSON that `jq -e .` alone
# would accept.
validate_shape() {
  jq -e '
    type == "object"
    and ((has("language") | not) or (.language | type) == "string")
    and ((has("response_tone") | not) or (.response_tone | type) == "string")
  ' "$1" >/dev/null 2>&1
}

show() {
  if [ ! -f "$STYLE_FILE" ]; then
    printf 'ABSENT: config/captain-style.json not set - firstmate defaults apply\n'
    return 0
  fi
  require_jq
  if ! jq -e . "$STYLE_FILE" >/dev/null 2>&1; then
    print_error "config/captain-style.json is not valid JSON"
    return 1
  fi
  if ! validate_shape "$STYLE_FILE"; then
    print_error "config/captain-style.json must be a JSON object with string \"language\"/\"response_tone\" fields"
    return 1
  fi
  local language response_tone
  language=$(jq -r '.language // empty' "$STYLE_FILE")
  response_tone=$(jq -r '.response_tone // empty' "$STYLE_FILE")
  printf 'language=%s\n' "${language:-(not set)}"
  printf 'response_tone=%s\n' "${response_tone:-(not set)}"
}

set_fields() {
  local new_language='' new_response_tone='' have_language=0 have_response_tone=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --language)
        [ $# -ge 2 ] || { print_error "--language requires a value"; return 2; }
        new_language=$(trim "$2")
        have_language=1
        shift 2
        ;;
      --response-tone)
        [ $# -ge 2 ] || { print_error "--response-tone requires a value"; return 2; }
        new_response_tone=$(trim "$2")
        have_response_tone=1
        shift 2
        ;;
      *)
        print_error "unknown argument: $1"
        return 2
        ;;
    esac
  done

  if [ "$have_language" -eq 0 ] && [ "$have_response_tone" -eq 0 ]; then
    print_error "set requires at least one of --language or --response-tone"
    return 2
  fi
  if [ "$have_language" -eq 1 ] && [ -z "$new_language" ]; then
    print_error "--language must not be empty"
    return 2
  fi
  if [ "$have_response_tone" -eq 1 ] && [ -z "$new_response_tone" ]; then
    print_error "--response-tone must not be empty"
    return 2
  fi

  require_jq
  local current='{}'
  if [ -f "$STYLE_FILE" ]; then
    if ! jq -e . "$STYLE_FILE" >/dev/null 2>&1; then
      print_error "config/captain-style.json is not valid JSON - refusing to merge over it"
      return 1
    fi
    if ! validate_shape "$STYLE_FILE"; then
      print_error "config/captain-style.json must be a JSON object with string \"language\"/\"response_tone\" fields - refusing to merge over it"
      return 1
    fi
    current=$(cat "$STYLE_FILE")
  fi

  local merged
  merged="$current"
  if [ "$have_language" -eq 1 ]; then
    merged=$(printf '%s' "$merged" | jq --arg v "$new_language" '.language = $v')
  fi
  if [ "$have_response_tone" -eq 1 ]; then
    merged=$(printf '%s' "$merged" | jq --arg v "$new_response_tone" '.response_tone = $v')
  fi

  mkdir -p "$CONFIG" 2>/dev/null || { print_error "cannot create $CONFIG"; return 1; }
  local tmp
  tmp=$(mktemp "$CONFIG/.fm-helm.XXXXXX" 2>/dev/null) || { print_error "mktemp failed in $CONFIG"; return 1; }
  if ! printf '%s\n' "$merged" | jq . > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    print_error "failed to write $STYLE_FILE"
    return 1
  fi
  if ! mv -f "$tmp" "$STYLE_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    print_error "failed to publish $STYLE_FILE"
    return 1
  fi

  show
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  show)
    shift
    show "$@"
    ;;
  set)
    shift
    set_fields "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
