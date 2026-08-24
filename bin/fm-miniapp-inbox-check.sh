#!/usr/bin/env bash
# fm-miniapp-inbox-check.sh - bring Mini App answers home and wake firstmate.
#
# The Mini App makes the answer instant FOR THE CAPTAIN: he taps and sees it
# land. It does not by itself make the answer visible to firstmate, because the
# existing Telegram poller prints its wake line only for messages it fetched
# itself, and an answer written by another process is not one of those.
#
# This script closes that gap. It runs as a registered check, fetches whatever
# answers the service has accepted since the last run into the local inbox, and
# prints exactly one line when something arrived and nothing at all otherwise -
# the contract every check in state/<id>.check.sh follows.
#
# The answers travel over ssh because the service runs on the host and the inbox
# lives here. The order is deliberate: a file is written locally FIRST and only
# then removed on the host, so an interruption repeats an answer rather than
# losing one. A repeat is harmless - the filename carries Telegram's own query
# id, so the same answer overwrites itself instead of arriving twice.
#
# Needs FM_MINIAPP_SSH and FM_MINIAPP_INBOX; FM_MINIAPP_REMOTE_ROOT defaults to
# /root/fm-miniapp. Settings come from bin/fm-miniapp-lib.sh.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export FM_MINIAPP_TOOL=fm-miniapp-inbox-check

# shellcheck source=bin/fm-miniapp-lib.sh
. "$SCRIPT_DIR/fm-miniapp-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
esac

fm_miniapp_load_config FM_MINIAPP_SSH FM_MINIAPP_INBOX
: "${FM_MINIAPP_REMOTE_ROOT:=/root/fm-miniapp}"

REMOTE_ANSWERS="$FM_MINIAPP_REMOTE_ROOT/answers"

# A check has a hard time budget and must never be the reason a watcher sweep
# stalls, so every remote call is bounded and a slow host is simply "nothing new
# this round".
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5)

# shellcheck disable=SC2029 # The remote paths come from local settings
# and are meant to expand here; the host must not resolve them itself.
names=$(ssh "${SSH_OPTS[@]}" "$FM_MINIAPP_SSH" \
  "ls -1 '$REMOTE_ANSWERS' 2>/dev/null | grep '\\.msg\$' || true" 2>/dev/null || true)
[ -n "$names" ] || exit 0

# Names come off the host, so they are checked here rather than trusted. The
# service only ever writes <id>.<channel>.msg, and anything else is left alone
# for a human to look at instead of being copied into the inbox.
safe=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  case "$name" in
    *[!A-Za-z0-9_.-]*|.*|*/*) continue ;;
    *.msg) safe+=("$name") ;;
  esac
done <<<"$names"
[ ${#safe[@]} -gt 0 ] || exit 0

mkdir -p "$FM_MINIAPP_INBOX"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

# shellcheck disable=SC2029 # The remote paths come from local settings
# and are meant to expand here; the host must not resolve them itself.
ssh "${SSH_OPTS[@]}" "$FM_MINIAPP_SSH" \
  "tar -C '$REMOTE_ANSWERS' -cf - ${safe[*]}" 2>/dev/null | tar -C "$staging" -xf - 2>/dev/null || exit 0

arrived=()
for name in "${safe[@]}"; do
  [ -f "$staging/$name" ] || continue
  install -m 600 "$staging/$name" "$FM_MINIAPP_INBOX/$name.tmp"
  mv "$FM_MINIAPP_INBOX/$name.tmp" "$FM_MINIAPP_INBOX/$name"
  arrived+=("$name")
done
[ ${#arrived[@]} -gt 0 ] || exit 0

# Only now, with every answer safely on this side.
# shellcheck disable=SC2029 # The remote paths come from local settings
# and are meant to expand here; the host must not resolve them itself.
ssh "${SSH_OPTS[@]}" "$FM_MINIAPP_SSH" \
  "cd '$REMOTE_ANSWERS' && rm -f ${arrived[*]}" >/dev/null 2>&1 || true

printf 'miniapp: %d answer(s) from the captain in %s\n' "${#arrived[@]}" "$FM_MINIAPP_INBOX"
