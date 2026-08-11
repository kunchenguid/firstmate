#!/usr/bin/env bash
# Behavior tests for the cross-operator ("Admiral") opt-in and the read-only
# prerequisite reporting that lets an operator decide whether they want it.
#
# The contract: multi-operator capability is OPT-IN. A home that never opts in must
# behave exactly as a single-operator home always has, and nothing in the reporting
# path may install, create, or change anything on the host.
set -u

# Portable helpers: BSD stat/sed (macOS) differ from GNU. macOS is a declared
# supported platform, so the suite must not assume GNU coreutils.
fm_portable_mode() { # <path>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then stat -f '%Lp' "$1" 2>/dev/null
  else stat -c '%a' "$1" 2>/dev/null; fi
}
fm_portable_sed_i() { # <expr> <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then sed -i '' "$1" "$2"
  else sed -i "$1" "$2"; fi
}
# Host state the privileged Tier C step would change, as one comparable string.
# `getent` is glibc-only and absent on macOS, so fall back to /etc/group the same
# way bin/fm-fleet-preflight.sh and scripts/fleet-root-prereq.sh already do -
# those two shipped the fallback, the test did not, and only the test broke.
# Always exits 0: "absent" is a legitimate reading of an unprovisioned host, and
# the assertion compares before/after, so a non-zero probe would say nothing
# useful while risking the same silent-exit trap under any future errexit.
fleet_host_snapshot() {
  if command -v getent >/dev/null 2>&1; then getent group agents 2>/dev/null
  else grep -E '^agents:' /etc/group 2>/dev/null | head -1
  fi
  fm_portable_mode /opt/agents/fleet 2>/dev/null
  return 0
}

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLEET="$ROOT/bin/fm-fleet.sh"
PREFLIGHT="$ROOT/bin/fm-fleet-preflight.sh"
PREREQ="$ROOT/scripts/fleet-root-prereq.sh"

new_home() { # <label>
  local base; base=$(fm_test_tmproot "$1"); mkdir -p "$base/config"; printf '%s\n' "$base"
}

test_admiral_is_disabled_by_default() {
  local home out; home=$(new_home adm-default)
  out=$(FM_HOME="$home" bash "$FLEET" admiral status)
  case "$out" in
    *disabled*) ;;
    *) fail "a fresh home must report admiral disabled, got: $out" ;;
  esac
  [ ! -e "$home/config/admiral" ] || fail "no opt-in flag may exist by default"
  pass "admiral: disabled by default"
}

test_enable_then_disable_is_a_round_trip() {
  local home; home=$(new_home adm-toggle)
  FM_HOME="$home" bash "$FLEET" admiral enable >/dev/null || fail "enable failed"
  [ -f "$home/config/admiral" ] || fail "enable must create the opt-in flag"
  FM_HOME="$home" bash "$FLEET" admiral disable >/dev/null || fail "disable failed"
  [ ! -e "$home/config/admiral" ] || fail "disable must remove the opt-in flag"
  FM_HOME="$home" bash "$FLEET" admiral status | grep -q disabled \
    || fail "status must report disabled after disable"
  pass "admiral: enable/disable is a clean round trip"
}

test_opt_in_flag_selects_the_shared_store() {
  local home solo shared; home=$(new_home adm-store)
  solo=$(FM_HOME="$home" bash "$ROOT/bin/fm-handoff-doc.sh" where | head -1)
  case "$solo" in
    "$home/state/handoffs") ;;
    *) fail "without the flag the store must be this home's own, got: $solo" ;;
  esac
  # Point the fleet at a directory this test owns, so the opt-in path is exercised
  # without depending on a real multi-operator fleet being present.
  printf '%s\n' "$home/fleet" > "$home/config/fleet-dir"
  mkdir -p "$home/fleet"
  FM_HOME="$home" bash "$FLEET" init >/dev/null 2>&1 || true
  : > "$home/config/admiral"
  shared=$(FM_HOME="$home" bash "$ROOT/bin/fm-handoff-doc.sh" where | head -1)
  [ "$shared" != "$solo" ] || fail "the opt-in flag must change where handoffs are stored"
  pass "admiral: the opt-in flag is what selects the shared store"
}

test_preflight_reports_and_changes_nothing() {
  local home before after out; home=$(new_home adm-preflight)
  before=$(find "$home" | sort)
  out=$(FM_HOME="$home" bash "$PREFLIGHT" 2>&1) || true
  after=$(find "$home" | sort)
  [ "$before" = "$after" ] || fail "preflight must not create or change anything"
  case "$out" in
    *"Nothing was changed"*) ;;
    *) fail "preflight must state plainly that it changed nothing, got: $out" ;;
  esac
  case "$out" in
    *"config/admiral absent - this is the default"*) ;;
    *) fail "preflight must present the absent opt-in as the default, not a defect" ;;
  esac
  pass "preflight: reports tier readiness and changes nothing"
}

test_preflight_names_the_opt_in_command() {
  local home out; home=$(new_home adm-pf-cmd)
  out=$(FM_HOME="$home" bash "$PREFLIGHT" 2>&1) || true
  case "$out" in
    *"admiral enable"*) ;;
    *) fail "preflight must name the exact command that opts in, got: $out" ;;
  esac
  pass "preflight: names the exact opt-in command"
}

test_root_prereq_check_needs_no_root_and_changes_nothing() {
  local out rc snap_before snap_after
  # `set +e` / `set -e` around the probe was wrong: this file runs under `set -u`
  # ONLY, so the trailing `set -e` did not RESTORE errexit, it ENABLED it for the
  # first time. The very next line then legitimately returns non-zero on any host
  # without the privileged Tier C setup - `getent` does not exist on macOS, and
  # `fm_portable_mode /opt/agents/fleet` fails when that path is absent, which is
  # the normal state - so the shell exited 1 silently, skipping this test's `pass`
  # and the file's final "ALL PASS". Every assertion printed ok while the file
  # exited 1, which is why it read as a harness quirk rather than a real failure.
  # `|| rc=$?` captures the status without touching errexit at all.
  snap_before=$(fleet_host_snapshot)
  out=$(FM_FLEET_OPERATORS="$(id -un)" bash "$PREREQ" --check 2>&1) && rc=0 || rc=$?
  snap_after=$(fleet_host_snapshot)
  [ "$snap_before" = "$snap_after" ] || fail "--check must not change host state"
  case "$out" in
    *"CHECK ONLY"*) ;;
    *) fail "--check must announce that it changes nothing, got: $out" ;;
  esac
  # It must be usable by an unprivileged operator deciding whether they want this.
  case "$out" in
    *"must run as root"*) fail "--check must not demand root just to look" ;;
  esac
  # Exit status is the machine-readable answer to "is action required?".
  case "$rc" in
    0|1) ;;
    *) fail "--check must exit 0 (nothing to do) or 1 (action required), got $rc" ;;
  esac
  pass "fleet-root-prereq --check: rootless, read-only, and composable"
}

# --- run --------------------------------------------------------------------
test_admiral_is_disabled_by_default
test_enable_then_disable_is_a_round_trip
test_opt_in_flag_selects_the_shared_store
test_preflight_reports_and_changes_nothing
test_preflight_names_the_opt_in_command
test_root_prereq_check_needs_no_root_and_changes_nothing
echo "ALL PASS: fm-admiral-optin"
