#!/usr/bin/env bash
# quota-failover watcher check: prints the wake lines the last passes left in
# state/quota-failover.wake as one line (the watcher's check: wake), then
# starts the next pass detached, since a pass's live tests outlast a check.
# Usage: check.sh <fm-home>
set -u
wake=$1/state/quota-failover.wake
mv -f "$wake" "$wake.$$" 2>/dev/null && { paste -sd ';' "$wake.$$"; rm -f "$wake.$$"; }
setsid -f "$(cd "$(dirname "$0")" && pwd)/quota-failover" "$1" >/dev/null 2>&1 </dev/null
