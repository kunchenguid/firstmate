#!/usr/bin/env bash
# Short-poll of Discord API for a pending self-hosted Discord mention.
#
# Inert by default: a HARD no-op (exit 0, no output) unless FM_DISCORD_BOT_TOKEN
# is configured (from the home's .env or environment).
# The watcher invokes this trusted repository script directly after
# state/discord-watch.check.sh matches the expected byte-static identity shim.
#
# Its contract: output "x-mention <request_id>" => wake firstmate, silence => keep sleeping.
#
# A captured item is also enqueued into the durable wake queue here, so capture
# itself is the wake. The stdout contract only reaches a session when the WATCHER
# ran this script: an operator-run or LaunchAgent-run ingress poll reaches nobody
# that way, because its stdout goes to a log file while the offered marker
# written during capture then makes every later watcher poll suppress the item.
# That combination captured a captain reply and never woke anyone for it. The
# enqueue is additive, so the watcher's own validated check dispatch still sees
# and still forwards the same line.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

fm_discord_load_config
[ -n "${FM_DISCORD_TOKEN:-}" ] || exit 0

command -v node >/dev/null 2>&1 || { printf 'x-mode-error missing node for self-hosted Discord\n'; exit 0; }

export FM_HOME FM_ROOT FM_STATE_OVERRIDE="$STATE"
export FM_DISCORD_BOT_TOKEN="$FM_DISCORD_TOKEN"
export FM_DISCORD_CHANNELS="${FM_DISCORD_CHANNELS:-}"
export FM_DISCORD_EXCLUDES="${FM_DISCORD_EXCLUDES-}"
export FM_DISCORD_ALLOW_DMS="${FM_DISCORD_DMS:-true}"
export FM_DISCORD_AUTHORIZED_USER_IDS="${FM_DISCORD_AUTHORIZED_USERS:-}"

# Only a token-gated run can capture anything, so the wake library is loaded
# only here: without a token this stays a hard no-op that touches no state.
if [ ! -r "$FM_ROOT/bin/fm-wake-lib.sh" ]; then
  printf 'fm-discord-poll: cannot enqueue a wake (missing %s)\n' "$FM_ROOT/bin/fm-wake-lib.sh" >&2
  exit 1
fi
# shellcheck source=/dev/null
FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$FM_ROOT/bin/fm-wake-lib.sh"

OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-discord-poll.XXXXXX") || exit 1
trap 'rm -f "$OUT_FILE"' EXIT
node "$SCRIPT_DIR/fm-discord-poll.js" > "$OUT_FILE"
poll_rc=$?
cat "$OUT_FILE"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    'x-mention '*) ;;
    *) continue ;;
  esac
  request_id=${line#x-mention }
  case "$request_id" in
    ''|.*|*[!A-Za-z0-9._-]*)
      printf 'fm-discord-poll: refusing to wake on an unusable request id\n' >&2
      continue
      ;;
  esac
  # The notifier's own decision-poll shim owns the same durable key, so a
  # duplicate here is absorbed by the queue's per-key dedupe instead of
  # surfacing the same reply twice. A failed enqueue never loses the capture:
  # the inbox record is already on disk, so report it loudly and let a later
  # poll's own capture retry.
  fm_wake_append check "discord-$request_id" "check: $line" \
    || printf 'fm-discord-poll: captured %s but could not enqueue its wake\n' "$request_id" >&2
done < "$OUT_FILE"
exit "$poll_rc"
