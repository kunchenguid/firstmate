#!/usr/bin/env bash
# Guarded local configuration helper for the AI Department portal connector.
#
# Usage:
#   fm-portal-config.sh install [--base-url <url>] [--allow-remote] [--token-stdin]
#   fm-portal-config.sh rotate  [--base-url <url>] [--allow-remote] [--token-stdin]
#   fm-portal-config.sh status
#   fm-portal-config.sh disable
#
# install defaults to http://127.0.0.1:8201.
# rotate preserves the current base URL unless --base-url is supplied.
# The token is read silently from /dev/tty by default, or from stdin only when
# --token-stdin is explicit. It is never accepted as an argument or printed.
# --allow-remote is required when installing an HTTPS non-loopback URL.
# The helper atomically publishes config/portal-connector.json as mode 0600.
# It never activates the connector itself: the next locked session-start
# bootstrap validates the file and publishes the authenticated watcher check.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-portal-lib.sh
. "$SCRIPT_DIR/fm-portal-lib.sh"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

command=${1:-}
case "$command" in
  install|rotate|status|disable) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [ "$command" = status ]; then
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if fmp_load_config; then
    printf 'portal connector: enabled (%s, config mode 0600)\n' "$FMP_BASE_URL"
    exit 0
  fi
  if [ "$FMP_CONFIG_ERROR" = absent ]; then
    printf 'portal connector: disabled\n'
    exit 0
  fi
  printf 'portal connector: invalid (%s)\n' "$FMP_CONFIG_ERROR" >&2
  exit 1
fi

if [ "$command" = disable ]; then
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if [ ! -e "$FMP_CONFIG_FILE" ] && [ ! -L "$FMP_CONFIG_FILE" ]; then
    printf 'portal connector: already disabled\n'
    exit 0
  fi
  fmp_config_file_identity_valid "$FMP_CONFIG_FILE" || {
    echo 'fm-portal-config: refusing to remove an unsafe configuration path' >&2
    exit 1
  }
  rm -f -- "$FMP_CONFIG_FILE" || {
    echo 'fm-portal-config: could not remove connector configuration' >&2
    exit 1
  }
  printf 'portal connector: disabled; run the next locked session start to remove polling artifacts\n'
  exit 0
fi

base=
allow_remote=0
token_stdin=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url)
      [ "$#" -gt 1 ] || { echo 'fm-portal-config: --base-url requires a value' >&2; exit 2; }
      base=$2
      shift 2
      ;;
    --allow-remote) allow_remote=1; shift ;;
    --token-stdin) token_stdin=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-portal-config: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$command" = rotate ]; then
  fmp_load_config || {
    echo 'fm-portal-config: rotate requires an existing valid configuration' >&2
    exit 1
  }
  [ -n "$base" ] || base=$FMP_BASE_URL
elif [ -z "$base" ]; then
  base=$FMP_DEFAULT_BASE_URL
fi

fmp_base_url_valid "$base" || {
  echo 'fm-portal-config: invalid base URL; use HTTP loopback or an HTTPS origin without userinfo, query, fragment, or trailing slash' >&2
  exit 2
}
case "$base" in
  http://127.0.0.1|http://127.0.0.1:*|http://localhost|http://localhost:*) ;;
  *)
    [ "$allow_remote" -eq 1 ] || {
      echo 'fm-portal-config: non-loopback HTTPS requires --allow-remote' >&2
      exit 2
    }
    ;;
esac

if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
  [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] || {
    echo 'fm-portal-config: config directory is unsafe' >&2
    exit 1
  }
else
  (umask 077; mkdir -p "$CONFIG") || {
    echo 'fm-portal-config: could not create config directory' >&2
    exit 1
  }
fi

if [ -e "$FMP_CONFIG_FILE" ] || [ -L "$FMP_CONFIG_FILE" ]; then
  fmp_config_file_identity_valid "$FMP_CONFIG_FILE" || {
    echo 'fm-portal-config: refusing to replace an unsafe configuration path' >&2
    exit 1
  }
fi

token_file=$(umask 077; mktemp "$CONFIG/.portal-token.XXXXXX") || exit 1
config_tmp=$(umask 077; mktemp "$CONFIG/.portal-config.XXXXXX") || { rm -f "$token_file"; exit 1; }
cleanup() { rm -f -- "$token_file" "$config_tmp"; }
trap cleanup EXIT HUP INT TERM

if [ "$token_stdin" -eq 1 ]; then
  IFS= read -r token || {
    echo 'fm-portal-config: no token received on stdin' >&2
    exit 1
  }
else
  if [ ! -r /dev/tty ]; then
    echo 'fm-portal-config: no terminal available; use --token-stdin' >&2
    exit 1
  fi
  printf 'Portal bearer token: ' >/dev/tty
  IFS= read -r -s token </dev/tty || {
    printf '\n' >/dev/tty
    echo 'fm-portal-config: could not read token' >&2
    exit 1
  }
  printf '\n' >/dev/tty
fi
printf '%s' "$token" > "$token_file" || exit 1
unset token
chmod 600 "$token_file" || exit 1

bytes=$(wc -c < "$token_file" | tr -d '[:space:]')
case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
if [ "$bytes" -lt 1 ] || [ "$bytes" -gt "$FMP_MAX_TOKEN_BYTES" ] \
  || LC_ALL=C grep '[[:cntrl:]]' "$token_file" >/dev/null 2>&1; then
  echo "fm-portal-config: token must contain 1-$FMP_MAX_TOKEN_BYTES bytes and no control characters" >&2
  exit 2
fi

jq -cn --arg base "$base" --rawfile token "$token_file" \
  '{base_url:$base,bearer_token:$token}' > "$config_tmp" || exit 1
chmod 600 "$config_tmp" || exit 1
parent_device=$(fm_pr_file_device "$CONFIG") || exit 1
fm_pr_private_file_valid "$config_tmp" 600 "$parent_device" || exit 1
if [ -e "$FMP_CONFIG_FILE" ] || [ -L "$FMP_CONFIG_FILE" ]; then
  fmp_config_file_identity_valid "$FMP_CONFIG_FILE" || exit 1
fi
mv -f -- "$config_tmp" "$FMP_CONFIG_FILE" || exit 1
config_tmp=
fmp_load_config || {
  rm -f -- "$FMP_CONFIG_FILE"
  echo 'fm-portal-config: published configuration failed validation and was removed' >&2
  exit 1
}
rm -f -- "$token_file"
token_file=
trap - EXIT HUP INT TERM
printf 'portal connector: configuration installed for %s; run the next locked session start to activate polling\n' "$base"
