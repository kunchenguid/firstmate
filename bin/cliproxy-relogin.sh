#!/usr/bin/env bash
# cliproxy-relogin.sh - the operator helper for one re-login session on the
# Claude account pool behind CLIProxyAPI, and for adding the Codex login.
#
# Usage:
#   cliproxy-relogin.sh [options]                 walk every registry account in order
#   cliproxy-relogin.sh --accounts a@x,b@y        walk only these accounts, in this order
#   cliproxy-relogin.sh --add codex               run CLIProxyAPI's own Codex OAuth login
#   cliproxy-relogin.sh --dry-run                 print the plan and change nothing
#   cliproxy-relogin.sh --help                    print this help
#
# Options:
#   --auth-dir DIR      credential directory (default ~/.cli-proxy-api)
#   --registry FILE     login-date registry (default <home>/config/cliproxy-login-registry.json)
#   --proxy URL         proxy base URL for the verification request (default http://127.0.0.1:8317)
#   --probe-model ID    model used for the one verification request
#                       (default claude-haiku-4-5-20251001; pass a model the proxy lists
#                       on GET /v1/models when the default is not in this deployment)
#   --api-key KEY       client API key for the verification request; read from the
#                       proxy config's first api-keys entry when omitted
#   --api-key-file FILE read that key from FILE instead
#   --timeout SECS      per-account approval wait (default 600)
#
# WHAT IT DOES, ONE ACCOUNT AT A TIME, IN ORDER. It starts `claude setup-token`,
# relays the approval URL it prints, waits for the token it prints back, then
# writes a setup-token credential into the auth dir by rename. The token is never
# echoed, never passed on a command line, and never written outside a 0600 file.
# After the FIRST account it sends exactly one real request through the proxy and
# stops before the remaining accounts if that request fails: the point of the
# first account is to prove this build accepts a setup token at all, and nine
# more human approvals spent on an unproven path is the failure mode to avoid.
#
# The superseded 30-day credential for an account is archived, never deleted, and
# only after the replacement is in place and (for the first account) proven. The
# dated archive lives OUTSIDE the auth dir, because a future CLIProxyAPI that
# walks subdirectories must never load a retired credential.
#
# WHAT THE VERIFICATION DOES AND DOES NOT PROVE. The proxy routes round-robin, so
# one request proves the proxy still serves and that the freshly written
# credential did not break the pool. It does not pin the request to that
# account, and this deployment has no per-credential endpoint to ask. Verify
# every account that matters by sending real traffic, and let
# bin/fm-cliproxy-expiry-check.sh carry the calendar deadline.
#
# THE REGISTRY. Each written account's login date is recorded in
# FM_CLIPROXY_LOGIN_REGISTRY, because the login date is not stored in a
# CLIProxyAPI auth file and the age alarm cannot measure what is not written
# down. A re-login that skips the registry silently disables that half of the
# alarm, so the write goes through bin/cliproxy-creds-lib.sh, never by hand.
#
# Environment:
#   FM_CLIPROXY_CLAUDE_BIN    the Claude Code CLI (default `claude`)
#   FM_CLIPROXY_BIN           the CLIProxyAPI binary (default `cli-proxy-api`, then
#                             ~/.local/bin/cli-proxy-api) used for --add codex
#   FM_CLIPROXY_CONFIG        CLIProxyAPI config (default ~/.config/cliproxyapi/config.yaml)
#   FM_CLIPROXY_AUTH_DIR      as --auth-dir
#   FM_CLIPROXY_ARCHIVE_ROOT  archive root (default ~/.cli-proxy-api-archive)
#   FM_CLIPROXY_LOGIN_REGISTRY as --registry
#   FM_CLIPROXY_TIMEOUT_SECS  as --timeout
#
# Distribution note: the helper lives in bin/ as cliproxy-relogin.sh so it is part
# of the linted shell set (bin/*.sh). docs/scripts.md lists it.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/cliproxy-creds-lib.sh
. "$SCRIPT_DIR/cliproxy-creds-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'cliproxy-relogin: %s\n' "$1" >&2
  exit 2
}

AUTH_DIR=
REGISTRY_OVERRIDE=
PROXY_URL=http://127.0.0.1:8317
PROBE_MODEL=${FM_CLIPROXY_PROBE_MODEL:-claude-haiku-4-5-20251001}
API_KEY=${CLIPROXY_API_KEY:-}
API_KEY_FILE=
TIMEOUT_SECS=${FM_CLIPROXY_TIMEOUT_SECS:-600}
ACCOUNTS=
DRY_RUN=0
ADD_CODEX=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --auth-dir) [ "$#" -ge 2 ] || die "--auth-dir needs a value"; AUTH_DIR=$2; shift 2 ;;
    --registry) [ "$#" -ge 2 ] || die "--registry needs a value"; REGISTRY_OVERRIDE=$2; shift 2 ;;
    --proxy) [ "$#" -ge 2 ] || die "--proxy needs a value"; PROXY_URL=${2%/}; shift 2 ;;
    --probe-model) [ "$#" -ge 2 ] || die "--probe-model needs a value"; PROBE_MODEL=$2; shift 2 ;;
    --api-key) [ "$#" -ge 2 ] || die "--api-key needs a value"; API_KEY=$2; shift 2 ;;
    --api-key-file) [ "$#" -ge 2 ] || die "--api-key-file needs a value"; API_KEY_FILE=$2; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; TIMEOUT_SECS=$2; shift 2 ;;
    --accounts) [ "$#" -ge 2 ] || die "--accounts needs a value"; ACCOUNTS=$2; shift 2 ;;
    --add) [ "$#" -ge 2 ] || die "--add needs a provider"; [ "$2" = codex ] || die "only --add codex is supported"; ADD_CODEX=1; shift 2 ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$TIMEOUT_SECS" in ''|*[!0-9]*|0) die "--timeout must be a positive whole number of seconds" ;; esac

[ -z "$AUTH_DIR" ] || FM_CLIPROXY_AUTH_DIR=$AUTH_DIR
[ -z "$REGISTRY_OVERRIDE" ] || FM_CLIPROXY_LOGIN_REGISTRY=$REGISTRY_OVERRIDE
export FM_CLIPROXY_AUTH_DIR FM_CLIPROXY_LOGIN_REGISTRY

AUTH_DIR=$(cliproxy_auth_dir)
REGISTRY=$(cliproxy_login_registry)
CLAUDE_BIN=${FM_CLIPROXY_CLAUDE_BIN:-claude}
PROXY_CONFIG=${FM_CLIPROXY_CONFIG:-$HOME/.config/cliproxyapi/config.yaml}
PROXY_BIN=${FM_CLIPROXY_BIN:-}
if [ -z "$PROXY_BIN" ]; then
  if command -v cli-proxy-api >/dev/null 2>&1; then
    PROXY_BIN=cli-proxy-api
  else
    PROXY_BIN=$HOME/.local/bin/cli-proxy-api
  fi
fi

URL_RE='https://[A-Za-z0-9./?=_%:&+#-]*'
TOKEN_RE='sk-ant-oat01-[A-Za-z0-9_-]+'

say() { printf '%s\n' "$*"; }

# The account list: explicit --accounts in the given order, else the registry's
# own key order so a re-login walks the pool the way it was recorded.
account_list() {
  if [ -n "$ACCOUNTS" ]; then
    printf '%s\n' "$ACCOUNTS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
    return 0
  fi
  python3 - "$REGISTRY" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except (OSError, ValueError):
    data = {}
if not isinstance(data, dict):
    data = {}
for key in data:
    if not key.startswith("_"):
        print(key)
PY
}

# proxy_api_key: read the first api-keys entry from the proxy config, never echoing it.
proxy_api_key() {
  local key
  if [ -n "$API_KEY" ]; then
    printf '%s\n' "$API_KEY"
    return 0
  fi
  if [ -n "$API_KEY_FILE" ]; then
    [ -r "$API_KEY_FILE" ] || return 1
    tr -d '\r\n' < "$API_KEY_FILE"
    return 0
  fi
  key=$(awk '
    /^api-keys:/ { inlist = 1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/"/, ""); print; exit }
    inlist && /^[^[:space:]-]/ { exit }
  ' "$PROXY_CONFIG" 2>/dev/null)
  [ -n "$key" ] || return 1
  printf '%s\n' "$key"
}

# verify_proxy: one real request through the proxy. Prints a diagnosis, never a secret.
verify_proxy() {
  local key code body
  key=$(proxy_api_key) || {
    say "  verification: no client API key found (pass --api-key, --api-key-file, or CLIPROXY_API_KEY)"
    return 1
  }
  body=$(mktemp "${TMPDIR:-/tmp}/cliproxy-verify.XXXXXX") || return 1
  code=$(curl -sS -o "$body" -w '%{http_code}' -m 60 \
    -X POST "$PROXY_URL/v1/messages" \
    -H "x-api-key: $key" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    --data-binary "{\"model\":\"$PROBE_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}" \
    2>/dev/null)
  if [ "$code" = 200 ]; then
    rm -f -- "$body"
    say "  verification: one request through $PROXY_URL with $PROBE_MODEL answered 200"
    return 0
  fi
  say "  verification: $PROXY_URL answered HTTP ${code:-none} for $PROBE_MODEL"
  case "$code" in
    401|403) say "  verification: the proxy rejected the client API key, so this proves nothing about the new credential" ;;
    404|400) say "  verification: $PROBE_MODEL is probably not a model this deployment lists; re-run with --probe-model <id> from GET /v1/models" ;;
    *) say "  verification: $(head -c 300 "$body" 2>/dev/null | tr '\n' ' ')" ;;
  esac
  rm -f -- "$body"
  return 1
}

# wait_for <file> <pattern> <seconds>: echo the first match, polling the file.
wait_for() {
  local file=$1 pattern=$2 limit=$3 waited=0 value=
  while [ "$waited" -lt "$limit" ]; do
    value=$(grep -oE "$pattern" "$file" 2>/dev/null | head -1)
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# superseded_files <email>: the OAuth credentials this replacement retires.
superseded_files() {
  local email=$1 path
  for path in "$AUTH_DIR"/claude-*.json; do
    [ -f "$path" ] || continue
    [ "$(basename -- "$path")" = "claude-setup-$(cliproxy_email_slug "$email").json" ] && continue
    if python3 - "$path" "$email" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
if data.get("is_setup_token") or not data.get("refresh_token"):
    sys.exit(1)
if str(data.get("email") or "").strip().lower() != sys.argv[2].strip().lower():
    sys.exit(1)
PY
    then
      printf '%s\n' "$path"
    fi
  done
}

relogin_one() {  # <email> <index> <total>
  local email=$1 index=$2 total=$3 out url token dest expired archived path
  local slug pid waited
  slug=$(cliproxy_email_slug "$email")
  dest="$AUTH_DIR/claude-setup-$slug.json"
  expired=$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v+1y +%Y-%m-%dT%H:%M:%SZ)

  if [ "$DRY_RUN" = 1 ]; then
    say "[$index/$total] $email"
    say "  would run: $CLAUDE_BIN setup-token"
    say "  would write: $dest (setup token, expires $expired, mode 0600, by rename)"
    say "  would record login date in: $REGISTRY"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      say "  would archive after success: $path"
    done < <(superseded_files "$email")
    return 0
  fi

  say "[$index/$total] $email"
  out=$(mktemp "${TMPDIR:-/tmp}/cliproxy-relogin.XXXXXX") || return 1
  "$CLAUDE_BIN" setup-token >"$out" 2>&1 &
  pid=$!
  if ! url=$(wait_for "$out" "$URL_RE" 60); then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f -- "$out"
    say "  the Claude CLI printed no approval URL within 60s; run \`$CLAUDE_BIN setup-token\` by hand to see why"
    return 1
  fi
  say "  open this URL and approve it while signed in as $email:"
  say "    $url"
  say "  waiting up to ${TIMEOUT_SECS}s for the token..."
  waited=0
  token=
  while [ "$waited" -lt "$TIMEOUT_SECS" ]; do
    token=$(grep -oE "$TOKEN_RE" "$out" 2>/dev/null | head -1)
    [ -n "$token" ] && break
    if ! kill -0 "$pid" 2>/dev/null; then
      token=$(grep -oE "$TOKEN_RE" "$out" 2>/dev/null | head -1)
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
  if [ -z "$token" ]; then
    say "  no token was printed for $email; the approval was not completed or was rejected"
    say "  the CLI's last words (no token can appear here):"
    grep -vE "$TOKEN_RE" "$out" 2>/dev/null | tail -5 | sed 's/^/    /'
    rm -f -- "$out"
    return 1
  fi
  rm -f -- "$out"

  (umask 077; mkdir -p "$AUTH_DIR") || return 1
  json=$(printf '%s' "$token" | cliproxy_json_setup_token "$email" "$expired") || {
    token=
    say "  could not build the credential for $email; nothing was written"
    return 1
  }
  token=
  if ! printf '%s\n' "$json" | cliproxy_atomic_write "$dest"; then
    say "  could not write $dest"
    return 1
  fi
  json=
  say "  wrote $dest (expires $expired)"

  if [ "$index" = 1 ]; then
    if ! verify_proxy; then
      archived=$(cliproxy_archive_move "$dest" "unverified credential archived") || archived=
      say "  stopped after the first account: a setup token did not pass one real request."
      say "  ${archived:+moved the unverified credential to $archived; }the 30-day credentials are untouched."
      return 1
    fi
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    archived=$(cliproxy_archive_move "$path") || { say "  could not archive $path"; return 1; }
    say "  archived the superseded credential to $archived"
  done < <(superseded_files "$email")

  if ! cliproxy_registry_set "$email" "$(date -u +%Y-%m-%d)"; then
    say "  wrote the credential but could not record the login date in $REGISTRY"
    return 1
  fi
  say "  recorded the login date for $email"
  return 0
}

add_codex() {
  [ -x "$PROXY_BIN" ] || command -v "$PROXY_BIN" >/dev/null 2>&1 \
    || die "CLIProxyAPI binary not found at $PROXY_BIN (set FM_CLIPROXY_BIN)"
  [ -r "$PROXY_CONFIG" ] || die "CLIProxyAPI config not readable at $PROXY_CONFIG (set FM_CLIPROXY_CONFIG)"
  if [ "$DRY_RUN" = 1 ]; then
    say "would run: $PROXY_BIN -codex-login -no-browser -config $PROXY_CONFIG"
    say "  CLIProxyAPI performs the Codex OAuth flow itself and writes its codex-*.json into $AUTH_DIR"
    return 0
  fi
  say "starting the Codex login through $PROXY_BIN; approve the URL it prints"
  "$PROXY_BIN" -codex-login -no-browser -config "$PROXY_CONFIG"
  return $?
}

if [ "$ADD_CODEX" = 1 ]; then
  add_codex
  exit $?
fi

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || [ -x "$CLAUDE_BIN" ] \
  || die "$CLAUDE_BIN not found on PATH (set FM_CLIPROXY_CLAUDE_BIN)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

emails=()
while IFS= read -r email; do
  [ -n "$email" ] && emails+=("$email")
done < <(account_list)
if [ "${#emails[@]}" -eq 0 ]; then
  die "no accounts: $REGISTRY lists none, and no --accounts was given"
fi

total=${#emails[@]}
say "CLIProxyAPI pool re-login: $total account(s), auth dir $AUTH_DIR"
[ "$DRY_RUN" = 0 ] || say "(dry run: nothing will be started, written, or archived)"
index=0
for email in "${emails[@]:-}"; do
  index=$((index + 1))
  if ! relogin_one "$email" "$index" "$total"; then
    say ""
    say "stopped at account $index of $total ($email)."
    exit 1
  fi
done
say ""
if [ "$DRY_RUN" = 1 ]; then
  say "dry run complete: $total account(s) planned, nothing changed"
else
  say "done: $total account(s) re-logged in, login dates recorded in $REGISTRY"
  say "the expiry alarm keeps watching the calendar; add the Codex login with --add codex if this deployment needs one"
fi
