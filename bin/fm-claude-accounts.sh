#!/usr/bin/env bash
# Manage firstmate's native Claude Code OAuth account rotation.
# Usage:
#   fm-claude-accounts.sh list
#   fm-claude-accounts.sh select
#   fm-claude-accounts.sh exec <account-id|email|file> -- <command> [args...]
#   fm-claude-accounts.sh token <account-id|email|file>
#   fm-claude-accounts.sh cool <account-id|email|file> [seconds]
#
# Account files default to ~/.cli-proxy-api/claude-*.json and can be overridden
# with FM_CLAUDE_ACCOUNT_DIR. The rotation state dir defaults to firstmate's
# state/ and can be overridden with FM_CLAUDE_ROTATION_STATE_DIR.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_CLAUDE_ROTATION_STATE_DIR:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"
ACCOUNT_DIR="${FM_CLAUDE_ACCOUNT_DIR:-$HOME/.cli-proxy-api}"
POLICY="${FM_CLAUDE_ROTATION_POLICY:-round-robin}"
REFRESH_MARGIN_SECONDS="${FM_CLAUDE_REFRESH_MARGIN_SECONDS:-300}"
COOLDOWN_SECONDS="${FM_CLAUDE_ROTATION_COOLDOWN_SECONDS:-1800}"
REFRESH_URL="${FM_CLAUDE_REFRESH_URL:-https://claude.ai/v1/oauth/token}"
REFRESH_CLIENT_ID="${FM_CLAUDE_REFRESH_CLIENT_ID:-https://claude.ai/oauth/claude-code-client-metadata}"
REFRESH_BETA="${FM_CLAUDE_REFRESH_BETA:-oauth-2025-04-20}"

usage() {
  sed -n '2,12p' "$0" >&2
}

need_jq() {
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required for Claude account rotation" >&2; exit 1; }
}

now_epoch() {
  date +%s
}

iso_now() {
  node -e 'console.log(new Date().toISOString())'
}

expiry_to_epoch() {
  local raw=$1
  [ -n "$raw" ] && [ "$raw" != null ] || { printf '0\n'; return; }
  node - "$raw" <<'NODE'
const raw = process.argv[2];
let ms = 0;
if (/^[0-9]+$/.test(raw)) {
  const n = Number(raw);
  ms = n > 100000000000 ? n : n * 1000;
} else {
  ms = Date.parse(raw);
}
if (!Number.isFinite(ms) || ms <= 0) ms = 0;
console.log(Math.floor(ms / 1000));
NODE
}

response_expiry_iso() {
  local response=$1
  node - "$response" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const j = JSON.parse(fs.readFileSync(path, "utf8"));
let ms = 0;
if (j.expires_at != null && String(j.expires_at).match(/^[0-9]+$/)) {
  const n = Number(j.expires_at);
  ms = n > 100000000000 ? n : n * 1000;
} else if (j.expiresAt != null && String(j.expiresAt).match(/^[0-9]+$/)) {
  const n = Number(j.expiresAt);
  ms = n > 100000000000 ? n : n * 1000;
} else if (j.expired != null) {
  ms = Date.parse(String(j.expired));
} else if (j.expires_in != null) {
  ms = Date.now() + Number(j.expires_in) * 1000;
}
if (!Number.isFinite(ms) || ms <= 0) {
  ms = Date.now() + 3600 * 1000;
}
console.log(new Date(ms).toISOString());
NODE
}

redact_token() {
  local token=${1:-} len
  [ -n "$token" ] || { printf '[empty]\n'; return; }
  len=${#token}
  if [ "$len" -le 12 ]; then
    printf '[redacted]\n'
  else
    printf '%s...%s\n' "${token:0:11}" "${token: -4}"
  fi
}

safe_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.@-' '_'
}

account_id_for_file() {
  local file=$1 base
  base=${file##*/}
  base=${base%.json}
  printf '%s\n' "$base"
}

account_email() {
  jq -r '.email // .identity // .account // empty' "$1"
}

account_type() {
  jq -r '.type // "claude"' "$1"
}

account_disabled() {
  jq -r 'if (.disabled // false) then "true" else "false" end' "$1"
}

account_access_token() {
  jq -r '.access_token // .accessToken // empty' "$1"
}

account_refresh_token() {
  jq -r '.refresh_token // .refreshToken // empty' "$1"
}

account_expiry_epoch() {
  local raw
  raw=$(jq -r '.expired // .expiresAt // .expires_at // .expires // empty' "$1")
  expiry_to_epoch "$raw"
}

account_files() {
  local file
  [ -d "$ACCOUNT_DIR" ] || return 0
  shopt -s nullglob
  for file in "$ACCOUNT_DIR"/claude-*.json; do
    [ -f "$file" ] || continue
    printf '%s\n' "$file"
  done
  shopt -u nullglob
}

find_account_file() {
  local needle=${1:-} file id email
  [ -n "$needle" ] || return 1
  if [ -f "$needle" ]; then
    printf '%s\n' "$needle"
    return 0
  fi
  while IFS= read -r file; do
    id=$(account_id_for_file "$file")
    email=$(account_email "$file")
    case "$needle" in
      "$id"|"$email"|"$file")
        printf '%s\n' "$file"
        return 0
        ;;
    esac
  done < <(account_files)
  return 1
}

account_is_usable() {
  local file=$1 access type disabled
  type=$(account_type "$file")
  [ "$type" = claude ] || return 1
  disabled=$(account_disabled "$file")
  [ "$disabled" = false ] || return 1
  access=$(account_access_token "$file")
  [ -n "$access" ] || return 1
}

cooling_dir() {
  printf '%s\n' "$STATE/.claude-rotation-cooling"
}

cooling_file_for_id() {
  local id
  id=$(safe_id "$1")
  printf '%s/%s\n' "$(cooling_dir)" "$id"
}

account_is_cooling() {
  local id=$1 file until now
  file=$(cooling_file_for_id "$id")
  [ -f "$file" ] || return 1
  until=$(cat "$file" 2>/dev/null || true)
  case "$until" in
    ''|*[!0-9]*)
      rm -f "$file"
      return 1
      ;;
  esac
  now=$(now_epoch)
  if [ "$until" -gt "$now" ]; then
    return 0
  fi
  rm -f "$file"
  return 1
}

write_text_atomic() {
  local path=$1 value=$2 dir tmp old_umask
  dir=$(dirname "$path")
  mkdir -p "$dir"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$dir/.tmp.XXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  printf '%s\n' "$value" > "$tmp"
  mv "$tmp" "$path"
}

lock_for_account() {
  local id=$1
  printf '%s/%s.lock\n' "$STATE/.claude-rotation-locks" "$(safe_id "$id")"
}

account_needs_refresh() {
  local file=$1 expiry now
  expiry=$(account_expiry_epoch "$file")
  [ "$expiry" -gt 0 ] || return 1
  now=$(now_epoch)
  [ "$expiry" -le $((now + REFRESH_MARGIN_SECONDS)) ]
}

refresh_account_unlocked() {
  local file=$1 id email refresh request response tmp dir old_umask expired_iso now_iso
  id=$(account_id_for_file "$file")
  email=$(account_email "$file")
  refresh=$(account_refresh_token "$file")
  [ -n "$refresh" ] || { echo "warning: claude account ${email:-$id} is near expiry but has no refresh token" >&2; return 1; }

  dir=$(dirname "$file")
  old_umask=$(umask)
  umask 077
  request=$(mktemp "$dir/.${id}.refresh-request.XXXXXXXX") || { umask "$old_umask"; return 1; }
  response=$(mktemp "$dir/.${id}.refresh-response.XXXXXXXX") || { rm -f "$request"; umask "$old_umask"; return 1; }
  tmp=$(mktemp "$dir/.${id}.account.XXXXXXXX") || { rm -f "$request" "$response"; umask "$old_umask"; return 1; }
  umask "$old_umask"

  jq -n --slurpfile account "$file" --arg client_id "$REFRESH_CLIENT_ID" \
    '{grant_type:"refresh_token", refresh_token:$account[0].refresh_token, client_id:$client_id}' > "$request"

  if ! curl -fsS -X POST "$REFRESH_URL" \
    -H 'content-type: application/json' \
    -H "anthropic-beta: $REFRESH_BETA" \
    --data-binary "@$request" \
    -o "$response"; then
    rm -f "$request" "$response" "$tmp"
    echo "warning: refresh failed for claude account ${email:-$id}" >&2
    return 1
  fi

  if ! jq -e '(.access_token // .accessToken // "") != "" and (.refresh_token // .refreshToken // "") != ""' "$response" >/dev/null; then
    rm -f "$request" "$response" "$tmp"
    echo "warning: refresh response for claude account ${email:-$id} did not include a full token pair" >&2
    return 1
  fi

  expired_iso=$(response_expiry_iso "$response")
  now_iso=$(iso_now)
  if ! jq -n --slurpfile account "$file" --slurpfile response "$response" \
    --arg expired "$expired_iso" --arg refreshed "$now_iso" '
      $account[0] as $account |
      $response[0] as $response |
      $account
      | .access_token = ($response.access_token // $response.accessToken)
      | .refresh_token = ($response.refresh_token // $response.refreshToken)
      | if (($response.id_token // $response.idToken // "") != "") then .id_token = ($response.id_token // $response.idToken) else . end
      | .expired = $expired
      | .last_refresh = $refreshed
    ' > "$tmp"; then
    rm -f "$request" "$response" "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$file"
  rm -f "$request" "$response"
}

refresh_account() {
  local file=$1 id lock locked status
  id=$(account_id_for_file "$file")
  mkdir -p "$STATE/.claude-rotation-locks"
  lock=$(lock_for_account "$id")
  locked=0
  for _ in $(seq 1 50); do
    if mkdir "$lock" 2>/dev/null; then
      locked=1
      break
    fi
    sleep 0.1
  done
  [ "$locked" -eq 1 ] || { echo "warning: could not acquire refresh lock for claude account $id" >&2; return 1; }

  status=0
  if account_needs_refresh "$file"; then
    refresh_account_unlocked "$file" || status=$?
  fi
  rmdir "$lock" 2>/dev/null || true
  return "$status"
}

ensure_fresh_account() {
  local file=$1
  if account_needs_refresh "$file"; then
    refresh_account "$file"
  else
    return 0
  fi
}

print_account_record() {
  local file=$1 id email access refresh expiry disabled
  id=$(account_id_for_file "$file")
  email=$(account_email "$file")
  access=$(account_access_token "$file")
  refresh=$(account_refresh_token "$file")
  expiry=$(account_expiry_epoch "$file")
  disabled=$(account_disabled "$file")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "${email:-$id}" "$file" "$expiry" "$disabled" "$(redact_token "$access")" "$(redact_token "$refresh")"
}

cmd_list() {
  local file
  need_jq
  while IFS= read -r file; do
    print_account_record "$file"
  done < <(account_files)
}

candidate_files() {
  local file
  while IFS= read -r file; do
    account_is_usable "$file" || continue
    printf '%s\n' "$file"
  done < <(account_files)
}

cmd_select() {
  local files=() file count cursor start i idx id email out_file status
  need_jq
  mkdir -p "$STATE"
  case "$POLICY" in
    round-robin|first-available) ;;
    *) echo "error: unsupported Claude rotation policy '$POLICY' (expected round-robin or first-available)" >&2; return 1 ;;
  esac

  while IFS= read -r file; do
    files+=("$file")
  done < <(candidate_files)
  count=${#files[@]}
  [ "$count" -gt 0 ] || { echo "warning: no usable Claude account files found in $ACCOUNT_DIR" >&2; return 1; }

  start=0
  cursor=$(cat "$STATE/.claude-rotation-cursor" 2>/dev/null || true)
  if [ "$POLICY" = round-robin ] && [ -n "$cursor" ]; then
    for i in $(seq 0 $((count - 1))); do
      id=$(account_id_for_file "${files[$i]}")
      if [ "$id" = "$cursor" ]; then
        start=$(((i + 1) % count))
        break
      fi
    done
  fi

  for i in $(seq 0 $((count - 1))); do
    if [ "$POLICY" = first-available ]; then
      idx=$i
    else
      idx=$(((start + i) % count))
    fi
    file=${files[$idx]}
    id=$(account_id_for_file "$file")
    email=$(account_email "$file")
    if account_is_cooling "$id"; then
      echo "warning: skipping cooling Claude account ${email:-$id}" >&2
      continue
    fi
    status=0
    ensure_fresh_account "$file" || status=$?
    if [ "$status" -eq 0 ]; then
      if [ "$POLICY" = round-robin ]; then
        write_text_atomic "$STATE/.claude-rotation-cursor" "$id"
      fi
      out_file=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "${email:-$id}" "$out_file" "$POLICY" "$(account_expiry_epoch "$file")"
      return 0
    fi
    echo "warning: trying next Claude account after refresh failure for ${email:-$id}" >&2
  done
  echo "warning: no Claude account was selectable after cooling and refresh checks" >&2
  return 1
}

cmd_token() {
  local file token
  need_jq
  file=$(find_account_file "${1:-}") || { echo "error: unknown Claude account '${1:-}'" >&2; return 1; }
  ensure_fresh_account "$file" || return 1
  token=$(account_access_token "$file")
  [ -n "$token" ] || { echo "error: Claude account has no access token: $(account_id_for_file "$file")" >&2; return 1; }
  printf '%s\n' "$token"
}

cmd_exec() {
  local account=${1:-}
  [ -n "$account" ] || { usage; return 1; }
  shift
  [ "${1:-}" = -- ] || { echo "error: exec requires -- before the command" >&2; return 1; }
  shift
  [ "$#" -gt 0 ] || { echo "error: exec requires a command" >&2; return 1; }
  CLAUDE_CODE_OAUTH_TOKEN=$(cmd_token "$account")
  export CLAUDE_CODE_OAUTH_TOKEN
  exec "$@"
}

cmd_cool() {
  local account=${1:-} seconds=${2:-$COOLDOWN_SECONDS} file id until
  need_jq
  file=$(find_account_file "$account") || { echo "error: unknown Claude account '$account'" >&2; return 1; }
  case "$seconds" in
    ''|*[!0-9]*) echo "error: cooldown seconds must be numeric" >&2; return 1 ;;
  esac
  id=$(account_id_for_file "$file")
  until=$(( $(now_epoch) + seconds ))
  write_text_atomic "$(cooling_file_for_id "$id")" "$until"
  printf '%s\t%s\n' "$id" "$until"
}

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    list) cmd_list "$@" ;;
    select) cmd_select "$@" ;;
    token) cmd_token "$@" ;;
    exec) cmd_exec "$@" ;;
    cool|limit) cmd_cool "$@" ;;
    -h|--help|help|'') usage ;;
    *) echo "error: unknown command '$cmd'" >&2; usage; exit 1 ;;
  esac
}

main "$@"
