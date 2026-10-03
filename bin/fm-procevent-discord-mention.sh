#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHANNEL_ID=1551134713727426570
SOURCE_ID=discord-claude-mentions

# shellcheck source=bin/fm-discord-lib.sh
source "$SCRIPT_DIR/fm-discord-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  printf '%s\n' \
    'fm-procevent-discord-mention.sh arm' \
    'fm-procevent-discord-mention.sh ensure' \
    'fm-procevent-discord-mention.sh poll' \
    'fm-procevent-discord-mention.sh classify <result-file>' \
    'fm-procevent-discord-mention.sh terminal <result-file>' \
    'fm-procevent-discord-mention.sh source-id'
  exit 2
}

load_discord_config() {
  FM_DISCORD_CHANNEL_ID="$CHANNEL_ID" fm_discord_load_config
  [ -n "${FM_DISCORD_TOKEN:-}" ] || return 1
  case ",${FM_DISCORD_EXCLUDES//[[:space:]]/}," in
    *",$CHANNEL_ID,"*) die "Firstcrew channel is explicitly excluded in FM_DISCORD_EXCLUDE_CHANNELS" ;;
  esac
  export FM_DISCORD_BOT_TOKEN="$FM_DISCORD_TOKEN"
}

is_primary_home() {
  [ "$(cd "$FM_HOME" && pwd -P)" = "$(cd "$FM_ROOT" && pwd -P)" ]
}

register_if_missing() {
  local registration="$STATE/procevent/$SOURCE_ID.source" expected actual
  if [ -f "$registration" ] || [ -L "$registration" ]; then
    [ -f "$registration" ] && [ ! -L "$registration" ] || die "source registration is unsafe"
    expected=$(printf 'adapter=discord-mention\nargc=2\nargv:\n%s\npoll' "$SCRIPT_DIR/fm-procevent-discord-mention.sh")
    actual=$(cat "$registration") || die "cannot read source registration"
    [ "$actual" = "$expected" ] || die "source registration differs; refusing to replace it"
    return 0
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" \
    register discord-mention "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-discord-mention.sh" poll
}

case "${1:-}" in
  arm)
    [ "$#" -eq 1 ] || usage
    is_primary_home || die "Discord mention source belongs to the primary Firstmate home"
    load_discord_config || die "FM_DISCORD_BOT_TOKEN is not configured"
    register_if_missing
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" reconcile
    ;;
  ensure)
    [ "$#" -eq 1 ] || usage
    is_primary_home || exit 0
    load_discord_config || exit 0
    register_if_missing >/dev/null
    ;;
  poll)
    [ "$#" -eq 1 ] || usage
    load_discord_config || {
      printf '{"schema":"firstmate.discord-mention-result.v1","status":"poll-error","error":"missing-token"}\n'
      exit 0
    }
    export FM_HOME FM_STATE_OVERRIDE="$STATE"
    exec python3 "$SCRIPT_DIR/fm-procevent-discord-mention.py"
    ;;
  source-id)
    [ "$#" -eq 1 ] || usage
    printf '%s\n' "$SOURCE_ID"
    ;;
  classify)
    [ "$#" -eq 2 ] || usage
    jq -er '.status | select(. == "mention" or . == "poll-error")' "$2"
    ;;
  terminal)
    [ "$#" -eq 2 ] || usage
    jq -e '.status == "poll-error" and (.error == "missing-token" or .error == "invalid-response" or .error == "oversized-response" or .error == "unsafe-cursor" or .error == "invalid-cursor" or .error == "invalid-message-id" or .error == "pagination-did-not-advance" or .error == "pagination-cap-exceeded" or .error == "http-401" or .error == "http-403" or .error == "http-404")' "$2" >/dev/null
    ;;
  -h|--help) usage ;;
  *) usage >&2 ;;
esac
