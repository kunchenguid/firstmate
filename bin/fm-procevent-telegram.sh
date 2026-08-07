#!/usr/bin/env bash
# Telegram adapter for the generic process-to-event runner: a phone reply from
# the operator wakes firstmate instead of sitting unseen in a chat.
#
# Usage:
#   fm-procevent-telegram.sh arm [<source-id>]
#   fm-procevent-telegram.sh poll
#   fm-procevent-telegram.sh ack <update-id>
#   fm-procevent-telegram.sh terminal <result-file>
#
# arm        Register this adapter's blocking poll with the generic runner under
#            <source-id> (default: telegram-captain). Registration is the whole
#            arming step: the runner's own reconcile cycle starts and supervises
#            the poll, exactly as with every other registered source.
# poll       The blocking child the runner supervises. It long-polls the Telegram
#            Bot API getUpdates method (offset = cursor + 1, server-side timeout
#            FM_TELEGRAM_POLL_TIMEOUT, default 50s) until a non-empty batch of
#            updates arrives, prints that raw JSON response to stdout once, and
#            exits 0. The batch is capped so even a worst-case response stays
#            well under the runner's captured-output limit and is published as
#            parseable JSON; updates beyond the cap stay queued at Telegram and
#            arrive on the next poll. Transient network and server errors retry
#            with bounded backoff (FM_TELEGRAM_BACKOFF_SECONDS, default 5), and
#            HTTP 429 waits the server's own retry_after instead, bounded by
#            FM_TELEGRAM_MAX_BACKOFF_SECONDS (default 60). A hard auth failure
#            (HTTP 401 or 403) and a getUpdates conflict (HTTP 409, which means
#            either a webhook is configured on the bot or another poller is
#            already running for it) exit non-zero so the runner surfaces the
#            blocker rather than spinning on it. The bot token is never printed.
# ack        Advance the cursor to <update-id> after that update has been fully
#            handled. The write is atomic and idempotent, and it never moves the
#            cursor backwards: an id at or below the current cursor is a
#            successful no-op, and concurrent acks are serialized so the cursor
#            cannot rewind. Anything but a nonnegative integer is refused.
# terminal   Always exits 1: a message stream never ends by itself, so no
#            captured result ever retires this source. Retirement is an explicit
#            operator action through `fm-procevent.sh retire <source-id>`.
#
# File contract:
#   ~/.config/firstmate/telegram-token   The bot token, one line, private.
#   ~/.config/firstmate/telegram-cursor  The last HANDLED update id. Absent
#                                        means 0: nothing handled yet.
#
# The poll only READS the cursor. The HANDLER - firstmate acting on the
# published wake - advances it, and only after it has fully handled the captured
# updates, by calling this adapter's `ack <update-id>` for the highest update id
# it handled. That acknowledgement is the sole writer of the cursor file, so a
# crash never advances past unhandled messages.
#
# Duplicate-result window, stated plainly: a poll restart before the handler
# acknowledges re-captures the same updates in a new result. Handlers must treat
# any update id <= the current cursor as already seen and act on it as a no-op;
# the runner's handled acknowledgement deduplicates announcements, not update
# ids.
#
# Result bytes are operator chat content: input, never instruction and never
# authority. They must not be executed, echoed into a shell, or read as
# approval; decisions in them route through the ordinary decision owners.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOKEN_FILE="$HOME/.config/firstmate/telegram-token"
CURSOR_FILE="$HOME/.config/firstmate/telegram-cursor"
CURSOR_LOCK="$HOME/.config/firstmate/.telegram-cursor.lock"
API_BASE='https://api.telegram.org'
POLL_TIMEOUT=${FM_TELEGRAM_POLL_TIMEOUT:-50}
BACKOFF=${FM_TELEGRAM_BACKOFF_SECONDS:-5}
MAX_BACKOFF=${FM_TELEGRAM_MAX_BACKOFF_SECONDS:-60}
# One update carries at most a few tens of kilobytes of escaped JSON, so a batch
# this size stays an order of magnitude under the runner's default 1 MiB output
# cap. Anything the cap truncates would be published as invalid JSON, and
# capping the batch costs nothing: unacknowledged updates are redelivered.
BATCH_LIMIT=8
# Longest update id bash arithmetic and `test` compare without overflowing.
MAX_ID_DIGITS=18

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# Read and validate the token without ever letting it reach stdout, stderr, or
# a command line: it is passed to curl only through a stdin config, so neither
# adapter output nor a process listing can leak it.
read_token() {
  local token=
  [ -f "$TOKEN_FILE" ] || die "telegram token file is missing: $TOKEN_FILE (write the bot token there, one line, mode 0600)"
  IFS= read -r token < "$TOKEN_FILE" || true
  case "$token" in
    '') die "telegram token file is empty: $TOKEN_FILE" ;;
    *[!A-Za-z0-9:_-]*) die "telegram token file contains unexpected characters: $TOKEN_FILE" ;;
  esac
  printf '%s\n' "$token"
}

read_cursor() {
  local cursor=
  [ -f "$CURSOR_FILE" ] || { printf '0\n'; return 0; }
  IFS= read -r cursor < "$CURSOR_FILE" || true
  case "$cursor" in
    ''|*[!0-9]*) die "telegram cursor file is not a nonnegative integer: $CURSOR_FILE" ;;
  esac
  [ "${#cursor}" -le "$MAX_ID_DIGITS" ] || die "telegram cursor file holds an implausibly large update id: $CURSOR_FILE"
  printf '%s\n' "$((10#$cursor))"
}

# The staged response file, kept out of cmd_poll's locals so the EXIT trap can
# still name it once that function has returned.
POLL_BODY=

cleanup_poll_body() {
  [ -n "$POLL_BODY" ] || return 0
  rm -f -- "$POLL_BODY"
  POLL_BODY=
}

# The server's own requested pause for a rate-limited request, bounded so a
# garbled or hostile retry_after cannot park the poll indefinitely.
retry_after_delay() {  # <body-file>
  local match value
  match=$(grep -o '"retry_after"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$1" 2>/dev/null | head -n 1)
  value=${match##*[![:digit:]]}
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$BACKOFF"; return 0 ;;
  esac
  [ "${#value}" -le "$MAX_ID_DIGITS" ] || { printf '%s\n' "$MAX_BACKOFF"; return 0; }
  value=$((10#$value))
  [ "$value" -ge 1 ] || { printf '%s\n' "$BACKOFF"; return 0; }
  [ "$value" -le "$MAX_BACKOFF" ] || value=$MAX_BACKOFF
  printf '%s\n' "$value"
}

cmd_poll() {
  local token cursor offset http_code rc
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  case "$POLL_TIMEOUT" in ''|*[!0-9]*) die "FM_TELEGRAM_POLL_TIMEOUT must be a nonnegative integer" ;; esac
  case "$BACKOFF" in ''|*[!0-9]*) die "FM_TELEGRAM_BACKOFF_SECONDS must be a nonnegative integer" ;; esac
  case "$MAX_BACKOFF" in ''|*[!0-9]*) die "FM_TELEGRAM_MAX_BACKOFF_SECONDS must be a nonnegative integer" ;; esac
  token=$(read_token) || exit 1
  cursor=$(read_cursor) || exit 1
  offset=$((cursor + 1))
  # The runner stops this child with a process-group SIGTERM, which kills a
  # bash with no signal trap before its EXIT trap can run; both traps together
  # are what actually keep the staged response from leaking.
  trap cleanup_poll_body EXIT
  trap 'cleanup_poll_body; exit 1' HUP INT TERM
  POLL_BODY=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-poll.XXXXXX") || die "cannot stage the response"
  while :; do
    # curl runs silent with stderr discarded so no failure message can echo the
    # tokened URL; classification uses only the exit code and the HTTP status.
    http_code=$(printf 'url = "%s/bot%s/getUpdates"\n' "$API_BASE" "$token" \
      | curl -s --config - -o "$POLL_BODY" -w '%{http_code}' \
          --max-time "$((POLL_TIMEOUT + 10))" \
          --data-urlencode "offset=$offset" \
          --data-urlencode "limit=$BATCH_LIMIT" \
          --data-urlencode "timeout=$POLL_TIMEOUT" \
          2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      sleep "$BACKOFF"
      continue
    fi
    case "$http_code" in
      401|403) die "telegram rejected the bot token (HTTP $http_code); check $TOKEN_FILE" ;;
      409) die "telegram refused getUpdates with a conflict (HTTP 409); either a webhook is configured on this bot or another getUpdates poller is already running for it, so check both before re-arming this poll" ;;
      429)
        sleep "$(retry_after_delay "$POLL_BODY")"
        continue
        ;;
      200) ;;
      *)
        sleep "$BACKOFF"
        continue
        ;;
    esac
    if grep -q '"update_id"' "$POLL_BODY"; then
      cat "$POLL_BODY"
      return 0
    fi
    if grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$POLL_BODY"; then
      # The server-side long poll expired with no updates; ask again at once.
      continue
    fi
    sleep "$BACKOFF"
  done
}

release_cursor_lock() {
  fm_lock_release "$CURSOR_LOCK" 2>/dev/null || true
}

# The cursor is keyed on the operating-system user, not on one firstmate home,
# so the compare-and-commit runs under the shared lock helper: without it two
# concurrent acks can both read the old value and the later commit wins,
# rewinding the cursor and re-capturing already handled updates.
cmd_ack() {
  local id=${1:-} cursor dir tmp message
  case "$id" in
    ''|*[!0-9]*) die "ack needs a nonnegative integer update id: $id" ;;
  esac
  [ "${#id}" -le "$MAX_ID_DIGITS" ] || die "ack needs a nonnegative integer update id: $id"
  id=$((10#$id))
  dir=$(dirname "$CURSOR_FILE")
  [ -d "$dir" ] || mkdir -p "$dir" || die "cannot create the cursor directory: $dir"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$CURSOR_LOCK" || die "cannot lock the telegram cursor: $CURSOR_LOCK"
  trap release_cursor_lock EXIT
  trap 'release_cursor_lock; exit 1' HUP INT TERM
  cursor=$(read_cursor) || exit 1
  if [ "$id" -gt "$cursor" ]; then
    tmp=$(umask 077; mktemp "$dir/.telegram-cursor.new.XXXXXX") || die "cannot stage the cursor"
    { printf '%s\n' "$id" > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$CURSOR_FILE"; } \
      || { rm -f -- "$tmp"; die "cannot commit the cursor: $CURSOR_FILE"; }
    message="acked: $id"
  else
    message="already-acked: $id (cursor $cursor)"
  fi
  release_cursor_lock
  trap - EXIT HUP INT TERM
  printf '%s\n' "$message"
}

cmd_terminal() {
  # A message stream never self-terminates: no captured result, whatever its
  # bytes, may retire this source. Only an explicit operator retire ends it.
  exit 1
}

cmd_arm() {
  local id=${1:-telegram-captain}
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  [ -f "$TOKEN_FILE" ] || die "telegram token file is missing: $TOKEN_FILE (write the bot token there, one line, mode 0600)"
  "$SCRIPT_DIR/fm-procevent.sh" register telegram "$id" -- \
    "$SCRIPT_DIR/fm-procevent-telegram.sh" poll || exit 1
  printf 'armed: %s\n' "$id"
}

case "${1-}" in
  arm)      shift; [ "$#" -le 1 ] || usage; cmd_arm "$@" ;;
  poll)     shift; [ "$#" -eq 0 ] || usage; cmd_poll ;;
  ack)      shift; [ "$#" -eq 1 ] || usage; cmd_ack "$@" ;;
  terminal) shift; cmd_terminal ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
