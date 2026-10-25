#!/usr/bin/env bash
# Run the uninstaller journey under a sentinel user install and ensure it remains untouched.
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
sentinel=$d/sentinel
mkdir -p "$sentinel/data/fm-owner-guard" "$sentinel/.local/share/fm-owner-guard"
printf 'pre-existing XDG install\n' >"$sentinel/data/fm-owner-guard/owner-guard"
printf 'pre-existing HOME install\n' >"$sentinel/.local/share/fm-owner-guard/owner-guard"
before=$(find "$sentinel" -type f -exec sha256sum {} + | sort)
HOME=$sentinel XDG_DATA_HOME=$sentinel/data GIT_CONFIG_GLOBAL=$d/global.gitconfig GIT_CONFIG_NOSYSTEM=1 \
  bash "$SRC/owner-guard-uninstall.test.sh"
after=$(find "$sentinel" -type f -exec sha256sum {} + | sort)
[ "$after" = "$before" ] || { echo 'FAIL: uninstall test touched the sentinel user install' >&2; exit 1; }
echo 'PASS owner-guard uninstall test preserves sentinel user install'
