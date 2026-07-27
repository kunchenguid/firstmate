#!/usr/bin/env bash
# fm-devenv-install.sh - install or verify a commit-pinned FirstMate runtime.
#
# Usage:
#   fm-devenv-install.sh <environment>
#       Resolve the environment through the validated Expanly devenv registry,
#       archive only tracked FirstMate runtime surfaces from HEAD, and install
#       that archive as the remote current release.
#   fm-devenv-install.sh --verify <environment>
#       Compare the remote current release marker with local HEAD without
#       installing or repairing remote files.
#
# FM_DEVENV_REGISTRY overrides the default ~/.expanly-devenvs.json registry.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=bin/fm-devenv-lib.sh
. "$SCRIPT_DIR/fm-devenv-lib.sh"

REMOTE_INSTALL_COMMAND='set -eu
umask 077
IFS= read -r environment
IFS= read -r commit
case "$environment" in
  ""|*[!A-Za-z0-9_-]*) echo "fm-devenv-install: invalid environment header" >&2; exit 1 ;;
esac
case "$commit" in
  ""|*[!0-9a-f]*) echo "fm-devenv-install: invalid commit header" >&2; exit 1 ;;
esac
if [ "${#commit}" -ne 40 ] && [ "${#commit}" -ne 64 ]; then
  echo "fm-devenv-install: invalid commit header" >&2
  exit 1
fi
share="$HOME/.local/share/firstmate-expanly"
release="$share/releases/$commit"
state="$HOME/.local/state/firstmate-expanly/$environment"
mkdir -p -m 700 "$release" "$state"
chmod 700 "$share" "$share/releases" "$release" "$HOME/.local/state/firstmate-expanly" "$state"
tar -xf - -C "$release"
printf "%s\n" "$commit" > "$release/.firstmate-runtime-commit"
next="$share/.current.$commit.$$"
cleanup_current() {
  rm -f -- "$next"
}
trap cleanup_current EXIT HUP INT TERM
ln -s "releases/$commit" "$next"
mv -Tf "$next" "$share/current"
trap - EXIT HUP INT TERM'

REMOTE_VERIFY_COMMAND='cat "$HOME/.local/share/firstmate-expanly/current/.firstmate-runtime-commit"'

usage() {
  printf 'usage: fm-devenv-install.sh <environment>\n' >&2
  printf '       fm-devenv-install.sh --verify <environment>\n' >&2
}

die() {
  printf 'fm-devenv-install: %s\n' "$1" >&2
  exit 1
}

mode=install
case "$#:${1-}" in
  1:*) environment=$1 ;;
  2:--verify) mode=verify; environment=$2 ;;
  *) usage; exit 2 ;;
esac

fm_devenv_name_valid "$environment" || die "invalid environment: $environment"
registry=$(fm_devenv_registry_path) || die 'could not resolve registry path'
row=$(fm_devenv_registry_get "$registry" "$environment") \
  || die "unknown environment: $environment"
host=$(printf '%s\n' "$row" | jq -r '.vm')
fm_devenv_vm_valid "$host" || die "registry returned an invalid VM for: $environment"
commit=$(git -C "$FM_ROOT" rev-parse HEAD) || die 'could not resolve local HEAD'
case "$commit" in
  ''|*[!0-9a-f]*) die 'local HEAD is not a commit id' ;;
esac

if [ "$mode" = verify ]; then
  remote_commit=$(ssh "$host" "$REMOTE_VERIFY_COMMAND") \
    || die "could not read remote runtime marker for: $environment"
  [ "$remote_commit" = "$commit" ] \
    || die "remote runtime mismatch for $environment: expected $commit, found ${remote_commit:-missing}"
  printf 'verified %s at %s\n' "$environment" "$commit"
  exit 0
fi

{
  printf '%s\n%s\n' "$environment" "$commit"
  git -C "$FM_ROOT" archive HEAD -- \
    AGENTS.md CLAUDE.md bin .agents/skills .claude/skills skills
} | ssh "$host" "$REMOTE_INSTALL_COMMAND"

printf 'installed %s at %s\n' "$environment" "$commit"
