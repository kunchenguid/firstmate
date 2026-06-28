#!/usr/bin/env bash
# fm-layout-pick.sh — interactive keyboard picker for reassigning a dashboard
# watch slot. Meant to run inside `tmux display-popup -E` (the popup gives it a
# TTY), but it works in any terminal too. This is the RELIABLE baseline selector:
# plain numbered prompts, no mouse, no tmux menu plumbing.
#
#   fm-layout-pick.sh [slot]   slot 1|2|3; if omitted, it asks which slot first.
#
# It only reads worker discovery and calls `fm-layout.sh assign`; it never touches
# a worker pane. Choosing 0 clears the slot.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="$SCRIPT_DIR/fm-layout.sh"

slot=${1:-}
if [ -z "$slot" ]; then
  printf 'Reassign which watch slot? [1-3]: '
  read -r slot || exit 0
fi
case "$slot" in
  1|2|3) ;;
  *) echo "invalid slot '$slot' (expected 1, 2, or 3)"; sleep 1.2; exit 0 ;;
esac

# Snapshot live workers: idx<TAB>window<TAB>repo<TAB>label.
WORKERS=()
while IFS= read -r line; do
  WORKERS+=("$line")
done < <("$LAYOUT" workers)

echo "== assign watch slot $slot =="
if [ "${#WORKERS[@]}" -eq 0 ]; then
  echo "no active workers to show right now."
  echo "(0 clears the slot)"
fi

for row in "${WORKERS[@]+"${WORKERS[@]}"}"; do
  IFS=$'\t' read -r idx win repo label <<<"$row"
  printf '  %s) %s - %s  (%s)\n' "$idx" "$repo" "$label" "$win"
done
echo "  0) clear this slot"
printf 'choice for slot %s: ' "$slot"
read -r choice || exit 0

if [ "$choice" = 0 ]; then
  "$LAYOUT" assign "$slot" -
  sleep 0.8
  exit 0
fi

for row in "${WORKERS[@]+"${WORKERS[@]}"}"; do
  IFS=$'\t' read -r idx win repo label <<<"$row"
  if [ "$choice" = "$idx" ]; then
    "$LAYOUT" assign "$slot" "$win"
    sleep 0.8
    exit 0
  fi
done

echo "no worker numbered '$choice'."
sleep 1.2
