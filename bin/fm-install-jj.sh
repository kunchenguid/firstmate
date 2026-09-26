#!/usr/bin/env bash
# fm-install-jj.sh - install CI's pinned, verified Jujutsu (jj) build.
#
# Single owner of the exact jj version, official release asset URL, and SHA-256
# pin used by the portable-serial CI lane's jj colocated-home tests. Never
# installs a floating package-manager latest.
#
# Usage:
#   fm-install-jj.sh <destination-directory>
#
# Pins jj v0.45.1, the suite-verified colocated-home release. Selects the
# official GitHub Releases asset for the host OS/arch, downloads with a bounded
# max size, verifies SHA-256 before install, then refuses to finish unless the
# binary reports the pinned version.
set -eu

# Exact pin - change only with a re-verified jj colocated-home matrix.
FM_JJ_CI_VERSION=0.45.1
FM_JJ_CI_TAG="v${FM_JJ_CI_VERSION}"
# Bounded download ceiling (bytes). The largest official 0.45.1 asset is under 15 MiB.
FM_JJ_CI_MAX_BYTES=20000000
FM_JJ_CI_REPO=jj-vcs/jj

die() {
  printf 'fm-install-jj.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-jj.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET=jj-v${FM_JJ_CI_VERSION}-x86_64-unknown-linux-musl.tar.gz
    SHA256=f35438350b5d61963aac5dd74ede510b31d6b9690769d1a6268cf058cc825f72
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=jj-v${FM_JJ_CI_VERSION}-aarch64-unknown-linux-musl.tar.gz
    SHA256=7349a43dd5a20dbc998b10114daa0ee63d2ab863fb822c7eb6b0ebca5903cc69
    ;;
  Darwin-arm64)
    ASSET=jj-v${FM_JJ_CI_VERSION}-aarch64-apple-darwin.tar.gz
    SHA256=51ba42e3d0682616f6eb015045bfe45289b396f03511f9897f645ce8e9272743
    ;;
  Darwin-x86_64)
    ASSET=jj-v${FM_JJ_CI_VERSION}-x86_64-apple-darwin.tar.gz
    SHA256=6171582d0b5a98a1005cd9643faebff7936812ec264d7968a39d9cef3654a99b
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official jj assets are linux/macos x86_64 and aarch64"
    ;;
esac

URL="https://github.com/${FM_JJ_CI_REPO}/releases/download/${FM_JJ_CI_TAG}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-jj.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-jj.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
# --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
curl -fsSL --max-filesize "$FM_JJ_CI_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_JJ_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the jj asset"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

mkdir -p "$DESTINATION"
tar -xzf "$TMP/$ASSET" -C "$TMP" \
  || die "failed to extract $ASSET"
install -m 0755 "$TMP/jj" "$DESTINATION/jj"

# Post-install version gate (no floating latest). The release binary reports
# "jj 0.45.1-<commit>", so accept the pin as a version prefix rather than an
# exact whole string.
installed_version=$("$DESTINATION/jj" --version 2>/dev/null | awk '{print $2; exit}')
case "$installed_version" in
  "${FM_JJ_CI_VERSION}"*) : ;;
  *) die "installed jj version is '${installed_version:-<empty>}', expected pin $FM_JJ_CI_VERSION" ;;
esac

printf 'fm-install-jj.sh: installed jj %s to %s\n' \
  "$installed_version" "$DESTINATION/jj" >&2
"$DESTINATION/jj" --version
