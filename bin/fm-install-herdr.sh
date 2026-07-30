#!/usr/bin/env bash
# fm-install-herdr.sh - install CI's pinned, verified Herdr build.
#
# Single owner of the exact Herdr version, official release asset URL, and
# SHA-256 pin used by the required real-Herdr CI lane. Never installs a
# floating package-manager latest.
#
# Usage:
#   fm-install-herdr.sh <destination-directory>
#
# Pins Herdr v0.7.4 (protocol 16), the suite-verified protocol-16 release.
# Selects the official GitHub Releases asset for the host OS/arch, downloads
# with a bounded max size, verifies SHA-256 before install, then refuses to
# finish unless the binary reports the exact pin version and a client protocol
# at or above the required floor (16 for the real-Herdr family).
set -eu

# Exact pin - change only with a re-verified real-Herdr matrix.
FM_HERDR_CI_VERSION=0.7.4
FM_HERDR_CI_TAG="v${FM_HERDR_CI_VERSION}"
FM_HERDR_CI_MIN_PROTOCOL=16
# Bounded download ceiling (bytes). The largest official 0.7.4 asset is under 20 MiB.
FM_HERDR_CI_MAX_BYTES=25000000
FM_HERDR_CI_REPO=ogulcancelik/herdr

die() {
  printf 'fm-install-herdr.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-herdr.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET=herdr-linux-x86_64
    SHA256=bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=herdr-linux-aarch64
    SHA256=544e0002de42806d1ab64ccdef3a7e7414f24717b0b6b022bc9e57d2eefd26a2
    ;;
  Darwin-arm64)
    ASSET=herdr-macos-aarch64
    SHA256=24992e1625dbdcb18354a59e299e4b263c312400b31396cdc07cd46ed57f24a7
    ;;
  Darwin-x86_64)
    ASSET=herdr-macos-x86_64
    SHA256=ddf430133352e1712413d5d865b34a485546f4658893fc89986257d65a7585a8
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Herdr assets are linux/macos x86_64 and aarch64"
    ;;
esac

URL="https://github.com/${FM_HERDR_CI_REPO}/releases/download/${FM_HERDR_CI_TAG}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-herdr.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-herdr.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
# --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
curl -fsSL --max-filesize "$FM_HERDR_CI_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_HERDR_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Herdr asset"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/$ASSET" "$DESTINATION/herdr"

# Post-install version and protocol gates (no floating latest).
installed_version=$("$DESTINATION/herdr" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_HERDR_CI_VERSION" ] \
  || die "installed herdr version is '${installed_version:-<empty>}', expected exact pin $FM_HERDR_CI_VERSION"

status=$("$DESTINATION/herdr" status --json 2>/dev/null) \
  || die "could not run 'herdr status --json' after install"
protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null) \
  || die "jq is required to parse herdr status after install"
case "$protocol" in
  ''|*[!0-9]*) die "could not read herdr client protocol from status --json" ;;
esac
[ "$protocol" -ge "$FM_HERDR_CI_MIN_PROTOCOL" ] \
  || die "herdr protocol $protocol is below the required floor $FM_HERDR_CI_MIN_PROTOCOL"

printf 'fm-install-herdr.sh: installed herdr %s (protocol %s) to %s\n' \
  "$installed_version" "$protocol" "$DESTINATION/herdr" >&2
"$DESTINATION/herdr" --version
