#!/usr/bin/env bash
# fm-install-hc.sh - install a pinned, verified Herdr Core (`hc`) build.
#
# Single owner of the exact herdr-core version, official release asset URLs,
# and SHA-256 pins used by the real-hc lab lane and by operators who want the
# verified build. Never installs a floating latest, and never runs upstream's
# install.sh or `hc update` - self-update is an operator-run step (the
# manifest pins below change only with a re-verified matrix).
#
# Usage:
#   fm-install-hc.sh <destination-directory>
#
# Pins herdr-core 0.1.14 (protocol generation 1), the suite-verified release.
# Selects the official releases.herdr.dev tarball for the host OS/arch,
# downloads with a bounded max size, verifies SHA-256 before install, extracts
# the `herdr-core` binary, then refuses to finish unless the installed binary
# reports `hc 0.1.14` exactly. The adapter (bin/backends/hc.sh) resolves
# `herdr-core` before the `hc` alias, so the asset name is what gets installed.
set -eu

FM_HC_PIN_VERSION=0.1.14
# Bounded download ceiling (bytes). The largest official 0.1.14 tarball is
# under 3 MiB.
FM_HC_MAX_BYTES=25000000
FM_HC_RELEASES=https://releases.herdr.dev/core

die() {
  printf 'fm-install-hc.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-hc.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    TARGET=linux-x86_64
    SHA256=e9dbabdead0ce0ce3de51b6f54cc9549efedbb41b2f8448b6932ab0d1442343e
    ;;
  Linux-aarch64|Linux-arm64)
    TARGET=linux-aarch64
    SHA256=19cef6a2e52f14c22c4b6f3fdaf1a462d2dafc78e8b03fabbfad5b063477a370
    ;;
  Darwin-arm64)
    TARGET=macos-aarch64
    SHA256=ca524329d2e0630219550055dcc71f42aafd85fba356e0d543d6f51244487970
    ;;
  Darwin-x86_64)
    TARGET=macos-x86_64
    SHA256=8e16ec43a17656f80e7d7f98292bf710c60c4aeff52941cca98fb24f37f35028
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official herdr-core assets are linux/macos x86_64 and aarch64"
    ;;
esac

ASSET="herdr-core-${TARGET}.tar.gz"
URL="${FM_HC_RELEASES}/${FM_HC_PIN_VERSION}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-hc-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-hc.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
# --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
curl -fsSL --max-filesize "$FM_HC_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_HC_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the herdr-core asset"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

tar -xzf "$TMP/$ASSET" -C "$TMP" || die "could not extract $ASSET"
[ -f "$TMP/herdr-core" ] || die "$ASSET did not contain a herdr-core binary"

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/herdr-core" "$DESTINATION/herdr-core"

# Post-install version and self-identity gates (no floating latest). The
# binary self-identifies as `hc x.y.z`; anything else is not Herdr Core.
installed_version=$("$DESTINATION/herdr-core" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_HC_PIN_VERSION" ] \
  || die "installed herdr-core reports version '$installed_version', expected $FM_HC_PIN_VERSION"
printf 'fm-install-hc.sh: installed herdr-core %s (protocol generation 1) to %s/herdr-core\n' \
  "$installed_version" "$DESTINATION" >&2
