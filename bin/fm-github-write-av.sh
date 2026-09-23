#!/usr/local/bin/av inject -- /bin/bash
# shellcheck shell=bash disable=SC2096
# --- automic-vault
# capabilities:
#   gh: write
#   ssh-agent: trusted
# ---
# Automic Vault Blessed Script for bin/fm-github-write.sh.
#
# Bless this exact canonical file without endorsing any worker or firstmate
# launcher. Automic Vault binds this file's path, contents, declaration, and
# capabilities to that review while keeping each invocation attended. This
# wrapper additionally binds the executable delivery implementation below, so
# changing either the implementation or this declaration requires a digest
# update and a fresh Blessing review.
set -eu

SELF=${AV_SCRIPT_PATH:-${BASH_SOURCE[0]}}
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
EXPECTED_WRITE_SHA256='cd57494124eb0871f24ca997e3c8e01f774c1cfbe38dfb0919ad2a6fbb4f71c2'

sha256_file() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo 'error: SHA-256 tool is unavailable' >&2
    exit 1
  fi
}

actual=$(sha256_file "$SCRIPT_DIR/fm-github-write.sh")
if [ "$actual" != "$EXPECTED_WRITE_SHA256" ]; then
  echo 'error: fm-github-write.sh changed after this Automic Vault declaration was reviewed; update the bound digest and re-bless this script' >&2
  exit 1
fi

# Use only fixed system command locations while the Blessing is active.
# The direct-PR implementation disables project hooks and supplies the exact
# GitHub SSH URL; the existing merge implementation retains its own guards.
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH
FM_GITHUB_WRITE_GH_AXI_BIN=$(command -v gh-axi 2>/dev/null || true)
[ -n "$FM_GITHUB_WRITE_GH_AXI_BIN" ] || {
  echo 'error: direct GitHub delivery requires gh-axi on the fixed Blessed Script PATH' >&2
  exit 1
}
export FM_GITHUB_WRITE_GH_AXI_BIN
FM_GITHUB_WRITE_ACTIVE=1
export FM_GITHUB_WRITE_ACTIVE
exec "$SCRIPT_DIR/fm-github-write.sh" "$@"
