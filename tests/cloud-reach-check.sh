#!/bin/sh
# Turn a recorded cloud reach into a failed suite.
#
# tests/run.sh calls this after EVERY admitted test, on every lane. The refusing
# `az` shim (tests/cloud-guard-bin/az) and the refusing provider
# (tests/cloud-provider-refusal.py) both append to the log named here, so a test
# that found its way to a real cloud seam cannot end green just because the seam
# said no. The refusal is the containment; this is the alarm.
#
# Exit 0 when the log is empty or absent. Exit 1 after printing every recorded
# reach, and truncate the log so the next test is judged on its own reaches.
#
# It is a separate script, not a shell function inside run.sh, so the behavior
# itself is executable and can be proven by tests/fm-cloud-provider-seal.test.sh
# rather than only asserted about.
set -u

[ "$#" -eq 1 ] || { echo "usage: cloud-reach-check.sh <reach-log>" >&2; exit 97; }
log=$1
[ -f "$log" ] || exit 0
reached=$(cat "$log" 2>/dev/null) || { echo "cloud reach log is unreadable: $log" >&2; exit 97; }
[ -n "$reached" ] || exit 0
printf 'test isolation violation: a behavior test reached a real cloud seam:\n%s\n' "$reached" >&2
: > "$log"
exit 1
