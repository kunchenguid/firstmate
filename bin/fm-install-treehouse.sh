#!/usr/bin/env bash
# fm-install-treehouse.sh - install CI's pinned, verified Treehouse build.
#
# Used only by the required real-Herdr CI lane for E2E scripts that genuinely
# need treehouse (spawn worktree acquisition). Same pin/checksum discipline as
# fm-install-herdr.sh: official release URL, exact asset, SHA-256, bounded
# download, post-install version check. Never a floating package-manager latest.
#
# Usage:
#   fm-install-treehouse.sh <destination-directory>
#
# Pins Treehouse v2.3.0, the version exercised by the local real-Herdr suite.
# The floor is v2.2.0, the first release carrying the global --root flag that
# bin/fm-treehouse-lib.sh needs to bind a non-primary home's pool to its own
# project clone (docs/configuration.md owns that contract).
set -eu

FM_TREEHOUSE_CI_VERSION=2.3.0
FM_TREEHOUSE_CI_TAG="v${FM_TREEHOUSE_CI_VERSION}"
# Bounded download ceiling (bytes). Official 2.3.0 archives are under 8 MiB.
FM_TREEHOUSE_CI_MAX_BYTES=15000000
FM_TREEHOUSE_CI_REPO=kunchenguid/treehouse

die() {
  printf 'fm-install-treehouse.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-treehouse.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-linux-amd64.tar.gz
    SHA256=94fd2b2c20c35aac1ddc2941317890ad82c9916f5ccecbac4a50cda783eed10f
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-linux-arm64.tar.gz
    SHA256=408589ba72b58d5e942071ed863a83fd96566cfd1e514945daa59defde528bbb
    ;;
  Darwin-arm64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-darwin-arm64.tar.gz
    SHA256=1cb09bcfa830b4eec5e54beeaa71589adb9c5d828573dda0f5150e2d80cf13d5
    ;;
  Darwin-x86_64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-darwin-amd64.tar.gz
    SHA256=349afcc13c2beb20d846eb560a11b30e1a5cab8e2dfb22988a36aa7f213b5881
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Treehouse assets are linux/darwin amd64 and arm64"
    ;;
esac

URL="https://github.com/${FM_TREEHOUSE_CI_REPO}/releases/download/${FM_TREEHOUSE_CI_TAG}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-treehouse.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-treehouse.sh: downloading %s from %s\n' "$ARCHIVE" "$URL" >&2
curl -fsSL --max-filesize "$FM_TREEHOUSE_CI_MAX_BYTES" "$URL" -o "$TMP/$ARCHIVE" \
  || die "download failed for $URL (bounded at $FM_TREEHOUSE_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Treehouse archive"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"

tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
# Archive layout: a single `treehouse` binary at the archive root (verified for v2.3.0).
if [ -f "$TMP/treehouse" ]; then
  BIN="$TMP/treehouse"
elif [ -f "$TMP/treehouse-v${FM_TREEHOUSE_CI_VERSION}/treehouse" ]; then
  BIN="$TMP/treehouse-v${FM_TREEHOUSE_CI_VERSION}/treehouse"
else
  BIN=$(find "$TMP" -type f -name treehouse | head -n 1)
  [ -n "$BIN" ] || die "archive $ARCHIVE did not contain a treehouse binary"
fi

mkdir -p "$DESTINATION"
install -m 0755 "$BIN" "$DESTINATION/treehouse"

installed_version=$("$DESTINATION/treehouse" --version 2>/dev/null | tr -d '[:space:]')
# treehouse prints "v2.3.0" (leading v) on --version.
case "$installed_version" in
  "v${FM_TREEHOUSE_CI_VERSION}"|"${FM_TREEHOUSE_CI_VERSION}") ;;
  *)
    die "installed treehouse version is '${installed_version:-<empty>}', expected exact pin v${FM_TREEHOUSE_CI_VERSION}"
    ;;
esac

printf 'fm-install-treehouse.sh: installed treehouse %s to %s\n' \
  "$installed_version" "$DESTINATION/treehouse" >&2
"$DESTINATION/treehouse" --version
