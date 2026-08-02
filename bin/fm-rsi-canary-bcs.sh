#!/usr/bin/env bash
# Verify a BCS production candidate with a positive versioned canary and a
# negative regression canary.
#
# Usage: fm-rsi-canary-bcs.sh --candidate-sha <full-sha> --positive <immutable-marker> [--url <url>]
#        [--negative-regex <regex>] [--attempts <positive-integer>]
#        [--retry-seconds <non-negative-integer>]
#
# Emits one JSON observation. The caller supplies a marker unique to the frozen
# candidate SHA; the script never turns a timeout or failed observation into a
# merge or rollback decision.
set -euo pipefail

usage() {
  sed -n '2,11{s/^# \{0,1\}//;p;}' "$0"
}

url=https://belcantoviolinstudio.live/dashboard/
positive=
candidate_sha=
negative_regex='gtag|googletagmanager'
attempts=${FM_RSI_CANARY_ATTEMPTS:-3}
retry_seconds=${FM_RSI_CANARY_RETRY_SECONDS:-5}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) url=${2:?--url requires a value}; shift 2 ;;
    --candidate-sha) candidate_sha=${2:?--candidate-sha requires a value}; shift 2 ;;
    --positive) positive=${2:?--positive requires a value}; shift 2 ;;
    --negative-regex) negative_regex=${2:?--negative-regex requires a value}; shift 2 ;;
    --attempts) attempts=${2:?--attempts requires a value}; shift 2 ;;
    --retry-seconds) retry_seconds=${2:?--retry-seconds requires a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-rsi-canary-bcs: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$positive" ] || {
  printf 'fm-rsi-canary-bcs: --positive is required\n' >&2
  exit 2
}
[ -n "$candidate_sha" ] || {
  printf 'fm-rsi-canary-bcs: --candidate-sha is required\n' >&2
  exit 2
}
case "$candidate_sha" in
  *[!0123456789abcdef]*|'') printf 'fm-rsi-canary-bcs: candidate SHA must be lowercase hexadecimal\n' >&2; exit 2 ;;
esac
[ "${#candidate_sha}" -ge 40 ] && [ "${#candidate_sha}" -le 64 ] || {
  printf 'fm-rsi-canary-bcs: candidate SHA must be 40 to 64 characters\n' >&2
  exit 2
}
case "$attempts" in
  ''|*[!0-9]*) printf 'fm-rsi-canary-bcs: attempts must be a positive integer\n' >&2; exit 2 ;;
esac
[ "$attempts" -gt 0 ] || { printf 'fm-rsi-canary-bcs: attempts must be a positive integer\n' >&2; exit 2; }
case "$retry_seconds" in
  ''|*[!0-9]*) printf 'fm-rsi-canary-bcs: retry seconds must be a non-negative integer\n' >&2; exit 2 ;;
esac

body=$(mktemp "${TMPDIR:-/tmp}/fm-rsi-canary-bcs.XXXXXX")
trap 'rm -f "$body"' EXIT HUP INT TERM

http=000
positive_found=false
negative_clear=false
attempt=1
while [ "$attempt" -le "$attempts" ]; do
  : > "$body"
  if ! http=$(curl -sS -o "$body" -w '%{http_code}' --max-time 25 "$url" 2>/dev/null); then
    http=000
  fi
  positive_found=false
  negative_clear=false
  if [ "$http" = 200 ] && grep -F -q -- "$positive" "$body" && ! grep -E -i -q -- "$negative_regex" "$body"; then
    positive_found=true
    negative_clear=true
    break
  fi
  if grep -F -q -- "$positive" "$body"; then
    positive_found=true
  fi
  if ! grep -E -i -q -- "$negative_regex" "$body"; then
    negative_clear=true
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -le "$attempts" ] && [ "$retry_seconds" -gt 0 ]; then
    sleep "$retry_seconds"
  fi
done

if [ "$http" = 200 ] && [ "$positive_found" = true ] && [ "$negative_clear" = true ]; then
  result=ok
else
  result=fail
fi
observations=$attempt
if [ "$observations" -gt "$attempts" ]; then
  observations=$attempts
fi

jq -cn \
  --arg url "$url" \
  --arg candidate_sha "$candidate_sha" \
  --arg marker "$positive" \
  --arg negative_regex "$negative_regex" \
  --arg http "$http" \
  --argjson attempts "$observations" \
  --argjson positive_found "$positive_found" \
  --argjson negative_clear "$negative_clear" \
  --arg result "$result" \
  '{url: $url, candidate_sha: $candidate_sha, positive_marker: $marker, negative_regex: $negative_regex, http: $http, attempts: $attempts, positive_found: $positive_found, negative_clear: $negative_clear, result: $result}'

[ "$result" = ok ]
