#!/usr/bin/env bash
# Vibe 3.0.2 rendered delivery shapes. Sourced; no side effects.
# fm_vibe_screen_state <plain-screen> -> busy|idle|unknown
# The composer must be the final ruled > region followed by Vibe's cwd/PID
# footer. Missing or changed shapes are unknown, never presumed idle.
fm_vibe_screen_state() {
  printf '%s\n' "$1" | awk '
    /[─][─][─][─][─][─][─][─]/ && /auto-approve|accept edits|smart.approve|ask/ { top=NR; glyph=0; bottom=0 }
    top && NR==top+1 && /^>[[:space:]]*/ { glyph=NR }
    glyph && NR>glyph && /^[─]+[[:space:]]*$/ { bottom=NR }
    bottom && NR>bottom && /\[PID [0-9]+\].*tokens/ { footer=NR }
    /Esc\/Ctrl\+C to interrupt/ { busy=NR }
    END {
      if (!top || !glyph || !bottom || footer!=NR) print "unknown";
      else if (busy && busy==top-1) print "busy";
      else print "idle";
    }'
}

# fm_vibe_composer_state <plain-screen> -> empty|pending|unknown
fm_vibe_composer_state() {
  local state
  state=$(fm_vibe_screen_state "$1")
  [ "$state" != unknown ] || { printf 'unknown'; return; }
  printf '%s\n' "$1" | awk '
    /[─][─][─][─][─][─][─][─]/ && /auto-approve|accept edits|smart.approve|ask/ { active=1; pending=0; next }
    active && /^[─]+[[:space:]]*$/ { active=0; next }
    active { sub(/^>[[:space:]]*/, ""); if ($0 ~ /[^[:space:]]/) pending=1 }
    END { print pending ? "pending" : "empty" }'
}
