#!/usr/bin/env bash
# Contract tests for the pinned Herdr / Treehouse CI installers and the
# bounded Herdr lab cleanup helper. These tests do not download release assets
# and never start or stop the captain's default Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERDR_INSTALL="$ROOT/bin/fm-install-herdr.sh"
TREEHOUSE_INSTALL="$ROOT/bin/fm-install-treehouse.sh"
CLEANUP="$ROOT/bin/fm-herdr-ci-cleanup.sh"
CI="$ROOT/.github/workflows/ci.yml"

assert_present "$HERDR_INSTALL" "bin/fm-install-herdr.sh is missing"
assert_present "$TREEHOUSE_INSTALL" "bin/fm-install-treehouse.sh is missing"
assert_present "$CLEANUP" "bin/fm-herdr-ci-cleanup.sh is missing"
[ -x "$HERDR_INSTALL" ] || fail "fm-install-herdr.sh must be executable"
[ -x "$TREEHOUSE_INSTALL" ] || fail "fm-install-treehouse.sh must be executable"
[ -x "$CLEANUP" ] || fail "fm-herdr-ci-cleanup.sh must be executable"

test_herdr_installer_pins_exact_version_and_checksums() {
  assert_grep 'FM_HERDR_CI_VERSION=0.7.4' "$HERDR_INSTALL" \
    "Herdr installer must pin suite-verified 0.7.4"
  assert_grep 'FM_HERDR_CI_MIN_PROTOCOL=16' "$HERDR_INSTALL" \
    "Herdr installer must require protocol floor 16"
  assert_grep 'ogulcancelik/herdr' "$HERDR_INSTALL" \
    "Herdr installer must use the official GitHub release source"
  assert_grep 'herdr-linux-x86_64' "$HERDR_INSTALL" \
    "Herdr installer must name the Linux x86_64 release asset"
  assert_grep 'bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059' "$HERDR_INSTALL" \
    "Herdr installer must pin the Linux x86_64 SHA-256"
  assert_grep 'sha256sum' "$HERDR_INSTALL" \
    "Herdr installer must verify a SHA-256 checksum"
  assert_grep '--max-filesize' "$HERDR_INSTALL" \
    "Herdr installer must bound the download size"
  assert_no_grep 'brew install' "$HERDR_INSTALL" \
    "Herdr installer must not use a floating package-manager install"
  assert_no_grep 'apt-get install' "$HERDR_INSTALL" \
    "Herdr installer must not use a floating package-manager install"
  pass "Herdr installer pins exact version, asset, checksum, and protocol floor"
}

test_treehouse_installer_pins_exact_version_and_checksums() {
  assert_grep 'FM_TREEHOUSE_CI_VERSION=2.0.1' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must pin the suite-verified 2.0.1 release"
  assert_grep 'kunchenguid/treehouse' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must use the official GitHub release source"
  assert_grep 'linux-amd64.tar.gz' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must name the Linux amd64 archive"
  assert_grep '1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must pin the Linux amd64 SHA-256"
  assert_grep '--max-filesize' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must bound the download size"
  assert_no_grep 'brew install' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must not use a floating package-manager install"
  pass "Treehouse installer pins exact version, asset, and checksum"
}

test_cleanup_only_targets_job_owned_lab_sessions() {
  assert_grep 'fm-lab-' "$CLEANUP" \
    "cleanup must only consider fm-lab-* session names"
  assert_grep 'default == false' "$CLEANUP" \
    "cleanup must refuse default sessions"
  assert_grep 'snapshot' "$CLEANUP" \
    "cleanup must support a pre-suite snapshot"
  assert_grep 'teardown' "$CLEANUP" \
    "cleanup must support post-suite teardown of the delta"
  # Must not call ambient server stop.
  assert_no_grep 'server stop' "$CLEANUP" \
    "cleanup must never call ambient herdr server stop"
  pass "cleanup is bounded to job-owned fm-lab-* sessions"
}

test_ci_wires_installers_and_required_lane() {
  assert_grep 'tests-herdr:' "$CI" "CI must define the required Herdr Behavior job"
  assert_grep 'fm-install-herdr.sh' "$CI" "CI must call the Herdr installer"
  assert_grep 'fm-install-treehouse.sh' "$CI" "CI must call the Treehouse installer"
  assert_grep 'fm-herdr-ci-cleanup.sh snapshot' "$CI" "CI must snapshot sessions before the suite"
  assert_grep 'fm-herdr-ci-cleanup.sh teardown' "$CI" "CI must teardown job-owned sessions after"
  assert_grep "fail-on-gate-skip 'herdr not found'" "$CI" \
    "CI Herdr lane must fail on herdr-not-found"
  assert_grep 'family real-herdr-gated' "$CI" \
    "CI Herdr lane must run only the real-herdr-gated family"
  assert_grep 'exclude-family real-herdr-gated' "$CI" \
    "portable CI lane must exclude real-herdr-gated once the Herdr job owns it"
  # Live harness credential tests must stay out of the default Herdr lane.
  assert_no_grep 'live-harness-optin' "$CI" \
    "CI must not run live-harness-optin in the required Herdr lane"
  assert_no_grep 'FM_AFK_PI_HERDR_E2E' "$CI" \
    "CI must not enable live Pi/Herdr credential tests"
  assert_no_grep 'FM_SEND_MARKER_HERDR_E2E' "$CI" \
    "CI must not enable live marker Herdr credential tests"
  pass "CI wires pinned installers into a required serial Herdr lane"
}

test_herdr_installer_pins_exact_version_and_checksums
test_treehouse_installer_pins_exact_version_and_checksums
test_cleanup_only_targets_job_owned_lab_sessions
test_ci_wires_installers_and_required_lane
