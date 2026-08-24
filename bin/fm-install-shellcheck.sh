#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Downloads the official GitHub release archive for the host OS/arch, verifies
# its per-archive SHA-256 pin, and installs the binary into the destination
# directory. Supported platforms: linux amd64/x86_64, linux arm64/aarch64,
# darwin amd64/x86_64, darwin arm64/aarch64. Pins come from the official
# ShellCheck release asset digests. Verification uses sha256sum when present,
# otherwise shasum -a 256. An unsupported OS/arch or a missing pin fails
# without downloading.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"

die() {
  printf 'fm-install-shellcheck.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are the GitHub release asset digests for shellcheck v0.11.0
# .tar.xz archives (https://github.com/koalaman/shellcheck/releases/tag/v0.11.0).
case "${os}-${arch}" in
  Linux-x86_64|Linux-amd64)
    ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
    SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE="shellcheck-v${VERSION}.linux.aarch64.tar.xz"
    SHA256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    ;;
  Darwin-x86_64|Darwin-amd64)
    ARCHIVE="shellcheck-v${VERSION}.darwin.x86_64.tar.xz"
    SHA256=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
    ;;
  Darwin-arm64|Darwin-aarch64)
    ARCHIVE="shellcheck-v${VERSION}.darwin.aarch64.tar.xz"
    SHA256=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
    ;;
  *)
    die "unsupported platform ${os}-${arch}; need linux or darwin on amd64/x86_64 or arm64/aarch64"
    ;;
esac
[ -n "$SHA256" ] || die "no pinned checksum for ${os}-${arch}"

URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-shellcheck.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the ShellCheck archive"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ARCHIVE" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"
"$DESTINATION/shellcheck" --version
