#!/usr/bin/env bash
# fm-vendor-auth-probe.sh - one hard-bounded, non-destructive authentication
# probe of a named vendor CLI.
#
# This script collects a FACT and renders no verdict. It takes no harness, model,
# or provider, reads no quota, and never decides whether a dispatch candidate is
# eligible. The dispatching first mate owns that judgment from `quota-axi`'s data
# plus each harness's authoritative model catalog; the decision procedure is
# owned once by .agents/skills/quota-array-dispatch/SKILL.md.
#
# Why it exists rather than the agent running the vendor CLI itself: the
# captain's 2026-07-30 `firstmate-grok-auth-preflight` decision approved exactly
# one bounded, non-interactive probe, and that safety envelope must not depend on
# agent memory. It is enforced here deterministically:
#   - the argv is fixed in this file and never composed from input, so no caller
#     can turn the probe into a login, logout, or interactive TUI launch;
#   - stdin is closed, so caller input can never reach the vendor CLI;
#   - a hard positive timeout bounds every command, so a hung CLI cannot wedge an
#     intake;
#   - raw vendor output is classified here and never printed, logged, or passed
#     in an argument.
#
# The probe registry is a fixed-argv safety allowlist, not a routing table. It
# carries no harness, model, provider, credential-store, or provider-family
# relationship, and asking for a probe is always the caller's own explicit
# decision. A probe is registered only after its non-destructive discovery
# command and its output discriminators are verified first-hand and recorded in
# docs/verification/dispatch-auth.md.
#
# Registered probes:
#   grok   `grok models` - the standalone Grok Build CLI. Verified on grok
#          1.0.3: the command exits 0 in BOTH the authenticated and the
#          unauthenticated case, so only the literal first stdout line
#          discriminates and the exit status is never a verdict.
#
# Output: exactly one sanitized `key=value` line on stdout. No token, refresh
# token, header, path, length, prefix, hash, or raw vendor output is ever
# printed, logged, or passed in an argument.
#
#   probe=            the requested probe name
#   status=           authenticated | unauthenticated | indeterminate |
#                     timeout | unavailable
#   version=          the probed CLI's version, or none
#   versionVerified=  yes | no | none - whether the running CLI matches the
#                     version whose discriminator strings were verified
#
# `status` is evidence, never eligibility. Only `authenticated` and
# `unauthenticated` are ground truth. `indeterminate`, `timeout`, and
# `unavailable` mean the probe established nothing and must never be read as
# either outcome; unrecognized output is `indeterminate`, never authenticated.
#
# Exit status: 0 whenever the line is printed, 2 on a usage error. The exit
# status deliberately does not encode the probe result, because this script
# renders no verdict for a caller to branch on.
#
# Usage:
#   fm-vendor-auth-probe.sh <probe>
#
# Environment:
#   FM_VENDOR_AUTH_PROBE_TIMEOUT   hard per-command bound in seconds; must be a
#                                  positive integer, otherwise the default 20 is
#                                  used. Zero is rejected because `timeout 0` and
#                                  `alarm 0` both mean "no deadline".
set -u

VERIFIED_GROK_VERSION=1.0.3

usage() {
  cat <<'EOF'
fm-vendor-auth-probe.sh - one hard-bounded, non-destructive authentication probe
of a named vendor CLI. It collects a fact and renders no verdict: it takes no
harness, model, or provider, reads no quota, and never decides dispatch
eligibility. The dispatching first mate owns that judgment.

Usage:
  fm-vendor-auth-probe.sh <probe>

Registered probes:
  grok   `grok models` on the standalone Grok Build CLI

Prints one sanitized key=value line: probe, status, version, versionVerified.

status is evidence, never eligibility:
  authenticated    the vendor CLI reports an authenticated session
  unauthenticated  the vendor CLI reports no authenticated session
  indeterminate    output the verified discriminators do not cover
  timeout          the hard bound was hit
  unavailable      the vendor CLI is not on PATH
Only authenticated and unauthenticated are ground truth; the other three
establish nothing and must never be read as either outcome.

The argv is fixed in the script, stdin is closed, and raw vendor output is never
printed. Login, logout, and the interactive TUI are never invoked.

Exit status: 0 whenever the line is printed, 2 on a usage error.

Environment:
  FM_VENDOR_AUTH_PROBE_TIMEOUT   hard per-command bound in seconds (default 20);
                                 a non-positive or non-numeric value is rejected
                                 in favor of the default
EOF
}

die_usage() {
  printf 'fm-vendor-auth-probe: %s\n' "$1" >&2
  printf 'usage: fm-vendor-auth-probe.sh <probe>   (registered probes: grok)\n' >&2
  exit 2
}

PROBE=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      [ -z "$PROBE" ] || die_usage "only one probe may be requested at a time"
      PROBE=$1
      shift
      ;;
  esac
done

[ -n "$PROBE" ] || die_usage "a probe name is required"

# A non-positive bound is not a bound: `timeout 0` and the Perl fallback's
# `alarm 0` both disable the deadline, so a hung vendor CLI would run unbounded.
TIMEOUT=${FM_VENDOR_AUTH_PROBE_TIMEOUT:-20}
case "$TIMEOUT" in
  ''|*[!0-9]*|0*) TIMEOUT=20 ;;
esac

# Bounded execution is owned by bin/fm-timeout-lib.sh, so a macOS host without
# coreutils still gets a hard bound instead of an unbounded vendor CLI call.
# Exit 124 means the bound was hit.
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

STATUS=unavailable
VERSION=none
VERSION_VERIFIED=none

emit() {
  printf 'probe=%s status=%s version=%s versionVerified=%s\n' \
    "$PROBE" "$STATUS" "$VERSION" "$VERSION_VERIFIED"
  exit 0
}

# The two argv forms below are literals in this file. Nothing the caller supplies
# reaches the vendor CLI's argv or stdin.
grok_version() {
  local output
  output=$(fm_run_timed "$TIMEOUT" grok --version 2>/dev/null </dev/null) || { printf 'none\n'; return 0; }
  printf '%s\n' "$output" | sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1 | grep . || printf 'none\n'
}

probe_grok() {
  local output first rc=0
  output=$(fm_run_timed "$TIMEOUT" grok models 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    printf 'timeout\n'
    return 0
  fi
  # The exit status is deliberately ignored: grok 1.0.3 exits 0 in both the
  # authenticated and unauthenticated cases, so only the first stdout line
  # discriminates. Raw output is classified here and never printed.
  first=$(printf '%s\n' "$output" | head -n 1)
  case "$first" in
    "You are logged in with "*) printf 'authenticated\n' ;;
    "You are not authenticated."*) printf 'unauthenticated\n' ;;
    *) printf 'indeterminate\n' ;;
  esac
}

case "$PROBE" in
  grok)
    command -v grok >/dev/null 2>&1 || emit
    VERSION=$(grok_version)
    if [ "$VERSION" = "$VERIFIED_GROK_VERSION" ]; then
      VERSION_VERIFIED=yes
    else
      VERSION_VERIFIED=no
    fi
    STATUS=$(probe_grok)
    emit
    ;;
  *)
    die_usage "no probe is registered for '$PROBE'"
    ;;
esac
