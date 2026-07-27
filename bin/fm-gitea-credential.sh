#!/usr/bin/env bash
# Git credential helper for the private Gitea host.
# Reads username/token from the effective Firstmate home so remote URLs never
# need embedded userinfo. Invoked by git as:
#   git credential-xxx get|store|erase
# or as an absolute-path helper:
#   !/path/to/fm-gitea-credential.sh
#
# Usage (as a credential helper; git feeds the action on argv and attributes on stdin):
#   fm-gitea-credential.sh get
#   fm-gitea-credential.sh store   # no-op (token file is the store)
#   fm-gitea-credential.sh erase   # no-op (does not delete the token file)
#
# Resolution order for the token file:
#   1. FM_GITEA_TOKEN_FILE
#   2. $FM_HOME/config/gitea-token (FM_HOME, else FM_CONFIG_OVERRIDE, else
#      the tracked root derived from this script)
# Username resolution:
#   1. FM_GITEA_USERNAME
#   2. $config_dir/gitea-username
#   3. fail closed (print nothing) so git can try the next helper
# Host gate (only answer for this host):
#   FM_GITEA_HOST or $config_dir/gitea-host or private-git.ocin.cloud
#
# Never prints the token to stderr. store/erase are intentional no-ops so a
# successful clone cannot rewrite or delete the captain-managed token file.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

action=${1:-}
case "$action" in
  get|store|erase) ;;
  *) exit 0 ;;
esac

# Parse credential attributes from stdin (key=value lines, blank line ends).
protocol=''
host=''
username=''
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || break
  case "$line" in
    protocol=*) protocol=${line#protocol=} ;;
    host=*) host=${line#host=} ;;
    username=*) username=${line#username=} ;;
  esac
done

# Only HTTPS to the configured Gitea host is in scope.
[ "$protocol" = https ] || exit 0
[ -n "$host" ] || exit 0

if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
  CONFIG_DIR=$FM_CONFIG_OVERRIDE
elif [ -n "${FM_HOME:-}" ]; then
  CONFIG_DIR=$FM_HOME/config
else
  CONFIG_DIR=$FM_ROOT/config
fi

configured_host=${FM_GITEA_HOST:-}
if [ -z "$configured_host" ] && [ -f "$CONFIG_DIR/gitea-host" ]; then
  configured_host=$(sed -n '1s/[[:space:]]*$//p' "$CONFIG_DIR/gitea-host" 2>/dev/null || true)
fi
[ -n "$configured_host" ] || configured_host=private-git.ocin.cloud

# Host match is exact (including optional :port on either side after stripping
# a trailing default :443).
normalize_host() {
  local h=$1
  case "$h" in
    *:443) h=${h%:443} ;;
  esac
  printf '%s' "$h"
}
host_n=$(normalize_host "$host")
cfg_n=$(normalize_host "$configured_host")
[ "$host_n" = "$cfg_n" ] || exit 0

case "$action" in
  store|erase)
    # Token file is captain-managed; do not mutate it from git's credential API.
    exit 0
    ;;
esac

token_file=${FM_GITEA_TOKEN_FILE:-$CONFIG_DIR/gitea-token}
[ -f "$token_file" ] || exit 0

# Refuse group/other-readable token files (must be owner-only bits on the
# group/other nybbles: mode ends in 00). Missing/unreadable mode fails closed.
if command -v stat >/dev/null 2>&1; then
  mode=$(stat -f '%Lp' "$token_file" 2>/dev/null || stat -c '%a' "$token_file" 2>/dev/null || echo '')
  case "$mode" in
    [0-7]00) ;;
    *) exit 0 ;;
  esac
fi

token=$(sed -n '1s/[[:space:]]*$//p' "$token_file" 2>/dev/null || true)
[ -n "$token" ] || exit 0

if [ -z "$username" ]; then
  username=${FM_GITEA_USERNAME:-}
  if [ -z "$username" ] && [ -f "$CONFIG_DIR/gitea-username" ]; then
    username=$(sed -n '1s/[[:space:]]*$//p' "$CONFIG_DIR/gitea-username" 2>/dev/null || true)
  fi
fi
[ -n "$username" ] || exit 0

printf 'username=%s\n' "$username"
printf 'password=%s\n' "$token"
printf '\n'
