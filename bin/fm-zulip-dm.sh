#!/usr/bin/env bash
# fm-zulip-dm.sh — send a private Zulip DM from abiba-bot to the captain.
#
# WHY: the captain's standing rule (2026-08-02/04/06, 2026-10-11) is that any
# decision or attention-worthy item is delivered to his Zulip DM, because the
# terminal scrolls past. Without a helper every caller re-derives the endpoint,
# the user id and the key location, and the rule silently fails to happen.
#
# The credential is NEVER printed, never hardcoded, and never passed in argv:
# it is read from ZULIP_API_KEY, then the Infisical vault, then the local
# extension .env, and handed to curl through a mode-600 config file.
#
# Usage:
#   fm-zulip-dm.sh [--to <user-id|email>] [--dry-run] --text <message>
#   fm-zulip-dm.sh [--to <id>] <body-file>
#   printf '...' | fm-zulip-dm.sh [--to <id>] -
#
# Exit: 0 sent · 2 usage · 3 no credential · 4 API refused · 5 transport
set -uo pipefail

SITE="${ZULIP_SITE:-https://chat.sysloggh.net}"
SENDER="${ZULIP_USER:-abiba-bot@chat.sysloggh.net}"
TO="9"
DRY=0
BODY=""
HAVE_BODY=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --to)      TO="${2:?--to needs a recipient}"; shift 2 ;;
    --text)    BODY="${2-}"; HAVE_BODY=1; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -)         BODY="$(cat)"; HAVE_BODY=1; shift ;;
    --)        shift; break ;;
    -*)        echo "fm-zulip-dm: unknown option $1" >&2; exit 2 ;;
    *)         BODY="$(cat -- "$1" 2>/dev/null)" || { echo "fm-zulip-dm: cannot read $1" >&2; exit 2; }
               HAVE_BODY=1; shift ;;
  esac
done

[ "$HAVE_BODY" = 1 ] || { echo "fm-zulip-dm: no message body (use --text, a file, or -)" >&2; exit 2; }
[ -n "${BODY//[[:space:]]/}" ] || { echo "fm-zulip-dm: refusing to send an empty message" >&2; exit 2; }

resolve_key() {
  if [ -n "${ZULIP_API_KEY:-}" ]; then printf '%s' "$ZULIP_API_KEY"; return 0; fi
  if command -v infisical >/dev/null 2>&1; then
    local k
    k=$(timeout 25 infisical secrets get ABIBA_ZULIP_API_KEY --plain \
        --domain "${INFISICAL_DOMAIN:-https://vault.sysloggh.net}" \
        --projectId="${INFISICAL_PROJECT_ID:-322fceab-39da-4854-a55a-568e76c0f13f}" \
        --env=prod --token "$(cat "${INFISICAL_TOKEN_FILE:-/root/.infisical-token}" 2>/dev/null)" 2>/dev/null)
    [ -n "$k" ] && { printf '%s' "$k"; return 0; }
  fi
  local f="${ZULIP_ENV_FILE:-/root/.pi/agent/extensions/zulip/.env}" k
  if [ -r "$f" ]; then
    k=$(sed -nE "s/^[[:space:]]*ABIBA_ZULIP_API_KEY[[:space:]]*=[[:space:]]*//p" "$f" | tail -1 | sed -E "s/^[\"']//; s/[\"'][[:space:]]*$//")
    [ -n "$k" ] && { printf '%s' "$k"; return 0; }
  fi
  return 1
}

KEY="$(resolve_key)" || { echo "fm-zulip-dm: no Zulip credential (ZULIP_API_KEY, vault ABIBA_ZULIP_API_KEY, or $ZULIP_ENV_FILE)" >&2; exit 3; }

# Recipient: numeric id -> [id]; email -> ["email"]
case "$TO" in
  *[!0-9]*) TO_JSON="[\"$TO\"]" ;;
  *)        TO_JSON="[$TO]" ;;
esac

if [ "$DRY" = 1 ]; then
  echo "fm-zulip-dm: dry-run ok — credential resolved, ${#BODY} bytes to $TO_JSON (nothing sent)" >&2
  exit 0
fi

umask 077
cf=$(mktemp); bf=$(mktemp)
cleanup() { rm -f "$cf" "$bf"; }
trap cleanup EXIT

printf 'user = "%s:%s"\n' "$SENDER" "$KEY" > "$cf"
printf '%s' "$BODY" > "$bf"

resp=$(curl -sS --max-time 25 -K "$cf" -X POST "${SITE}/api/v1/messages" \
  -w '\n%{http_code}' \
  --data-urlencode "type=private" \
  --data-urlencode "to=${TO_JSON}" \
  --data-urlencode "content@${bf}" 2>&1) || { echo "fm-zulip-dm: transport error" >&2; exit 5; }

http_code=${resp##*$'\n'}
body=${resp%$'\n'*}

if [ "$http_code" != "200" ]; then
  echo "fm-zulip-dm: API refused (HTTP ${http_code}) — ${body:0:200}" >&2
  exit 4
fi

# HTTP 200 means the message was accepted. If the body is unparseable we must NOT
# report failure: a caller would retry and duplicate the DM (this happened once).
out=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("UNPARSEABLE"); sys.exit(0)
if d.get("result") != "success":
    print("REFUSED:" + str(d.get("msg", "")))
else:
    print(str(d.get("id", "")))
' 2>/dev/null) || out="UNPARSEABLE"

case "$out" in
  REFUSED:*)  echo "fm-zulip-dm: API refused — ${out#REFUSED:}" >&2; exit 4 ;;
  UNPARSEABLE) echo "fm-zulip-dm: HTTP 200 but unparseable response — treated as SENT (verify in Zulip)" >&2; exit 0 ;;
  "")         echo "fm-zulip-dm: HTTP 200 but no message id — treated as SENT" >&2; exit 0 ;;
  *)          echo "fm-zulip-dm: sent (message id ${out}) to ${TO_JSON}" >&2; printf '%s\n' "$out"; exit 0 ;;
esac
