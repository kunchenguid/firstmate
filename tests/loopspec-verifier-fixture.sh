#!/usr/bin/env bash
# A controllable verifier for the LoopSpec suites.
#
# Real verifiers read the world; this one reads FIXTURE_VERIFIER_RC so a test can
# put the machinery in front of a passing, a rejecting, and an unrunnable verifier
# without depending on the network, the forge, or the state of this repository.
#
# It honours the same invocation contract bin/fm-loopspec.sh verify imposes on
# every bound verifier: exit 0 pass, 1 fail, anything else unavailable, with one
# evidence line per observed fact on stdout.
set -u

rc=${FIXTURE_VERIFIER_RC:-0}
lines=${FIXTURE_VERIFIER_EVIDENCE:-3}

i=1
while [ "$i" -le "$lines" ]; do
  printf 'evidence: fixture observation %s of %s for %s\n' "$i" "$lines" "$*"
  i=$((i + 1))
done

exit "$rc"
