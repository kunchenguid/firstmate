# shellcheck shell=bash
# Shared .env-style file accessor.
# Usage: . bin/fm-env-lib.sh
#
# This file is the single owner of the one-key .env read: the Relay pairing
# token (bin/fm-x-lib.sh and its callers) and the optional typesafe.ai
# dispatch key (bin/fm-dispatch-resolve.sh) both resolve their value through
# fmx_env_get, so those opt-in secrets in $FM_HOME/.env are parsed by one rule.
# It also owns the dispatch key's source order (environment, then .env, then
# the macOS Keychain) for the resolver and bin/fm-bootstrap.sh.
# (bin/fm-mail.sh loads its whole .env block itself under the same env-wins
# contract.) The value is printed to the caller's command substitution only;
# nothing is logged.

# fmx_env_get <key> <file>
# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fmx_env_get() {
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

# fm_typesafe_key <env-value> <file>
# Print the typed dispatch key: <env-value> (the caller's private copy of
# TYPESAFE_API_KEY) when non-empty, else the TYPESAFE_API_KEY line in <file>,
# else the macOS Keychain generic password for service typesafe-api-key. A
# missing security command, Keychain item, or unreadable secret is absent, so
# empty output is off for the resolver and bootstrap alike.
fm_typesafe_key() {
  local val=$1
  [ -n "$val" ] || val=$(fmx_env_get TYPESAFE_API_KEY "$2")
  if [ -z "$val" ] && command -v security >/dev/null 2>&1; then
    val=$(security find-generic-password -s typesafe-api-key -w 2>/dev/null) || val=''
  fi
  printf '%s' "$val"
}
