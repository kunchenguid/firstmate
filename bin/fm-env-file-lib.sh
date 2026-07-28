#!/usr/bin/env bash
# Shared reader for the firstmate home's gitignored .env file.
#
# This file is sourced, never executed. Every channel that takes its secret from
# the home's private .env (X mode, the Telegram bridge) reads it through this one
# function, so quoting, `export` prefixes, and last-assignment-wins can never
# disagree between two channels reading the same file.
#
# It defines:
#   fm_env_file_get <key> <file>  - print the value of KEY, or nothing
#
# Values are never logged here. A caller that reports a configuration problem is
# responsible for reporting the problem without echoing the value it read.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fm_env_file_get() {
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
