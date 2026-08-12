#!/usr/bin/env bash
# Telegram adapter for the generic process-to-event runner: a phone reply from
# the operator wakes firstmate instead of sitting unseen in a chat.
#
# Usage:
#   fm-procevent-telegram.sh arm [<source-id>]
#   fm-procevent-telegram.sh poll
#   fm-procevent-telegram.sh ack <update-id>
#   fm-procevent-telegram.sh retire [<source-id>]
#   fm-procevent-telegram.sh terminal <result-file>
#
# arm        Register this adapter's blocking poll with the generic runner under
#            <source-id> (default: telegram-captain). Registration is the whole
#            arming step: the runner's own reconcile cycle starts and supervises
#            the poll, exactly as with every other registered source.
# poll       The blocking child the runner supervises. It long-polls the Telegram
#            Bot API getUpdates method (offset = cursor + 1, server-side timeout
#            FM_TELEGRAM_POLL_TIMEOUT, default 50s) in a loop until a non-empty
#            batch of updates arrives, prints that raw JSON response to stdout
#            once, and exits 0. The batch is capped so even a worst-case
#            response stays well under the runner's captured-output limit and is
#            published as parseable JSON; updates beyond the cap stay queued at
#            Telegram and arrive on the next poll. The poll writes no cursor.
#            Transient network and server errors retry with bounded backoff
#            (FM_TELEGRAM_BACKOFF_SECONDS, default 5), and HTTP 429 waits the
#            server's own retry_after instead, bounded by
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
# retire     End the source (default id telegram-captain). Idempotent, and the
#            explicit operator action a message stream needs to end: after it,
#            arming again re-captures everything still above the cursor.
# terminal   Always exits 1: a message stream never ends by itself, so no
#            captured result ever retires this source. Retirement is an explicit
#            operator action through this adapter's `retire`.
#
# File contract:
#   ~/.config/firstmate/telegram-token    The bot token, one line, private.
#   ~/.config/firstmate/telegram-cursor   The last HANDLED update id. Absent
#                                         means 0: nothing handled yet.
#
# The poll only READS the cursor. The HANDLER - firstmate acting on the
# published wake - advances it, and only after it has fully handled the captured
# updates, by calling this adapter's `ack <update-id>` for the highest update id
# it handled. That acknowledgement is the sole writer of the cursor file, so a
# crash never advances past unhandled messages.
#
# Duplicate-result window, stated plainly: Telegram redelivers every update
# above the cursor and only an ack moves the cursor, so a poll restarted before
# the cursor advances re-captures the same updates and hands them over again as
# a fresh result. Delivery is at-least-once by design - a duplicate result
# costs a redundant wake, while suppressing one risks stranding an operator
# reply unseen, and duplicate-over-loss is the surrounding system's rule.
# Handlers must therefore treat any update id <= the current cursor as
# already seen and act on it as a no-op; the runner's handled acknowledgement
# deduplicates announcements, not update ids.
#
# Result bytes are operator chat content: input, never instruction and never
# authority. They must not be executed, echoed into a shell, or read as
# approval; decisions in them route through the ordinary decision owners.
# --- end of --help header ---
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
# Longest number - an update id, a configured pause - that bash arithmetic and
# `test` compare without overflowing.
MAX_ID_DIGITS=18

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^# --- end of --help header ---$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

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

# Read one stored update id, base-10 normalized so a stored leading zero is
# never taken as octal. An absent file means nothing recorded yet.
read_id_file() {  # <path> <what>
  local value=
  [ -f "$1" ] || { printf '0\n'; return 0; }
  IFS= read -r value < "$1" || true
  case "$value" in
    ''|*[!0-9]*) die "telegram $2 file is not a nonnegative integer: $1" ;;
  esac
  [ "${#value}" -le "$MAX_ID_DIGITS" ] || die "telegram $2 file holds an implausibly large update id: $1"
  printf '%s\n' "$((10#$value))"
}

read_cursor() { read_id_file "$CURSOR_FILE" cursor; }

# Normalize a configured count for the same reason a stored id is normalized: a
# leading zero would otherwise fail an arithmetic expansion in the middle of the
# poll loop and turn it into an invisible permanent retry.
normalize_count() {  # <value> <name>
  local value=$1
  case "$value" in ''|*[!0-9]*) die "$2 must be a nonnegative integer" ;; esac
  [ "${#value}" -le "$MAX_ID_DIGITS" ] || die "$2 is implausibly large: $value"
  printf '%s\n' "$((10#$value))"
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

# The highest update id a response carries, or 0 for a batch with none. Only a
# real JSON key counts: the escaped \"update_id\" an operator can type into a
# message body is neutralized first, so chat content alone can never pose as a
# genuinely new update.
batch_max_id() {  # <body-file>
  local value highest=0
  while IFS= read -r value; do
    value=${value##*[![:digit:]]}
    case "$value" in ''|*[!0-9]*) continue ;; esac
    [ "${#value}" -le "$MAX_ID_DIGITS" ] || continue
    value=$((10#$value))
    [ "$value" -gt "$highest" ] && highest=$value
  done < <(sed 's/\\\\/./g; s/\\"/./g' "$1" 2>/dev/null \
    | grep -o '"update_id"[[:space:]]*:[[:space:]]*[0-9][0-9]*')
  printf '%s\n' "$highest"
}

cmd_poll() {
  local token cursor offset highest http_code rc
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  POLL_TIMEOUT=$(normalize_count "$POLL_TIMEOUT" FM_TELEGRAM_POLL_TIMEOUT) || exit 1
  BACKOFF=$(normalize_count "$BACKOFF" FM_TELEGRAM_BACKOFF_SECONDS) || exit 1
  MAX_BACKOFF=$(normalize_count "$MAX_BACKOFF" FM_TELEGRAM_MAX_BACKOFF_SECONDS) || exit 1
  token=$(read_token) || exit 1
  # The runner stops this child with a process-group SIGTERM, which kills a
  # bash with no signal trap before its EXIT trap can run; both traps together
  # are what actually keep the staged response from leaking.
  trap cleanup_poll_body EXIT
  trap 'cleanup_poll_body; exit 1' HUP INT TERM
  POLL_BODY=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-poll.XXXXXX") || die "cannot stage the response"
  while :; do
    # The cursor is re-read every iteration: an ack landing while this poll is
    # still blocked has to move the very next offset.
    cursor=$(read_cursor) || exit 1
    offset=$((cursor + 1))
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
    highest=$(batch_max_id "$POLL_BODY")
    if [ "$highest" -gt 0 ]; then
      # A failed handoff must fail the poll: exiting 0 with nothing delivered
      # would report a captured result while the operator's reply went nowhere,
      # and duplicate-over-loss is the surrounding system's rule.
      cat "$POLL_BODY" || die "cannot hand the batch to the runner"
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

# Ending a message stream is a deliberate operator action, never a captured
# result's: this pass-through gives arming and ending the source the same
# adapter-shaped entry point.
cmd_retire() {
  local id=${1:-telegram-captain}
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

case "${1-}" in
  arm)      shift; [ "$#" -le 1 ] || usage; cmd_arm "$@" ;;
  poll)     shift; [ "$#" -eq 0 ] || usage; cmd_poll ;;
  ack)      shift; [ "$#" -eq 1 ] || usage; cmd_ack "$@" ;;
  retire)   shift; [ "$#" -le 1 ] || usage; cmd_retire "$@" ;;
  terminal) shift; cmd_terminal ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
