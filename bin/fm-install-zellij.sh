#!/usr/bin/env bash
# fm-install-zellij.sh - install CI's pinned, verified Zellij build.
#
# Usage:
#   fm-install-zellij.sh <destination-directory>
set -eu

FM_ZELLIJ_CI_VERSION=0.44.0
FM_ZELLIJ_CI_TAG="v${FM_ZELLIJ_CI_VERSION}"
FM_ZELLIJ_CI_MAX_BYTES=25000000
FM_ZELLIJ_CI_ASSET=zellij-x86_64-unknown-linux-musl.tar.gz
FM_ZELLIJ_CI_SHA256=7e981d50c98ec13ad6cc882e8ca4da32544dd6b69fd0d1b2b753eb597847adb3
FM_ZELLIJ_CI_REPO=zellij-org/zellij

die() {
  printf 'fm-install-zellij.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-zellij.sh <destination-directory>}
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] \
  || die 'CI Zellij pin currently supports Linux x86_64 only'

URL="https://github.com/${FM_ZELLIJ_CI_REPO}/releases/download/${FM_ZELLIJ_CI_TAG}/${FM_ZELLIJ_CI_ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-zellij.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --max-filesize "$FM_ZELLIJ_CI_MAX_BYTES" "$URL" -o "$TMP/$FM_ZELLIJ_CI_ASSET" \
  || die "download failed for $URL"
actual_sha256=$(sha256sum "$TMP/$FM_ZELLIJ_CI_ASSET" | awk '{print $1}')
[ "$actual_sha256" = "$FM_ZELLIJ_CI_SHA256" ] \
  || die "checksum mismatch (expected $FM_ZELLIJ_CI_SHA256, got $actual_sha256)"

tar -xzf "$TMP/$FM_ZELLIJ_CI_ASSET" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/zellij" "$DESTINATION/zellij"
version=$("$DESTINATION/zellij" --version | awk '{print $2}')
[ "$version" = "$FM_ZELLIJ_CI_VERSION" ] \
  || die "installed Zellij version is '${version:-<empty>}', expected $FM_ZELLIJ_CI_VERSION"
printf 'fm-install-zellij.sh: installed zellij %s to %s\n' "$version" "$DESTINATION/zellij" >&2
