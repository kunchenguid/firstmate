#!/usr/bin/env bash
# Default-on live guard for the Herdr presentation version floor.
#
# Protocol is the floor's structural signal, and its mapping to real releases
# is a vendor-supplied fact that no fixture can prove. The runtime gate checks
# both the client and any selected running server; this guard measures the
# release mapping from each REAL release binary's client report by fetching each
# pinned upstream asset, verifies its digest, asks it for its own
# `status --json`, and checks the floor classifier's verdict for the release
# identity the binary actually reports. It fails naming the version and protocol
# rather than degrading quietly.
#
# A run downloads upstream release binaries over the network but submits no
# prompt, so the shared live gate runs it by default wherever its tools exist.
# Run it after every Herdr upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Presentation version floor" entry.
#
# Every Herdr invocation, including the downloaded binaries', is routed through
# bin/fm-herdr-lab.sh against a named non-default lab session. Only the
# read-only, session-independent `status --json` client probe is ever run, so no
# lifecycle operation and no server is involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_VERSION_FLOOR_LIVE_E2E herdr jq curl shasum

[ -x "$LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) ASSET=herdr-macos-aarch64 ;;
  Darwin/x86_64) ASSET=herdr-macos-x86_64 ;;
  Linux/aarch64|Linux/arm64) ASSET=herdr-linux-aarch64 ;;
  Linux/x86_64) ASSET=herdr-linux-x86_64 ;;
  *) echo "skip: no pinned Herdr release asset for $(uname -s)/$(uname -m)"; exit 0 ;;
esac

# Digests are pinned for every supported asset measured on 2026-08-05.
# tag<TAB>expected-version-prefix<TAB>expected-verdict<TAB>macos-aarch64-sha256<TAB>macos-x86_64-sha256<TAB>linux-aarch64-sha256<TAB>linux-x86_64-sha256
RELEASES=$(cat <<'EOF'
v0.7.5	0.7.5	below	37350546b0012555943b92eaf962665de4e264395baeb44227b8015e8ff5b0d6	3fe50c4a63dc8102306b1322178628ddb3655cd3ae56d784f094153408d69e62	32e763a1499a6b694b1d708e4f062b743be1da9f34fcfa4d212d6db6fe09a8b9	3dc83288073e4c2d3c679a30e7be97bcca9141c6fd17dbbb9219142e95c59253
preview-2026-07-29-44b3adb12552	0.7.5-preview	below	99941b4a40e852c8f21694c7ec1e96f85abd4f764d9f667757c65fae6e4b065b	b9316cdff4802f325f6b77b83ea36cd33deb8da4ef9efa8454423b0ce8de77fc	2167fb9127d0a67c1dad368d54e6468fd7c2a3858b832922c7f0c264d012be13	2d50d64ab849c3d0f5d0d53e0bebd00fa94d5ed120797532c8fcfd1a679ebc19
v0.8.0	0.8.0	above	d53a9f93fccfdfcc55632927bf51002f5add0aa7990bcdf508ffbd84ac658178	77cb5afd6c8fcaaaf3bc28e474ec01c209331ad08094e20d7f8aa9b0bb78d649	f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87	b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28
EOF
)

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-version-floor.XXXXXX")
ORIGINAL_PATH=$PATH
LAB_SESSION=$("$LAB_HELPER" name fm-herdr-version-floor)
cleanup() {
  local status=$?
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

# The probe is read-only and session-independent, so it needs no provisioned lab
# server; routing it through the helper keeps the named non-default session the
# only session any of these binaries can ever be pointed at.
probe_client() {  # <binary-dir> -> "<version>\t<protocol>"
  local dir=$1 out
  out=$(PATH="$dir:$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" status --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er '"\(.client.version)\t\(.client.protocol)"' 2>/dev/null
}

floor_verdict() {  # <protocol> <version> -> above|below|indeterminate
  bash -c '
    . "$0/bin/backends/herdr.sh"
    status=0
    fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
    case "$status" in
      0) printf "above\n" ;;
      1) printf "below\n" ;;
      *) printf "indeterminate\n" ;;
    esac
  ' "$ROOT" "$1" "$2"
}

CHECKED=0

# The installed release first, so an environment with no network still proves
# the classifier agrees with the Herdr this machine actually runs.
INSTALLED_DIR="$TMP_ROOT/installed"
mkdir -p "$INSTALLED_DIR"
ln -sf "$(command -v herdr)" "$INSTALLED_DIR/herdr"
INSTALLED=$(probe_client "$INSTALLED_DIR") \
  || fail 'the installed herdr client did not report a readable version and protocol'
INSTALLED_VERSION=${INSTALLED%%$'\t'*}
INSTALLED_PROTOCOL=${INSTALLED#*$'\t'}
INSTALLED_VERDICT=$(floor_verdict "$INSTALLED_PROTOCOL" "$INSTALLED_VERSION")
[ "$INSTALLED_VERDICT" != indeterminate ] \
  || fail "the installed herdr $INSTALLED_VERSION (protocol $INSTALLED_PROTOCOL) could not be classified against the presentation floor"
CHECKED=$((CHECKED + 1))
pass "installed herdr $INSTALLED_VERSION protocol $INSTALLED_PROTOCOL classifies $INSTALLED_VERDICT the presentation floor"

while IFS=$'\t' read -r TAG VERSION_PREFIX EXPECTED MACOS_AARCH64_DIGEST MACOS_X86_64_DIGEST LINUX_AARCH64_DIGEST LINUX_X86_64_DIGEST; do
  [ -n "${TAG:-}" ] || continue
  case "$ASSET" in
    herdr-macos-aarch64) DIGEST=$MACOS_AARCH64_DIGEST ;;
    herdr-macos-x86_64) DIGEST=$MACOS_X86_64_DIGEST ;;
    herdr-linux-aarch64) DIGEST=$LINUX_AARCH64_DIGEST ;;
    herdr-linux-x86_64) DIGEST=$LINUX_X86_64_DIGEST ;;
    *) fail "no pinned digest field for $ASSET" ;;
  esac
  DIR="$TMP_ROOT/$TAG"
  mkdir -p "$DIR"
  if ! curl -fsSL --max-time 300 -o "$DIR/herdr" \
    "https://github.com/ogulcancelik/herdr/releases/download/$TAG/$ASSET"; then
    fail "could not download the pinned Herdr $TAG $ASSET asset; the floor mapping is unverified"
  fi
  GOT_DIGEST=$(shasum -a 256 "$DIR/herdr" | awk '{print $1}')
  [ "$GOT_DIGEST" = "$DIGEST" ] \
    || fail "Herdr $TAG $ASSET digest changed (expected $DIGEST, got $GOT_DIGEST); re-measure the floor mapping before trusting it"
  chmod +x "$DIR/herdr"
  RELEASE=$(probe_client "$DIR") \
    || fail "Herdr $TAG did not report a readable version and protocol"
  GOT_VERSION=${RELEASE%%$'\t'*}
  GOT_PROTOCOL=${RELEASE#*$'\t'}
  case "$GOT_VERSION" in
    "$VERSION_PREFIX"*) ;;
    *) fail "Herdr $TAG reported version $GOT_VERSION, which does not start with the expected $VERSION_PREFIX" ;;
  esac
  GOT_VERDICT=$(floor_verdict "$GOT_PROTOCOL" "$GOT_VERSION")
  [ "$GOT_VERDICT" = "$EXPECTED" ] \
    || fail "Herdr $TAG reports version $GOT_VERSION protocol $GOT_PROTOCOL, which the presentation floor classifies $GOT_VERDICT instead of $EXPECTED"
  CHECKED=$((CHECKED + 1))
  pass "herdr $TAG: version $GOT_VERSION protocol $GOT_PROTOCOL classifies $EXPECTED the presentation floor (sha256 $GOT_DIGEST)"
done <<EOF
$RELEASES
EOF

[ "$CHECKED" -ge 4 ] \
  || fail "the version-floor guard checked only $CHECKED releases; a pass that verified nothing is not a pass"
printf 'evidence: asset=%s releases_checked=%s installed=%s protocol=%s\n' \
  "$ASSET" "$CHECKED" "$INSTALLED_VERSION" "$INSTALLED_PROTOCOL"
