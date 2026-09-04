#!/usr/bin/env bash
# fm-ollama-websearch.sh - the key-holding proxy for Ollama Cloud web search.
#
# Firstmate gives Pi scouts a web_search tool they can call without ever holding
# the credential that makes it work. This script is the half that holds it: the
# agent-facing half is bin/fm-pi-websearch-ext.ts, which shells out to this
# script and returns only its stdout. The agent supplies a query and receives
# results; the key stays in this process.
#
# THE ONE GUARANTEE
# The Ollama key never becomes readable through this script. Concretely, for
# every invocation, including malformed and failing ones:
#   - it is never printed on stdout or stderr, in success or in any error path;
#   - it is never placed in this script's own argv, nor in any child's argv,
#     so a concurrent `ps` from the agent cannot catch it;
#   - it is never exported, so it is absent from every child's environment and
#     from `ps -E` output for this process;
#   - it is never written to a file, a log, or a temp path;
#   - it reaches curl only through a configuration read from curl's stdin
#     (curl --config -), which lives in a pipe rather than in argv or on disk.
# The key travels to exactly one place, the Ollama web-search endpoint over
# HTTPS, and the endpoint is pinned rather than taken from the caller: see
# "Test seam" below for the single, narrow exception and why it cannot widen.
#
# WHAT THIS SCRIPT IS NOT
# It is not a privilege boundary. It runs as the same user as the agent that
# calls it, so it can never be stronger than the key file's own permissions: a
# worker that can read that file directly needs no help from this script. That
# preexisting exposure belongs to the key file's mode and location, not here.
# What this script does own is that IT never becomes the leak - never an oracle
# that prints, forwards, or otherwise hands the key to its caller.
#
# Key resolution, first match wins:
#   1. $FM_OLLAMA_CLOUD_ENV                       (explicit override)
#   2. $HOME/Library/Application Support/firstmate/ollama-cloud.env   (macOS)
#   3. ${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/ollama-cloud.env   (Linux)
# The file is the same one the Ollama usage probe already reads. It is PARSED,
# never sourced: sourcing an env file executes it, which would turn a corrupted
# or hostile key file into code execution for no benefit.
# A key alone does not turn the feature on. The file predates this feature
# (the usage probe reads it), so bin/fm-spawn.sh treats its presence as a
# credential, not as consent to spend: it wires the extension into a scout only
# when the home's captain opted in via the local config/pi-scout-websearch flag
# AND `status` here confirms a usable key. A home missing either simply never
# sees a web_search tool.
#
# Output. `search` prints one JSON object, {"results":[{title,url,content,
# truncated}]}, and nothing else. Content is truncated per result because the
# upstream payload is very large in practice - three results measured at 101 KB
# on 2026-09-01 (docs/verification/ollama-websearch.md) - which would otherwise
# spend a scout's whole context on one call. Truncation is always reported in
# the `truncated` field rather than hidden.
#
# Cost. Every search counts against the same Ollama Cloud quota the usage probe
# reports, itemized there as the model name "web search" (measured; see the
# verification record). Bounding calls therefore matters: exposure is limited to
# scouts by bin/fm-spawn.sh, and the extension additionally caps calls per turn.
#
# Test seam. FM_OLLAMA_WEBSEARCH_URL redirects the request, and is honored ONLY
# when the key came from an explicit FM_OLLAMA_CLOUD_ENV pointing somewhere
# other than a default path AND the target is http on localhost. That pairing is
# the point: the real key lives at a default path, so no invocation can ever
# send the REAL key anywhere but https://ollama.com. A redirect is reachable
# only with a key file the caller supplied, whose contents it already knows.
#
# Usage:
#   fm-ollama-websearch.sh search --query <text> [--max-results <1-10>] [--max-chars <200-8000>]
#   fm-ollama-websearch.sh status            report whether a key is configured, without calling out
#   fm-ollama-websearch.sh --help            print this usage
#
# Exit codes: 0 ok, 2 usage error, 3 no key configured, 4 upstream or transport failure.
set -u

PRODUCTION_URL="https://ollama.com/api/web_search"
DEFAULT_MAX_RESULTS=3
DEFAULT_MAX_CHARS=2000
CURL_MAX_TIME=60
CURL_CONNECT_TIMEOUT=15

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-ollama-websearch: %s\n' "$1" >&2
  exit "${2:-2}"
}

# Every default location the key may live at. Used both to resolve the key and
# to decide whether a caller-supplied key file is a non-default one, which is
# what gates the localhost test seam.
default_key_paths() {
  printf '%s\n' "$HOME/Library/Application Support/firstmate/ollama-cloud.env"
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/ollama-cloud.env"
}

resolve_key_file() {
  local candidate
  if [ -n "${FM_OLLAMA_CLOUD_ENV:-}" ]; then
    printf '%s\n' "$FM_OLLAMA_CLOUD_ENV"
    return 0
  fi
  while IFS= read -r candidate; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$(default_key_paths)
EOF
  return 1
}

is_default_key_path() {
  local path=$1 candidate
  while IFS= read -r candidate; do
    [ "$path" = "$candidate" ] && return 0
  done <<EOF
$(default_key_paths)
EOF
  return 1
}

# Parse OLLAMA_API_KEY out of the env file WITHOUT sourcing it, then hold it in
# an ordinary shell variable. Deliberately never `export`: an exported value
# would appear in every child's environment and in `ps -E`, which is exactly the
# exposure this whole script exists to avoid.
read_key() {
  local file=$1 raw
  raw=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}OLLAMA_API_KEY=//p' "$file" 2>/dev/null | head -1)
  raw=${raw%$'\r'}
  # Strip one matching pair of surrounding quotes, the two forms an env file uses.
  case "$raw" in
    \"*\") raw=${raw#\"}; raw=${raw%\"} ;;
    \'*\') raw=${raw#\'}; raw=${raw%\'} ;;
  esac
  printf '%s' "$raw"
}

# A key with a character outside this set would have to be escaped into curl's
# configuration syntax, and a mis-escape there is precisely how a credential
# ends up somewhere unintended. Refuse instead, naming nothing but the fault.
key_is_wellformed() {
  case "$1" in
    '') return 1 ;;
    *[!A-Za-z0-9._~+/=-]*) return 1 ;;
  esac
  [ "${#1}" -ge 8 ]
}

require_int_in_range() {
  local value=$1 low=$2 high=$3 label=$4
  case "$value" in
    ''|*[!0-9]*) die "$label must be an integer between $low and $high" ;;
  esac
  [ "$value" -ge "$low" ] && [ "$value" -le "$high" ] ||
    die "$label must be between $low and $high"
}

# Sets RESOLVED_URL, or dies. Deliberately not a command substitution: a die
# inside one would only kill the subshell and let the caller continue with an
# empty endpoint, which is the shape of bug this whole script must not have.
RESOLVED_URL=
resolve_url() {
  local key_file=$1 override=${FM_OLLAMA_WEBSEARCH_URL:-}
  if [ -z "$override" ]; then
    RESOLVED_URL=$PRODUCTION_URL
    return 0
  fi
  if [ -z "${FM_OLLAMA_CLOUD_ENV:-}" ] || is_default_key_path "$key_file"; then
    die "FM_OLLAMA_WEBSEARCH_URL is refused for a default key file; the configured key is only ever sent to $PRODUCTION_URL"
  fi
  case "$override" in
    http://127.0.0.1:*|http://localhost:*) ;;
    *) die "FM_OLLAMA_WEBSEARCH_URL must be an http URL on localhost" ;;
  esac
  RESOLVED_URL=$override
}

cmd_status() {
  local key_file key
  if ! key_file=$(resolve_key_file) || [ ! -f "$key_file" ]; then
    printf 'unconfigured: no Ollama key file found (looked at the default locations in --help)\n'
    exit 3
  fi
  key=$(read_key "$key_file")
  if ! key_is_wellformed "$key"; then
    printf 'unconfigured: %s has no usable OLLAMA_API_KEY\n' "$key_file"
    exit 3
  fi
  printf 'configured: web search key available from %s\n' "$key_file"
  exit 0
}

cmd_search() {
  local query='' max_results=$DEFAULT_MAX_RESULTS max_chars=$DEFAULT_MAX_CHARS
  while [ $# -gt 0 ]; do
    case "$1" in
      --query) [ $# -ge 2 ] || die "--query needs a value"; query=$2; shift 2 ;;
      --max-results) [ $# -ge 2 ] || die "--max-results needs a value"; max_results=$2; shift 2 ;;
      --max-chars) [ $# -ge 2 ] || die "--max-chars needs a value"; max_chars=$2; shift 2 ;;
      *) die "unknown search option: $1" ;;
    esac
  done
  [ -n "$query" ] || die "search needs a non-empty --query"
  require_int_in_range "$max_results" 1 10 "--max-results"
  require_int_in_range "$max_chars" 200 8000 "--max-chars"

  command -v curl >/dev/null 2>&1 || die "curl is required for web search" 4
  command -v jq >/dev/null 2>&1 || die "jq is required for web search" 4

  local key_file key
  if ! key_file=$(resolve_key_file) || [ ! -f "$key_file" ]; then
    die "no Ollama key file found, so web search is not configured on this home" 3
  fi
  key=$(read_key "$key_file")
  key_is_wellformed "$key" ||
    die "$key_file has no usable OLLAMA_API_KEY" 3
  resolve_url "$key_file"

  local body escaped_body
  body=$(jq -cn --arg q "$query" --argjson n "$max_results" \
    '{query: $q, max_results: $n}') ||
    die "could not encode the search request" 4
  # The body travels inside the same curl configuration as the key, so it has to
  # survive curl's quoted-value syntax. jq -c emits exactly one line with no raw
  # control characters, so escaping the two metacharacters of that syntax -
  # backslash first, then quote - is complete. A query cannot then close the
  # value and add a directive of its own, which is what keeps an adversarial
  # search string (a prompt injection reaching the tool) from steering the
  # request that carries the credential.
  escaped_body=$(printf '%s' "$body" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

  # One search writes NO files. The key reaches curl through a configuration on
  # STDIN: printf is a bash builtin, so the key exists only in this shell's
  # memory and in that pipe, never in an argument vector, an environment entry,
  # or a path something else could open. The response comes back on stdout with
  # the status code appended, so there is no temp file and no cleanup path that
  # could fail and leave content behind.
  local response http curl_rc
  response=$(
    printf 'url = "%s"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\ndata = "%s"\n' \
      "$RESOLVED_URL" "$key" "$escaped_body" |
      curl --silent --show-error --config - \
        --request POST \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        --write-out '\n%{http_code}'
  )
  curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then
    # curl's own diagnostics describe transport and reach our stderr directly;
    # they never quote back the configuration they were handed.
    die "web search request failed (curl exit $curl_rc)" 4
  fi
  http=${response##*$'\n'}
  response=${response%$'\n'*}
  case "$http" in
    2*) ;;
    401|403) die "web search rejected the configured Ollama key (HTTP $http)" 4 ;;
    *) die "web search returned HTTP $http: $(printf '%s' "$response" | head -c 300 | tr '\n' ' ')" 4 ;;
  esac

  # Reshape rather than pass through: the upstream content fields are whole-page
  # dumps, so an untruncated relay would hand a scout a six-figure byte payload.
  jq --argjson n "$max_chars" '
      {
        results: [
          (.results // [])[] | {
            title: (.title // ""),
            url: (.url // ""),
            content: (
              (.content // "")
              | if (length > $n) then (.[0:$n] + "\n[truncated]") else . end
            ),
            truncated: (((.content // "") | length) > $n)
          }
        ]
      }
    ' <<EOF || die "web search returned a response that is not the expected JSON" 4
$response
EOF
}

case "${1:---help}" in
  --help|-h|help) usage; exit 0 ;;
  status) [ $# -eq 1 ] || die "status takes no options"; cmd_status ;;
  search) shift; cmd_search "$@" ;;
  *) die "unknown command: $1" ;;
esac
