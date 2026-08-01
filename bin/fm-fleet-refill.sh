#!/usr/bin/env bash
# Fleet refill — run this as the FIRST action of ANY turn (before review
# polls, folds, landings, or completion processing). It is the mechanical
# answer to the 4x "wake the crew" recurrence: the dispatch decision is not a
# judgment call, it is a count.
#
# Prints a live status line + the exact next-wave dispatch commands. The
# battery is counted from the OWNED MANIFEST with a SHORT active window
# (5 min): running agents write output every 0-1 min, so a completed worker
# drops out of the count within minutes — the sentinel's 25-min freshness
# window was the bug that masked drained fleets (2026-08-01, the 5x
# recurrence).
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TASKS_DIR="/tmp/pi-subagents-1000/home-holu-fmate-firstmate/019fb7d2-b01e-71d5-845d-3d2fd223d0cf/tasks"
MANIFEST="$FM_HOME/state/fleet-manifest.jsonl"
ACTIVE_WINDOW_MIN=5
QUEUE_WINDOW_MIN=60
MIN_BATTERY=6
MIN_OPEN=3

now="$(date +%s)"
active=0
battery=0
for id in $(cut -d' ' -f1 "$MANIFEST" 2>/dev/null); do
  f="$TASKS_DIR/${id}.output"
  [ -f "$f" ] || continue
  m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  age=$(( (now - m) / 60 ))
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  if [ "$age" -le "$ACTIVE_WINDOW_MIN" ]; then
    active=$((active + 1))
  fi
  if [ "$age" -le "$ACTIVE_WINDOW_MIN" ] || \
     { [ "$sz" -lt 3000 ] && [ "$age" -le "$QUEUE_WINDOW_MIN" ]; }; then
    battery=$((battery + 1))
  fi
done

echo "fleet-refill: active=$active battery=$battery (min_battery=$MIN_BATTERY min_open=$MIN_OPEN)"

open_count="$(cd /home/holu/decision-os && br list --status open --json 2>/dev/null \
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("total", 0))
except Exception:
    print(-1)' 2>/dev/null || echo -1)"

if [ "$battery" -lt "$MIN_BATTERY" ] && [ "$open_count" -ge "$MIN_OPEN" ]; then
  echo "DISPATCH-NEEDED: battery $battery < $MIN_BATTERY with $open_count open beads."
  echo "Dispatch the next wave now (see NEXT-WAVE list, verify each id with br show,"
  echo "then launch the Agent calls). Do NOT process reviews/folds/landings first."
  exit 1
else
  echo "fleet-ok: battery $battery >= $MIN_BATTERY or open=$open_count < $MIN_OPEN."
  exit 0
fi
