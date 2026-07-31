#!/usr/bin/env bash
# fm-install-shellcheck.sh - install the pinned, verified ShellCheck build.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
#
# Selects the official GitHub Releases tar.xz asset for the host OS and
# architecture, verifies its release SHA-256, installs the binary, and refuses
# to finish unless that binary reports the exact version pinned by fm-lint.sh.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"

die() {
  printf 'fm-install-shellcheck.sh: %s\n' "$*" >&2
  exit 1
}

os=$(uname -s) || die "could not identify the host operating system"
arch=$(uname -m) || die "could not identify the host architecture"
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET_PLATFORM=linux.x86_64
    SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET_PLATFORM=linux.aarch64
    SHA256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    ;;
  Linux-armv6l)
    ASSET_PLATFORM=linux.armv6hf
    SHA256=8afc50b302d5feeac9381ea114d563f0150d061520042b254d6eb715797c8223
    ;;
  Linux-riscv64)
    ASSET_PLATFORM=linux.riscv64
    SHA256=693c987777e7b524dd311d9b8c704885a39c889c9804bb1ef1fd29b48567b0b3
    ;;
  Darwin-arm64|Darwin-aarch64)
    ASSET_PLATFORM=darwin.aarch64
    SHA256=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
    ;;
  Darwin-x86_64)
    ASSET_PLATFORM=darwin.x86_64
    SHA256=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official ShellCheck $VERSION tar.xz assets cover Linux x86_64, aarch64, armv6hf, and riscv64 plus macOS x86_64 and aarch64"
    ;;
esac

ARCHIVE="shellcheck-v${VERSION}.${ASSET_PLATFORM}.tar.xz"
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=3
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    die "download failed after $DOWNLOAD_ATTEMPTS attempts"
  }
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep "$download_attempt"
  download_attempt=$((download_attempt + 1))
done
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify $ARCHIVE"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] \
  || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"
installed_version=$("$DESTINATION/shellcheck" --version 2>/dev/null | awk '/^version:/ {print $2; exit}')
[ "$installed_version" = "$VERSION" ] || {
  rm -f "$DESTINATION/shellcheck"
  die "installed ShellCheck version is '${installed_version:-<empty>}', expected exact pin $VERSION"
}
"$DESTINATION/shellcheck" --version
