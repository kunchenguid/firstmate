#!/usr/bin/env bash
# Send one line of literal text to a crewmate window, then Enter.
# Usage: fm-send.sh <window> <text...>
#   <window> may be a bare firstmate window name (fm-xyz), resolved through
#   this home's state/<id>.meta, or explicit session:window.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or Enter, C-c, ...)
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the composer clears. If a swallowed
# Enter is positively confirmed (the text is still sitting in the composer after
# all retries), fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction (incident afk-invx-i5).
# The composer/submit logic is shared with the away-mode daemon via
# bin/fm-tmux-lib.sh. Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: a cleared composer only proves the text was
# submitted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    fm-*)
      meta="$STATE/${1#fm-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $1 in $STATE; pass session:window to target a window outside this firstmate home" >&2
        exit 1
      fi
      window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; exit 1; }
      echo "$window"
      ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
         || { echo "error: no window named $1" >&2; exit 1; } ;;
  esac
}

T=$(resolve "$1")
shift

if [ "${1:-}" = "--key" ]; then
  tmux send-keys -t "$T" "$2"
else
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing. Give popups time to settle.
  case "$*" in /*) settle=1.2 ;; *) settle=0.3 ;; esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Lenient: only a positively-confirmed swallow
  # (text still in the composer) is an error; an unreadable pane is assumed sent.
  verdict=$(fm_tmux_submit_core "$T" "$*" "$retries" "$sleep_s" "$settle")
  case "$verdict" in
    pending)
      echo "error: text not submitted to $T (Enter swallowed; text left in composer)" >&2
      exit 1
      ;;
    send-failed)
      echo "error: text not sent to $T (tmux send-keys failed)" >&2
      exit 1
      ;;
  esac
  # Submit landed (verdict was not pending/send-failed). The cleared composer only
  # proves the text was submitted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
