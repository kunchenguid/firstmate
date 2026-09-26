#!/usr/bin/env bash
# Process-event adapter for the Notion bot-manager issue ledger.
#
# Usage:
#   fm-procevent-bot-manager.sh arm
#   fm-procevent-bot-manager.sh ensure
#   fm-procevent-bot-manager.sh poll
#   fm-procevent-bot-manager.sh classify <result-file>
#   fm-procevent-bot-manager.sh terminal <result-file>
#   fm-procevent-bot-manager.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-bot-manager.sh source-id
#
# arm registers one long-polling Notion reader in this Firstmate home. poll is
# runner-owned and must not be invoked in a conversational turn. Captured issue
# batches are acknowledged only after atomically advancing the private cursor.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SOURCE_ID=bot-manager-issues
DB_ID=05814415-7a73-435d-b394-aa016fd088eb

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

load_token() {
  local env_file="${HOME:?}/.claude/prompts/discord-bot.env"
  [ -r "$env_file" ] || die "Notion credential file is unavailable"
  # The approved runtime file is the same environment file used by the bot
  # manager cron. Source it in this process; never print or persist its values.
  # shellcheck disable=SC1090
  . "$env_file"
  [ -n "${NOTION_TOKEN:-}" ] || die "NOTION_TOKEN is absent from the approved runtime file"
  export NOTION_TOKEN
}

register_if_missing() {
  local registration="$STATE/procevent/$SOURCE_ID.source"
  if [ -f "$registration" ]; then
    local expected actual
    expected=$(printf 'adapter=bot-manager\nargc=2\nargv:\n%s\npoll\n' "$SCRIPT_DIR/fm-procevent-bot-manager.sh")
    actual=$(cat "$registration") || die "cannot read the existing source registration"
    [ "$actual" = "${expected%$'\n'}" ] || die "source registration differs; refusing to replace it"
    return 0
  fi
  mkdir -p "$STATE/procevent"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register bot-manager "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-bot-manager.sh" poll
}

run_poll() {
  load_token
  exec python3 "$SCRIPT_DIR/fm-bot-manager-poll.py" poll \
    --database "$DB_ID" --state "$STATE/bot-manager-autofix.json"
}

case "${1:-}" in
  arm)
    # The primary home alone owns this source; secondmate homes must not create
    # duplicate pollers against the same issue database.
    [ "$(cd "$FM_HOME" && pwd -P)" = "$(cd "$FM_ROOT" && pwd -P)" ] || exit 0
    register_if_missing
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile
    ;;
  ensure)
    [ "$(cd "$FM_HOME" && pwd -P)" = "$(cd "$FM_ROOT" && pwd -P)" ] || exit 0
    register_if_missing
    ;;
  poll) run_poll ;;
  source-id) printf '%s\n' "$SOURCE_ID" ;;
  classify)
    [ $# -eq 2 ] || die "classify requires a result file"
    jq -er '.kind | select(. == "issues" or . == "poll-error")' "$2"
    ;;
  silent)
    # Every newly detected batch requires firstmate judgment.
    exit 1
    ;;
  terminal)
    # Individual issue batches keep polling; permanent API failures end it.
    jq -e '.kind == "poll-error" and .status == "error"' "$2" >/dev/null
    ;;
  autohandle)
    [ $# -eq 4 ] || die "autohandle requires source id, sequence, and result file"
    [ "$2" = "$SOURCE_ID" ] || die "unexpected source id"
    jq -e '.kind == "issues" and (.snapshot_ids | type == "array")' "$4" >/dev/null || exit 1
    python3 "$SCRIPT_DIR/fm-bot-manager-poll.py" acknowledge \
      --state "$STATE/bot-manager-autofix.json" --result "$4"
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" handled "$2" "$3" >/dev/null
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
