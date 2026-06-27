#!/usr/bin/env bash
# fm-watch-pane.sh — the long-lived content of one dashboard pane.
#
#   fm-watch-pane.sh <1|2|3>   read-only mirror of the worker assigned to that
#                              slot: a header plus the tail of the worker's live
#                              pane, refreshed every FM_LAYOUT_REFRESH seconds.
#   fm-watch-pane.sh summary   the terse active-worker summary: one "• repo -
#                              label" bullet per live worker, truncated to fit.
#
# This NEVER writes to, sends keys to, or restructures a worker — it only
# `capture-pane`s. The worker stays in its own window doing its work. Slot
# assignments come from state/.layout-slot-<n> (written by fm-layout.sh), re-read
# every refresh, so reassigning a slot is just a file rewrite with no pane churn.
# A killed pane ends the loop cleanly; that is how arrange tears a viewer down.
#
# FM_LAYOUT_REFRESH (default 2) sets the cadence. FM_LAYOUT_ONCE=1 renders a
# single frame and exits (used by tests and one-shot inspection).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-layout-lib.sh
. "$SCRIPT_DIR/fm-layout-lib.sh"

SLOT=${1:-summary}
STATE=$(fm_layout_state)
REFRESH=${FM_LAYOUT_REFRESH:-2}

BOLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'

pane_dim() {  # <which: width|height> -> numeric, with a sane fallback
  local fmt=$1 val=""
  if [ -n "${TMUX_PANE:-}" ]; then
    val=$(tmux display-message -p -t "$TMUX_PANE" "#{pane_$fmt}" 2>/dev/null || true)
  fi
  case "$val" in ''|*[!0-9]*) [ "$fmt" = width ] && val=80 || val=12 ;; esac
  printf '%s' "$val"
}

# Truncate a line to <width> columns (best-effort; byte-wise under C locale, which
# is enough to stop wrapping in a narrow watch pane).
fit() {  # <width>
  local w=$1
  LC_ALL=C awk -v w="$w" '{ if (length($0) > w) print substr($0, 1, w); else print }'
}

clear_screen() { printf '\033[H\033[2J'; }

render_slot() {  # <width> <height>
  local w=$1 h=$2 file win repo label live body lines
  file=$(fm_layout_slot_file "$STATE" "$SLOT")
  if [ ! -s "$file" ]; then
    printf '%s[ watch %s ]%s %s(unassigned)%s\n' "$BOLD" "$SLOT" "$RST" "$DIM" "$RST"
    printf '%s\n' "$(printf '%*s' "$w" '' | tr ' ' '-')" | fit "$w"
    printf '%sno worker here — open the picker to assign one%s\n' "$DIM" "$RST"
    return 0
  fi
  IFS=$'\t' read -r win repo label < "$file"
  printf '%s[ watch %s ]%s %s · %s %s(%s)%s\n' "$BOLD" "$SLOT" "$RST" "$repo" "$label" "$DIM" "$win" "$RST" | fit "$w"
  printf '%s\n' "$(printf '%*s' "$w" '' | tr ' ' '-')" | fit "$w"
  if printf '%s\n' "$(fm_layout_live_windows)" | grep -Fxq "$win"; then
    lines=$((h - 2)); [ "$lines" -ge 1 ] || lines=1
    body=$(tmux capture-pane -p -t "$win" 2>/dev/null | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n "$lines")
    printf '%s\n' "$body" | fit "$w"
  else
    printf '%sworker ended — reassign this slot from the picker%s\n' "$DIM" "$RST"
  fi
}

render_summary() {  # <width>
  local w=$1 win repo label any=0
  printf '%sactive workers%s\n' "$BOLD" "$RST"
  printf '%s\n' "$(printf '%*s' "$w" '' | tr ' ' '-')" | fit "$w"
  while IFS=$'\t' read -r win repo label; do
    [ -n "$win" ] || continue
    any=1
    printf '%s\n' "• $repo - $label" | fit "$w"
  done <<EOF
$(fm_layout_workers)
EOF
  [ "$any" -eq 1 ] || printf '%s(none active)%s\n' "$DIM" "$RST"
}

render() {
  local w h
  w=$(pane_dim width); h=$(pane_dim height)
  clear_screen
  if [ "$SLOT" = summary ]; then
    render_summary "$w"
  else
    render_slot "$w" "$h"
  fi
}

if [ "${FM_LAYOUT_ONCE:-0}" = 1 ]; then
  render
  exit 0
fi

# Long-lived refresh loop. Transient capture/tmux errors never exit it; only a
# killed pane (SIGHUP/SIGPIPE on the dead terminal) stops it.
while :; do
  render || true
  sleep "$REFRESH" || exit 0
done
