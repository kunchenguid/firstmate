#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
# The ambient composer scope at the moment of each call, so a test can prove a
# container-creating call carries none of it into the server it starts.
[ -z "${FM_FAKE_TMUX_ENV_LOG:-}" ] \
  || printf '%s|%s\n' "${1:-}" "${FM_COMPOSER_HARNESS-}" >> "$FM_FAKE_TMUX_ENV_LOG"
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
      # With FM_FAKE_AGY_READY_SCRIPT set (a comma-separated list of good/bad),
      # each capture in the ready state consumes the next entry and the last
      # entry repeats. `bad` renders the INCOMPLETE composer Agy repaints for a
      # second or two right after trust acceptance: the opening rule and the
      # prompt without the closing rule, which the separated-composer proof
      # must not read as an empty composer.
      if [ -n "${FM_FAKE_AGY_READY_SCRIPT:-}" ]; then
        frame=$(cat "$FM_FAKE_AGY_FRAME_COUNTER" 2>/dev/null || printf 0)
        frame=$((frame + 1))
        printf '%s\n' "$frame" > "$FM_FAKE_AGY_FRAME_COUNTER"
        verdict=$(printf '%s' "$FM_FAKE_AGY_READY_SCRIPT" | cut -d, -f"$frame")
        [ -n "$verdict" ] || verdict=$(printf '%s' "$FM_FAKE_AGY_READY_SCRIPT" | tr ',' '\n' | tail -1)
        if [ "$verdict" = bad ]; then
          printf '%s\n' \
            'Antigravity CLI' \
            '────────────────────────────────────────────────────────────────' \
            '>'
          return 0 2>/dev/null || exit 0
        fi
      fi
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
    complete)
      printf '%s\n' \
        "Read the brief at $FM_FAKE_BRIEF_REAL and follow it exactly." \
        '────────────────────────────────────────────────────────────────' \
        '>' \
        '────────────────────────────────────────────────────────────────' \
        '? for shortcuts                              Gemini 3.6 Flash · low'
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
          # Which ready frame the readiness gate accepted before typing. That
          # index is the observable difference between accepting one good frame
          # and requiring the verdict to hold.
          [ -z "${FM_FAKE_POINTER_FRAME:-}" ] \
            || cat "$FM_FAKE_AGY_FRAME_COUNTER" 2>/dev/null > "$FM_FAKE_POINTER_FRAME"
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
          pointer-typed) printf '%s\n' "${FM_FAKE_AGY_TURN:-busy}" > "$FM_FAKE_AGY_STATE" ;;
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
