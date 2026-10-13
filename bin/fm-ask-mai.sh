#!/usr/bin/env bash
# fm-ask-mai.sh - one-shot MAI-Pro call for firstmate mechanical routing.
#
# Returns ONLY the model's answer text on stdout (no reasoning, no headers).
# Fails CLOSED: non-zero exit on transport/timeout/HTTP-error/empty/truncated
# answer so the caller (firstmate) escalates on its own thread rather than
# trusting a silent stub. Escalation never routes to another gateway model:
# the model is fixed to marutai/MAI-Pro and is not selectable by argument or
# environment - any extra argument or a set FM_MAI_MODEL is a usage error.
#
# Usage:  fm-ask-mai.sh <prompt> [max_tokens]
# Env:    F2_GATEWAY_TOKEN_CMD   helper printing a fresh bearer (default ~/bin/f2-gateway-token)
#         F2_GATEWAY_URL         inference host (default https://stageapi.marut.cloud/api/v1/gateway/v1)
#         FM_MAI_TIMEOUT_SECS    request cap per attempt (default 180)
#         FM_MAI_RETRIES         attempts total (default 3 - 503 saturation is retry-able)
#         FM_MAI_RETRY_DELAY_SECS  base backoff between attempts (default 5, doubles)
#
# Exit codes: 2 usage/no token, 3 transport or HTTP error after retry,
# 4 empty/null content, 5 finish_reason=length or content_filter.
set -euo pipefail

die() { printf 'fm-ask-mai: %s: %s\n' "$1" "$2" >&2; exit "$3"; }

[ "${1-}" = "--help" ] && { sed -n '2,18p' "$0"; exit 0; }
[ -z "${FM_MAI_MODEL:-}" ] || die usage "FM_MAI_MODEL may not select a model; only marutai/MAI-Pro is served" 2
[ $# -le 2 ] || die usage "model is not selectable; only marutai/MAI-Pro is served" 2

prompt=$1
max=${2:-512}
model=marutai/MAI-Pro
cmd=${F2_GATEWAY_TOKEN_CMD:-$HOME/bin/f2-gateway-token}
url=${F2_GATEWAY_URL:-https://stageapi.marut.cloud/api/v1/gateway/v1}
timeout=${FM_MAI_TIMEOUT_SECS:-180}
retries=${FM_MAI_RETRIES:-3}
delay=${FM_MAI_RETRY_DELAY_SECS:-5}

token=$("$cmd") || die auth "no token from $cmd" 2
body=$(jq -nc --arg m "$model" --arg p "$prompt" --argjson k "$max" \
  '{model:$m,messages:[{role:"user",content:$p}],max_tokens:$k,temperature:0,reasoning_effort:"low"}')

# Bounded retry: the stage gateway's 503 "Database session capacity is
# temporarily saturated" clears in seconds; one attempt is not a fair test of
# the backend, but unbounded retry wedges a routing decision. Retries apply to
# transport and HTTP failures only - a structured empty or truncated answer is
# a definitive model verdict for that prompt, ending the call immediately.
attempt=1
while :; do
  raw=$(mktemp "${TMPDIR:-/tmp}/fm-ask-mai.XXXXXX")
  http_code=$(curl -sS --max-time "$timeout" -o "$raw" -w '%{http_code}' \
    -X POST "$url/chat/completions" \
    -H "Authorization: Bearer $token" -H "content-type: application/json" \
    -d "$body" 2>&1) || { curl_err=$http_code
      rm -f "$raw"
      http_code=000
      cause=${curl_err##*curl: }
      cause=${cause%%$'\n'*}
      if [ "$attempt" -lt "$retries" ]; then
        sleep "$delay"; delay=$((delay * 2)); attempt=$((attempt + 1)); continue
      fi
      die transport "$cause" 3
    }

  # HTTP error: surface the gateway's own cause fragment, never the body bytes.
  if [ "$http_code" != 200 ]; then
    cause=$(jq -r '.error.message? // .message? // empty' "$raw" 2>/dev/null || true)
    [ -n "$cause" ] || cause="status $http_code"
    rm -f "$raw"
    if [ "$attempt" -lt "$retries" ]; then
      sleep "$delay"; delay=$((delay * 2)); attempt=$((attempt + 1)); continue
    fi
    die transport "$cause" 3
  fi

  text=$(jq -r '.choices[0].message.content // empty' <"$raw")
  finish=$(jq -r '.choices[0].finish_reason // empty' <"$raw")
  rm -f "$raw"
  case "$finish" in
    length|content_filter) die "$finish" "answer truncated or filtered" 5 ;;
  esac
  [ -n "$text" ] || die empty "no content in answer (finish=${finish:-none})" 4
  printf '%s\n' "$text"
  exit 0
done
