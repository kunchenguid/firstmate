#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_AGY_STATE" 2>/dev/null || true)

fake_screen() {
  case "$state" in
    trust)
      printf '%s\n' \
        'Accessing workspace: /fixture' \
        'Do you trust the contents of this project?' \
        '> Yes, I trust this folder' \
        '  No, exit'
      ;;
    ready)
      printf '%s\n' \
        'Antigravity CLI' \
        '────────────────────────────────────────────────────────────────' \
        '>' \
        '────────────────────────────────────────────────────────────────' \
        '? for shortcuts                              Gemini 3.6 Flash · low'
      ;;
    pointer-typed)
      printf '%s\n' \
        'Antigravity CLI' \
        '────────────────────────────────────────────────────────────────' \
        "> Read the brief at $FM_FAKE_BRIEF_REAL and follow it exactly." \
        '────────────────────────────────────────────────────────────────' \
        '? for shortcuts                              Gemini 3.6 Flash · low'
      ;;
    busy)
      printf '%s\n' \
        "Read the brief at $FM_FAKE_BRIEF_REAL and follow it exactly." \
        '────────────────────────────────────────────────────────────────' \
        '>' \
        '────────────────────────────────────────────────────────────────' \
        'esc to cancel                               Gemini 3.6 Flash · low'
      ;;
    *)
      printf '%s\n' 'shell starting' '$ '
      ;;
  esac
}

case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '2\n'; exit 0 ;;
esac

case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        'treehouse get'|'export GOTMPDIR='*) ;;
        agy\ *)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_AGY_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_AGY_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched) printf 'trust\n' > "$FM_FAKE_AGY_STATE" ;;
          trust) printf 'ready\n' > "$FM_FAKE_AGY_STATE" ;;
          pointer-typed) printf 'busy\n' > "$FM_FAKE_AGY_STATE" ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    fake_screen
    exit 0
    ;;
esac
exit 0
