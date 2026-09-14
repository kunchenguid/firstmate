#!/usr/bin/env bash
# fm-install-treehouse.sh - install CI's pinned, verified Treehouse build.
#
# Used only by the required real-Herdr CI lane for E2E scripts that genuinely
# need treehouse (spawn worktree acquisition). Same pin/checksum discipline as
# fm-install-herdr.sh: immutable upstream source, SHA-256, bounded
# download, post-install version check. Never a floating package-manager latest.
#
# Usage:
#   fm-install-treehouse.sh <destination-directory>
#
# Usage requires Go 1.25.5 or newer; builds immutable upstream source in a temporary directory.
set -eu

FM_TREEHOUSE_CI_VERSION=b227e59cf73fd15d69f00b580da0f5bee6b38fce
FM_TREEHOUSE_CI_MAX_BYTES=15000000
FM_TREEHOUSE_CI_REPO=kunchenguid/treehouse
SHA256=6aacdf5e75bd4145660bb47c732e128342ea621ec0ab37b802ddc780b4226c06

die() {
  printf 'fm-install-treehouse.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-treehouse.sh <destination-directory>}

command -v go >/dev/null 2>&1 || die "Go 1.25.5 or newer is required to build the pinned Treehouse source"
ARCHIVE="treehouse-${FM_TREEHOUSE_CI_VERSION}.tar.gz"
URL="https://codeload.github.com/${FM_TREEHOUSE_CI_REPO}/tar.gz/${FM_TREEHOUSE_CI_VERSION}"
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
BIN="$TMP/treehouse"
(cd "$TMP/treehouse-${FM_TREEHOUSE_CI_VERSION}" && \
  GOTOOLCHAIN=local go build -trimpath -mod=readonly -ldflags "-X main.version=${FM_TREEHOUSE_CI_VERSION}" -o "$BIN" .) \
  || die "pinned Treehouse source build failed"
"$BIN" lease --help >/dev/null || die "pinned Treehouse lacks in-place lease"

mkdir -p "$DESTINATION"
install -m 0755 "$BIN" "$DESTINATION/treehouse"

installed_version=$("$DESTINATION/treehouse" --version 2>/dev/null | tr -d '[:space:]')
case "$installed_version" in
  "v${FM_TREEHOUSE_CI_VERSION}"|"${FM_TREEHOUSE_CI_VERSION}") ;;
  *)
    die "installed treehouse version is '${installed_version:-<empty>}', expected exact pin v${FM_TREEHOUSE_CI_VERSION}"
    ;;
esac

printf 'fm-install-treehouse.sh: installed treehouse %s to %s\n' \
  "$installed_version" "$DESTINATION/treehouse" >&2
"$DESTINATION/treehouse" --version
