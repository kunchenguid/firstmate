#!/usr/bin/env bash
# Watcher liveness guard, called at the top of the supervision scripts.
# If any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud warning so the
# agent sees it in the tool output of whatever it was doing - the one channel
# every harness has. Normal wake handling (watcher briefly down between a wake
# and its restart) stays inside the grace window and stays silent.
# Always exits 0: the guard warns, it never blocks.
set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$FM_ROOT/state"
GRACE=${FM_GUARD_GRACE:-300}

has_meta=false
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  has_meta=true
  break
done
"$has_meta" || exit 0

BEAT="$STATE/.last-watcher-beat"
if [ -e "$BEAT" ]; then
  m=$(stat -f %m "$BEAT" 2>/dev/null || stat -c %Y "$BEAT" 2>/dev/null) || exit 0
  age=$(( $(date +%s) - m ))
  [ "$age" -lt "$GRACE" ] && exit 0
  echo "WARNING: tasks are in flight but no watcher has been alive for ${age}s (>${GRACE}s)." >&2
else
  echo "WARNING: tasks are in flight but no watcher has ever run (no liveness beacon)." >&2
fi
echo "Restart it NOW, before anything else: run bin/fm-watch.sh as a background task." >&2
exit 0
