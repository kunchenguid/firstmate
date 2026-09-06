#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
AFK_DAEMON_DOWN=0
AFK_ABSENCE_PROVEN=0
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--afk-daemon-down 0|1] [--afk-absence-proven 0|1] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

--afk-daemon-down reports that away mode is flagged with no live supervisor daemon.
It is only meaningful alongside --afk 1, and defaults to 0 so a caller that cannot
answer the question keeps the ordinary away-mode wording.
--afk-absence-proven reports that the absence is PROVEN - no lock, no recorded pid,
or no live process - rather than a live daemon whose ownership could not be
verified. It is only meaningful alongside --afk-daemon-down 1, and defaults to 0,
which is the weaker claim, so a caller that cannot tell the two apart never
overstates what it knows.

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --afk-daemon-down)
      [ "$#" -gt 1 ] || { echo "error: --afk-daemon-down requires 0 or 1" >&2; exit 2; }
      AFK_DAEMON_DOWN=$(bool_value "$2")
      shift 2
      ;;
    --afk-absence-proven)
      [ "$#" -gt 1 ] || { echo "error: --afk-absence-proven requires 0 or 1" >&2; exit 2; }
      AFK_ABSENCE_PROVEN=$(bool_value "$2")
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

case "$HARNESS" in
  claude|codex|opencode|pi|grok|cursor) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  pi-signed) SNIPPET="$DOC_DIR/pi.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"

checkpoint_seconds=${FM_CODEX_WATCH_CHECKPOINT:-180}
pi_ext="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

x_mode_env_sh=$(shell_quote "$x_mode_env")

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

render_snippet() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//__FM_PI_EXT__/$pi_ext}
    line=${line//__FM_PI_TURNEND_EXT__/$pi_turnend_ext}
    line=${line//__FM_X_MODE_ENV_SH__/$x_mode_env_sh}
    line=${line//__FM_X_MODE_ENV__/$x_mode_env}
    printf '%s\n' "$line"
  done < "$SNIPPET"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    if [ "$AFK_DAEMON_DOWN" -eq 1 ] && [ "$AFK_ABSENCE_PROVEN" -eq 1 ]; then
      printf '%s\n' 'Away mode is flagged but no away-mode daemon is running; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    elif [ "$AFK_DAEMON_DOWN" -eq 1 ]; then
      printf '%s\n' 'Away mode is flagged and a daemon is running, but its ownership of watcher supervision cannot be confirmed; load /afk and confirm the daemon is supervising instead of starting normal supervision directly.'
    else
      printf '%s\n' 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    fi
    return 0
  fi

  prefix=
  if [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  if [ "$X_MODE" -eq 1 ]; then
    prefix="${prefix}source ${x_mode_env_sh} first, then "
  fi

  case "$HARNESS" in
    claude)
      printf '%s%s\n' "$prefix" 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.'
      ;;
    codex)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    pi|pi-signed)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Grok tracked background task, never shell &.'
      ;;
    cursor)
      printf '%s%s\n' "$prefix" 'watcher supervision is owned by the stop-hook park; inspect the hook registration and watcher startup path before ending the turn.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

ordinary_wake_line() {
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    codex)
      printf '%s\n' '- Ordinary wake: take the next foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
      ;;
    pi|pi-signed)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Grok tracked background task as directed below.'
      ;;
    cursor)
      printf '%s\n' '- Ordinary wake: the stop-hook park (bin/fm-turnend-guard-cursor.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    *)
      printf '%s\n' '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
      ;;
  esac
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================================================================================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
if [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ] && [ "$AFK_DAEMON_DOWN" -eq 1 ] && [ "$AFK_ABSENCE_PROVEN" -eq 1 ] && [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Away mode: FLAGGED, BUT NO SUPERVISOR IS RUNNING; no away-mode daemon is running for this home, so nothing is supervising. Repairing this needs the fleet lock, so report it to the session holding the lock rather than relaunching from here.'
elif [ "$AFK" -eq 1 ] && [ "$AFK_DAEMON_DOWN" -eq 1 ] && [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Away mode: FLAGGED, BUT SUPERVISION CANNOT BE CONFIRMED; a daemon is running but cannot be confirmed as owning this home, so supervision is unproven. Repairing this needs the fleet lock, so report it to the session holding the lock rather than relaunching from here.'
elif [ "$AFK" -eq 1 ] && [ "$AFK_DAEMON_DOWN" -eq 1 ] && [ "$AFK_ABSENCE_PROVEN" -eq 1 ]; then
  printf '%s\n' '- Away mode: FLAGGED, BUT NO SUPERVISOR IS RUNNING; no away-mode daemon is running for this home, so nothing is supervising. Load /afk and relaunch the daemon, or exit away mode properly, before relying on away-mode supervision.'
elif [ "$AFK" -eq 1 ] && [ "$AFK_DAEMON_DOWN" -eq 1 ]; then
  printf '%s\n' '- Away mode: FLAGGED, BUT SUPERVISION CANNOT BE CONFIRMED; a daemon is running but cannot be confirmed as owning this home, so supervision is unproven. Load /afk and confirm the daemon is supervising before relying on away-mode supervision.'
elif [ "$AFK" -eq 1 ]; then
  printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
else
  printf '%s\n' '- Away mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
ordinary_wake_line
printf '\n'
render_snippet
printf '\n'
