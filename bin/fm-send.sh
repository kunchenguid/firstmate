#!/usr/bin/env bash
# Send one line of literal text to a crewmate endpoint, then Enter.
# Usage: fm-send.sh <target> <text...>
#   <target> may be a bare firstmate task name (fm-xyz), resolved through
#   this home's state/<id>.meta, or an explicit backend target.
# Special keys instead of text: fm-send.sh <target> --key Escape   (or Enter, C-c, ...)
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the composer clears. If a swallowed
# Enter is positively confirmed (the text is still sitting in the composer after
# all retries), fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction (incident afk-invx-i5).
# Submission dispatches through the target's recorded backend; the tmux adapter
# shares its composer/submit core with the away-mode daemon via bin/fm-tmux-lib.sh.
# Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
#
# From-firstmate marker: when the resolved target is a bare `fm-<id>` whose meta
# records kind=secondmate, the text is prefixed with the from-firstmate marker
# (bin/fm-marker-lib.sh) so the secondmate routes its reply via its status file
# or a status-pointed doc instead of stranding it in chat the main firstmate
# never reads. A crewmate/scout target, an explicit backend-target escape-hatch
# target, and the --key path are never marked - their behavior is unchanged.
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

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
T=$(fm_backend_resolve_selector "$1" "$STATE")
shift

# Mark a from-firstmate -> secondmate request. Only a bare `fm-<id>` target,
# resolved through this home's meta and recording kind=secondmate, is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_PREFIX=""
case "$RAW_TARGET" in
  fm-*)
    meta="$STATE/${RAW_TARGET#fm-}.meta"
    if [ -f "$meta" ] && grep -q '^kind=secondmate$' "$meta" 2>/dev/null; then
      MARK_PREFIX="$FM_FROMFIRST_MARK"
    fi
    ;;
esac

# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A bare fm-<id> target carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from fm-<id> meta, or from matching the resolved
# explicit target back to recorded meta, then falls back to tmux.
TARGET_HARNESS=""
TARGET_BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
case "$RAW_TARGET" in
  fm-*)
    meta="$STATE/${RAW_TARGET#fm-}.meta"
    if [ -f "$meta" ]; then
      TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    fi
    ;;
esac

if [ "${1:-}" = "--key" ]; then
  fm_backend_send_key "$TARGET_BACKEND" "$T" "$2"
else
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The retried Enter in
  # fm_tmux_submit_core still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Lenient: only a positively-confirmed swallow
  # (text still in the composer) is an error; an unreadable pane is assumed sent.
  verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MARK_PREFIX$*" "$retries" "$sleep_s" "$settle")
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
