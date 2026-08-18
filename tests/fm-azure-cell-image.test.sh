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

run_guest_waits_for_egress_before_downloading() {
  # NAT egress is not usable the instant `az vm create` returns. Two consecutive
  # bakes died on apt "connection timed out" against the mirror, and the same
  # builder reached the same URL fine a minute later. Every step in the bake
  # downloads something, so the wait has to come before the FIRST one or it
  # guards nothing.
  local wait_line first_download
  wait_line=$(grep -n 'egress_ready=1' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$wait_line" ] || fail "the guest bake script does not wait for egress at all"
  # The first thing that reaches the network: apt, or any curl of a pinned tool.
  first_download=$(grep -nE '^(apt-get update|curl -fsSL)' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$first_download" ] || fail "no download step found, so this ordering proves nothing"
  [ "$wait_line" -lt "$first_download" ] \
    || fail "the egress wait runs AFTER the first download, which is the one that fails"

  # It must also give up rather than bake half an image against a dead network.
  grep -q 'builder has no egress' "$SCRIPT" \
    || fail "a builder with no egress does not refuse; it would bake an incomplete image"
  pass "the guest bake script proves egress before its first download"
}

run_host_waits_for_the_guest_agent() {
  # RunCommandLinux is a VM extension and cannot provision until the guest agent
  # is up. Invoking it the instant `az vm create` returns raced that and failed
  # the bake with VMExtensionProvisioningTimeout without running a single line
  # of the script. The guest-side egress wait cannot cover this: the guest
  # script never runs when the extension itself will not provision.
  local wait_line invoke_line
  wait_line=$(grep -n 'agent_ready=1' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$wait_line" ] || fail "the bake never waits for the builder guest agent"
  invoke_line=$(grep -n 'az vm run-command invoke' "$SCRIPT" | head -1 | cut -d: -f1)
  [ -n "$invoke_line" ] || fail "no run-command invoke found, so this ordering proves nothing"
  [ "$wait_line" -lt "$invoke_line" ] \
    || fail "the agent wait runs AFTER the invoke it is supposed to protect"
  grep -q 'guest agent never reported ready' "$SCRIPT" \
    || fail "a builder whose agent never comes up does not refuse"
  pass "the bake waits for the builder guest agent before invoking a VM extension"
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
run_guest_waits_for_egress_before_downloading
run_host_waits_for_the_guest_agent
run_failed_bake_does_not_leak_the_builder

echo "# fm-azure-cell-image.test.sh: all assertions passed"
