#!/usr/bin/env bash
# fm-quota-gate.sh - deterministic go/no-go check for whether current Claude
# provider quota headroom allows a new crewmate/scout spawn.
#
# Runs `quota-axi --json` and reads the claude provider's GENERAL account
# windows only: windows[] entries with id "five_hour" or "seven_day". Any
# "model:*" window (a named-model-specific bound, e.g. "model:fable") is
# ignored - this gate is about the account's overall headroom, not one
# model's bound. The result is the MINIMUM percentRemaining across just
# those two windows, floored to an integer (quota-axi's percentRemaining
# is not guaranteed to be a whole number; flooring never reports more
# headroom than is actually available).
#
# Thresholds (env-overridable):
#   FM_QUOTA_SONNET_ONLY_PCT  default 40
#   FM_QUOTA_PAUSE_PCT        default 20
#
# Levels (checked most-restrictive first):
#   remaining <= FM_QUOTA_PAUSE_PCT        -> pause
#   remaining <= FM_QUOTA_SONNET_ONLY_PCT  -> sonnet-only
#   otherwise                              -> ok
#
# This script only reports the quota level; it does not know or check any
# model. The caller (bin/fm-spawn.sh) enforces "sonnet-only" by matching an
# explicitly requested --model against opus/fable - a spawn left to a
# harness's own implicit default model is not evaluated, so pass --model
# explicitly to get sonnet-only protection.
#
# Output contract: exactly one line on stdout, "<level> remaining=<N>", e.g.
# "ok remaining=87", "sonnet-only remaining=31", "pause remaining=12".
#
# Exit codes:
#   0  ok           (including the fail-open case, remaining=unknown)
#   1  sonnet-only
#   2  pause
#
# Fail-open: quota-axi missing, exiting non-zero, or producing output this
# script cannot parse into a numeric percentRemaining for both windows is
# data unavailability, not a quota problem - it must never block dispatch.
# That case prints a warning to stderr, then "ok remaining=unknown" to
# stdout, and exits 0, the same fail-open principle the quota-array-dispatch
# selection procedure (AGENTS.md, .agents/skills/quota-array-dispatch) uses.
set -eu

PAUSE_PCT=${FM_QUOTA_PAUSE_PCT:-20}
SONNET_ONLY_PCT=${FM_QUOTA_SONNET_ONLY_PCT:-40}

fail_open() {
  echo "warning: fm-quota-gate.sh: $1; failing open" >&2
  echo "ok remaining=unknown"
  exit 0
}

case "$PAUSE_PCT" in
  ''|*[!0-9]*) fail_open "FM_QUOTA_PAUSE_PCT '$PAUSE_PCT' is not a non-negative integer" ;;
esac
case "$SONNET_ONLY_PCT" in
  ''|*[!0-9]*) fail_open "FM_QUOTA_SONNET_ONLY_PCT '$SONNET_ONLY_PCT' is not a non-negative integer" ;;
esac

command -v quota-axi >/dev/null 2>&1 || fail_open "quota-axi not found on PATH"
command -v jq >/dev/null 2>&1 || fail_open "jq not found on PATH"

RAW=$(quota-axi --json 2>/dev/null) || fail_open "quota-axi --json exited non-zero"
[ -n "$RAW" ] || fail_open "quota-axi --json produced no output"

MIN_REMAINING=$(printf '%s' "$RAW" | jq -r '
  [ .providers[]? | select(.provider == "claude") | .windows[]?
    | select(.id == "five_hour" or .id == "seven_day")
    | select(.percentRemaining != null) | .percentRemaining ]
  | if length == 0 then "" else min | floor end
' 2>/dev/null) || fail_open "quota-axi --json output could not be parsed"

case "$MIN_REMAINING" in
  ''|*[!0-9]*) fail_open "no numeric percentRemaining found for claude's five_hour/seven_day windows" ;;
esac

if [ "$MIN_REMAINING" -le "$PAUSE_PCT" ]; then
  echo "pause remaining=$MIN_REMAINING"
  exit 2
elif [ "$MIN_REMAINING" -le "$SONNET_ONLY_PCT" ]; then
  echo "sonnet-only remaining=$MIN_REMAINING"
  exit 1
else
  echo "ok remaining=$MIN_REMAINING"
  exit 0
fi
