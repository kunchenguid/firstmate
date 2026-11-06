#!/usr/bin/env bash
# fm-search.sh - you.com web search for firstmate.
#
# THE PROBLEM THIS SOLVES: firstmate needs current public facts (pricing, docs,
# APIs, news) without inventing them from memory. Tavily was the prior tool;
# its key is absent in this home, so you.com is now the search path.
#
# Intentionally single-vendor for now: this hard-embeds you.com's endpoint,
# auth, and response shape rather than a provider-adapter abstraction, since
# no such adapter pattern exists elsewhere in this repo (bin/backends/ is
# runtime spawn backends, unrelated) and a two-line key-source swap does not
# by itself justify inventing one. Revisit if a second search provider shows
# up.
#
# API: you.com Web Search API, https://api.you.com/v1/search
#   - GET works and is used here (extraction is POST-only and not implemented).
#   - Auth: X-API-Key header. Key sources, first match wins:
#       1. $YOUCOM_API_KEY
#       2. ~/.pi/agent/youcom.key (mode 600; one key on one line)
#   - Results: results.web[] with url/title/description/snippets[].
#   - Pricing: $5.00 per 1,000 calls (up to 100 results). See you.com/docs.
#
# OUTPUT: one block per result, Markdown-friendly:
#   ## <title>
#   <url>
#   <description>
#   <snippet>
#   <snippet>
# Blank line between results. --json prints the raw API response instead.
#
# Usage:
#   fm-search.sh "<query>" [--count N] [--json] [--freshness day|week|month|year]
#       Query is required. --count default 5 (max 100).
#       --freshness filters by recency (day/week/month/year).
set -u

usage() {
  cat <<'EOF'
usage: fm-search.sh "<query>" [--count N] [--freshness day|week|month|year] [--json]
  Query is required. Results print as Markdown blocks; --json prints raw JSON.
  Key: $YOUCOM_API_KEY or ~/.pi/agent/youcom.key (mode 600).
EOF
}

COUNT=5
FRESHNESS=""
JSON_OUT=0
QUERY=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --count) COUNT="${2:-}"; shift 2 ;;
    --freshness) FRESHNESS="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    -*) echo "fm-search: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) QUERY="$1"; shift ;;
  esac
done

[ -n "$QUERY" ] || { usage >&2; exit 2; }
case "$COUNT" in
  ''|*[!0-9]*) echo "fm-search: --count must be a number" >&2; exit 2 ;;
esac
[ "$COUNT" -ge 1 ] && [ "$COUNT" -le 100 ] || { echo "fm-search: --count must be 1-100" >&2; exit 2; }
case "$FRESHNESS" in
  ""|day|week|month|year) ;;
  *) echo "fm-search: --freshness must be day|week|month|year" >&2; exit 2 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "fm-search: curl not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "fm-search: jq not found" >&2; exit 1; }

KEY="${YOUCOM_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$HOME/.pi/agent/youcom.key" ]; then
  KEY="$(tr -d ' \n' < "$HOME/.pi/agent/youcom.key")"
fi
[ -n "$KEY" ] || { echo "fm-search: no API key (set YOUCOM_API_KEY or ~/.pi/agent/youcom.key)" >&2; exit 1; }

URL="https://api.you.com/v1/search?query=$(printf '%s' "$QUERY" | jq -sRr @uri)&count=$COUNT"
[ -n "$FRESHNESS" ] && URL="$URL&freshness=$FRESHNESS"

RESPONSE="$(curl -sS -m 30 "$URL" -H "X-API-Key: $KEY" -H "Accept: application/json" 2>/dev/null)"
CURL_RC=$?
if [ $CURL_RC -ne 0 ]; then
  echo "fm-search: curl failed (rc=$CURL_RC)" >&2
  exit 1
fi

if [ "$JSON_OUT" -eq 1 ]; then
  printf '%s\n' "$RESPONSE"
  exit 0
fi

ERROR="$(printf '%s' "$RESPONSE" | jq -r '.error // ""' 2>/dev/null)"
if [ -n "$ERROR" ]; then
  echo "fm-search: API error: $ERROR" >&2
  exit 1
fi

printf '%s' "$RESPONSE" | jq -r '
  .results.web[]? |
  "## \(.title)\n\(.url)\n\(.description // "")\n" +
  ([.snippets[]? | "> \(.)"] | join("\n"))
' 2>/dev/null || { echo "fm-search: could not parse response" >&2; exit 1; }
