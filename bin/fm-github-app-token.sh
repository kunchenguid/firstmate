#!/usr/bin/env bash
# Mint a short-lived GitHub App installation access token for worker identity.
#
# Usage: fm-github-app-token.sh
#
# Reads local, gitignored config under the effective Firstmate home
# (docs/configuration.md "GitHub App worker identity"):
#   config/github-app-id                 App id (digits only, one line)
#   config/github-app-installation-id    Installation id (digits only, one line)
#   config/github-app-private-key-path   Absolute path to the App private key PEM
#
# The private key file is used only as the openssl signing input; this script
# never prints the key, never puts a token or JWT on argv, and never writes a
# token to a worktree or tracked path. The mint request uses curl -H @file so
# the JWT rides a mode-0600 header file, not the process argument list.
#
# Exit status:
#   0  success; the installation access token is printed alone on stdout
#   2  no App configured (any required config item absent or empty) - not an error
#   1  configured but mint failed (bad key, bad ids, network, API, missing tools)
#
# Installation tokens last about one hour. Call this helper again to remint;
# there is no durable on-disk token cache. Mid-task expiry is expected: remint
# and re-export GH_TOKEN / GITHUB_TOKEN before the next git push or gh call.
#
# Optional test / operator overrides (never secrets):
#   FM_GITHUB_APP_API_BASE   API origin (default https://api.github.com)
#   FM_CONFIG_OVERRIDE       config directory override (same contract as other scripts)
#   FM_HOME / FM_ROOT_OVERRIDE  home and code-root resolution (same contract as other scripts)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
API_BASE="${FM_GITHUB_APP_API_BASE:-https://api.github.com}"
API_BASE=${API_BASE%/}

die() {
  printf 'error: fm-github-app-token: %s\n' "$1" >&2
  exit 1
}

not_configured() {
  exit 2
}

# Read one config value: first non-empty, non-comment line, trailing CR stripped.
# Prints nothing and returns 1 when the file is absent, unreadable, or empty.
read_config_line() {
  local path=$1 line
  [ -f "$path" ] || return 1
  [ -r "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|\#*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$path"
  return 1
}

require_digits() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# stdin -> base64url without padding (JWT-safe).
b64url_encode() {
  # macOS base64 has no --wrap; GNU base64 defaults to wrapped lines.
  if base64 --help 2>&1 | grep -q -- '--wrap'; then
    base64 --wrap=0 | tr '+/' '-_' | tr -d '='
  else
    base64 | tr -d '\n\r' | tr '+/' '-_' | tr -d '='
  fi
}

# Sign JWT signing-input on stdin with RS256; write base64url signature to stdout.
# The private key path is passed only as openssl's -sign file argument, never as
# key material on argv.
jwt_rs256_sign() {
  local key_path=$1
  openssl dgst -sha256 -sign "$key_path" 2>/dev/null | b64url_encode
}

# shellcheck disable=SC2329 # Invoked only via trap on EXIT/HUP/INT/TERM.
cleanup_temps() {
  # Always return 0: under set -e, a false test in an EXIT trap would replace
  # the script's intended exit status (including the not-configured exit 2).
  if [ -n "${AUTH_HEADER_FILE:-}" ]; then
    rm -f -- "$AUTH_HEADER_FILE" || true
  fi
  if [ -n "${BODY_FILE:-}" ]; then
    rm -f -- "$BODY_FILE" || true
  fi
  return 0
}
AUTH_HEADER_FILE=
BODY_FILE=
trap cleanup_temps EXIT HUP INT TERM

# --- resolve config (absent => not configured) --------------------------------

APP_ID=$(read_config_line "$CONFIG/github-app-id" 2>/dev/null || true)
INSTALLATION_ID=$(read_config_line "$CONFIG/github-app-installation-id" 2>/dev/null || true)
KEY_PATH=$(read_config_line "$CONFIG/github-app-private-key-path" 2>/dev/null || true)

if [ -z "$APP_ID" ] || [ -z "$INSTALLATION_ID" ] || [ -z "$KEY_PATH" ]; then
  not_configured
fi

# Present but invalid is a hard error so a half-configured home cannot silently
# fall back to the captain's identity.
require_digits "$APP_ID" || die "config/github-app-id must be digits only"
require_digits "$INSTALLATION_ID" || die "config/github-app-installation-id must be digits only"

case "$KEY_PATH" in
  /*) ;;
  *) die "config/github-app-private-key-path must be an absolute path" ;;
esac
if [ -L "$KEY_PATH" ]; then
  die "private key path must not be a symlink"
fi
if [ ! -f "$KEY_PATH" ]; then
  die "private key file is missing or not a regular file"
fi
if [ ! -r "$KEY_PATH" ]; then
  die "private key file is not readable"
fi

command -v openssl >/dev/null 2>&1 || die "openssl is required to sign the App JWT"
command -v curl >/dev/null 2>&1 || die "curl is required to mint an installation token"
command -v base64 >/dev/null 2>&1 || die "base64 is required to encode the App JWT"
command -v jq >/dev/null 2>&1 || die "jq is required to parse the installation token response"

# --- build App JWT (iss=app id, iat=now-60, exp<=now+10m) ---------------------

now=$(date +%s)
iat=$((now - 60))
exp=$((now + 540))

header_json='{"alg":"RS256","typ":"JWT"}'
payload_json=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$exp" "$APP_ID")

header_b64=$(printf '%s' "$header_json" | b64url_encode) || die "failed to encode JWT header"
payload_b64=$(printf '%s' "$payload_json" | b64url_encode) || die "failed to encode JWT payload"
signing_input="${header_b64}.${payload_b64}"

sig_b64=$(printf '%s' "$signing_input" | jwt_rs256_sign "$KEY_PATH") || die "failed to sign App JWT (bad private key?)"
[ -n "$sig_b64" ] || die "failed to sign App JWT (empty signature)"

jwt="${signing_input}.${sig_b64}"
# jwt is held only in this shell; it never goes on argv below.

# --- mint installation access token ------------------------------------------

AUTH_HEADER_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-gh-app-auth.XXXXXX") \
  || die "could not create private auth header file"
chmod 600 "$AUTH_HEADER_FILE" 2>/dev/null || die "could not restrict auth header file mode"
printf 'Authorization: Bearer %s\n' "$jwt" > "$AUTH_HEADER_FILE" \
  || die "could not write auth header file"
# Drop the JWT from shell memory as soon as the header file holds it.
jwt=

BODY_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-gh-app-body.XXXXXX") \
  || die "could not create private response body file"
chmod 600 "$BODY_FILE" 2>/dev/null || true

url="${API_BASE}/app/installations/${INSTALLATION_ID}/access_tokens"
# Header file keeps the JWT out of argv; empty JSON body is the documented form.
http_code=$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
  -X POST \
  -H @"$AUTH_HEADER_FILE" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H 'Content-Type: application/json' \
  -d '{}' \
  -- "$url" 2>/dev/null) || die "installation token request failed (network or curl error)"

# Auth header is no longer needed once the request completed.
rm -f -- "$AUTH_HEADER_FILE"
AUTH_HEADER_FILE=

case "$http_code" in
  201)
    ;;
  *)
    # Never dump the body: it may echo request context. Report only the status.
    die "installation token request returned HTTP ${http_code:-unknown}"
    ;;
esac

token=$(jq -r '.token // empty' < "$BODY_FILE" 2>/dev/null) || die "could not parse installation token response"
rm -f -- "$BODY_FILE"
BODY_FILE=

case "$token" in
  '') die "installation token response contained no token" ;;
  *$'\n'*|*$'\r'*) die "installation token response was malformed" ;;
esac

# Success: token alone on stdout. No trailing diagnostics.
printf '%s\n' "$token"
exit 0
