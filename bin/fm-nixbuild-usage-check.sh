#!/usr/bin/env bash
# fm-nixbuild-usage-check.sh - probe nixbuild.net free-tier quota usage.
#
# Usage:
#   fm-nixbuild-usage-check.sh [check]
#   fm-nixbuild-usage-check.sh --help
#
# Prints ONE line only when an account is at or above the warning threshold or
# cannot be reached; prints nothing when all accounts are healthy.
# Intended for use with fm-check-register.sh; firstmate wires the registration.
#
# Environment:
#   FM_NIXBUILD_ALIASES    comma-separated SSH config alias names
#                          default: nixbuild-1,nixbuild-2,nixbuild-3,nixbuild-4
#   FM_NIXBUILD_WARN_PCT   integer warning threshold 0-100, default: 80
#   FM_NIXBUILD_PROBE_SECS per-alias SSH probe timeout in seconds, default: 10
#
# Each alias must resolve via ~/.ssh/config. No key material is read or printed.
# The usage query runs: ssh -o BatchMode=yes <alias> shell usage
#
# Output format (single line, only when attention is needed):
#   nixbuild usage: <alias> <pct>% warn[, ...]
#   nixbuild usage: <alias> <pct>% exhausted[, ...]
#   nixbuild usage: <alias> unverifiable: <reason>[, ...]
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ALIASES=${FM_NIXBUILD_ALIASES:-nixbuild-1,nixbuild-2,nixbuild-3,nixbuild-4}
WARN_PCT=${FM_NIXBUILD_WARN_PCT:-80}
PROBE_SECS=${FM_NIXBUILD_PROBE_SECS:-10}

case "${1:-check}" in
  --help)
    grep '^#' "$0" | head -25 | sed 's/^# \{0,2\}//; s/^#//'
    exit 0 ;;
  check) ;;
  *) printf 'fm-nixbuild-usage-check: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

# Clamp inputs to sane integers; fm_run_timed refuses a non-positive bound.
case "$PROBE_SECS" in ''|*[!0-9]*|0) PROBE_SECS=10 ;; esac
case "$WARN_PCT"   in ''|*[!0-9]*)   WARN_PCT=80   ;; esac

# parse_pct: extract an integer usage percentage from nixbuild shell output.
# Handles three formats: a direct "Usage: N%" line, cpu_seconds_used /
# cpu_seconds_quota key-value pairs, and generic "used" / "quota" lines.
# Prints nothing and returns 1 on parse failure.
parse_pct() {
  local text=$1 pct used quota
  # Direct percentage: "Usage: 5.98%" or "usage: 100%"
  pct=$(printf '%s\n' "$text" | grep -i 'usage' | grep -oE '[0-9]+%' | head -1 | tr -d '%')
  [ -n "$pct" ] && { printf '%s' "$pct"; return 0; }
  # Key-value: cpu_seconds_used / cpu_seconds_quota
  used=$(printf '%s\n' "$text" | grep -i 'cpu_seconds_used'  | grep -oE '[0-9]+' | head -1)
  quota=$(printf '%s\n' "$text" | grep -i 'cpu_seconds_quota' | grep -oE '[0-9]+' | head -1)
  if [ -n "$used" ] && [ -n "$quota" ] && [ "$quota" -gt 0 ] 2>/dev/null; then
    printf '%s' "$((used * 100 / quota))"; return 0
  fi
  # Generic: first "used" line / first "quota" line
  used=$(printf '%s\n' "$text" | grep -i 'used'  | grep -oE '[0-9]+' | tail -1)
  quota=$(printf '%s\n' "$text" | grep -i 'quota' | grep -oE '[0-9]+' | tail -1)
  if [ -n "$used" ] && [ -n "$quota" ] && [ "$quota" -gt 0 ] 2>/dev/null; then
    printf '%s' "$((used * 100 / quota))"; return 0
  fi
  return 1
}

alerts=''
IFS=',' read -ra nixbuild_alias_list <<< "$ALIASES"
for nixbuild_alias in "${nixbuild_alias_list[@]}"; do
  nixbuild_alias=${nixbuild_alias## }
  nixbuild_alias=${nixbuild_alias%% }
  [ -n "$nixbuild_alias" ] || continue

  output=$(fm_run_timed "$PROBE_SECS" ssh -o BatchMode=yes "$nixbuild_alias" shell usage 2>&1)
  rc=$?

  if [ "$rc" -eq 124 ]; then
    alerts="${alerts:+$alerts, }${nixbuild_alias} unverifiable: timeout"
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    alerts="${alerts:+$alerts, }${nixbuild_alias} unverifiable: ssh error"
    continue
  fi

  pct=$(parse_pct "$output") || {
    alerts="${alerts:+$alerts, }${nixbuild_alias} unverifiable: parse failed"
    continue
  }

  if [ "$pct" -ge 100 ] 2>/dev/null; then
    alerts="${alerts:+$alerts, }${nixbuild_alias} ${pct}% exhausted"
  elif [ "$pct" -ge "$WARN_PCT" ] 2>/dev/null; then
    alerts="${alerts:+$alerts, }${nixbuild_alias} ${pct}% warn"
  fi
done

[ -z "$alerts" ] || printf 'nixbuild usage: %s\n' "$alerts"
