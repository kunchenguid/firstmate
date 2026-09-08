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
# Pins Treehouse v2.0.1, the version exercised by the local real-Herdr suite.
# That pin already publishes Windows assets, so Windows support needed no
# version bump: the Windows arm differs only in archive format (.zip) and
# binary name (treehouse.exe).
set -eu

FM_TREEHOUSE_CI_VERSION=2.0.1
FM_TREEHOUSE_CI_TAG="v${FM_TREEHOUSE_CI_VERSION}"
# Bounded download ceiling (bytes). Official 2.0.1 archives are under 8 MiB.
FM_TREEHOUSE_CI_MAX_BYTES=15000000
FM_TREEHOUSE_CI_REPO=kunchenguid/treehouse

die() {
  printf 'fm-install-treehouse.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-treehouse.sh <destination-directory>}

# ARCHIVE_FORMAT selects the extractor below; BINARY is the file name inside the
# archive and the name installed into DESTINATION.
ARCHIVE_FORMAT=tar.gz
BINARY=treehouse

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-linux-amd64.tar.gz
    SHA256=1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-linux-arm64.tar.gz
    SHA256=eaccc9c5b98125df8bd77425598eeecee66cb0371db4eb1cf75f0d813c18fab9
    ;;
  Darwin-arm64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-darwin-arm64.tar.gz
    SHA256=7ee5078f3d1f33c01196548797fce65408e459d53530b77d4ba56e074fa1c1a2
    ;;
  Darwin-x86_64)
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-darwin-amd64.tar.gz
    SHA256=1cf44580a5837f995e1d3bb74f4fbd3112b642acd20406087d9735a8106112fd
    ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64)
    # Git Bash and MSYS2 report MINGW64_NT-* / MSYS_NT-*. Windows assets are
    # .zip rather than .tar.gz and carry a .exe binary.
    ARCHIVE=treehouse-v${FM_TREEHOUSE_CI_VERSION}-windows-amd64.zip
    SHA256=d4c7bebc876b6dc1f9cf2f2b934803234d4f2f6e1c1c314505db85e64f5100bc
    ARCHIVE_FORMAT=zip
    BINARY=treehouse.exe
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Treehouse assets are linux/darwin amd64 and arm64 and windows amd64"
    ;;
esac

# Check the extractor before spending a download on an archive we cannot open.
if [ "$ARCHIVE_FORMAT" = zip ] && ! command -v unzip >/dev/null 2>&1; then
  die "need unzip to extract $ARCHIVE"
fi

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

if [ "$ARCHIVE_FORMAT" = zip ]; then
  unzip -q -o "$TMP/$ARCHIVE" -d "$TMP" || die "failed to extract $ARCHIVE"
else
  tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
fi

# Archive layout: a single `treehouse` binary at the archive root (verified for v2.0.1).
if [ -f "$TMP/$BINARY" ]; then
  BIN="$TMP/$BINARY"
elif [ -f "$TMP/treehouse-v${FM_TREEHOUSE_CI_VERSION}/$BINARY" ]; then
  BIN="$TMP/treehouse-v${FM_TREEHOUSE_CI_VERSION}/$BINARY"
else
  BIN=$(find "$TMP" -type f -name "$BINARY" | head -n 1)
  [ -n "$BIN" ] || die "archive $ARCHIVE did not contain a $BINARY binary"
fi

mkdir -p "$DESTINATION"
install -m 0755 "$BIN" "$DESTINATION/$BINARY"

installed_version=$("$DESTINATION/$BINARY" --version 2>/dev/null | tr -d '[:space:]')
# treehouse prints "v2.0.1" (leading v) on --version.
case "$installed_version" in
  "v${FM_TREEHOUSE_CI_VERSION}"|"${FM_TREEHOUSE_CI_VERSION}") ;;
  *)
    die "installed treehouse version is '${installed_version:-<empty>}', expected exact pin v${FM_TREEHOUSE_CI_VERSION}"
    ;;
esac

printf 'fm-install-treehouse.sh: installed treehouse %s to %s\n' \
  "$installed_version" "$DESTINATION/$BINARY" >&2
"$DESTINATION/$BINARY" --version
