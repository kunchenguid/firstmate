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
# Pins Herdr v0.8.2 (protocol 20), the earliest stable release carrying an
# official Windows asset. Supported platforms: linux x86_64/aarch64, darwin
# x86_64/arm64, and windows x86_64 under Git Bash/MSYS (the .zip asset,
# extracted with unzip).
# Selects the official GitHub Releases asset for the host OS/arch, downloads
# with a bounded max size, verifies SHA-256 before install, then refuses to
# finish unless the binary reports the exact pin version and a client protocol
# at or above the required floor (16 for the real-Herdr family).
#
# The Windows asset is a .zip rather than a bare binary. It holds herdr.exe at
# its root beside the app-local ConPTY runtime under conpty/, which Herdr's own
# installer requires to sit next to the executable, so both are installed.
set -eu

# Exact pin - change only with a re-verified real-Herdr matrix.
FM_HERDR_CI_VERSION=0.8.2
FM_HERDR_CI_TAG="v${FM_HERDR_CI_VERSION}"
FM_HERDR_CI_MIN_PROTOCOL=16
# Bounded download ceiling (bytes). The largest official 0.8.2 asset is under 22 MiB.
FM_HERDR_CI_MAX_BYTES=25000000
FM_HERDR_CI_REPO=herdrdev/herdr

die() {
  printf 'fm-install-herdr.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-herdr.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are the GitHub release asset digests for herdr v0.8.2
# (https://github.com/herdrdev/herdr/releases/tag/v0.8.2).
BIN_DEST=herdr
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET=herdr-linux-x86_64
    SHA256=976150a14d490c94b243ea2e1a7eb2dfb67f12e36b182db90936f6728e6aecf4
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=herdr-linux-aarch64
    SHA256=f55610658e1c2e0d2aaef730b4b2ab885f7f8ba00285ab372bfb14f2e3d5b40d
    ;;
  Darwin-arm64)
    ASSET=herdr-macos-aarch64
    SHA256=a5d4f4d504d8b309c91f811050559300faba31258425f53c50852fc96f6ae574
    ;;
  Darwin-x86_64)
    ASSET=herdr-macos-x86_64
    SHA256=ab50262c8190cd7aa9056d249d255c08c328c3e8716de9cfa29db4f131b8e2c1
    ;;
  MINGW*_NT*-x86_64|MSYS_NT*-x86_64)
    # The Windows asset is a .zip holding herdr.exe plus its conpty/ runtime.
    ASSET=herdr-windows-x86_64.zip
    SHA256=0ab3d0fe1434d55757997542b978c771d642987bb15a7130f4160f0db38821d5
    BIN_DEST=herdr.exe
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Herdr assets are linux/macos x86_64 and aarch64, or windows (Git Bash/MSYS) on x86_64"
    ;;
esac
case "$ASSET" in
  *.zip) command -v unzip >/dev/null 2>&1 || die "need unzip to extract $ASSET" ;;
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
case "$ASSET" in
  *.zip)
    unzip -oq "$TMP/$ASSET" -d "$TMP/extract" \
      || die "could not extract $ASSET"
    [ -f "$TMP/extract/herdr.exe" ] \
      || die "$ASSET did not contain herdr.exe at its root"
    install -m 0755 "$TMP/extract/herdr.exe" "$DESTINATION/$BIN_DEST"
    # The app-local ConPTY runtime and its notices must sit beside the binary,
    # matching the layout Herdr's own Windows installer validates. Copying the
    # directory contents (rather than the directory) keeps a reinstall flat.
    for bundle in conpty THIRD-PARTY-NOTICES; do
      [ -d "$TMP/extract/$bundle" ] \
        || die "$ASSET did not contain the expected $bundle/ directory"
      mkdir -p "$DESTINATION/$bundle"
      cp -R "$TMP/extract/$bundle/." "$DESTINATION/$bundle/" \
        || die "could not install the $bundle/ bundle beside $BIN_DEST"
    done
    ;;
  *)
    install -m 0755 "$TMP/$ASSET" "$DESTINATION/$BIN_DEST"
    ;;
esac

# Post-install version and protocol gates (no floating latest).
installed_version=$("$DESTINATION/$BIN_DEST" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_HERDR_CI_VERSION" ] \
  || die "installed herdr version is '${installed_version:-<empty>}', expected exact pin $FM_HERDR_CI_VERSION"

status=$("$DESTINATION/$BIN_DEST" status --json 2>/dev/null) \
  || die "could not run 'herdr status --json' after install"
protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null) \
  || die "jq is required to parse herdr status after install"
case "$protocol" in
  ''|*[!0-9]*) die "could not read herdr client protocol from status --json" ;;
esac
[ "$protocol" -ge "$FM_HERDR_CI_MIN_PROTOCOL" ] \
  || die "herdr protocol $protocol is below the required floor $FM_HERDR_CI_MIN_PROTOCOL"

printf 'fm-install-herdr.sh: installed herdr %s (protocol %s) to %s\n' \
  "$installed_version" "$protocol" "$DESTINATION/$BIN_DEST" >&2
"$DESTINATION/$BIN_DEST" --version
