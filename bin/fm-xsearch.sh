#!/usr/bin/env bash
# Call xAI server-side web_search and/or x_search via the Responses API.
#
# Usage:
#   fm-xsearch.sh [options] <prompt>
#   fm-xsearch.sh [options] --prompt-file <path>
#   fm-xsearch.sh [options] -
#
# This is firstmate's fleet path for Grok X Search and Web Search. It is NOT the
# X Developer API and NOT firstmate X-mode (public @mentions). Auth is SuperGrok
# OAuth from an existing OpenCode or Pi store, or an explicit XAI_API_KEY. Tokens
# are never printed.
#
# Server tools only work on POST https://api.x.ai/v1/responses (chat completions
# rejects type x_search). Default model is grok-4.5. Calls are metered; prefer a
# low --max-tool-calls and tight prompts.
#
# Auth resolution (first match wins):
#   1. XAI_API_KEY environment variable
#   2. FM_XAI_AUTH_FILE when set (OpenCode/Pi-shaped JSON with an "xai" entry)
#   3. OpenCode store: ${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json
#   4. Pi store: $HOME/.pi/agent/auth.json
#
# OAuth access tokens near expiry are refreshed against auth.x.ai and written
# back to the same store (mode 600) when the store is writable.
#
# Options:
#   --tool <x_search|web_search|both>   tools to attach (default: both)
#   --model <id>                        Responses model (default: grok-4.5)
#   --max-tool-calls <n>                cap server tool rounds (default: 3)
#   --allowed-handle <handle>           x_search allowlist (repeatable, max 20)
#   --excluded-handle <handle>          x_search denylist (repeatable, max 20)
#   --from-date <YYYY-MM-DD>            x_search lower bound (inclusive)
#   --to-date <YYYY-MM-DD>              x_search upper bound (inclusive)
#   --enable-image-understanding        opt-in x_search image analysis (costly)
#   --enable-video-understanding        opt-in x_search video analysis (costly)
#   --prompt-file <path>                read prompt from file instead of argv
#   --json                              print the full API JSON response
#   --dry-run                           build and print the request body; no auth
#                                       refresh and no network call
#   -h, --help                          show this help
#
# Exit codes:
#   0 success
#   1 transport or unexpected failure
#   2 usage error
#   3 no usable auth
#   4 API non-2xx (stderr has HTTP code; body only with --json on stdout empty)
#
# Env overrides (tests / advanced):
#   FM_XAI_AUTH_FILE       force one auth.json path
#   FM_XAI_BASE_URL        API base (default https://api.x.ai/v1)
#   FM_XAI_TOKEN_URL       OAuth token URL (default https://auth.x.ai/oauth2/token)
#   FM_XAI_CLIENT_ID       OAuth client id (OpenCode/Pi shared default)
#   FM_XAI_REFRESH_SKEW_MS refresh this many ms before expires (default 300000)
#   FM_XAI_CURL_TIMEOUT    curl -m seconds (default 120)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

DEFAULT_MODEL=grok-4.5
DEFAULT_MAX_TOOL_CALLS=3
DEFAULT_BASE_URL=https://api.x.ai/v1
DEFAULT_TOKEN_URL=https://auth.x.ai/oauth2/token
DEFAULT_CLIENT_ID=b1a00492-073a-47ea-816f-4c329264a828
DEFAULT_REFRESH_SKEW_MS=300000
DEFAULT_CURL_TIMEOUT=120
DEFAULT_TOKEN_LIFETIME_S=3600

TOOL=both
MODEL=$DEFAULT_MODEL
MAX_TOOL_CALLS=$DEFAULT_MAX_TOOL_CALLS
PROMPT_FILE=
PROMPT=
JSON_OUT=0
DRY_RUN=0
ENABLE_IMAGE=0
ENABLE_VIDEO=0
ALLOWED_HANDLES=()
EXCLUDED_HANDLES=()

usage() {
  cat <<'EOF'
usage: fm-xsearch.sh [options] <prompt>
       fm-xsearch.sh [options] --prompt-file <path>
       fm-xsearch.sh [options] -

Call xAI server-side web_search and/or x_search on /v1/responses using SuperGrok
OAuth (OpenCode or Pi store) or XAI_API_KEY. Not the X Developer API. Not X-mode.

Options:
  --tool <x_search|web_search|both>   tools to attach (default: both)
  --model <id>                        model id (default: grok-4.5)
  --max-tool-calls <n>                server tool-call cap (default: 3)
  --allowed-handle <handle>           x_search allowlist handle (repeatable)
  --excluded-handle <handle>          x_search denylist handle (repeatable)
  --from-date <YYYY-MM-DD>            x_search from_date
  --to-date <YYYY-MM-DD>              x_search to_date
  --enable-image-understanding        enable x_search image understanding
  --enable-video-understanding        enable x_search video understanding
  --prompt-file <path>                read prompt text from a file
  --json                              emit full API JSON on stdout
  --dry-run                           print request JSON only; no network
  -h, --help                          show this help
EOF
}

die_usage() {
  echo "fm-xsearch: $1" >&2
  usage >&2
  exit 2
}

die() {
  echo "fm-xsearch: $1" >&2
  exit "${2:-1}"
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_iso_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

is_safe_handle() {
  case "$1" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}

now_ms() {
  # Portable epoch milliseconds. GNU date's %N is nanoseconds; take the first
  # three digits. Do not use %s%3N — some builds paste full nanoseconds and
  # produce a value far larger than real epoch-ms.
  local s n
  s=$(date +%s) || return 1
  n=$(date +%N 2>/dev/null || true)
  case "$n" in
    [0-9][0-9][0-9]*)
      printf '%s%s\n' "$s" "${n:0:3}"
      ;;
    *)
      printf '%s000\n' "$s"
      ;;
  esac
}

opencode_auth_path() {
  local base
  base="${XDG_DATA_HOME:-$HOME/.local/share}"
  printf '%s\n' "$base/opencode/auth.json"
}

pi_auth_path() {
  printf '%s\n' "$HOME/.pi/agent/auth.json"
}

# Parse argv -----------------------------------------------------------------

FROM_DATE=
TO_DATE=

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --tool)
      [ $# -ge 2 ] || die_usage "--tool requires a value"
      TOOL=$2
      shift 2
      ;;
    --model)
      [ $# -ge 2 ] || die_usage "--model requires a value"
      MODEL=$2
      shift 2
      ;;
    --max-tool-calls)
      [ $# -ge 2 ] || die_usage "--max-tool-calls requires a value"
      MAX_TOOL_CALLS=$2
      shift 2
      ;;
    --allowed-handle)
      [ $# -ge 2 ] || die_usage "--allowed-handle requires a value"
      ALLOWED_HANDLES+=("$2")
      shift 2
      ;;
    --excluded-handle)
      [ $# -ge 2 ] || die_usage "--excluded-handle requires a value"
      EXCLUDED_HANDLES+=("$2")
      shift 2
      ;;
    --from-date)
      [ $# -ge 2 ] || die_usage "--from-date requires a value"
      FROM_DATE=$2
      shift 2
      ;;
    --to-date)
      [ $# -ge 2 ] || die_usage "--to-date requires a value"
      TO_DATE=$2
      shift 2
      ;;
    --enable-image-understanding)
      ENABLE_IMAGE=1
      shift
      ;;
    --enable-video-understanding)
      ENABLE_VIDEO=1
      shift
      ;;
    --prompt-file)
      [ $# -ge 2 ] || die_usage "--prompt-file requires a path"
      PROMPT_FILE=$2
      shift 2
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -)
      PROMPT_FILE=-
      shift
      break
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

case "$TOOL" in
  x_search|web_search|both) ;;
  *) die_usage "--tool must be x_search, web_search, or both" ;;
esac

is_uint "$MAX_TOOL_CALLS" || die_usage "--max-tool-calls must be a non-negative integer"
[ "$MAX_TOOL_CALLS" -ge 1 ] || die_usage "--max-tool-calls must be >= 1"
[ "${#ALLOWED_HANDLES[@]}" -le 20 ] || die_usage "at most 20 --allowed-handle values"
[ "${#EXCLUDED_HANDLES[@]}" -le 20 ] || die_usage "at most 20 --excluded-handle values"
if [ "${#ALLOWED_HANDLES[@]}" -gt 0 ] && [ "${#EXCLUDED_HANDLES[@]}" -gt 0 ]; then
  die_usage "cannot combine --allowed-handle and --excluded-handle"
fi

for h in "${ALLOWED_HANDLES[@]:-}"; do
  [ -n "$h" ] || continue
  is_safe_handle "$h" || die_usage "unsafe --allowed-handle: $h"
done
for h in "${EXCLUDED_HANDLES[@]:-}"; do
  [ -n "$h" ] || continue
  is_safe_handle "$h" || die_usage "unsafe --excluded-handle: $h"
done

if [ -n "$FROM_DATE" ]; then
  is_iso_date "$FROM_DATE" || die_usage "--from-date must be YYYY-MM-DD"
fi
if [ -n "$TO_DATE" ]; then
  is_iso_date "$TO_DATE" || die_usage "--to-date must be YYYY-MM-DD"
fi

if [ -n "$PROMPT_FILE" ]; then
  [ $# -eq 0 ] || die_usage "prompt text and --prompt-file/- are mutually exclusive"
  if [ "$PROMPT_FILE" = - ]; then
    PROMPT=$(cat) || die "failed to read prompt from stdin"
  else
    [ -f "$PROMPT_FILE" ] || die_usage "prompt file not found: $PROMPT_FILE"
    PROMPT=$(cat -- "$PROMPT_FILE") || die "failed to read prompt file"
  fi
else
  [ $# -ge 1 ] || die_usage "prompt required"
  PROMPT=$*
fi

[ -n "${PROMPT//[[:space:]]/}" ] || die_usage "prompt must be non-empty"

command -v jq >/dev/null 2>&1 || die "jq not found"

BASE_URL=${FM_XAI_BASE_URL:-$DEFAULT_BASE_URL}
TOKEN_URL=${FM_XAI_TOKEN_URL:-$DEFAULT_TOKEN_URL}
CLIENT_ID=${FM_XAI_CLIENT_ID:-$DEFAULT_CLIENT_ID}
REFRESH_SKEW_MS=${FM_XAI_REFRESH_SKEW_MS:-$DEFAULT_REFRESH_SKEW_MS}
CURL_TIMEOUT=${FM_XAI_CURL_TIMEOUT:-$DEFAULT_CURL_TIMEOUT}
is_uint "$REFRESH_SKEW_MS" || die "FM_XAI_REFRESH_SKEW_MS must be an integer"
is_uint "$CURL_TIMEOUT" || die "FM_XAI_CURL_TIMEOUT must be an integer"

# Build tools JSON -----------------------------------------------------------

handles_json_array() {
  # Encode argv handles as a JSON string array (raw lines are not JSON).
  if [ "$#" -eq 0 ]; then
    printf '%s\n' '[]'
    return 0
  fi
  jq -cn --args '$ARGS.positional' -- "$@"
}

build_x_search_tool_json() {
  local tool handles
  tool=$(jq -cn '{type:"x_search"}') || return 1
  if [ "${#ALLOWED_HANDLES[@]}" -gt 0 ]; then
    handles=$(handles_json_array "${ALLOWED_HANDLES[@]}") || return 1
    tool=$(jq -cn --argjson t "$tool" --argjson h "$handles" \
      '$t + {allowed_x_handles:$h}') || return 1
  fi
  if [ "${#EXCLUDED_HANDLES[@]}" -gt 0 ]; then
    handles=$(handles_json_array "${EXCLUDED_HANDLES[@]}") || return 1
    tool=$(jq -cn --argjson t "$tool" --argjson h "$handles" \
      '$t + {excluded_x_handles:$h}') || return 1
  fi
  if [ -n "$FROM_DATE" ]; then
    tool=$(jq -cn --argjson t "$tool" --arg d "$FROM_DATE" '$t + {from_date:$d}') || return 1
  fi
  if [ -n "$TO_DATE" ]; then
    tool=$(jq -cn --argjson t "$tool" --arg d "$TO_DATE" '$t + {to_date:$d}') || return 1
  fi
  if [ "$ENABLE_IMAGE" -eq 1 ]; then
    tool=$(jq -cn --argjson t "$tool" '$t + {enable_image_understanding:true}') || return 1
  fi
  if [ "$ENABLE_VIDEO" -eq 1 ]; then
    tool=$(jq -cn --argjson t "$tool" '$t + {enable_video_understanding:true}') || return 1
  fi
  printf '%s\n' "$tool"
}

build_tools_json() {
  local parts=() t
  case "$TOOL" in
    web_search)
      parts+=('{"type":"web_search"}')
      ;;
    x_search)
      t=$(build_x_search_tool_json) || return 1
      parts+=("$t")
      ;;
    both)
      parts+=('{"type":"web_search"}')
      t=$(build_x_search_tool_json) || return 1
      parts+=("$t")
      ;;
  esac
  printf '%s\n' "${parts[@]}" | jq -cs '.'
}

TOOLS_JSON=$(build_tools_json) || die "failed to build tools JSON"

REQUEST_JSON=$(jq -cn \
  --arg model "$MODEL" \
  --arg prompt "$PROMPT" \
  --argjson tools "$TOOLS_JSON" \
  --argjson max "$MAX_TOOL_CALLS" \
  '{
    model: $model,
    input: [{role:"user", content:$prompt}],
    tools: $tools,
    max_tool_calls: $max
  }') || die "failed to build request JSON"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$REQUEST_JSON"
  exit 0
fi

# Auth -----------------------------------------------------------------------

TMP_FILES=()
# shellcheck disable=SC2329 # Invoked via EXIT trap.
cleanup_tmp() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup_tmp EXIT

make_tmp() {
  local var=$1 f
  f=$(mktemp "${TMPDIR:-/tmp}/fm-xsearch.XXXXXX") || return 1
  chmod 600 "$f" || return 1
  TMP_FILES+=("$f")
  printf -v "$var" '%s' "$f"
}

AUTH_BEARER=

read_store_xai() {
  local file=$1
  [ -f "$file" ] || return 1
  jq -e '.xai and (.xai|type=="object")' "$file" >/dev/null 2>&1 || return 1
  return 0
}

# Sets AUTH_BEARER and optionally AUTH_STORE / AUTH_KIND from a store file.
load_oauth_from_store() {
  local file=$1 typ access refresh expires now skew
  typ=$(jq -r '.xai.type // empty' "$file") || return 1
  [ "$typ" = oauth ] || return 1
  access=$(jq -r '.xai.access // empty' "$file") || return 1
  refresh=$(jq -r '.xai.refresh // empty' "$file") || return 1
  expires=$(jq -r '.xai.expires // 0' "$file") || return 1
  [ -n "$access" ] || return 1
  now=$(now_ms)
  skew=$REFRESH_SKEW_MS
  # expires may be ms (OpenCode/Pi) ; if it looks like seconds (< 1e12), scale.
  if is_uint "$expires" && [ "$expires" -gt 0 ] && [ "$expires" -lt 1000000000000 ]; then
    expires=$((expires * 1000))
  fi
  if is_uint "$expires" && [ "$expires" -gt 0 ] && [ "$((now + skew))" -ge "$expires" ]; then
    [ -n "$refresh" ] || die "OAuth access expired and no refresh token in $file" 3
    access=$(refresh_oauth_token "$file" "$refresh") || return 1
    [ -n "$access" ] || return 1
  fi
  AUTH_BEARER=$access
  return 0
}

# Refresh OAuth; print the new access token on stdout. Best-effort write-back to
# the auth store (mode 600). A write failure still returns the fresh access so
# the current call can proceed.
refresh_oauth_token() {
  local file=$1 refresh=$2 form_file resp_file out_file code new_json expires_in access new_refresh expires_ms
  command -v curl >/dev/null 2>&1 || die "curl not found"
  make_tmp form_file || die "mktemp failed"
  make_tmp resp_file || die "mktemp failed"
  # Never log refresh token. Write form body to a 0600 temp file.
  {
    printf 'grant_type=refresh_token&client_id='
    jq -rn --arg v "$CLIENT_ID" '$v|@uri'
    printf '&refresh_token='
    jq -rn --arg v "$refresh" '$v|@uri'
  } > "$form_file" || die "failed to build refresh body"

  code=$(curl -m "$CURL_TIMEOUT" -sS -o "$resp_file" -w '%{http_code}' \
    -X POST \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary @"$form_file" \
    "$TOKEN_URL" 2>/dev/null) || die "OAuth refresh transport failed" 3

  case "$code" in
    2[0-9][0-9]) ;;
    *) die "OAuth refresh failed (HTTP $code)" 3 ;;
  esac

  access=$(jq -r '.access_token // empty' "$resp_file") || true
  [ -n "$access" ] || die "OAuth refresh response missing access_token" 3
  new_refresh=$(jq -r '.refresh_token // empty' "$resp_file") || true
  [ -n "$new_refresh" ] || new_refresh=$refresh
  expires_in=$(jq -r '.expires_in // empty' "$resp_file") || true
  if ! is_uint "${expires_in:-}"; then
    expires_in=$DEFAULT_TOKEN_LIFETIME_S
  fi
  expires_ms=$(( $(now_ms) + expires_in * 1000 - REFRESH_SKEW_MS ))
  [ "$expires_ms" -gt 0 ] || expires_ms=$(( $(now_ms) + expires_in * 1000 ))

  new_json=$(jq -c \
    --arg access "$access" \
    --arg refresh "$new_refresh" \
    --argjson expires "$expires_ms" \
    '.xai.type = "oauth"
     | .xai.access = $access
     | .xai.refresh = $refresh
     | .xai.expires = $expires' "$file") || {
    printf '%s\n' "$access"
    return 0
  }

  make_tmp out_file || {
    printf '%s\n' "$access"
    return 0
  }
  printf '%s\n' "$new_json" > "$out_file" || {
    printf '%s\n' "$access"
    return 0
  }
  chmod 600 "$out_file" || true
  if ! mv -f "$out_file" "$file" 2>/dev/null; then
    if ! cat "$out_file" > "$file" 2>/dev/null; then
      echo "fm-xsearch: warning: could not write refreshed token to $file" >&2
    else
      chmod 600 "$file" 2>/dev/null || true
    fi
    rm -f "$out_file"
  fi
  printf '%s\n' "$access"
  return 0
}

resolve_auth() {
  if [ -n "${XAI_API_KEY:-}" ]; then
    AUTH_BEARER=$XAI_API_KEY
    return 0
  fi
  if [ -n "${FM_XAI_AUTH_FILE:-}" ]; then
    read_store_xai "$FM_XAI_AUTH_FILE" || die "FM_XAI_AUTH_FILE has no usable xai entry: $FM_XAI_AUTH_FILE" 3
    load_oauth_from_store "$FM_XAI_AUTH_FILE" || die "cannot load OAuth from $FM_XAI_AUTH_FILE" 3
    return 0
  fi
  local oc pi
  oc=$(opencode_auth_path)
  pi=$(pi_auth_path)
  if read_store_xai "$oc" && load_oauth_from_store "$oc"; then
    return 0
  fi
  if read_store_xai "$pi" && load_oauth_from_store "$pi"; then
    return 0
  fi
  die "no xAI auth: set XAI_API_KEY or sign in via OpenCode/Pi SuperGrok OAuth" 3
}

resolve_auth
command -v curl >/dev/null 2>&1 || die "curl not found"

make_tmp AUTH_HEADER_FILE || die "mktemp failed"
# Authorization header via file so the token never appears on the process argv.
{
  printf 'Authorization: Bearer '
  # shellcheck disable=SC2059
  printf '%s\n' "$AUTH_BEARER"
} > "$AUTH_HEADER_FILE" || die "failed to write auth header"
# Clear shell copy promptly; curl reads the file.
AUTH_BEARER=

make_tmp RESPONSE_BODY_FILE || die "mktemp failed"
make_tmp REQ_FILE || die "mktemp failed"
printf '%s\n' "$REQUEST_JSON" > "$REQ_FILE" || die "failed to write request body"

HTTP_CODE=$(curl -m "$CURL_TIMEOUT" -sS -o "$RESPONSE_BODY_FILE" -w '%{http_code}' \
  -X POST \
  -H @"$AUTH_HEADER_FILE" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data-binary @"$REQ_FILE" \
  "$BASE_URL/responses" 2>/dev/null) || die "request to xAI /responses failed"

case "$HTTP_CODE" in
  2[0-9][0-9]) ;;
  *)
    echo "fm-xsearch: xAI returned HTTP $HTTP_CODE" >&2
    if [ "$JSON_OUT" -eq 1 ] && [ -s "$RESPONSE_BODY_FILE" ]; then
      cat "$RESPONSE_BODY_FILE"
      echo
    fi
    exit 4
    ;;
esac

if [ "$JSON_OUT" -eq 1 ]; then
  cat "$RESPONSE_BODY_FILE"
  echo
  exit 0
fi

# Human-oriented summary: assistant text + tool usage counters (no secrets).
TEXT=$(jq -r '
  def texts:
    if type == "array" then
      [.[]
        | if type == "object" then
            if .type == "message" then
              (.content // [])
              | if type == "array" then
                  [.[] | select(.type == "output_text" or .type == "text") | (.text // .)]
                else [] end
            elif .type == "output_text" or .type == "text" then
              [(.text // .)]
            else [] end
          elif type == "string" then [.]
          else [] end]
      | add // []
    else [] end;
  (.output | texts | map(select(type=="string" and length>0)) | join("\n"))
  // .output_text // .text // empty
' "$RESPONSE_BODY_FILE" 2>/dev/null || true)

if [ -z "$TEXT" ]; then
  TEXT=$(jq -r '
    [ .. | objects | select(has("text")) | .text | select(type=="string" and length>0) ] | last // empty
  ' "$RESPONSE_BODY_FILE" 2>/dev/null || true)
fi

USAGE=$(jq -c '
  {
    web_search_calls: (
      .usage.server_side_tool_usage_details.web_search_calls
      // .server_side_tool_usage_details.web_search_calls
      // .usage.web_search_calls
      // 0
    ),
    x_search_calls: (
      .usage.server_side_tool_usage_details.x_search_calls
      // .server_side_tool_usage_details.x_search_calls
      // .usage.x_search_calls
      // 0
    ),
    num_server_side_tools_used: (
      .usage.num_server_side_tools_used
      // .num_server_side_tools_used
      // 0
    ),
    input_tokens: (.usage.input_tokens // .usage.prompt_tokens // null),
    output_tokens: (.usage.output_tokens // .usage.completion_tokens // null)
  }
' "$RESPONSE_BODY_FILE" 2>/dev/null || printf '%s\n' '{}')

if [ -n "$TEXT" ]; then
  printf '%s\n' "$TEXT"
else
  echo "fm-xsearch: response contained no assistant text (use --json for raw body)" >&2
fi
printf 'fm-xsearch: usage %s\n' "$USAGE" >&2
exit 0
