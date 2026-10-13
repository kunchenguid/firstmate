#!/usr/bin/env bash
# fm-ask-mai-wake.sh - classify ONE wake reason through MAI-Pro for the caller.
#
# Opt-in: the home's config/mai-routing flag must be present or this exits 2
# and no classification is attempted. When the flag is absent, firstmate wakes
# are handled exactly as before - this helper is the only consumer wiring and
# it stays inert.
#
# Usage: fm-ask-mai-wake.sh <home> <wake-reason...>
#   <home>   the firstmate home whose config/mai-routing flag governs this call
# Prints one word on stdout: absorb | surface | escalate.
# Any failure (flag off, refusal, transport, out-of-set answer) resolves to
# escalate, so an MAI-Pro failure always lands the wake on the caller's own
# thread; exit is 0 with "escalate" for a failed call, 2 only for flag-off.
set -euo pipefail
home=${1:?"usage: fm-ask-mai-wake.sh <home> <wake-reason...>"}
shift
reason="$*"
[ -n "$reason" ] || { printf 'usage: fm-ask-mai-wake.sh <home> <wake-reason...>\n' >&2; exit 2; }
[ -e "$home/config/mai-routing" ] || exit 2

wrapper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-ask-mai-redacted.sh"
prompt=$(cat <<EOF
Classify this firstmate wake reason into exactly one of: absorb surface escalate.
absorb = routine, no judgement needed; surface = show an outcome; escalate = needs higher-judgement handling.
Reply with the single word and nothing else.
Wake reason: $reason
EOF
)
answer=$("$wrapper" "$prompt" 2>/dev/null || true)
answer=$(printf '%s' "$answer" | tr -d '[:space:]')
case "$answer" in
  absorb|surface|escalate) printf '%s\n' "$answer" ;;
  *) printf 'escalate\n' ;;
esac
