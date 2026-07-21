#!/usr/bin/env bash
# Resolve Firstmate's default timeout for Pi bash tool calls.
# Usage: fm-pi-bash-timeout.sh
# Prints one positive integer in seconds, or prints nothing when injection is disabled.
# FM_PI_BASH_TIMEOUT_SECS wins when it is set; otherwise the resolver reads
# FM_CONFIG_OVERRIDE/pi-bash-timeout, falling back to $FM_HOME/config/pi-bash-timeout.
# A positive integer selects that timeout, while 0, off, or none disables injection.
# Missing configuration selects 900 seconds, and invalid configuration safely falls back to 900 seconds.
# Pi reports an elapsed timeout as an error for only that bash call; it does not terminate the agent session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DEFAULT_TIMEOUT_SECS=900

if [ "${FM_PI_BASH_TIMEOUT_SECS+x}" = x ]; then
  raw=$FM_PI_BASH_TIMEOUT_SECS
elif [ -f "$CONFIG/pi-bash-timeout" ]; then
  raw=$(< "$CONFIG/pi-bash-timeout")
else
  printf '%s\n' "$DEFAULT_TIMEOUT_SECS"
  exit 0
fi

# Permit surrounding whitespace without accepting whitespace inside the value.
raw=${raw#"${raw%%[![:space:]]*}"}
raw=${raw%"${raw##*[![:space:]]}"}
normalized=${raw,,}
case "$normalized" in
  off|none)
    exit 0
    ;;
esac
case "$raw" in
  ''|*[!0-9]*)
    printf '%s\n' "$DEFAULT_TIMEOUT_SECS"
    exit 0
    ;;
esac

# Canonicalize decimal leading zeroes so every zero spelling disables injection.
while [ "${raw#0}" != "$raw" ]; do
  raw=${raw#0}
done
if [ -z "$raw" ]; then
  exit 0
fi
printf '%s\n' "$raw"
