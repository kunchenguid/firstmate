#!/usr/bin/env bash
# Behavior tests for fm-install-no-mistakes.sh, the pinned + checksum-verified
# no-mistakes installer that replaced the unversioned `curl .../main | sh`.
#
# The security-critical contract is FAIL CLOSED: a downloaded artifact whose
# SHA256 does not match the pinned checksum must NOT be installed, and a matching
# artifact installs to the expected location/symlink. These tests source the
# installer (its BASH_SOURCE guard keeps main from running on source), stub the
# download with a local `curl` shim, and point the install/symlink dirs at temp
# dirs so the LIVE ~/.no-mistakes install is never touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-install-no-mistakes-tests)

# Source the installer for its functions; the guard keeps nm_install_main from
# running here.
# shellcheck source=bin/fm-install-no-mistakes.sh
. "$ROOT/bin/fm-install-no-mistakes.sh"

# A fake `curl` that "downloads" by copying a local file (our base URL is a local
# dir), plus real tar/sha256sum from the system. Fails like curl -f on a missing
# source so the installer's download-failure path is exercised too.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
dest=""; src=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    -*) shift ;;
    *) src="$1"; shift ;;
  esac
done
[ -n "$src" ] || exit 2
[ -f "$src" ] || exit 22
cp "$src" "$dest"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# Build a fake release tarball (containing a stub `no-mistakes` binary) for the
# current platform under <artifacts>/<version>/, echo the tarball path.
build_fake_tarball() {
  local artifacts=$1 platform version pkg tarball
  version="$NO_MISTAKES_PINNED_VERSION"
  platform="$(nm_platform)"
  pkg="$artifacts/pkgroot"
  mkdir -p "$pkg" "$artifacts/$version"
  cat > "$pkg/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "fake no-mistakes ${*}"
SH
  chmod +x "$pkg/no-mistakes"
  tarball="$artifacts/$version/no-mistakes-${version}-${platform}.tar.gz"
  tar czf "$tarball" -C "$pkg" no-mistakes
  printf '%s\n' "$tarball"
}

# --- nm_verify_sha256: correct passes, wrong fails --------------------------
test_verify_sha256_both_directions() {
  local dir file correct wrong
  dir="$TMP_ROOT/verify"
  mkdir -p "$dir"
  file="$dir/blob"
  printf 'squared-away pinned artifact\n' > "$file"
  correct=$(nm_sha256_of "$file")
  wrong="0000000000000000000000000000000000000000000000000000000000000000"

  nm_verify_sha256 "$file" "$correct" || fail "verify: a correct SHA256 must pass"
  if nm_verify_sha256 "$file" "$wrong"; then
    fail "verify: a wrong SHA256 must fail closed"
  fi
  pass "nm_verify_sha256 passes the correct checksum and rejects a wrong one"
}

# --- end-to-end: a checksum MISMATCH fails closed, installs nothing ---------
# Uses the REAL pinned checksum table (not overridden), so the fake tarball's
# sha cannot match: proves the pinned checksum is actually consulted and that a
# non-matching artifact never lands.
test_install_rejects_mismatched_artifact() {
  local case_dir fakebin artifacts idir ldir out rc
  case_dir="$TMP_ROOT/mismatch"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  artifacts="$case_dir/artifacts"
  build_fake_tarball "$artifacts" >/dev/null
  idir="$case_dir/install"; ldir="$case_dir/link"
  mkdir -p "$idir" "$ldir"

  out=$(
    PATH="$fakebin:$BASE_PATH"; export PATH
    HOME="$case_dir/fakehome"; export HOME
    NO_MISTAKES_INSTALL_DIR="$idir"; export NO_MISTAKES_INSTALL_DIR
    NO_MISTAKES_LINK_DIR="$ldir"; export NO_MISTAKES_LINK_DIR
    FM_NO_MISTAKES_BASE_URL="$artifacts"; export FM_NO_MISTAKES_BASE_URL
    FM_NO_MISTAKES_SKIP_DAEMON=1; export FM_NO_MISTAKES_SKIP_DAEMON
    nm_install_main 2>&1
  )
  rc=$?

  [ "$rc" -ne 0 ] || fail "mismatch: installer must exit non-zero on checksum mismatch (got 0)"$'\n'"$out"
  assert_contains "$out" "checksum verification FAILED" "mismatch: should report a checksum failure"
  assert_absent "$idir/no-mistakes" "mismatch: no binary may be installed on a checksum failure"
  assert_absent "$ldir/no-mistakes" "mismatch: no symlink may be created on a checksum failure"
  pass "installer fails closed on a checksum mismatch and installs nothing"
}

# --- end-to-end: a MATCHING artifact installs to the expected layout --------
# Overrides pinned_sha256 (inside the subshell only) to the fake tarball's real
# sha, proving the download -> verify -> install -> symlink mechanism end to end.
test_install_accepts_verified_artifact() {
  local case_dir fakebin artifacts tarball fake_sha idir ldir out rc
  case_dir="$TMP_ROOT/match"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  artifacts="$case_dir/artifacts"
  tarball=$(build_fake_tarball "$artifacts")
  fake_sha=$(nm_sha256_of "$tarball")
  idir="$case_dir/install"; ldir="$case_dir/link"
  mkdir -p "$idir" "$ldir"

  out=$(
    PATH="$fakebin:$BASE_PATH"; export PATH
    HOME="$case_dir/fakehome"; export HOME
    NO_MISTAKES_INSTALL_DIR="$idir"; export NO_MISTAKES_INSTALL_DIR
    NO_MISTAKES_LINK_DIR="$ldir"; export NO_MISTAKES_LINK_DIR
    FM_NO_MISTAKES_BASE_URL="$artifacts"; export FM_NO_MISTAKES_BASE_URL
    FM_NO_MISTAKES_SKIP_DAEMON=1; export FM_NO_MISTAKES_SKIP_DAEMON
    # shellcheck disable=SC2317 # Invoked indirectly by nm_install_main below.
    pinned_sha256() { echo "$fake_sha"; }
    nm_install_main 2>&1
  )
  rc=$?

  [ "$rc" -eq 0 ] || fail "match: verified install must succeed (rc=$rc)"$'\n'"$out"
  assert_present "$idir/no-mistakes" "match: binary must be installed"
  [ -x "$idir/no-mistakes" ] || fail "match: installed binary must be executable"
  [ -L "$ldir/no-mistakes" ] || fail "match: a symlink must be created at the link path"
  [ "$(readlink "$ldir/no-mistakes")" = "$idir/no-mistakes" ] \
    || fail "match: symlink must point at the installed binary"
  assert_contains "$out" "installed to" "match: should confirm the install"
  pass "installer verifies and installs a matching artifact to the expected layout"
}

test_verify_sha256_both_directions
test_install_rejects_mismatched_artifact
test_install_accepts_verified_artifact
