# shellcheck shell=bash
# Shared reader for `.env`-style credential files.
# Usage: . bin/fm-env-lib.sh
#
# A firstmate home keeps its credentials in one gitignored `.env`, and more than
# one opt-in feature now reads from it. This file is the single owner of what a
# KEY=VALUE line in that file means, so a second feature never grows a second
# parser that drifts from the first.
#
# It defines:
#   fm_env_get <key> <file>  - read one KEY=VALUE from a .env-style file
#
# Deliberately a reader and not a loader: it never sources the file and never
# exports anything, so a credential file can carry no shell surface at all.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fm_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}
