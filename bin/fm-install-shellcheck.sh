#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Resolves the release asset from the host OS and architecture, then verifies the
# download against that platform's own recorded SHA-256 digest. Every supported
# platform carries its own verified digest, so no platform is installed unverified
# and an unsupported OS/architecture pair is refused rather than mis-downloaded.
# Digests are the upstream release assets for the pinned version, confirmed by
# direct download; tests/fm-lint.test.sh asserts this table.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
#   fm-install-shellcheck.sh --resolve [<uname-s> <uname-m>]
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"

# <uname -s> <uname -m> -> "<asset-platform> <sha256>" for the pinned release.
fm_shellcheck_asset() {  # <uname-s> <uname-m>
  local os arch
  case "$1" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) return 1 ;;
  esac
  case "$2" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *) return 1 ;;
  esac
  case "$os.$arch" in
    darwin.aarch64)
      printf 'darwin.aarch64 56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79\n' ;;
    darwin.x86_64)
      printf 'darwin.x86_64 3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6\n' ;;
    linux.aarch64)
      printf 'linux.aarch64 12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588\n' ;;
    linux.x86_64)
      printf 'linux.x86_64 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198\n' ;;
    *) return 1 ;;
  esac
}

# SHA-256 through whichever tool the host provides: sha256sum on Linux and on
# macOS 26 and later, shasum on earlier macOS. A missing tool is a hard failure,
# never a skipped verification.
fm_shellcheck_sha256() {  # <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'fm-install-shellcheck.sh: no SHA-256 tool found; install sha256sum or shasum\n' >&2
    return 1
  fi
}

# The release asset and digest for one platform, as "<archive> <sha256>". The
# archive name is built here and nowhere else, so --resolve reports exactly the
# file the install path below downloads.
fm_shellcheck_resolve() {  # <uname-s> <uname-m>
  local asset platform sha256
  asset=$(fm_shellcheck_asset "$1" "$2") || {
    printf 'fm-install-shellcheck.sh: unsupported platform %s/%s; this installer supports ShellCheck %s on darwin and linux for aarch64 and x86_64\n' \
      "$1" "$2" "$VERSION" >&2
    return 1
  }
  read -r platform sha256 <<EOF
$asset
EOF
  printf 'shellcheck-v%s.%s.tar.xz %s\n' "$VERSION" "$platform" "$sha256"
}

if [ "${1:-}" = "--resolve" ]; then
  # Separate assignment so set -eu aborts on an unsupported platform instead of
  # printing an empty archive name and checksum.
  RESOLVED=$(fm_shellcheck_resolve "${2:-$(uname -s)}" "${3:-$(uname -m)}")
  printf '%s\n' "$RESOLVED"
  exit 0
fi

RESOLVED=$(fm_shellcheck_resolve "$(uname -s)" "$(uname -m)")
read -r ARCHIVE SHA256 <<EOF
$RESOLVED
EOF
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=3
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-shellcheck.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep "$download_attempt"
  download_attempt=$((download_attempt + 1))
done
ACTUAL_SHA256=$(fm_shellcheck_sha256 "$TMP/$ARCHIVE")
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"
"$DESTINATION/shellcheck" --version
