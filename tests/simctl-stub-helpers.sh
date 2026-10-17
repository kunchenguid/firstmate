#!/usr/bin/env bash
# tests/simctl-stub-helpers.sh - the shared fake `xcrun` fixture writer that
# keeps the host's real Simulator set out of teardown-driven runs.
#
# docs/configuration.md "Task Simulator cleanup" owns device selection and opt-in.
# Any fixture that drives the real script must shadow `xcrun` with this stub instead of letting
# the host answer for it. tests/lib.sh installs the stub into every fm_fakebin
# dir and onto the shared test PATH for suites that source it,
# tests/herdr-test-safety.sh installs it for the real-Herdr suites that never
# source tests/lib.sh, and tests/remote-herdr-fixture.sh drops it beside the
# fake remote herdr CLI so remote-side spawn/teardown paths stay isolated too.
#
# Usage:
#   # shellcheck source=tests/simctl-stub-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/simctl-stub-helpers.sh"
#   fm_test_fake_simctl <dir-that-should-hold-xcrun>
#
# The stub appends every `simctl` invocation to $FM_SIMCTL_LOG, answers
# `simctl list devices` from $FM_FAKE_SIMCTL_LIST_FILE, refuses
# `simctl shutdown <udid>` when that list already reports the UDID Shutdown,
# and refuses `simctl delete <udid>` when FM_FAKE_SIMCTL_DELETE_FAIL=1. Every
# other xcrun invocation exits 0. tests/fm-teardown.test.sh and
# tests/fm-test-fixtures.test.sh exercise the contract.

fm_test_fake_simctl() {
  local fakebin=$1
  cat > "$fakebin/xcrun" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = simctl ]; then
  printf 'simctl %s\n' "${*:2}" >> "${FM_SIMCTL_LOG:-/dev/null}"
fi
if [ "${1:-} ${2:-} ${3:-}" = "simctl list devices" ]; then
  cat "${FM_FAKE_SIMCTL_LIST_FILE:-/dev/null}"
  exit 0
fi
if [ "${1:-} ${2:-}" = "simctl shutdown" ] &&
  jq -e --arg udid "${3:-}" '.devices[][]? | select(.udid == $udid and .state == "Shutdown")' \
    "${FM_FAKE_SIMCTL_LIST_FILE:-/dev/null}" >/dev/null 2>&1; then
  exit 1
fi
if [ "${1:-} ${2:-}" = "simctl delete" ] && [ "${FM_FAKE_SIMCTL_DELETE_FAIL:-0}" = 1 ]; then
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/xcrun"
}
