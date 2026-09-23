#!/usr/bin/env bash
# Classify a bounded plain-text Grok pane capture against the project-folder
# trust dialog.
# Usage: fm-grok-trust.sh active      # reads the capture from stdin
#        fm-grok-trust.sh superseded  # reads the capture from stdin
#
# active      exit 0 when the capture's last complete trust frame is still
#             waiting for an answer.
# superseded  exit 0 when Grok's own session surface is the newest trust-related
#             thing in the capture, the positive proof that no dialog waits.
#
# Grok repaints its whole screen, so a pane too short to hold the dialog body
# renders a clipped frame - header row and build footer, no title and no
# shortcuts - and pushes the complete frame above the visible slice. A complete
# frame is therefore NEVER the last thing a scrolled-out capture holds, which is
# why the caller reads bounded history rather than the viewport, and why
# "nothing follows the footer" cannot be the test for an active frame: it is
# false exactly when the dialog is below the fold. What separates a waiting frame
# from trust text left in scrollback is not whether anything follows it but WHAT
# follows it. Only Grok's interactive session surface proves the dialog was
# answered and the session moved on; a clipped repaint of the same frame proves
# the opposite. Both verdicts read one definition of that surface below, so the
# active frame and the historical one cannot be told apart by drifting rules.
set -u

case "${1:-}" in
  active|superseded) ;;
  *)
    echo "usage: fm-grok-trust.sh active|superseded" >&2
    exit 2
    ;;
esac

FM_GROK_TRUST_MODE=$1 awk '
  # Rows only Grok itself paints once its session is interactive: the composer
  # box, the keybinding and usage chrome framing it, and the first-run notices
  # that sit beside it.
  function session_surface(row) {
    return row ~ /Weekly limit left:/ ||
      row ~ /Ctrl\+c:cancel/ ||
      row ~ /Shift\+Tab:mode/ ||
      row ~ /Ctrl\+x:shortcuts/ ||
      row ~ /\[Dashboard\]/ ||
      row ~ /Help improve Grok/ ||
      row ~ /^[[:space:]]*Tip:/ ||
      row ~ /│[[:space:]]*❯/
  }
  BEGIN {
    mode = ENVIRON["FM_GROK_TRUST_MODE"]
    title = "Do you trust the contents of this directory?"
  }
  # Newest-wins bookkeeping, before the frame machine consumes any row.
  index($0, title) || /Yes, proceed[[:space:]]+y[[:space:]]*$/ ||
    /No, quit[[:space:]]+n[[:space:]]*$/ { marker = NR }
  session_surface($0) { surface = NR }
  # Frame machine. A title starts a frame, blanks never break one, and the row
  # Grok wraps the project path onto sits between the title and the shortcuts.
  # Anything else abandons the frame in progress rather than completing it, and
  # a frame that completes records where. A clipped repaint carries a footer but
  # no title, so it cannot start a second frame let alone complete one, and the
  # complete frame it scrolled out of view stands.
  index($0, title) { phase = 1; next }
  phase == 0 { next }
  /^[[:space:]]*$/ { next }
  phase == 1 && /Yes, proceed[[:space:]]+y[[:space:]]*$/ { phase = 2; next }
  phase == 2 && /No, quit[[:space:]]+n[[:space:]]*$/ { phase = 3; next }
  phase == 3 && /Grok Build[[:space:]]+[0-9][^[:space:]]*[[:space:]]+\[[^]]+\][[:space:]]*$/ {
    complete = NR
    phase = 0
    next
  }
  phase == 1 { next }
  { phase = 0 }
  END {
    if (mode == "superseded") { exit !(surface > marker) }
    exit !(complete > 0 && surface < complete)
  }
'
