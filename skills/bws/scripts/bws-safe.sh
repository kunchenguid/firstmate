#!/usr/bin/env bash
# bws-safe.sh - safe helper for Bitwarden Secrets Manager CLI (bws).
#
# Owned by skills/bws/SKILL.md. Never prints access tokens or secret values.
# Consult `bws --help` and subcommand help for flags; this script does not
# memorize CLI syntax beyond what it needs for safe probes and redaction.
#
# Usage:
#   bws-safe.sh probe
#   bws-safe.sh redact-json
#   bws-safe.sh list-metadata [PROJECT_ID]
#   bws-safe.sh resolve-id <PROJECT_ID> <KEY>
#
# probe prints one sanitized key=value line per fact on stdout:
#   status= unavailable | no_token | invalid_token | authenticated | forbidden | indeterminate
#   version=  bws version or none
#   token_present= yes | no
#
# resolve-id prints exactly one secret UUID on stdout when the key is unique in
# the project; exit 0. Exit 1 when absent, 2 when duplicate names exist, 3 on
# probe or CLI failure. Never prints secret values.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF'
bws-safe.sh - safe helper for Bitwarden Secrets Manager CLI (bws)

Usage:
  bws-safe.sh probe
  bws-safe.sh redact-json
  bws-safe.sh list-metadata [PROJECT_ID]
  bws-safe.sh resolve-id <PROJECT_ID> <KEY>

Never prints access tokens or secret values.
EOF
}

die_usage() {
  printf 'bws-safe: %s\n' "$1" >&2
  usage >&2
  exit 2
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die_usage "jq is required"
}

bws_version() {
  if ! command -v bws >/dev/null 2>&1; then
    printf 'none\n'
    return 0
  fi
  bws --version 2>/dev/null | awk '{print $2; exit}' || printf 'none\n'
}

token_present() {
  if [ -n "${BWS_ACCESS_TOKEN:-}" ]; then
    printf 'yes\n'
    return 0
  fi
  if [ -n "${BWS_PROFILE:-}" ] || [ -f "${BWS_CONFIG_FILE:-$HOME/.config/bws/config}" ]; then
    printf 'yes\n'
    return 0
  fi
  printf 'no\n'
}

classify_bws_stderr() {
  local err=$1
  case "$err" in
    *"Missing access token"*) printf 'no_token\n' ;;
    *"Doesn't contain a decryption key"*|*"401"*) printf 'invalid_token\n' ;;
    *"403"*|*"Forbidden"*|*"forbidden"*)
      printf 'forbidden\n'
      ;;
    *) printf 'indeterminate\n' ;;
  esac
}

run_bws() {
  # shellcheck disable=SC2068
  bws "$@" 2>/dev/null
}

cmd_probe() {
  local version status token stderr
  version=$(bws_version)
  token=$(token_present)
  if [ "$version" = none ]; then
    status=unavailable
    printf 'status=%s version=%s token_present=%s\n' "$status" "$version" "$token"
    exit 0
  fi
  if [ "$token" = no ]; then
    status=no_token
    printf 'status=%s version=%s token_present=%s\n' "$status" "$version" "$token"
    exit 0
  fi
  stderr=$(mktemp)
  chmod 600 "$stderr"
  if bws project list -o none > /dev/null 2>"$stderr"; then
    status=authenticated
  else
    status=$(classify_bws_stderr "$(<"$stderr")")
  fi
  rm -f "$stderr"
  printf 'status=%s version=%s token_present=%s\n' "$status" "$version" "$token"
  exit 0
}

cmd_redact_json() {
  require_jq
  jq '
    walk(
      if type == "object" then
        (if has("value") then .value = "[REDACTED]" else . end)
        | (if has("note") then .note = "[REDACTED]" else . end)
      else
        .
      end
    )
  '
}

cmd_list_metadata() {
  local project_id=${1:-} json
  require_jq
  if [ -n "$project_id" ]; then
    json=$(run_bws secret list "$project_id" -o json) || exit 3
  else
    json=$(run_bws secret list -o json) || exit 3
  fi
  printf '%s\n' "$json" | cmd_redact_json
}

cmd_resolve_id() {
  local project_id=$1 key=$2 json matches count id
  [ -n "$project_id" ] && [ -n "$key" ] || die_usage "resolve-id requires PROJECT_ID and KEY"
  require_jq
  json=$(run_bws secret list "$project_id" -o json) || exit 3
  matches=$(jq -r --arg key "$key" '[.[] | select(.key == $key) | .id] | @json' <<<"$json")
  count=$(jq 'length' <<<"$matches")
  case "$count" in
    0) exit 1 ;;
    1)
      id=$(jq -r '.[0]' <<<"$matches")
      printf '%s\n' "$id"
      exit 0
      ;;
    *)
      printf 'bws-safe: duplicate secret key %s in project %s (%s matches)\n' \
        "$key" "$project_id" "$count" >&2
      jq -r '.[]' <<<"$matches" >&2
      exit 2
      ;;
  esac
}

CMD=${1:-}
shift || true

case "$CMD" in
  -h|--help|'')
    usage
    [ -n "$CMD" ] || exit 2
    exit 0
    ;;
  probe)
    [ $# -eq 0 ] || die_usage "probe takes no arguments"
    cmd_probe
    ;;
  redact-json)
    [ $# -eq 0 ] || die_usage "redact-json reads stdin and takes no arguments"
    cmd_redact_json
    ;;
  list-metadata)
    [ $# -le 1 ] || die_usage "list-metadata accepts an optional PROJECT_ID"
    cmd_list_metadata "${1:-}"
    ;;
  resolve-id)
    [ $# -eq 2 ] || die_usage "resolve-id requires PROJECT_ID and KEY"
    cmd_resolve_id "$1" "$2"
    ;;
  *)
    die_usage "unknown command: $CMD"
    ;;
esac
