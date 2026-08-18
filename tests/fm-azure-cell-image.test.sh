#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT=$ROOT/bin/fm-azure-cell-image.sh

run_guest_script_survives_dash() {
  # Azure's RunShellScript hands the bake payload to /bin/sh. On Ubuntu that is
  # dash, which has no pipefail, so a bare `set -euxo pipefail` aborts on LINE 1
  # and the whole bake silently does nothing. That is what produced a gallery
  # image with no /opt/fm-tools at all, and the pre-gate script captured it.
  local guard
  guard=$(grep -n 'exec /bin/bash' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$guard" ] || fail "the guest bake script has no re-exec guard for a POSIX sh host"
  local strict
  strict=$(grep -n '^set -euxo pipefail' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$strict" ] || fail "the guest bake script no longer sets strict mode"
  [ "$guard" -lt "$strict" ] \
    || fail "the re-exec guard sits AFTER strict mode, so sh still dies before reaching it"

  # Behavioral, not textual. The hazard needs a POSIX sh WITHOUT pipefail, which
  # is dash on the Ubuntu guest. macOS /bin/sh is bash in POSIX mode and accepts
  # pipefail, so prefer a real dash when the host has one and say plainly when
  # the host cannot demonstrate the hazard rather than asserting something
  # weaker and calling it proof. CI runs on Ubuntu, where /bin/sh IS dash.
  local posix_sh
  posix_sh=$(command -v dash || true)
  if [ -z "$posix_sh" ] && ! sh -c 'set -o pipefail' 2>/dev/null; then
    posix_sh=$(command -v sh)
  fi
  local probe
  probe=$(fm_test_tmproot)/guest.sh
  {
    # shellcheck disable=SC2016  # The probe must contain these LITERALLY.
    printf 'if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi\n'
    printf 'set -euxo pipefail\n'
    printf 'printf GUEST-RAN\n'
  } > "$probe"
  if [ -n "$posix_sh" ]; then
    # The bare form must actually die, or the guard below proves nothing.
    if "$posix_sh" -c 'set -euxo pipefail; exit 0' 2>/dev/null; then
      fail "$posix_sh accepts pipefail, so this case cannot demonstrate the hazard"
    fi
    local out
    out=$("$posix_sh" "$probe" 2>/dev/null) \
      || fail "the guarded guest script still fails under $posix_sh"
    assert_contains "$out" "GUEST-RAN" "the guarded guest script did not run its body: $out"
  else
    # No pipefail-less shell here: still prove the guarded script runs at all,
    # and let CI's dash carry the hazard half.
    local out
    out=$(sh "$probe" 2>/dev/null) || fail "the guarded guest script does not even run"
    assert_contains "$out" "GUEST-RAN" "the guarded guest script did not run its body: $out"
    echo "# note: this host has no pipefail-less sh; the hazard half runs on CI dash" >&2
  fi
  pass "the guest bake script re-execs under bash before using pipefail"
}

run_failed_bake_does_not_leak_the_builder() {
  # The builder is billable compute. A bake that refuses to capture used to
  # leave a running D4as_v6 behind with nothing owning it, reclaimed only
  # whenever someone noticed.
  grep -q 'BUILDER_LIVE=1' "$SCRIPT" \
    || fail "nothing tracks whether the builder is still live"
  grep -q 'trap cleanup_builder EXIT' "$SCRIPT" \
    || fail "the builder is not deallocated on exit"
  grep -q 'BUILDER_LIVE=0' "$SCRIPT" \
    || fail "a captured image never clears the live flag, so it deallocates twice"

  # Drive the real cleanup shape with a fake az and prove it deallocates only
  # while the builder is live.
  local tmp
  fm_test_tmproot_into tmp fm-azure-cell-image
  cat > "$tmp/probe.sh" <<'PROBE'
BAKE=$1; KEYDIR=$2; RESOURCE_GROUP=rg; BUILDER=vm-builder; SUBSCRIPTION=sub
command() { shift; printf '%s\n' "$*" >> "$LOG"; }
cleanup_builder() {
  rm -f "$BAKE"
  rm -rf "$KEYDIR"
  if [ "$BUILDER_LIVE" = 1 ]; then
    command az vm deallocate --name "$BUILDER"
  fi
}
BUILDER_LIVE=$3
cleanup_builder
PROBE
  LOG=$tmp/az.log; export LOG; : > "$LOG"
  ( . "$tmp/probe.sh" "$tmp/bake" "$tmp/keys" 1 )
  grep -q "vm deallocate" "$LOG" || fail "a failed bake did not deallocate its builder"
  : > "$LOG"
  ( . "$tmp/probe.sh" "$tmp/bake" "$tmp/keys" 0 )
  [ ! -s "$LOG" ] || fail "a captured bake deallocated its builder a second time: $(cat "$LOG")"
  pass "a bake that does not capture deallocates its builder instead of leaking it"
}

run_guest_script_survives_dash
run_failed_bake_does_not_leak_the_builder

echo "# fm-azure-cell-image.test.sh: all assertions passed"
