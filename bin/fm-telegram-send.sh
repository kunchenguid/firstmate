#!/usr/bin/env bash
# Post one outbound Telegram message to the configured private chat via Bot API
# sendMessage. Opt-in and inert unless FM_TELEGRAM_BOT_TOKEN and
# FM_TELEGRAM_CHAT_ID are set (see docs/telegram-mode.md).
#
# Usage:
#   fm-telegram-send.sh --text-file <path>
#   fm-telegram-send.sh -                 # read text from stdin
#   fm-telegram-send.sh --text-file <path> --reply   # always send (command reply)
#   fm-telegram-send.sh --text-file <path> --force   # ignore AFK-only gate
#
# Exit codes:
#   0 success (or dry-run recorded, or deliberate skip)
#   1 usage / missing text
#   2 mode off / kill switch / secretish refuse
#   3 transport / API failure
#   4 confirmed delivery with a non-retryable merge-authority persistence warning
#
# AFK-only outbound (default): routine notifications send only while state/.afk
# exists, unless --reply/--force or FM_TELEGRAM_ALWAYS_NOTIFY is set. Command
# replies always use --reply so inbound acknowledgements still reach the phone.
# Secrets and credential-looking text are refused (desk-only). Full GitHub PR
# URLs in successful sends are recorded for Stage-2 merge authority.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-telegram-send.sh --text-file <path> | -
       fm-telegram-send.sh --text-file <path> --reply
       fm-telegram-send.sh --text-file <path> --force

Send one message to the configured Telegram chat. Inert when Telegram mode is
off. --reply / --force bypass the AFK-only outbound gate (command replies and
explicit always-send). Dry-run (FM_TELEGRAM_DRY_RUN) records to
state/telegram-outbox/ without posting.
Exit 4 means Telegram confirmed delivery but merge-authority persistence needs
attention; callers must not retry the send.
EOF
}

TEXT_FILE=
TEXT_STDIN=0
FORCE=0
REPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file)
      [ "$#" -gt 1 ] || { usage >&2; exit 1; }
      TEXT_FILE=$2
      shift 2
      ;;
    -)
      TEXT_STDIN=1
      shift
      ;;
    --reply)
      REPLY=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$TEXT_STDIN" -eq 1 ] && [ -n "$TEXT_FILE" ]; then
  echo "error: pass either --text-file or -, not both" >&2
  exit 1
fi
if [ "$TEXT_STDIN" -eq 0 ] && [ -z "$TEXT_FILE" ]; then
  usage >&2
  exit 1
fi

fmt_load_config
if ! fmt_mode_enabled; then
  fmt_audit_append outbound skipped "mode-off"
  exit 2
fi

TEXT=
if [ "$TEXT_STDIN" -eq 1 ]; then
  TEXT=$(cat) || true
else
  [ -f "$TEXT_FILE" ] || { echo "error: text file not found: $TEXT_FILE" >&2; exit 1; }
  TEXT=$(cat -- "$TEXT_FILE") || true
fi

# Reject empty / whitespace-only bodies.
trimmed=$(printf '%s' "$TEXT" | tr -d '[:space:]')
if [ -z "$trimmed" ]; then
  echo "error: empty message" >&2
  exit 1
fi

# Telegram hard limit is 4096 characters. jq --rawfile counts and slices whole
# codepoints regardless of locale, so multibyte UTF-8 is never split (jq's raw
# stdin reader can corrupt characters on its internal buffer boundaries).
if [ "${#TEXT}" -gt 4096 ]; then
  command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }
  TRUNC_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-trunc.XXXXXX") \
    || { echo "error: cannot truncate message" >&2; exit 3; }
  printf '%s' "$TEXT" > "$TRUNC_FILE"
  TEXT=$(jq -rn --rawfile text "$TRUNC_FILE" \
    '$text | if length > 4096 then .[:4093] + "..." else . end') \
    || { rm -f "$TRUNC_FILE"; echo "error: cannot truncate message" >&2; exit 3; }
  rm -f "$TRUNC_FILE"
fi

if fmt_secretish "$TEXT"; then
  fmt_audit_append outbound refused "secretish"
  echo "error: message looks like it contains secrets; refused (desk-only)" >&2
  exit 2
fi

# AFK-only gate for routine notifications.
if [ "$FORCE" -eq 0 ] && [ "$REPLY" -eq 0 ] && [ -z "${FMT_ALWAYS_NOTIFY:-}" ]; then
  if ! fmt_afk_active; then
    fmt_audit_append outbound skipped "not-afk"
    # Silent success: not an error when the captain is at the desk.
    exit 0
  fi
fi

# Dry-run preview.
if [ -n "${FMT_DRY:-}" ]; then
  now=$(date +%s 2>/dev/null || echo 0)
  base="send-$now-$$"
  payload=$(jq -cn --arg text "$TEXT" --arg chat "$FMT_CHAT_ID" --arg ts "$now" \
    '{endpoint:"sendMessage",chat_id:$chat,text:$text,recorded_at:($ts|tonumber)}' 2>/dev/null) \
    || { echo "error: jq required for dry-run" >&2; exit 1; }
  printf '%s\n' "$payload" | fmx_private_artifact_publish_stdin "$STATE/telegram-outbox" "$base.json" 600 \
    || { echo "error: cannot write dry-run outbox" >&2; exit 1; }
  first=$(printf '%s\n' "$TEXT" | head -n1)
  fmt_audit_append outbound dry-run "$first"
  printf 'DRY RUN telegram send recorded: %s\n' "$STATE/telegram-outbox/$base.json" >&2
  exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "error: curl required" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-send.XXXXXX") || exit 3
PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-send-payload.XXXXXX") || { rm -f "$BODY_FILE"; exit 3; }
trap 'rm -f "$BODY_FILE" "$PAYLOAD_FILE"' EXIT

if ! jq -cn --arg text "$TEXT" --arg chat "$FMT_CHAT_ID" \
  '{chat_id:$chat,text:$text,disable_web_page_preview:true}' > "$PAYLOAD_FILE" 2>/dev/null; then
  echo "error: cannot build payload" >&2
  exit 3
fi

url="$FMT_API/bot${FMT_TOKEN}/sendMessage"
URL_FILE=$(fmt_curl_url_config "$url") || { echo "error: cannot prepare request" >&2; exit 3; }
trap 'rm -f "$BODY_FILE" "$PAYLOAD_FILE" "$URL_FILE"' EXIT
code=$(curl -m 10 -s -o "$BODY_FILE" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-binary @"$PAYLOAD_FILE" \
  --config "$URL_FILE" 2>/dev/null) || code=000

case "$code" in
  2[0-9][0-9])
    ok=$(jq -r '.ok // false' "$BODY_FILE" 2>/dev/null) || ok=false
    if [ "$ok" != true ] && [ "$ok" != "true" ]; then
      fmt_audit_append outbound failed "api-ok-false http=$code"
      echo "error: telegram API returned ok=false (HTTP $code)" >&2
      exit 3
    fi
    first=$(printf '%s\n' "$TEXT" | head -n1)
    fmt_audit_append outbound sent "$first"
    authority_recovered=0
    authority_ordinal=0
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      authority_ordinal=$((authority_ordinal + 1))
      if ! fmt_notified_pr_record "$pr"; then
        if fmt_notified_pr_recovery_record "$pr" "$authority_ordinal"; then
          authority_recovered=1
          fmt_audit_append outbound authority-recovered "url=$pr"
        else
          fmt_audit_append outbound authority-missing "authority-record-failed url=$pr"
          echo "error: Telegram received the message, but merge authority could not be recorded for $pr" >&2
          exit 4
        fi
      fi
    done <<EOF
$(fmt_extract_pr_urls "$TEXT")
EOF
    if [ "$authority_recovered" -eq 1 ]; then
      echo "warning: Telegram received the message; merge authority was preserved in recovery storage" >&2
      exit 4
    fi
    exit 0
    ;;
  *)
    fmt_audit_append outbound failed "http=$code"
    echo "error: telegram sendMessage HTTP $code" >&2
    exit 3
    ;;
esac
