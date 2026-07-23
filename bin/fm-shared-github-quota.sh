#!/usr/bin/env bash
# Coordinate fleet-wide GitHub API quota and cached gh-heavy reads.
# Usage:
#   fm-shared-github-quota.sh check [--provider github] [--account <id>] [--route <name>]
#   fm-shared-github-quota.sh mark [--provider github] [--account <id>] [--route <name>] (--reset-at <iso>|--reset-epoch <n>) [--source <label>]
#   fm-shared-github-quota.sh mark-from-text [--provider github] [--account <id>] [--route <name>] [--source <label>] [--file <path>]
#   fm-shared-github-quota.sh cache-get --key <key> [--provider github] [--account <id>] [--route <name>] [--max-age-secs <n>]
#   fm-shared-github-quota.sh cache-put --key <key> [--provider github] [--account <id>] [--route <name>]
#
# Shared state is intentionally home-independent.
# Override with FM_SHARED_STATE_OVERRIDE in tests or unusual deployments.
set -eu

default_shared_state() {
  printf '%s/firstmate\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

shared_state_root() {
  printf '%s/shared-github-quota\n' "${FM_SHARED_STATE_OVERRIDE:-${FM_SHARED_STATE:-$(default_shared_state)}}"
}

now_epoch() {
  if [ -n "${FM_SHARED_QUOTA_NOW_EPOCH:-}" ]; then
    printf '%s\n' "$FM_SHARED_QUOTA_NOW_EPOCH"
  else
    date +%s
  fi
}

iso_now() {
  node -e 'console.log(new Date().toISOString())'
}

safe_fragment() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.@:-' '_'
}

hash_key() {
  printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "${4:-}" | cksum | awk '{print $1}'
}

quota_file() {  # <provider> <account> <route>
  local root provider=$1 account=$2 route=$3 hash
  root=$(shared_state_root)
  hash=$(hash_key "$provider" "$account" "$route")
  printf '%s/cooldowns/%s-%s.env\n' "$root" "$(safe_fragment "$provider")" "$hash"
}

cache_dir() {  # <provider> <account> <route> <key>
  local root provider=$1 account=$2 route=$3 key=$4 hash
  root=$(shared_state_root)
  hash=$(hash_key "$provider" "$account" "$route" "$key")
  printf '%s/cache/%s-%s\n' "$root" "$(safe_fragment "$provider")" "$hash"
}

account_file() {  # <provider>
  local root provider=$1
  root=$(shared_state_root)
  printf '%s/accounts/%s.env\n' "$root" "$(safe_fragment "$provider")"
}

write_atomic() {  # <path> <content>
  local path=$1 content=$2 dir tmp old_umask
  dir=$(dirname "$path")
  mkdir -p "$dir"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$dir/.tmp.XXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$path"
}

write_stdin_atomic() {  # <path>
  local path=$1 dir tmp old_umask
  dir=$(dirname "$path")
  mkdir -p "$dir"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$dir/.tmp.XXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  cat > "$tmp"
  mv "$tmp" "$path"
}

one_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/[[:cntrl:]]//g'
}

field_value() {  # <file> <field>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

account_valid() {
  case "$1" in
    ''|*[!A-Za-z0-9_.@:-]*) return 1 ;;
  esac
}

remember_account() {  # <provider> <account> <source>
  local provider=$1 account=$2 source=$3 file now content
  account_valid "$account" || return 1
  file=$(account_file "$provider")
  now=$(now_epoch)
  content=$(cat <<EOF
schema=fm-shared-github-account.v1
provider=$provider
account=$account
source=$(one_line "$source")
updated_at=$(iso_now)
updated_epoch=$now
EOF
)
  write_atomic "$file" "$content"
}

cached_account() {  # <provider>
  local provider=$1 file account
  file=$(account_file "$provider")
  [ -f "$file" ] || return 1
  account=$(field_value "$file" account)
  account_valid "$account" || return 1
  printf '%s\n' "$account"
}

derive_account() {  # <provider>
  local provider=$1 account
  [ "$provider" = github ] || return 1
  [ "${FM_SHARED_GITHUB_QUOTA_DERIVE_ACCOUNT:-1}" != 0 ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  account=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh api user --jq .id 2>/dev/null) || return 1
  account_valid "$account" || return 1
  printf '%s\n' "$account"
}

resolve_account() {  # <provider>
  local provider=$1 account
  if [ -n "$ACCOUNT" ]; then
    account_valid "$ACCOUNT" || { echo "error: invalid GitHub account id" >&2; return 2; }
    remember_account "$provider" "$ACCOUNT" env >/dev/null 2>&1 || true
    return 0
  fi
  account=$(cached_account "$provider" 2>/dev/null || true)
  if [ -n "$account" ]; then
    ACCOUNT=$account
    return 0
  fi
  account=$(derive_account "$provider" 2>/dev/null || true)
  if [ -n "$account" ]; then
    ACCOUNT=$account
    remember_account "$provider" "$ACCOUNT" derived >/dev/null 2>&1 || true
    return 0
  fi
  echo "error: --account or FM_GITHUB_ACCOUNT_ID required; could not derive GitHub account id" >&2
  return 2
}

parse_reset_epoch() {  # <reset-at-or-epoch>
  RESET_RAW=$1 node <<'NODE'
const raw = (process.env.RESET_RAW || "").trim();
if (/^[0-9]+$/.test(raw)) {
  console.log(raw);
  process.exit(0);
}
let s = raw;
let ms = Date.parse(s);
if (!Number.isFinite(ms)) {
  const m = raw.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})\s+UTC$/i);
  if (m) ms = Date.parse(`${m[1]}T${m[2]}Z`);
}
if (!Number.isFinite(ms)) process.exit(1);
console.log(Math.floor(ms / 1000));
NODE
}

epoch_to_iso() {  # <epoch>
  RESET_EPOCH=$1 node <<'NODE'
const epoch = Number(process.env.RESET_EPOCH || 0);
if (!Number.isFinite(epoch) || epoch <= 0) process.exit(1);
console.log(new Date(epoch * 1000).toISOString().replace(/\.000Z$/, "Z"));
NODE
}

extract_github_rate_limit() {  # <text>
  FM_GITHUB_QUOTA_TEXT=$1 node <<'NODE'
const text = process.env.FM_GITHUB_QUOTA_TEXT || "";
if (!/rate[- ]?limit/i.test(text)) process.exit(1);
let account = "";
for (const re of [
  /(?:user|account)(?:\s+id)?\s*[:#]?\s*([0-9]{4,})/i,
  /\b([0-9]{6,})\b/,
]) {
  const m = text.match(re);
  if (m) { account = m[1]; break; }
}
let resetAt = "";
for (const re of [
  /(20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)/i,
  /(20\d\d-\d\d-\d\d[ T]\d\d:\d\d:\d\d\s+UTC)/i,
]) {
  const m = text.match(re);
  if (m) { resetAt = m[1]; break; }
}
if (!account || !resetAt) process.exit(1);
let ms = Date.parse(resetAt);
if (!Number.isFinite(ms)) {
  const m = resetAt.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})\s+UTC$/i);
  if (m) ms = Date.parse(`${m[1]}T${m[2]}Z`);
}
if (!Number.isFinite(ms)) process.exit(1);
console.log(`account=${account}`);
console.log(`reset_at=${new Date(ms).toISOString().replace(/\.000Z$/, "Z")}`);
console.log(`reset_epoch=${Math.floor(ms / 1000)}`);
NODE
}

mark_quota() {
  local provider=$1 account=$2 route=$3 reset_epoch=$4 reset_at=$5 source=$6 file now content
  case "$reset_epoch" in ''|*[!0-9]*) echo "error: reset epoch must be numeric" >&2; return 2 ;; esac
  now=$(now_epoch)
  if [ "$reset_epoch" -le "$now" ]; then
    echo "error: reset epoch is not in the future" >&2
    return 2
  fi
  file=$(quota_file "$provider" "$account" "$route")
  content=$(cat <<EOF
schema=fm-shared-github-quota.v1
provider=$provider
account=$account
route=$route
class=quota
reason=github_rate_limit
created_at=$(iso_now)
created_epoch=$now
reset_at=$reset_at
reset_epoch=$reset_epoch
source=$(one_line "$source")
EOF
)
  write_atomic "$file" "$content"
  printf '%s\n' "$file"
}

check_quota() {
  local provider=$1 account=$2 route=$3 file reset_epoch now remaining
  file=$(quota_file "$provider" "$account" "$route")
  if [ ! -f "$file" ]; then
    printf 'state=allow\nprovider=%s\naccount=%s\nroute=%s\n' "$provider" "$account" "$route"
    return 0
  fi
  reset_epoch=$(field_value "$file" reset_epoch)
  case "$reset_epoch" in
    ''|*[!0-9]*)
      rm -f "$file"
      printf 'state=allow\nprovider=%s\naccount=%s\nroute=%s\nexpired_record=invalid\n' "$provider" "$account" "$route"
      return 0
      ;;
  esac
  now=$(now_epoch)
  if [ "$reset_epoch" -le "$now" ]; then
    rm -f "$file"
    printf 'state=allow\nprovider=%s\naccount=%s\nroute=%s\nexpired_reset_epoch=%s\n' "$provider" "$account" "$route" "$reset_epoch"
    return 0
  fi
  remaining=$((reset_epoch - now))
  printf 'state=defer\n'
  cat "$file"
  printf 'remaining_secs=%s\n' "$remaining"
}

cache_get() {
  local provider=$1 account=$2 route=$3 key=$4 max_age=$5 dir meta body created now age
  case "$max_age" in ''|*[!0-9]*) echo "error: --max-age-secs must be numeric" >&2; return 2 ;; esac
  dir=$(cache_dir "$provider" "$account" "$route" "$key")
  meta="$dir/meta.env"
  body="$dir/body"
  [ -f "$meta" ] && [ -f "$body" ] || return 1
  created=$(field_value "$meta" created_epoch)
  case "$created" in ''|*[!0-9]*) rm -rf "$dir"; return 1 ;; esac
  now=$(now_epoch)
  age=$((now - created))
  if [ "$age" -gt "$max_age" ]; then
    rm -rf "$dir"
    return 1
  fi
  cat "$body"
}

cache_put() {
  local provider=$1 account=$2 route=$3 key=$4 dir now meta_content
  dir=$(cache_dir "$provider" "$account" "$route" "$key")
  now=$(now_epoch)
  mkdir -p "$dir"
  write_stdin_atomic "$dir/body"
  meta_content=$(cat <<EOF
schema=fm-shared-github-cache.v1
provider=$provider
account=$account
route=$route
key=$(one_line "$key")
created_at=$(iso_now)
created_epoch=$now
EOF
)
  write_atomic "$dir/meta.env" "$meta_content"
}

usage() {
  sed -n '2,10p' "$0" >&2
}

need_value() {
  [ "$#" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift || true

PROVIDER=github
ACCOUNT=${FM_GITHUB_ACCOUNT_ID:-}
ROUTE=${FM_GITHUB_ROUTE:-default}
RESET_AT=
RESET_EPOCH=
SOURCE=manual
FILE=
KEY=
MAX_AGE_SECS=60

while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) need_value "$@"; PROVIDER=$2; shift 2 ;;
    --provider=*) PROVIDER=${1#--provider=}; shift ;;
    --account) need_value "$@"; ACCOUNT=$2; shift 2 ;;
    --account=*) ACCOUNT=${1#--account=}; shift ;;
    --route) need_value "$@"; ROUTE=$2; shift 2 ;;
    --route=*) ROUTE=${1#--route=}; shift ;;
    --reset-at) need_value "$@"; RESET_AT=$2; shift 2 ;;
    --reset-at=*) RESET_AT=${1#--reset-at=}; shift ;;
    --reset-epoch) need_value "$@"; RESET_EPOCH=$2; shift 2 ;;
    --reset-epoch=*) RESET_EPOCH=${1#--reset-epoch=}; shift ;;
    --source) need_value "$@"; SOURCE=$2; shift 2 ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    --file) need_value "$@"; FILE=$2; shift 2 ;;
    --file=*) FILE=${1#--file=}; shift ;;
    --key) need_value "$@"; KEY=$2; shift 2 ;;
    --key=*) KEY=${1#--key=}; shift ;;
    --max-age-secs) need_value "$@"; MAX_AGE_SECS=$2; shift 2 ;;
    --max-age-secs=*) MAX_AGE_SECS=${1#--max-age-secs=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

case "$cmd" in
  check)
    resolve_account "$PROVIDER" || exit $?
    check_quota "$PROVIDER" "$ACCOUNT" "$ROUTE"
    ;;
  mark)
    resolve_account "$PROVIDER" || exit $?
    if [ -z "$RESET_EPOCH" ]; then
      [ -n "$RESET_AT" ] || { echo "error: mark requires --reset-at or --reset-epoch" >&2; exit 2; }
      RESET_EPOCH=$(parse_reset_epoch "$RESET_AT") || { echo "error: could not parse --reset-at" >&2; exit 2; }
    fi
    [ -n "$RESET_AT" ] || RESET_AT=$(epoch_to_iso "$RESET_EPOCH")
    mark_quota "$PROVIDER" "$ACCOUNT" "$ROUTE" "$RESET_EPOCH" "$RESET_AT" "$SOURCE"
    ;;
  mark-from-text)
    if [ -n "$FILE" ]; then
      TEXT=$(cat "$FILE")
    else
      TEXT=$(cat)
    fi
    EXTRACTED=$(extract_github_rate_limit "$TEXT") || { echo "error: no GitHub rate-limit reset/account found" >&2; exit 1; }
    EXTRACTED_ACCOUNT=$(printf '%s\n' "$EXTRACTED" | sed -n 's/^account=//p' | tail -1)
    [ -n "$ACCOUNT" ] || ACCOUNT=$EXTRACTED_ACCOUNT
    resolve_account "$PROVIDER" || exit $?
    RESET_AT=$(printf '%s\n' "$EXTRACTED" | sed -n 's/^reset_at=//p' | tail -1)
    RESET_EPOCH=$(printf '%s\n' "$EXTRACTED" | sed -n 's/^reset_epoch=//p' | tail -1)
    printf 'provider=%s\naccount=%s\nroute=%s\nreset_at=%s\nreset_epoch=%s\n' "$PROVIDER" "$ACCOUNT" "$ROUTE" "$RESET_AT" "$RESET_EPOCH"
    mark_quota "$PROVIDER" "$ACCOUNT" "$ROUTE" "$RESET_EPOCH" "$RESET_AT" "$SOURCE" >/dev/null
    ;;
  cache-get)
    [ -n "$KEY" ] || { echo "error: cache-get requires --key" >&2; exit 2; }
    resolve_account "$PROVIDER" || exit $?
    cache_get "$PROVIDER" "$ACCOUNT" "$ROUTE" "$KEY" "$MAX_AGE_SECS"
    ;;
  cache-put)
    [ -n "$KEY" ] || { echo "error: cache-put requires --key" >&2; exit 2; }
    resolve_account "$PROVIDER" || exit $?
    cache_put "$PROVIDER" "$ACCOUNT" "$ROUTE" "$KEY"
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage
    exit 2
    ;;
esac
