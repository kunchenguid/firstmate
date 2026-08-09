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

assert_present "$HERDR_INSTALL" "bin/fm-install-herdr.sh is missing"
assert_present "$TREEHOUSE_INSTALL" "bin/fm-install-treehouse.sh is missing"
assert_present "$CLEANUP" "bin/fm-herdr-ci-cleanup.sh is missing"
[ -x "$HERDR_INSTALL" ] || fail "fm-install-herdr.sh must be executable"
[ -x "$TREEHOUSE_INSTALL" ] || fail "fm-install-treehouse.sh must be executable"
[ -x "$CLEANUP" ] || fail "fm-herdr-ci-cleanup.sh must be executable"

test_herdr_installer_pins_exact_version_and_checksums() {
  local dir fakebin dest
  dir=$(fm_test_tmproot fm-herdr-installer)
  fakebin=$(fm_fakebin "$dir")
  dest="$dir/dest"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
out=
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out=$2; shift 2; continue; }
  shift
done
cat > "$out" <<'BIN'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'herdr 0.7.4\n' ;;
  status) printf '{"client":{"protocol":16}}\n' ;;
esac
BIN
chmod +x "$out"
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '%s  %s\n' bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059 "$1"
SH
  chmod +x "$fakebin/curl" "$fakebin/sha256sum"
  PATH="$fakebin:$PATH" RUNNER_TEMP="$dir" "$HERDR_INSTALL" "$dest" >/dev/null \
    || fail "Herdr installer rejected a valid pinned fixture"
  [ "$("$dest/herdr" --version)" = 'herdr 0.7.4' ] \
    || fail "installed Herdr fixture did not report the pinned version"
  pass "Herdr installer executes checksum, version, and protocol gates"
}

test_treehouse_installer_pins_exact_version_and_checksums() {
  local dir fakebin dest
  dir=$(fm_test_tmproot fm-treehouse-installer)
  fakebin=$(fm_fakebin "$dir")
  dest="$dir/dest"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
out=
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out=$2; shift 2; continue; }
  shift
done
: > "$out"
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '%s  %s\n' 1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2 "$1"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
dest=
while [ "$#" -gt 0 ]; do
  [ "$1" = -C ] && { dest=$2; shift 2; continue; }
  shift
done
cat > "$dest/treehouse" <<'BIN'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf 'v2.0.1\n'
BIN
chmod +x "$dest/treehouse"
SH
  chmod +x "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/tar"
  PATH="$fakebin:$PATH" RUNNER_TEMP="$dir" "$TREEHOUSE_INSTALL" "$dest" >/dev/null \
    || fail "Treehouse installer rejected a valid pinned fixture"
  [ "$("$dest/treehouse" --version)" = 'v2.0.1' ] \
    || fail "installed Treehouse fixture did not report the pinned version"
  pass "Treehouse installer executes checksum and version gates"
}

test_herdr_installer_pins_exact_version_and_checksums
test_treehouse_installer_pins_exact_version_and_checksums
