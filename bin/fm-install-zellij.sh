#!/usr/bin/env bash
# fm-install-zellij.sh - install CI's pinned, verified Zellij build.
#
# Usage:
#   fm-install-zellij.sh <destination-directory>
#
# Pins the no-web Zellij v0.44.0 release exercised by the real backend smoke
# test. Selects an official release asset for Linux, macOS, or native Windows
# under Git Bash, verifies its SHA-256, and checks the installed version.
set -eu

FM_ZELLIJ_CI_VERSION=0.44.0
FM_ZELLIJ_CI_TAG="v${FM_ZELLIJ_CI_VERSION}"
FM_ZELLIJ_CI_MAX_BYTES=30000000
FM_ZELLIJ_CI_REPO=zellij-org/zellij

die() {
  printf 'fm-install-zellij.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-zellij.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ARCHIVE=zellij-no-web-x86_64-unknown-linux-musl.tar.gz
    SHA256=458b0c5ec19d6313580293e451c9a467c73b337d42faf8e2ce1712c56767b727
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE=zellij-no-web-aarch64-unknown-linux-musl.tar.gz
    SHA256=434daa1283c1f7054d0077ee224822b9ec822bfc75de9dea5c3ad794bf8bb28d
    ;;
  Darwin-arm64)
    ARCHIVE=zellij-no-web-aarch64-apple-darwin.tar.gz
    SHA256=25dff7238d2587542d0267b4a99db11dba91d131285432e35cac8c2a11f6df62
    ;;
  Darwin-x86_64)
    ARCHIVE=zellij-no-web-x86_64-apple-darwin.tar.gz
    SHA256=510fc73b4c119a8cd74d8ea554bfa30a79d5ede97254c286aeda808ebc661411
    ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64)
    ARCHIVE=zellij-no-web-x86_64-pc-windows-msvc.zip
    SHA256=fb37f4236bc3476f66a52923a23a6e08211695f2c89cea650baafd266ecb2e0d
    WINDOWS=1
    ;;
  *)
    die "unsupported platform ${os}-${arch}; supported assets are linux/macos x86_64 and arm64, plus Windows x86_64"
    ;;
esac

if [ "${WINDOWS:-0}" = 1 ] && command -v cygpath >/dev/null 2>&1; then
  DESTINATION=$(cygpath -u "$DESTINATION")
  TMP_BASE=$(cygpath -u "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")
else
  TMP_BASE=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
fi

URL="https://github.com/${FM_ZELLIJ_CI_REPO}/releases/download/${FM_ZELLIJ_CI_TAG}/${ARCHIVE}"
TMP=$(mktemp -d "$TMP_BASE/fm-zellij.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-zellij.sh: downloading %s from %s\n' "$ARCHIVE" "$URL" >&2
curl -fsSL --max-filesize "$FM_ZELLIJ_CI_MAX_BYTES" "$URL" -o "$TMP/$ARCHIVE" \
  || die "download failed for $URL (bounded at $FM_ZELLIJ_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Zellij archive"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] \
  || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"

case "$ARCHIVE" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || die "unzip is required for the Windows Zellij archive"
    unzip -q "$TMP/$ARCHIVE" -d "$TMP/unpacked"
    BIN=$(find "$TMP/unpacked" -type f -name zellij.exe | head -n 1)
    [ -n "$BIN" ] || die "archive $ARCHIVE did not contain zellij.exe"
    TARGET=zellij.exe
    ;;
  *)
    tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
    BIN=$(find "$TMP" -type f -name zellij | head -n 1)
    [ -n "$BIN" ] || die "archive $ARCHIVE did not contain zellij"
    TARGET=zellij
    ;;
esac

mkdir -p "$DESTINATION"
install -m 0755 "$BIN" "$DESTINATION/$TARGET"

installed_version=$("$DESTINATION/$TARGET" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_ZELLIJ_CI_VERSION" ] \
  || die "installed zellij version is '${installed_version:-<empty>}', expected exact pin $FM_ZELLIJ_CI_VERSION"

printf 'fm-install-zellij.sh: installed zellij %s to %s\n' \
  "$installed_version" "$DESTINATION/$TARGET" >&2
"$DESTINATION/$TARGET" --version
