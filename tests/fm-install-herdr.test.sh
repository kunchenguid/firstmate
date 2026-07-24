#!/usr/bin/env bash
# Contract tests for the pinned Herdr / Treehouse CI installers, the Treehouse
# upstream-mirror sync helper, and the bounded Herdr lab cleanup helper. The
# Herdr installer pins a prebuilt release asset; the Treehouse installer builds
# the pinned tag+commit from Codebase source; the sync helper refreshes the
# Codebase mirror from upstream without bumping the install pin. These tests
# never download a release asset, clone the source, or reach the network (the
# Treehouse behavioral tests exercise the Go preflight before any clone, and the
# sync test exercises arg parsing before any clone), and never start or stop the
# captain's default Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERDR_INSTALL="$ROOT/bin/fm-install-herdr.sh"
TREEHOUSE_INSTALL="$ROOT/bin/fm-install-treehouse.sh"
TREEHOUSE_SYNC="$ROOT/bin/fm-sync-treehouse-upstream.sh"
CLEANUP="$ROOT/bin/fm-herdr-ci-cleanup.sh"
CI="$ROOT/.github/workflows/ci.yml"

assert_present "$HERDR_INSTALL" "bin/fm-install-herdr.sh is missing"
assert_present "$TREEHOUSE_INSTALL" "bin/fm-install-treehouse.sh is missing"
assert_present "$TREEHOUSE_SYNC" "bin/fm-sync-treehouse-upstream.sh is missing"
assert_present "$CLEANUP" "bin/fm-herdr-ci-cleanup.sh is missing"
[ -x "$HERDR_INSTALL" ] || fail "fm-install-herdr.sh must be executable"
[ -x "$TREEHOUSE_INSTALL" ] || fail "fm-install-treehouse.sh must be executable"
[ -x "$TREEHOUSE_SYNC" ] || fail "fm-sync-treehouse-upstream.sh must be executable"
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

test_treehouse_installer_builds_pinned_source() {
  assert_grep 'FM_TREEHOUSE_CI_VERSION=2.0.1' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must pin the suite-verified 2.0.1 version"
  assert_grep 'FM_TREEHOUSE_CI_COMMIT=5b8ecdec49034fe6861d63b8ea331490bb14c946' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must pin the exact v2.0.1 commit for integrity"
  assert_grep 'code.byted.org/obric/treehouse' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must build from the Codebase source mirror by default"
  assert_grep 'main.version=' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must inject the version via -ldflags -X main.version, matching the upstream Makefile"
  assert_grep 'rev-parse HEAD' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must verify the checked-out commit against the pin"
  # No prebuilt-binary download path any more: source build only.
  assert_no_grep 'releases/download' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must not download a prebuilt release binary"
  assert_no_grep 'kunchenguid.github.io' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must not use the GitHub Pages install script"
  assert_no_grep 'brew install' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must not use a floating package-manager install"
  pass "Treehouse installer builds the pinned v2.0.1 tag+commit from Codebase source"
}

# Go-missing must fail loudly and BEFORE any clone (hermetic: no network).
test_treehouse_installer_requires_go() {
  local dest out rc
  dest=$(mktemp -d "${TMPDIR:-/tmp}/fm-th-nogo.XXXXXX")
  out=$(FM_TREEHOUSE_GO=fm-nonexistent-go-xyz "$TREEHOUSE_INSTALL" "$dest" 2>&1) && rc=0 || rc=$?
  rm -rf "$dest"
  [ "$rc" -ne 0 ] || fail "installer must exit non-zero when the Go toolchain is absent (got rc=0: $out)"
  printf '%s\n' "$out" | grep -Fi 'Go toolchain not found' >/dev/null \
    || fail "installer must report the missing Go toolchain clearly (got: $out)"
  printf '%s\n' "$out" | grep -Fi 'clon' >/dev/null \
    && fail "installer must fail before attempting a clone when Go is absent (got: $out)"
  pass "Treehouse installer fails loudly when the Go toolchain is missing"
}

# A too-old Go toolchain must be rejected against the 1.25 floor, hermetically:
# a fake `go` that reports go1.24.0 and would loudly break if ever invoked to build.
test_treehouse_installer_rejects_old_go() {
  local dir dest out rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-th-oldgo.XXXXXX")
  cat > "$dir/go" <<'SH'
#!/usr/bin/env bash
case "$1" in
  version) echo "go version go1.24.0 linux/amd64" ;;
  *) echo "fake go must not be invoked to build" >&2; exit 99 ;;
esac
SH
  chmod +x "$dir/go"
  dest=$(mktemp -d "${TMPDIR:-/tmp}/fm-th-oldgo-dest.XXXXXX")
  out=$(FM_TREEHOUSE_GO="$dir/go" "$TREEHOUSE_INSTALL" "$dest" 2>&1) && rc=0 || rc=$?
  rm -rf "$dir" "$dest"
  [ "$rc" -ne 0 ] || fail "installer must reject a sub-1.25 Go toolchain (got rc=0: $out)"
  printf '%s\n' "$out" | grep -Fi 'older than the required 1.25' >/dev/null \
    || fail "installer must name the 1.25 floor when Go is too old (got: $out)"
  pass "Treehouse installer rejects a Go toolchain older than 1.25"
}

# The upstream sync helper must be additive and must not bump the install pin.
test_treehouse_sync_is_additive_and_pin_independent() {
  assert_grep 'github.com/kunchenguid/treehouse' "$TREEHOUSE_SYNC" \
    "sync must track the canonical GitHub upstream (provenance)"
  assert_grep 'code.byted.org/obric/treehouse' "$TREEHOUSE_SYNC" \
    "sync must push into the Codebase mirror"
  # Additive only: never a destructive mirror/prune/force/delete push.
  assert_no_grep 'push --mirror' "$TREEHOUSE_SYNC" \
    "sync must not push --mirror (that would prune Codebase-only refs)"
  assert_no_grep '--prune' "$TREEHOUSE_SYNC" \
    "sync must not prune refs"
  assert_no_grep '--force' "$TREEHOUSE_SYNC" \
    "sync must never force-push"
  assert_grep 'refs/pull' "$TREEHOUSE_SYNC" \
    "sync must drop GitHub-only pull refs before pushing"
  # Pin-independence: it must never define or rewrite the installer's pin
  # variables (those are assignments only in fm-install-treehouse.sh; the header
  # here may name them in prose, but must never assign them).
  assert_no_grep 'FM_TREEHOUSE_CI_VERSION=' "$TREEHOUSE_SYNC" \
    "sync must not set the install version pin"
  assert_no_grep 'FM_TREEHOUSE_CI_COMMIT=' "$TREEHOUSE_SYNC" \
    "sync must not set the install commit pin"
  pass "upstream sync is additive, drops pull refs, and never bumps the install pin"
}

# Arg parsing happens before any network access, so this stays hermetic.
test_treehouse_sync_rejects_unknown_arg() {
  local out rc
  out=$("$TREEHOUSE_SYNC" --definitely-not-a-flag 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "sync must exit 2 on an unknown argument (got rc=$rc: $out)"
  printf '%s\n' "$out" | grep -Fi 'usage:' >/dev/null \
    || fail "sync must print usage on an unknown argument (got: $out)"
  pass "upstream sync rejects an unknown argument with a usage error"
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
  assert_grep 'actions/setup-go' "$CI" \
    "CI Herdr lane must provide a Go toolchain for the Treehouse source build"
  assert_grep 'FM_TREEHOUSE_SRC_REPO=https://github.com/kunchenguid/treehouse.git' "$CI" \
    "CI Herdr lane must point the source build at the reachable GitHub mirror"
  assert_grep 'fm-herdr-ci-cleanup.sh snapshot' "$CI" "CI must snapshot sessions before the suite"
  assert_grep 'fm-herdr-ci-cleanup.sh teardown' "$CI" "CI must teardown job-owned sessions after"
  assert_grep "fail-on-gate-skip 'herdr not found'" "$CI" \
    "CI Herdr lane must fail on herdr-not-found"
  assert_grep 'family real-herdr-gated' "$CI" \
    "CI Herdr lane must run only the real-herdr-gated family"
  assert_grep 'lane portable-parallel-1' "$CI" \
    "portable CI must run parallel shard 1"
  assert_grep 'lane portable-parallel-2' "$CI" \
    "portable CI must run parallel shard 2"
  assert_grep 'lane portable-serial' "$CI" \
    "portable CI must run the serial remainder"
  assert_grep 'fm-test-run.sh --check-coverage' "$CI" \
    "CI must prove portable lanes and Herdr partition the complete inventory"
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
test_treehouse_installer_builds_pinned_source
test_treehouse_installer_requires_go
test_treehouse_installer_rejects_old_go
test_treehouse_sync_is_additive_and_pin_independent
test_treehouse_sync_rejects_unknown_arg
test_cleanup_only_targets_job_owned_lab_sessions
test_ci_wires_installers_and_required_lane
