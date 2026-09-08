#!/usr/bin/env bash
# fm-install-actionlint.sh - install CI's pinned, verified actionlint build.
#
# Downloads the official GitHub release archive for the host OS/arch, verifies
# its per-archive SHA-256 pin, and installs the binary into the destination
# directory. Supported platforms: linux amd64/x86_64, linux arm64/aarch64,
# darwin amd64/x86_64, darwin arm64/aarch64, and windows x86_64 under Git
# Bash/MSYS (the .zip asset, extracted with unzip). Pins come from the
# official actionlint release checksums file. Verification uses sha256sum when
# present, otherwise shasum -a 256. An unsupported OS/arch or a missing pin
# fails without downloading.
#
# Usage:
#   fm-install-actionlint.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint-workflows.sh" --required-version)"

die() {
  printf 'fm-install-actionlint.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-actionlint.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are from actionlint_1.7.12_checksums.txt on the official
# v1.7.12 release (https://github.com/rhysd/actionlint/releases/tag/v1.7.12).
BIN_SRC=actionlint
BIN_DEST=actionlint
case "${os}-${arch}" in
  Linux-x86_64|Linux-amd64)
    ARCHIVE="actionlint_${VERSION}_linux_amd64.tar.gz"
    SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE="actionlint_${VERSION}_linux_arm64.tar.gz"
    SHA256=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
    ;;
  Darwin-x86_64|Darwin-amd64)
    ARCHIVE="actionlint_${VERSION}_darwin_amd64.tar.gz"
    SHA256=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
    ;;
  Darwin-arm64|Darwin-aarch64)
    ARCHIVE="actionlint_${VERSION}_darwin_arm64.tar.gz"
    SHA256=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    ;;
  MINGW*_NT*-x86_64|MSYS_NT*-x86_64)
    # The Windows asset is a .zip holding actionlint.exe at its root.
    ARCHIVE="actionlint_${VERSION}_windows_amd64.zip"
    SHA256=6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9
    BIN_SRC=actionlint.exe
    BIN_DEST=actionlint.exe
    ;;
  *)
    die "unsupported platform ${os}-${arch}; need linux or darwin on amd64/x86_64 or arm64/aarch64, or windows (Git Bash/MSYS) on x86_64"
    ;;
esac
[ -n "$SHA256" ] || die "no pinned checksum for ${os}-${arch}"
case "$ARCHIVE" in
  *.zip) command -v unzip >/dev/null 2>&1 || die "need unzip to extract $ARCHIVE" ;;
esac

URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-actionlint.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-actionlint.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-actionlint.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the actionlint archive"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-actionlint.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ARCHIVE" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}
case "$ARCHIVE" in
  *.zip) unzip -oq "$TMP/$ARCHIVE" -d "$TMP" ;;
  *) tar -xzf "$TMP/$ARCHIVE" -C "$TMP" ;;
esac
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/$BIN_SRC" "$DESTINATION/$BIN_DEST"
"$DESTINATION/$BIN_DEST" -version
