#!/usr/bin/env bash
# Opt-in live guard for the Herdr presentation version floor.
#
# The floor's structural signal is the client protocol number, and its mapping
# to real releases is a vendor-supplied fact that no fixture can prove. This
# guard reads that mapping from the REAL release binaries: it fetches each
# pinned upstream asset, verifies its digest, asks it for its own
# `status --json`, and checks the floor classifier's verdict for the release
# identity the binary actually reports. It fails naming the version and protocol
# rather than degrading quietly.
#
# It is opt-in because it downloads upstream release binaries over the network.
# Run it after every Herdr upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Presentation version floor" entry.
#
# Every Herdr invocation, including the downloaded binaries', is routed through
# bin/fm-herdr-lab.sh against a named non-default lab session. Only the
# read-only, session-independent `status --json` client probe is ever run, so no
# lifecycle operation and no server is involved.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_VERSION_FLOOR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_VERSION_FLOOR_LIVE_E2E=1 to run the real-release Herdr version-floor guard"
  exit 0
fi

for tool in herdr jq curl shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
[ -x "$LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) ASSET=herdr-macos-aarch64 ;;
  Darwin/x86_64) ASSET=herdr-macos-x86_64 ;;
  Linux/aarch64|Linux/arm64) ASSET=herdr-linux-aarch64 ;;
  Linux/x86_64) ASSET=herdr-linux-x86_64 ;;
  *) echo "skip: no pinned Herdr release asset for $(uname -s)/$(uname -m)"; exit 0 ;;
esac

# Digests are pinned for the macOS aarch64 assets measured on 2026-08-05; on any
# other platform the asset is still exercised, with the digest recorded in the
# output instead of enforced, because no measurement exists to pin it against.
# tag<TAB>expected-version-prefix<TAB>expected-verdict<TAB>macos-aarch64-sha256
RELEASES=$(cat <<'EOF'
v0.7.5	0.7.5	below	37350546b0012555943b92eaf962665de4e264395baeb44227b8015e8ff5b0d6
preview-2026-07-29-44b3adb12552	0.7.5-preview	below	99941b4a40e852c8f21694c7ec1e96f85abd4f764d9f667757c65fae6e4b065b
v0.8.0	0.8.0	above	d53a9f93fccfdfcc55632927bf51002f5add0aa7990bcdf508ffbd84ac658178
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

while IFS=$'\t' read -r TAG VERSION_PREFIX EXPECTED DIGEST; do
  [ -n "${TAG:-}" ] || continue
  DIR="$TMP_ROOT/$TAG"
  mkdir -p "$DIR"
  if ! curl -fsSL --max-time 300 -o "$DIR/herdr" \
    "https://github.com/ogulcancelik/herdr/releases/download/$TAG/$ASSET"; then
    fail "could not download the pinned Herdr $TAG $ASSET asset; the floor mapping is unverified"
  fi
  chmod +x "$DIR/herdr"
  GOT_DIGEST=$(shasum -a 256 "$DIR/herdr" | awk '{print $1}')
  if [ "$ASSET" = herdr-macos-aarch64 ]; then
    [ "$GOT_DIGEST" = "$DIGEST" ] \
      || fail "Herdr $TAG $ASSET digest changed (expected $DIGEST, got $GOT_DIGEST); re-measure the floor mapping before trusting it"
  fi
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
