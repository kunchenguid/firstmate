# shellcheck shell=bash
# Typed-decision provider code shared by every Firstmate caller that asks a
# model a constrained pick over predefined options.
# Usage: . bin/fm-decision-provider-lib.sh
#
# This file is the single owner of the provider plumbing: the opt-in gate that
# selects typesafe.ai, OpenRouter, a System One-compatible host, or OpenAI and
# its key, endpoint, and timeout; the never-send check over a final request
# body; and the one POST. bin/fm-dispatch-resolve.sh (crew dispatch rules) and
# bin/fm-best-practices.sh (best-practices adapter routing) build their own
# request and read their own answers, including any provider-specific request
# shape such as OpenAI's; everything between those two steps is here, so both
# callers send under one key-handling and withholding rule.
# docs/configuration.md "Typed dispatch resolution" owns the operator contract
# for the settings, the key handling, and the never-send list.
#
# Key handling: a caller's first statements, before any child process exists
# and so before it can even locate this file, copy TYPESAFE_API_KEY,
# OPENROUTER_API_KEY, OPENAI_API_KEY, and FM_DISPATCH_API_KEY into the
# non-exported TYPESAFE_API_KEY_PRIVATE, OPENROUTER_API_KEY_PRIVATE,
# OPENAI_API_KEY_PRIVATE, and DISPATCH_API_KEY_PRIVATE and unset the public
# names, so no child environment carries a key; this library reads only the
# private names, and the POST hands the selected key to curl through file
# descriptor 3, never argv.
#
# Requires fmx_env_get (bin/fm-env-lib.sh) and fm_timing_now_ms
# (bin/fm-timing-lib.sh) to be sourced by the caller.

FM_DECISION_TS_MODEL=jev-latest
FM_DECISION_TS_BASE=https://api.typesafe.ai
FM_DECISION_TS_TIMEOUT=5
FM_DECISION_OR_BASE=https://openrouter.ai/api
FM_DECISION_OR_TIMEOUT=10
FM_DECISION_SO_TIMEOUT=10
FM_DECISION_OA_BASE=https://api.openai.com
FM_DECISION_OA_TIMEOUT=10

# fm_decision_gate <label> <home>
# Resolve FM_DISPATCH_PROVIDER, FM_DISPATCH_MODEL, and FM_DISPATCH_BASE_URL
# from the environment or <home>/.env (environment wins) into
# FM_DECISION_PROVIDER, FM_DECISION_MODEL, FM_DECISION_ENDPOINT, and
# FM_DECISION_TIMEOUT, and the selected key into the non-exported
# FM_DECISION_KEY_PRIVATE, loading it from <home>/.env when the environment had
# none. Returns 0 when on; 1 when off, after printing one "<label>: off (...)"
# line on stderr; 2 on a configuration error, with the message in
# FM_DECISION_ERROR for the caller to report.
# shellcheck disable=SC2034  # FM_DECISION_* are this library's results for its caller
fm_decision_gate() {
  local label=$1 home=$2 base_url
  FM_DECISION_ERROR=
  FM_DECISION_PROVIDER=${FM_DISPATCH_PROVIDER:-}
  [ -n "$FM_DECISION_PROVIDER" ] || FM_DECISION_PROVIDER=$(fmx_env_get FM_DISPATCH_PROVIDER "$home/.env")
  FM_DECISION_MODEL=${FM_DISPATCH_MODEL:-}
  [ -n "$FM_DECISION_MODEL" ] || FM_DECISION_MODEL=$(fmx_env_get FM_DISPATCH_MODEL "$home/.env")
  case "$FM_DECISION_PROVIDER" in
    '' | typesafe)
      [ -n "$FM_DECISION_PROVIDER" ] || FM_DECISION_MODEL=$FM_DECISION_TS_MODEL
      FM_DECISION_PROVIDER=typesafe
      [ -n "$FM_DECISION_MODEL" ] || FM_DECISION_MODEL=$FM_DECISION_TS_MODEL
      [ -n "$TYPESAFE_API_KEY_PRIVATE" ] || TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$home/.env")
      if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
        echo "$label: off (TYPESAFE_API_KEY absent from the environment and $home/.env)" >&2
        return 1
      fi
      FM_DECISION_ENDPOINT=$FM_DECISION_TS_BASE/v1/systemone
      FM_DECISION_TIMEOUT=$FM_DECISION_TS_TIMEOUT
      FM_DECISION_KEY_PRIVATE=$TYPESAFE_API_KEY_PRIVATE
      ;;
    openrouter)
      if [ -z "$FM_DECISION_MODEL" ]; then
        FM_DECISION_ERROR="FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openrouter"
        return 2
      fi
      [ -n "$OPENROUTER_API_KEY_PRIVATE" ] || OPENROUTER_API_KEY_PRIVATE=$(fmx_env_get OPENROUTER_API_KEY "$home/.env")
      if [ -z "$OPENROUTER_API_KEY_PRIVATE" ]; then
        echo "$label: off (OPENROUTER_API_KEY absent from the environment and $home/.env)" >&2
        return 1
      fi
      FM_DECISION_ENDPOINT=$FM_DECISION_OR_BASE/alpha/decisions
      FM_DECISION_TIMEOUT=$FM_DECISION_OR_TIMEOUT
      FM_DECISION_KEY_PRIVATE=$OPENROUTER_API_KEY_PRIVATE
      ;;
    systemone)
      if [ -z "$FM_DECISION_MODEL" ]; then
        FM_DECISION_ERROR="FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=systemone"
        return 2
      fi
      base_url=${FM_DISPATCH_BASE_URL:-}
      [ -n "$base_url" ] || base_url=$(fmx_env_get FM_DISPATCH_BASE_URL "$home/.env")
      if [ -z "$base_url" ]; then
        FM_DECISION_ERROR="FM_DISPATCH_BASE_URL required when FM_DISPATCH_PROVIDER=systemone"
        return 2
      fi
      case "$base_url" in
        http://?* | https://?*) ;;
        *)
          FM_DECISION_ERROR="FM_DISPATCH_BASE_URL must start with http:// or https://"
          return 2
          ;;
      esac
      # The key is optional: a local host may need none.
      [ -n "$DISPATCH_API_KEY_PRIVATE" ] || DISPATCH_API_KEY_PRIVATE=$(fmx_env_get FM_DISPATCH_API_KEY "$home/.env")
      FM_DECISION_ENDPOINT=${base_url%/}/v1/systemone
      FM_DECISION_TIMEOUT=$FM_DECISION_SO_TIMEOUT
      FM_DECISION_KEY_PRIVATE=$DISPATCH_API_KEY_PRIVATE
      ;;
    openai)
      if [ -z "$FM_DECISION_MODEL" ]; then
        FM_DECISION_ERROR="FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openai"
        return 2
      fi
      [ -n "$OPENAI_API_KEY_PRIVATE" ] || OPENAI_API_KEY_PRIVATE=$(fmx_env_get OPENAI_API_KEY "$home/.env")
      if [ -z "$OPENAI_API_KEY_PRIVATE" ]; then
        echo "$label: off (OPENAI_API_KEY absent from the environment and $home/.env)" >&2
        return 1
      fi
      FM_DECISION_ENDPOINT=$FM_DECISION_OA_BASE/v1/decisions
      FM_DECISION_TIMEOUT=$FM_DECISION_OA_TIMEOUT
      FM_DECISION_KEY_PRIVATE=$OPENAI_API_KEY_PRIVATE
      ;;
    *)
      FM_DECISION_ERROR="unknown FM_DISPATCH_PROVIDER: $FM_DECISION_PROVIDER (expected typesafe, openrouter, systemone, or openai)"
      return 2
      ;;
  esac
  export -n FM_DECISION_KEY_PRIVATE 2>/dev/null || true
  return 0
}

# fm_decision_never_send <label> <subject> <body-json> <list-path> <scratch-file>
# Check the endpoint and every string of the final request body, including
# strings inside JSON text such as OpenAI's serialized input, against the
# optional never-send list before anything is sent. Each non-blank, non-# line
# is a literal matched case-insensitively, with surrounding whitespace trimmed
# and every run of whitespace, on both sides, treated as one space. Returns 0
# when the request may be sent; 1 after printing one
# "<label>: off (...; nothing sent)" line on stderr naming at most the list line
# number, never its value. <subject> names what matched, such as "brief text".
# grep's own stderr is discarded because it can echo the pattern.
fm_decision_never_send() {
  local label=$1 subject=$2 body=$3 list_path=$4 scratch=$5 list value n=0 rc
  [ -e "$list_path" ] || [ -L "$list_path" ] || return 0
  if ! { [ -f "$list_path" ] && [ -r "$list_path" ]; }; then
    echo "$label: off ($list_path is not a readable regular file; nothing sent)" >&2
    return 1
  fi
  if ! jq -r --arg endpoint "$FM_DECISION_ENDPOINT" '
      $endpoint, (.. | strings | ., (try (fromjson | .. | strings) catch empty))
      | gsub("\\s+"; " ")' <<<"$body" > "$scratch" 2>/dev/null; then
    echo "$label: off (could not extract the request text to check; nothing sent)" >&2
    return 1
  fi
  if ! list=$(jq -Rr 'gsub("\\s+"; " ")' "$list_path" 2>/dev/null); then
    echo "$label: off (could not read $list_path; nothing sent)" >&2
    return 1
  fi
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$scratch" 2>/dev/null; rc=$?
    case "$rc" in
      0) echo "$label: off ($subject matches $list_path line $n; nothing sent)" >&2; return 1 ;;
      1) ;;
      *) echo "$label: off (could not check the request text against $list_path line $n; nothing sent)" >&2; return 1 ;;
    esac
  done <<<"$list"
  return 0
}

# fm_decision_post <body-json> <response-file>
# Send the final request body to the endpoint fm_decision_gate selected and
# write the answer to <response-file>; with no key (a systemone host that needs
# none) the request carries no Authorization header. Sets FM_DECISION_HTTP (000
# when curl itself failed) and FM_DECISION_LAT_MS. Call it directly, never in a
# command substitution, so both values reach the caller.
# shellcheck disable=SC2034  # FM_DECISION_* are this library's results for its caller
fm_decision_post() {
  local body=$1 resp_file=$2 t0 t1
  t0=$(fm_timing_now_ms)
  if [ -n "$FM_DECISION_KEY_PRIVATE" ]; then
    FM_DECISION_HTTP=$(printf '%s' "$body" | curl -sS --max-time "$FM_DECISION_TIMEOUT" -o "$resp_file" -w '%{http_code}' \
      -X POST "$FM_DECISION_ENDPOINT" -H 'Content-Type: application/json' \
      -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$FM_DECISION_KEY_PRIVATE") \
      --data-binary @- 2>/dev/null) || FM_DECISION_HTTP=000
  else
    FM_DECISION_HTTP=$(printf '%s' "$body" | curl -sS --max-time "$FM_DECISION_TIMEOUT" -o "$resp_file" -w '%{http_code}' \
      -X POST "$FM_DECISION_ENDPOINT" -H 'Content-Type: application/json' \
      --data-binary @- 2>/dev/null) || FM_DECISION_HTTP=000
  fi
  t1=$(fm_timing_now_ms)
  FM_DECISION_LAT_MS=$(( t1 - t0 ))
}

# fm_decision_http_reason <response-file>
# The reason line for a non-200 answer: typesafe.ai's first 200 bytes are
# echoed, as the resolver has always reported them; no other provider's body is.
fm_decision_http_reason() {
  if [ "$FM_DECISION_PROVIDER" = typesafe ]; then
    printf 'http %s after %s ms: %s' "$FM_DECISION_HTTP" "$FM_DECISION_LAT_MS" "$(head -c 200 "$1" 2>/dev/null | tr '\n' ' ')"
  else
    printf 'http %s after %s ms' "$FM_DECISION_HTTP" "$FM_DECISION_LAT_MS"
  fi
}
