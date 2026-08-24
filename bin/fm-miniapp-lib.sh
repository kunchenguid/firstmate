#!/usr/bin/env bash
# fm-miniapp-lib.sh - shared configuration handling for the Telegram Mini App
# scripts (fm-miniapp-deploy.sh, fm-miniapp-ask.sh, fm-miniapp-inbox-check.sh).
#
# This file is the single owner of where the Mini App's local settings come from
# and of how the bot token is read. The scripts that source it document only the
# values they themselves require.
#
# Settings are read from ~/.config/fm-miniapp.env, overridable with
# FM_MINIAPP_CONFIG. Any value already exported wins over the file, so a one-off
# run can override a single setting without editing anything. No value has a
# default that points at a real bot, chat, host or address: an unset required
# value refuses the run rather than guessing.
#
# The file holds settings, not secrets. The bot token stays where it already
# lives - the operator's own environment file - and is read one variable at a
# time by fm_miniapp_read_token.

fm_miniapp_die() {
  printf '%s: %s\n' "${FM_MINIAPP_TOOL:-fm-miniapp}" "$1" >&2
  exit 1
}

# fm_miniapp_load_config <required-variable>...
#
# Loads the settings file, then refuses unless every named variable is set.
fm_miniapp_load_config() {
  local config=${FM_MINIAPP_CONFIG:-$HOME/.config/fm-miniapp.env}
  if [ -f "$config" ]; then
    local line name value
    while IFS= read -r line; do
      case "$line" in
        ''|\#*) continue ;;
        *=*) : ;;
        *) continue ;;
      esac
      name=${line%%=*}
      value=${line#*=}
      value=${value%\"}
      value=${value#\"}
      value=${value%\'}
      value=${value#\'}
      [ -n "${!name:-}" ] || export "$name=$value"
    done <"$config"
  fi

  local missing=() name
  for name in "$@"; do
    [ -n "${!name:-}" ] || missing+=("$name")
  done
  [ ${#missing[@]} -eq 0 ] || fm_miniapp_die "unset (config $config): ${missing[*]}"
}

# fm_miniapp_read_token
#
# Echoes the one bot token named by FM_MINIAPP_TOKEN_VAR out of the file named
# by FM_MINIAPP_TOKEN_FILE. The file is read, never sourced: sourcing a file of
# secrets pulls every one of them into the calling process, and this needs one.
fm_miniapp_read_token() {
  local file=${FM_MINIAPP_TOKEN_FILE:-} var=${FM_MINIAPP_TOKEN_VAR:-} value
  [ -n "$file" ] && [ -n "$var" ] \
    || fm_miniapp_die "FM_MINIAPP_TOKEN_FILE and FM_MINIAPP_TOKEN_VAR are required"
  [ -f "$file" ] || fm_miniapp_die "token file not found: $file"
  value=$(sed -n "s/^[[:space:]]*${var}[[:space:]]*=[[:space:]]*//p" "$file" | head -1)
  value=${value%\"}
  value=${value#\"}
  value=${value%\'}
  value=${value#\'}
  [ -n "$value" ] || fm_miniapp_die "$var is not set in $file"
  printf '%s' "$value"
}

fm_miniapp_on_host() {
  ssh -o BatchMode=yes "$FM_MINIAPP_SSH" "$@"
}

# fm_miniapp_probe <url> -> "<url> <status>"
#
# ERR rather than a shell failure, so a probe of an address that is deliberately
# not up yet reports a status instead of aborting the run around it.
fm_miniapp_probe() {
  local url=$1 code
  code=$(curl -sS -o /dev/null -m 20 -w '%{http_code}' "$url" 2>/dev/null || printf 'ERR')
  printf '%s %s\n' "$url" "$code"
}
