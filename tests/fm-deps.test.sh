#!/usr/bin/env bash
# Focused tests for the Linux dependency checker. Network calls and upgrades
# stay outside this suite; fixtures exercise Debian version ordering, APT
# metadata parsing, quiet-window deferral, and NVM upgrade command selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEPS="$ROOT/bin/fm-deps.sh"
TMP_ROOT=$(fm_test_tmproot fm-deps-tests)

# shellcheck source=bin/fm-deps.sh
FM_DEPS_SOURCE_ONLY=1 FM_ROOT_OVERRIDE="$ROOT" . "$DEPS"

test_version_ordering() {
  version_is_older 1.2.3 1.2.4 || fail "semver patch update was not detected"
  version_is_older 3.7a 3.7b || fail "lettered patch update was not detected"
  version_is_older 2.45.0-1ubuntu0.2 2.45.0-1ubuntu0.3 \
    || fail "Debian revision update was not detected"
  ! version_is_older 2.0.0 1.9.9 || fail "downgrade was treated as an update"
  ! version_is_older 1.2.3 1.2.3 || fail "equal versions were treated as an update"
  pass "version ordering uses Debian's native comparison semantics"
}

test_apt_metadata() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/apt")
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'install ok installed\\t2.45.0-1ubuntu0.2\\n'" > "$fakebin/dpkg-query"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'gh:\\n  Installed: 2.45.0-1ubuntu0.2\\n  Candidate: 2.45.0-1ubuntu0.3\\n'" > "$fakebin/apt-cache"
  chmod +x "$fakebin/dpkg-query" "$fakebin/apt-cache"

  out=$(PATH="$fakebin:$PATH" apt_package_versions gh)
  [ "$out" = $'2.45.0-1ubuntu0.2\t2.45.0-1ubuntu0.3' ] \
    || fail "APT versions were parsed incorrectly: $out"
  pass "APT installed and candidate versions are parsed without refreshing indexes"
}

test_quiet_window_defers() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/quiet")
  # shellcheck disable=SC2016 # literal fixture script; expansion happens when it runs.
  printf '%s\n' '#!/usr/bin/env bash' '[ "${2:-}" = codex ]' > "$fakebin/pgrep"
  chmod +x "$fakebin/pgrep"

  # shellcheck disable=SC2034 # consumed by the sourced offer_update function.
  AVAILABLE=0 DEFERRED=0 CHECK_ONLY=1
  out=$(PATH="$fakebin:$PATH" offer_update codex Codex 0.146.0 0.147.0 quiet)
  assert_contains "$out" "UPDATE: Codex 0.146.0 -> 0.147.0 [quiet window]" \
    "Codex update was reported"
  assert_contains "$out" "DEFER: Codex - Codex process is active; close Codex and rerun" \
    "active Codex process deferred update"
  pass "quiet-window upgrades defer while their runtime is active"
}

test_node_upgrade_uses_nvm() {
  local nvm_dir log
  nvm_dir="$TMP_ROOT/nvm"
  log="$TMP_ROOT/nvm.log"
  mkdir -p "$nvm_dir"
  # shellcheck disable=SC2016 # literal fixture function; expansion happens when sourced.
  printf '%s\n' 'nvm() {' '  printf '\''%s\\n'\'' "$*" >> "$FM_DEPS_TEST_LOG"' '}' \
    > "$nvm_dir/nvm.sh"

  FM_DEPS_NVM_DIR="$nvm_dir" FM_DEPS_TEST_LOG="$log" \
    run_upgrade node 24.18.0 24.19.0
  assert_grep "install 24.19.0 --reinstall-packages-from=24.18.0" "$log" \
    "Node upgrade did not preserve global packages"
  assert_grep "alias default 24.19.0" "$log" \
    "Node upgrade did not move the NVM default alias"
  pass "Node upgrades stay on the selected release and preserve NVM globals"
}

test_version_ordering
test_apt_metadata
test_quiet_window_defers
test_node_upgrade_uses_nvm

echo "# all fm-deps tests passed"
