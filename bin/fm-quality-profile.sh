#!/usr/bin/env bash
# fm-quality-profile.sh - the single reader of this home's quality profile and
# of the verifier runtime that profile uses.
#
# Usage:
#   fm-quality-profile.sh [profile]   print "default" or "pstack"
#   fm-quality-profile.sh verifier    print three lines for the verifier scout:
#                                       harness=<adapter>
#                                       model=<model or empty>
#                                       effort=<effort or empty>
#   fm-quality-profile.sh -h|--help
#
# docs/configuration.md "Quality profile" owns what each profile means and the
# schema of both settings; this header owns only how they are parsed.
#
# config/quality-profile: the first and only non-empty, non-comment line, with
# surrounding white space removed, must be "default" or "pstack". An absent file
# reads as "default". A present file that is not a readable regular file, holds
# no value, holds more than one value line, or holds any other value stops this
# script with exit 2, an error on stderr, and nothing on stdout. It never guesses.
#
# config/verifier-harness: one line "<harness> [<model>] [<effort>]", parsed
# like config/secondmate-harness. An absent file resolves to the documented
# default, codex with its own model and effort defaults. The read refuses
# (exit 2, nothing on stdout) when the harness is not a verified adapter, when
# it is claude and no model is named, or when the harness can run models from
# several providers and no model is named. Only codex, grok, kimi, and gemini
# reach one provider by default and may omit the model. The read prints only
# what the file names; it never checks or replaces an unusable runtime.
#
# The config directory is FM_CONFIG_OVERRIDE when set, otherwise
# "$FM_HOME/config", with FM_HOME defaulting to the tracked code root, the same
# resolution bin/fm-brief.sh and bin/fm-harness.sh use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {  # <message>
  printf 'error: %s\n' "$1" >&2
  exit 2
}

# Print the value lines of a present setting file: comments and blank lines
# removed, surrounding white space trimmed. Refuses a path that is not a
# readable regular file.
value_lines() {  # <path>
  local path=$1 body
  { [ -f "$path" ] && [ -r "$path" ] && body=$(cat "$path" 2>/dev/null); } \
    || refuse "$path must be a readable regular file"
  printf '%s\n' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v -e '^$' -e '^#' || true
}

# Print the one value line of a present setting file, or refuse.
single_value() {  # <path>
  local path=$1 lines count
  lines=$(value_lines "$path") || exit 2
  count=$(printf '%s' "$lines" | grep -c '' || true)
  [ "$count" -ge 1 ] || refuse "$path is present but holds no value; write a value or remove the file"
  [ "$count" -eq 1 ] || refuse "$path holds $count value lines; it must hold exactly one"
  printf '%s\n' "$lines"
}

read_profile() {
  local path="$CONFIG/quality-profile" value
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'default\n'
    return 0
  fi
  value=$(single_value "$path") || exit 2
  case "$value" in
    default|pstack) printf '%s\n' "$value" ;;
    *) refuse "$path holds unknown value '$value'; accepted values are 'default' and 'pstack'" ;;
  esac
}

read_verifier() {
  local path="$CONFIG/verifier-harness" line harness model effort extra
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'harness=codex\nmodel=\neffort=\n'
    return 0
  fi
  line=$(single_value "$path") || exit 2
  # shellcheck disable=SC2086 # Word splitting the one value line is the format.
  set -- $line
  harness=${1:-}
  model=${2:-}
  effort=${3:-}
  extra=${4:-}
  [ -z "$extra" ] || refuse "$path holds more than '<harness> [<model>] [<effort>]'"
  fm_control_harness_supported "$harness" \
    || refuse "$path names '$harness', which is not a verified adapter"
  case "$harness" in
    codex|grok|kimi|gemini) ;;
    claude) [ -n "$model" ] \
      || refuse "$path names claude with no model; name the verifier's model after it, for example 'claude sonnet'" ;;
    *) [ -n "$model" ] \
      || refuse "$path names '$harness', which can run models from several providers; name the verifier's model after it" ;;
  esac
  printf 'harness=%s\nmodel=%s\neffort=%s\n' "$harness" "$model" "$effort"
}

case "${1:-profile}" in
  -h|--help) usage ;;
  profile) read_profile ;;
  verifier) read_verifier ;;
  *) refuse "unknown verb '$1'; see --help" ;;
esac
