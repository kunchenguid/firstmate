# shellcheck shell=bash
# Shared TypeSafe Jev caller for Firstmate shadow features.
# Usage: . bin/fm-jev-lib.sh
#
# This file is the single owner of how Firstmate talks to TypeSafe Jev. Feature
# tasks source it and call the helpers below; they do not roll their own HTTP
# client. It is a sourceable library, not a user CLI: executing it prints a
# one-line usage hint and exits 2.
#
# Dual route (resolved at each fm_jev_decide call):
#   - TypeSafe POST https://api.typesafe.ai/v1/systemone with TYPESAFE_API_KEY,
#     model jev-latest unless JEV_MODEL is set.
#   - OpenRouter POST https://openrouter.ai/api/alpha/decisions with
#     OPENROUTER_API_KEY, model typesafe/jev-1.13 unless JEV_MODEL is set.
#   JEV_ROUTE=openrouter selects OpenRouter even when a TypeSafe key is also
#   present. JEV_ROUTE=typesafe requires a TypeSafe key. With JEV_ROUTE unset,
#   a TypeSafe key wins; otherwise a present OpenRouter key is used. Each key
#   is taken from the process environment first, else from $FM_HOME/.env via
#   fmx_env_get (bin/fm-env-lib.sh); the environment wins.
#
# Key handling matches bin/fm-dispatch-resolve.sh: the chosen secret lives in a
# function-local non-exported variable and reaches curl only as an
# Authorization header read from a file descriptor, never on argv. Curl runs
# in a subshell with the API-key names unset so the secret is absent from the
# child environment. Nothing prints, logs, or writes the key.
#
# Public helpers:
#   fm_jev_decide <state> <questions-json>
#     POST {model, state, questions}. <state> is a string; <questions-json>
#     is a JSON object. Prints the full JSON response on stdout. Non-zero on
#     hard failure: 2 for usage/config (missing args, missing key, missing
#     jq/curl, questions not a JSON object), 1 for transport or a non-JSON /
#     non-200 response. Sets FM_JEV_LAST_ROUTE, FM_JEV_LAST_URL,
#     FM_JEV_LAST_MODEL, FM_JEV_LAST_HTTP, and FM_JEV_LAST_LATENCY_MS on every
#     attempted call (empty HTTP/latency when the call never reached curl).
#   fm_jev_choice_confidence_ok <confidence> [<floor>]
#     Succeeds when <confidence> is a number in 0..1 at or above <floor>.
#     Default floor is 0.7 (new shadows). Typed dispatch keeps 0.6 in its own
#     tool. JEV_CONFIDENCE_FLOOR overrides the default when <floor> is omitted.
#   fm_jev_probabilities_sum_ok <probabilities-json>
#     Succeeds when the value is a JSON object of numbers in 0..1 that sum to
#     approximately 1 within 0.01.
#   fm_jev_log_call <json-object> [<path>]
#     Appends one JSONL line. Default path is $FM_HOME/state/jev-calls.jsonl.
#     Known secret-shaped object keys are replaced with [redacted]; live
#     TYPESAFE_API_KEY / OPENROUTER_API_KEY values are stripped from the line.
#   fm_jev_compact_state <state>
#     Strips obvious secret-shaped tokens and prints the remainder. Refuses
#     (exit 1) when the raw state exceeds JEV_STATE_MAX_BYTES (default 8192).
#
# Environment (library-specific):
#   TYPESAFE_API_KEY, OPENROUTER_API_KEY, JEV_ROUTE, JEV_MODEL, JEV_TIMEOUT
#   (positive integer seconds, default 5), JEV_CONFIDENCE_FLOOR,
#   JEV_STATE_MAX_BYTES, FM_HOME.
#
# bin/fm-dispatch-resolve.sh keeps its own TypeSafe-only process and is not
# rewired through this library.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'fm-jev-lib.sh is a sourceable library. Usage: . bin/fm-jev-lib.sh\n' >&2
  exit 2
fi

if [ -n "${_FM_JEV_LIB_SOURCED:-}" ]; then
  return 0
fi
_FM_JEV_LIB_SOURCED=1

_FM_JEV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FM_JEV_ROOT="$(cd "$_FM_JEV_LIB_DIR/.." && pwd)"

# shellcheck source=bin/fm-env-lib.sh
. "$_FM_JEV_LIB_DIR/fm-env-lib.sh"

FM_JEV_TYPESAFE_URL='https://api.typesafe.ai/v1/systemone'
FM_JEV_OPENROUTER_URL='https://openrouter.ai/api/alpha/decisions'
FM_JEV_TYPESAFE_MODEL='jev-latest'
FM_JEV_OPENROUTER_MODEL='typesafe/jev-1.13'
FM_JEV_CONFIDENCE_FLOOR=0.7
FM_JEV_STATE_MAX_BYTES=8192
FM_JEV_TIMEOUT=5

_fm_jev_err() {
  printf 'jev: %s\n' "$1" >&2
}

_fm_jev_now_ms() {
  local raw sec frac
  raw=${EPOCHREALTIME:-}
  case "$raw" in
    *[0-9][.,][0-9]*)
      sec=${raw%%[.,]*}
      frac=${raw#*[.,]}
      frac="${frac}000"
      frac=${frac:0:3}
      case "$sec$frac" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$((sec * 1000 + 10#$frac))"; return 0 ;;
      esac
      ;;
  esac
  sec=$(date +%s 2>/dev/null || printf '0')
  case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
  printf '%s\n' "$((sec * 1000))"
}

_fm_jev_home() {
  printf '%s' "${FM_HOME:-$_FM_JEV_ROOT}"
}

_fm_jev_timeout() {
  local timeout=${JEV_TIMEOUT:-$FM_JEV_TIMEOUT}
  case "$timeout" in
    ''|*[!0-9]*|0) printf '%s' "$FM_JEV_TIMEOUT" ;;
    *) printf '%s' "$timeout" ;;
  esac
}

_fm_jev_state_max() {
  local max=${JEV_STATE_MAX_BYTES:-$FM_JEV_STATE_MAX_BYTES}
  case "$max" in
    ''|*[!0-9]*|0) printf '%s' "$FM_JEV_STATE_MAX_BYTES" ;;
    *) printf '%s' "$max" ;;
  esac
}

# Resolve route into _fm_jev_route, _fm_jev_url, _fm_jev_model, _fm_jev_key.
# The key variable is local to the caller of this function (fm_jev_decide).
_fm_jev_resolve_route() {
  local typesafe_key openrouter_key home route
  typesafe_key=${TYPESAFE_API_KEY:-}
  openrouter_key=${OPENROUTER_API_KEY:-}
  home=$(_fm_jev_home)
  if [ -z "$typesafe_key" ]; then
    typesafe_key=$(fmx_env_get TYPESAFE_API_KEY "$home/.env")
  fi
  if [ -z "$openrouter_key" ]; then
    openrouter_key=$(fmx_env_get OPENROUTER_API_KEY "$home/.env")
  fi
  route=${JEV_ROUTE:-}
  case "$route" in
    openrouter)
      if [ -z "$openrouter_key" ]; then
        _fm_jev_err "OPENROUTER_API_KEY missing for JEV_ROUTE=openrouter"
        return 2
      fi
      _fm_jev_route=openrouter
      ;;
    typesafe)
      if [ -z "$typesafe_key" ]; then
        _fm_jev_err "TYPESAFE_API_KEY missing for JEV_ROUTE=typesafe"
        return 2
      fi
      _fm_jev_route=typesafe
      ;;
    '')
      if [ -n "$typesafe_key" ]; then
        _fm_jev_route=typesafe
      elif [ -n "$openrouter_key" ]; then
        _fm_jev_route=openrouter
      else
        _fm_jev_err "no TYPESAFE_API_KEY or OPENROUTER_API_KEY in the environment or $home/.env"
        return 2
      fi
      ;;
    *)
      _fm_jev_err "unknown JEV_ROUTE=$route (want openrouter, typesafe, or empty)"
      return 2
      ;;
  esac
  if [ "$_fm_jev_route" = openrouter ]; then
    _fm_jev_key=$openrouter_key
    _fm_jev_url=$FM_JEV_OPENROUTER_URL
    _fm_jev_model=${JEV_MODEL:-$FM_JEV_OPENROUTER_MODEL}
  else
    _fm_jev_key=$typesafe_key
    _fm_jev_url=$FM_JEV_TYPESAFE_URL
    _fm_jev_model=${JEV_MODEL:-$FM_JEV_TYPESAFE_MODEL}
  fi
}

fm_jev_decide() {
  local state questions request resp_file http t0 t1 timeout
  local _fm_jev_route _fm_jev_url _fm_jev_model _fm_jev_key
  FM_JEV_LAST_ROUTE=''
  FM_JEV_LAST_URL=''
  FM_JEV_LAST_MODEL=''
  FM_JEV_LAST_HTTP=''
  FM_JEV_LAST_LATENCY_MS=''
  if [ $# -ne 2 ]; then
    _fm_jev_err "usage: fm_jev_decide <state> <questions-json>"
    return 2
  fi
  state=$1
  questions=$2
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  command -v curl >/dev/null 2>&1 || { _fm_jev_err "curl not installed"; return 2; }
  printf '%s' "$questions" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    _fm_jev_err "questions must be a JSON object"
    return 2
  }
  _fm_jev_resolve_route || return 2
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_ROUTE=$_fm_jev_route
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_URL=$_fm_jev_url
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_MODEL=$_fm_jev_model
  request=$(jq -n --arg model "$_fm_jev_model" --arg state "$state" --argjson questions "$questions" \
    '{model: $model, state: $state, questions: $questions}') || {
    _fm_jev_err "could not build request"
    return 2
  }
  resp_file=$(mktemp) || { _fm_jev_err "mktemp failed"; return 2; }
  timeout=$(_fm_jev_timeout)
  t0=$(_fm_jev_now_ms)
  http=$(
    unset TYPESAFE_API_KEY OPENROUTER_API_KEY
    unset TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY_PRIVATE
    printf '%s' "$request" | curl -sS --max-time "$timeout" -o "$resp_file" -w '%{http_code}' \
      -X POST "$_fm_jev_url" -H 'Content-Type: application/json' \
      -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$_fm_jev_key") \
      --data-binary @- 2>/dev/null
  ) || http=000
  t1=$(_fm_jev_now_ms)
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_JEV_LAST_HTTP=$http
  FM_JEV_LAST_LATENCY_MS=$((t1 - t0))
  if [ "$http" != 200 ]; then
    _fm_jev_err "http $http after ${FM_JEV_LAST_LATENCY_MS} ms: $(head -c 200 "$resp_file" 2>/dev/null | tr '\n' ' ')"
    rm -f "$resp_file"
    return 1
  fi
  if ! jq -e 'type == "object"' "$resp_file" >/dev/null 2>&1; then
    _fm_jev_err "response is not a JSON object"
    rm -f "$resp_file"
    return 1
  fi
  cat "$resp_file"
  rm -f "$resp_file"
  return 0
}

fm_jev_choice_confidence_ok() {
  local confidence floor
  if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    _fm_jev_err "usage: fm_jev_choice_confidence_ok <confidence> [<floor>]"
    return 2
  fi
  confidence=$1
  floor=${2:-${JEV_CONFIDENCE_FLOOR:-$FM_JEV_CONFIDENCE_FLOOR}}
  awk -v c="$confidence" -v f="$floor" 'BEGIN {
    if (c !~ /^-?[0-9]+(\.[0-9]+)?$/ || f !~ /^-?[0-9]+(\.[0-9]+)?$/) exit 1
    if (c+0 < 0 || c+0 > 1) exit 1
    exit !(c+0 >= f+0)
  }'
}

fm_jev_probabilities_sum_ok() {
  if [ $# -ne 1 ]; then
    _fm_jev_err "usage: fm_jev_probabilities_sum_ok <probabilities-json>"
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  printf '%s' "$1" | jq -e '
    type == "object"
    and (keys | length) > 0
    and all(.[]; type == "number" and . >= 0 and . <= 1)
    and (([.[]] | add) as $t | $t >= 0.99 and $t <= 1.01)
  ' >/dev/null 2>&1
}

fm_jev_compact_state() {
  local state max bytes
  if [ $# -ne 1 ]; then
    _fm_jev_err "usage: fm_jev_compact_state <state>"
    return 2
  fi
  state=$1
  max=$(_fm_jev_state_max)
  bytes=$(printf '%s' "$state" | wc -c)
  bytes=${bytes// /}
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  if [ "$bytes" -gt "$max" ]; then
    _fm_jev_err "state exceeds $max bytes"
    return 1
  fi
  printf '%s' "$state" | awk '
    {
      if (NR > 1) buf = buf "\n"
      buf = buf $0
    }
    END {
      gsub(/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*-----END [A-Z0-9 ]*PRIVATE KEY-----/, "[redacted]", buf)
      while (match(buf, /(TYPESAFE_API_KEY|OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|FMX_PAIRING_TOKEN|FM_MAIL_PASS|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|GITHUB_TOKEN|GH_TOKEN|JEV_API_KEY)=[^[:space:]]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      while (match(buf, /[Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+[^[:space:]]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      while (match(buf, /Bearer[[:space:]]+[^[:space:]]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      while (match(buf, /sk-or-[A-Za-z0-9_-]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      while (match(buf, /github_pat_[A-Za-z0-9_]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      while (match(buf, /ghp_[A-Za-z0-9]+/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      while (match(buf, /sk-[A-Za-z0-9_-]{16,}/)) {
        buf = substr(buf, 1, RSTART - 1) "[redacted]" substr(buf, RSTART + RLENGTH)
      }
      printf "%s", buf
    }
  '
}

_fm_jev_redact_live_keys() {
  local text=$1
  local typesafe_key=${TYPESAFE_API_KEY:-}
  local openrouter_key=${OPENROUTER_API_KEY:-}
  [ -n "$typesafe_key" ] && text=${text//"$typesafe_key"/[redacted]}
  [ -n "$openrouter_key" ] && text=${text//"$openrouter_key"/[redacted]}
  printf '%s' "$text"
}

fm_jev_log_call() {
  local json path dir line home
  if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    _fm_jev_err "usage: fm_jev_log_call <json-object> [<path>]"
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { _fm_jev_err "jq required"; return 2; }
  json=$1
  home=$(_fm_jev_home)
  path=${2:-$home/state/jev-calls.jsonl}
  line=$(printf '%s' "$json" | jq -c '
    def redact:
      if type == "object" then
        with_entries(
          if (.key | test("(?i)(authorization|api[_-]?key|token|password|secret)"))
          then .value = "[redacted]"
          else .value |= redact
          end
        )
      elif type == "array" then map(redact)
      else .
      end;
    if type == "object" then redact else empty end
  ' 2>/dev/null) || line=''
  if [ -z "$line" ]; then
    _fm_jev_err "log payload must be a JSON object"
    return 2
  fi
  line=$(_fm_jev_redact_live_keys "$line")
  dir=$(dirname "$path")
  mkdir -p "$dir" || { _fm_jev_err "could not create $dir"; return 1; }
  printf '%s\n' "$line" >> "$path" || { _fm_jev_err "could not write $path"; return 1; }
}
