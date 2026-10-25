#!/usr/bin/env bash
# Fleet retro cadence (captain 5 Oct): wake when the newest data/*retro*/report.md
# across known homes is missing or at least 60 h old, at most once per 12 h.
# Prints one wake line and exits 0 when due; silent exit 1 otherwise.
# Usage: fleet-retro-due.sh <main-home>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'usage: fleet-retro-due.sh <main-home>' >&2
  exit 2
fi
main=$(cd "$1" && pwd -P)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
now=${FM_RETRO_NOW:-$(date +%s)}
mark=$main/state/.fleet-retro.last
# 60 h since last report; 12 h between wakes.
age_limit=${FM_RETRO_AGE_SECS:-216000}
wake_limit=${FM_RETRO_WAKE_SECS:-43200}

last=$("$here/newest-retro-report.sh" "$main" || true)
due=0
if [ -z "$last" ]; then
  due=1
  last='(none)'
elif [ $((now - $(stat -c %Y "$last"))) -ge "$age_limit" ]; then
  due=1
fi
[ "$due" -eq 1 ] || exit 1
if [ -f "$mark" ] && [ $((now - $(stat -c %Y "$mark"))) -lt "$wake_limit" ]; then
  exit 1
fi
mkdir -p "$main/state"
touch -d "@$now" "$mark" 2>/dev/null || touch "$mark"
echo "fleet-retro due: last report $last; spawn the next strong-model fleet retro scout (captain-shared A5)"
exit 0
