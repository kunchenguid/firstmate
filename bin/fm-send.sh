#!/usr/bin/env bash
# Send one line of literal text to a crewmate pane, then submit it.
# Usage: fm-send.sh <window> <text...>
#   <window> may be a bare firstmate window name (fm-xyz), resolved through
#   this home's state/<id>.meta, or an explicit target - a herdr pane id, or a
#   tmux session:window for a pre-cutover pane still being drained.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or enter, C-c, ...)
#
# Delivery goes through bin/fm-herdr.sh. Agents run in herdr and it is the only
# surface firstmate spawns onto, so there is no driver to choose.
#
# `herdr agent prompt --wait` returns only once the agent has actually consumed
# the prompt. That acknowledgment is the thing tmux could never give: there, the
# line had to be typed once and Enter retried until the composer cleared, and
# "did it land" was inferred from rendered text. Here it is answered. A crewmate
# blocked at an approval dialog is REFUSED rather than typed over, and a
# delivery that goes in without a state change is reported as unconfirmed rather
# than as a failure - re-sending a steer the crewmate already has is the worse
# of the two errors.
#
# THE DRAIN. Crewmates spawned before the herdr cutover live in tmux windows and
# their meta has no `mux=herdr` line. Those must stay STEERABLE as well as
# readable until they are torn down - a supervisor that can watch a live
# crewmate but not correct it has lost half of supervision, and some of that
# work carries unlanded commits. So the pre-cutover submit path below is kept
# verbatim for them, via bin/fm-tmux-lib.sh, which is retired for NEW use only.
# Tune it with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4) /
# FM_SEND_SETTLE (1, 0 disables) exactly as before.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-herdr.sh
. "$SCRIPT_DIR/fm-herdr.sh"
# DRAIN ONLY: the pre-cutover submit path, for panes that predate the cutover.
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

fm_herdr_resolve "$1" "$STATE" || exit 1
T=$FM_HERDR_TARGET
shift

if [ "${1:-}" = "--key" ]; then
  # A key is the documented trust-dialog clearing step. Letting the herdr path
  # fail silently gave the operator a non-zero exit and NOTHING to act on; the
  # drain path beside it has always let tmux print its own error.
  if [ "$FM_HERDR_DRAIN" = 1 ]; then
    tmux send-keys -t "$T" "$2"
  elif ! fm_herdr_send_key "$T" "$2"; then
    echo "error: key '$2' was not delivered to $T" >&2
    exit 1
  fi
elif [ "$FM_HERDR_DRAIN" = 0 ]; then
  # Acknowledged delivery. There is nothing to verify afterwards and nothing to
  # settle for: the call does not return until the agent has taken the prompt,
  # so the failure modes the drain path has to infer are reported here directly.
  rc=0
  fm_herdr_prompt "$T" "$*" || rc=$?
  case "$rc" in
    0) : ;;
    3) echo "error: $T is at an approval dialog; the steer was refused, not delivered" >&2; exit 1 ;;
    5)
      # No agent in that pane. Nothing was delivered and, deliberately, nothing
      # was executed: forwarding a steer to a shell would run it.
      echo "error: no agent in $T; the steer was NOT delivered (and NOT executed)" >&2
      exit 1 ;;
    4)
      # Delivered, but the acknowledgment never came. Same lenient rule the
      # drain path uses: only a POSITIVELY CONFIRMED swallow is an error.
      # Reporting failure would make the caller re-send a steer that landed.
      echo "warning: $T took the steer but did not acknowledge it; assuming delivered, not re-sending" >&2
      ;;
    *) echo "error: text not submitted to $T (herdr delivery failed)" >&2; exit 1 ;;
  esac
else
  # DRAIN ONLY - the pre-cutover submit path, verbatim. Delete this branch when
  # fm_herdr_drain_pending reports no pre-cutover meta is left in any home.
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
