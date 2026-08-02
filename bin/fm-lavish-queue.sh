#!/usr/bin/env bash
# Queue one already-durable Lavish answer visibly into the supervisor CLI when a
# safe terminal-backed target is available.
#
# This deliberately uses Firstmate's backend terminal adapters, not Claude Code
# private state.
# Claude's documented external queued-input surface is print-mode streaming
# input, not injection into an already-running interactive TUI.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOME_ARG=
DECISION=
ANSWER=
DIGEST=
DESTINATION=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) HOME_ARG=${2:-}; shift 2 ;;
    --decision) DECISION=${2:-}; shift 2 ;;
    --answer) ANSWER=${2:-}; shift 2 ;;
    --digest) DIGEST=${2:-}; shift 2 ;;
    --destination) DESTINATION=${2:-}; shift 2 ;;
    *) printf 'fm-lavish-queue: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$HOME_ARG" ] || { echo "fm-lavish-queue: --home is required" >&2; exit 2; }
[ -n "$DECISION" ] || { echo "fm-lavish-queue: --decision is required" >&2; exit 2; }
[ -n "$ANSWER" ] || { echo "fm-lavish-queue: --answer is required" >&2; exit 2; }
[ -n "$DIGEST" ] || { echo "fm-lavish-queue: --digest is required" >&2; exit 2; }

case "$DECISION" in
  [a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9]) ;;
  *) echo "fm-lavish-queue: invalid decision id" >&2; exit 2 ;;
esac
[ "${#DECISION}" -le 64 ] || { echo "fm-lavish-queue: invalid decision id" >&2; exit 2; }
case "$DIGEST" in
  sha256:*) ;;
  *) echo "fm-lavish-queue: invalid answer digest" >&2; exit 2 ;;
esac
hex=${DIGEST#sha256:}
case "$hex" in
  ''|*[!0-9a-f]*) echo "fm-lavish-queue: invalid answer digest" >&2; exit 2 ;;
esac
[ "${#hex}" -eq 64 ] || { echo "fm-lavish-queue: invalid answer digest" >&2; exit 2; }

[ -d "$HOME_ARG" ] && [ ! -L "$HOME_ARG" ] \
  || { echo "fm-lavish-queue: unsafe FM_HOME" >&2; exit 2; }
FM_HOME=$(cd "$HOME_ARG" && pwd -P)
STATE_ARG=${FM_STATE_OVERRIDE:-$FM_HOME/state}
[ -d "$STATE_ARG" ] && [ ! -L "$STATE_ARG" ] \
  || { echo "fm-lavish-queue: unsafe state directory" >&2; exit 2; }
STATE=$(cd "$STATE_ARG" && pwd -P)
FM_STATE_OVERRIDE=$STATE
export FM_STATE_OVERRIDE
[ -d "$STATE" ] && [ ! -L "$STATE" ] \
  || { echo "fm-lavish-queue: unsafe state directory" >&2; exit 2; }

delivery_dir="$STATE/lavish-deliveries"
mkdir -p "$delivery_dir"
[ -d "$delivery_dir" ] && [ ! -L "$delivery_dir" ] \
  || { echo "fm-lavish-queue: unsafe delivery directory" >&2; exit 2; }
marker="$delivery_dir/$DECISION.digest"
if [ -e "$marker" ] || [ -L "$marker" ]; then
  [ -f "$marker" ] && [ ! -L "$marker" ] \
    || { echo "fm-lavish-queue: unsafe delivery marker" >&2; exit 2; }
  existing=$(cat "$marker")
  if [ "$existing" = "$DIGEST" ]; then
    printf 'lavish-delivery: prompt already queued for %s\n' "$DECISION"
    exit 0
  fi
  echo "fm-lavish-queue: delivery marker digest changed for $DECISION" >&2
  exit 3
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

route=$(fm_session_lock_supervisor_route "$STATE/.lock" "$FM_HOME" 2>/dev/null || true)
[ -n "$route" ] || {
  echo "fm-lavish-queue: home-bound supervisor target is missing or stale for $FM_HOME" >&2
  exit 4
}
backend=${route%%$'\t'*}
target=${route#*$'\t'}
[ "$route" != "$backend" ] && [ -n "$target" ] || {
  echo "fm-lavish-queue: home-bound supervisor target is invalid for $FM_HOME" >&2
  exit 4
}
fm_backend_validate "$backend" || exit 4
fm_backend_target_exists "$backend" "$target" \
  || { echo "fm-lavish-queue: supervisor target is not live: $backend $target" >&2; exit 4; }

if [ "$backend" = tmux ]; then
  fm_backend_source tmux || exit 4
  command_name=$(fm_backend_tmux_current_command "$target" || true)
  case "$command_name" in
    claude) ;;
    '')
      echo "fm-lavish-queue: could not verify Claude Code is foreground in $target" >&2
      exit 4
      ;;
    *)
      echo "fm-lavish-queue: refusing to queue into non-Claude foreground command: $command_name" >&2
      exit 4
      ;;
  esac
fi

composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || true)
case "$composer" in
  empty) ;;
  pending)
    echo "fm-lavish-queue: supervisor composer already has pending input" >&2
    exit 4
    ;;
  *)
    echo "fm-lavish-queue: supervisor composer state is unknown" >&2
    exit 4
    ;;
esac

[ -n "$DESTINATION" ] \
  || { echo "fm-lavish-queue: --destination is required" >&2; exit 2; }
case "$DESTINATION" in
  data/?*) ;;
  *) echo "fm-lavish-queue: invalid destination" >&2; exit 2 ;;
esac
case "$DESTINATION" in
  /*|*\\*|*/|*//*|*/./*|*/../*|*$'\n'*|*$'\r'*)
    echo "fm-lavish-queue: invalid destination" >&2
    exit 2
    ;;
esac

relative_answer=${ANSWER#"$FM_HOME/"}
message="Captain submitted Lavish decision $DECISION. The durable answer is saved at $relative_answer and should now be ingested at $DESTINATION. Run bin/fm-lavish-intake.sh if needed, read the answer, and do not ask the captain to resubmit."
verdict=$(fm_backend_send_text_submit "$backend" "$target" "$message" 3 0.4 0.2)
case "$verdict" in
  empty)
    tmp=$(mktemp "$delivery_dir/.$DECISION.digest.XXXXXX")
    printf '%s\n' "$DIGEST" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$marker"
    printf 'lavish-delivery: prompt queued for %s via %s %s\n' "$DECISION" "$backend" "$target"
    ;;
  *)
    printf 'fm-lavish-queue: prompt submit was not confirmed for %s: %s\n' "$DECISION" "$verdict" >&2
    exit 4
    ;;
esac
