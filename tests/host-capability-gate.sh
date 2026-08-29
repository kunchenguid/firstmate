#!/usr/bin/env bash
# tests/host-capability-gate.sh - the ONE door a behavior unit uses to say
# "this unit needs a host capability that not every sealed-suite host has".
#
# Source it, then guard the unit:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/host-capability-gate.sh"
#   fm_require_host_capability real-tmux-server "$unit_label" || return 0
#
# WHY THIS SHAPE, and not `command -v tmux` / `sudo -n true` / "does the
# Keychain answer?":
#
#   A probe of the capability itself evaluates false on a BROKEN host too. That
#   is how a real regression turns into an invisible skip - this program already
#   lost mutation coverage exactly that way, when a test gated on `command -v pi`
#   quietly skipped in CI and two mutations of the actuator passed green.
#
#   So the gate never probes. It reads two FACTS about where the test is
#   running:
#
#     1. the platform (`uname -s`), against the PLATFORMS column of
#        tests/host-capabilities.tsv; and
#     2. an explicit, by-name declaration of absence that the ENVIRONMENT makes
#        about itself in FM_TEST_HOST_CAPABILITIES_ABSENT.
#
#   Everything else RUNS. A host that is on a listed platform and declares
#   nothing runs the unit, and the unit FAILS if the capability is really
#   missing. That is deliberate: a required condition that fails when unmet beats
#   a condition that skips when unmet.
#
#   The declaration is REFUSED on Darwin. macOS is where these units are the
#   coverage of record, so on a Mac they can never be turned off - not by an
#   environment variable, not by accident, not by a broken host.
#
# Every skip is LOUD: one FM_HOST_CAPABILITY_SKIP line on stdout AND stderr,
# naming the test, the unit, the capability, what the capability is, and why it
# was not available. Nothing here can skip quietly.

if [ -n "${FM_HOST_CAPABILITY_GATE_SOURCED:-}" ]; then
  return 0
fi
FM_HOST_CAPABILITY_GATE_SOURCED=1

FM_HOST_CAPABILITY_REGISTRY=${FM_HOST_CAPABILITY_REGISTRY:-$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P
)/host-capabilities.tsv}

# A wiring mistake in the gate is never a skip and never a pass: it stops the
# test with the harness refusal code, the same way test admission does.
fm_host_capability_refuse() {
  printf 'host capability gate refused: %s\n' "$1" >&2
  exit 97
}

# Load the PLATFORMS and DESCRIPTION of <capability> into
# FM_HOST_CAPABILITY_PLATFORMS / FM_HOST_CAPABILITY_DESCRIPTION, or fail closed.
# It assigns rather than echoes on purpose: `exit 97` inside a command
# substitution would only kill the subshell and let an unknown capability sail
# through as an empty row.
fm_host_capability_load() {
  local capability=$1 row status=0
  [ -r "$FM_HOST_CAPABILITY_REGISTRY" ] \
    || fm_host_capability_refuse "registry is unreadable: $FM_HOST_CAPABILITY_REGISTRY"
  row=$(awk -F '\t' -v want="$capability" '
    $1 == "capability" && $2 == want { print $3 "\t" $4; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$FM_HOST_CAPABILITY_REGISTRY") || status=$?
  [ "$status" -eq 0 ] && [ -n "$row" ] \
    || fm_host_capability_refuse "unknown capability '$capability' (declare it in tests/host-capabilities.tsv)"
  FM_HOST_CAPABILITY_PLATFORMS=${row%%$'\t'*}
  FM_HOST_CAPABILITY_DESCRIPTION=${row#*$'\t'}
  [ -n "$FM_HOST_CAPABILITY_PLATFORMS" ] && [ -n "$FM_HOST_CAPABILITY_DESCRIPTION" ] \
    || fm_host_capability_refuse "capability '$capability' has no platforms or no description"
}

# Every name the environment declares must be a real capability, or the
# declaration is a typo that would otherwise silently protect nothing.
fm_host_capability_validate_declaration() {
  local declared name
  declared=${FM_TEST_HOST_CAPABILITIES_ABSENT:-}
  [ -n "$declared" ] || return 0
  if [ "$(uname -s)" = Darwin ]; then
    fm_host_capability_refuse \
      "FM_TEST_HOST_CAPABILITIES_ABSENT is set on Darwin ('$declared'); macOS always runs the host-coupled units"
  fi
  local IFS=,
  for name in $declared; do
    [ -n "$name" ] || continue
    fm_host_capability_load "$name"
  done
}

fm_host_capability_declared_absent() {
  local capability=$1 name
  local IFS=,
  for name in ${FM_TEST_HOST_CAPABILITIES_ABSENT:-}; do
    [ "$name" = "$capability" ] && return 0
  done
  return 1
}

fm_host_capability_skip() {
  local capability=$1 label=$2 description=$3 reason=$4 line test_name
  test_name=${FM_TEST_CURRENT_TEST:-unknown-test}
  line="FM_HOST_CAPABILITY_SKIP ${test_name##*/} :: ${label} requires host capability '${capability}' (${description}); ${reason}"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >&2
}

# fm_require_host_capability <capability> <label>
#   0 - the capability is available here: RUN the unit.
#   1 - it is not: a loud skip has been printed, the caller returns/exits 0.
fm_require_host_capability() {
  [ "$#" -eq 2 ] \
    || fm_host_capability_refuse "fm_require_host_capability needs <capability> <label>, got $*"
  local capability=$1 label=$2 platform
  platform=$(uname -s)
  # Validate the whole declaration FIRST: it loads other capabilities into the
  # same two variables, so loading the requested one before it would read back
  # the last declared name's row.
  fm_host_capability_validate_declaration
  fm_host_capability_load "$capability"

  case ",$FM_HOST_CAPABILITY_PLATFORMS," in
    *",$platform,"*) ;;
    *)
      fm_host_capability_skip "$capability" "$label" "$FM_HOST_CAPABILITY_DESCRIPTION" \
        "this platform ($platform) cannot provide it; it is provided on: $FM_HOST_CAPABILITY_PLATFORMS"
      return 1
      ;;
  esac

  if fm_host_capability_declared_absent "$capability"; then
    fm_host_capability_skip "$capability" "$label" "$FM_HOST_CAPABILITY_DESCRIPTION" \
      "this $platform host declared it absent by name in FM_TEST_HOST_CAPABILITIES_ABSENT"
    return 1
  fi
  return 0
}
