#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

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
  claude|codex|opencode|pi|grok) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"

checkpoint_seconds=${FM_CODEX_WATCH_CHECKPOINT:-180}
pi_ext="$STATE/fm-primary-pi-watch.ts"
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
    printf '%s\n' 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
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
      printf '%s%s\n' "$prefix" 'resume supervision with bin/fm-watch-arm.sh as its own Claude Code background task, never shell &.'
      ;;
    codex)
      printf '%s%s%s%s\n' "$prefix" 'resume supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    pi)
      printf '%s%s%s%s%s%s\n' "$prefix" 'resume supervision through the Pi extension command /fm-watch-arm-pi or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extension is not loaded.'
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'resume supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s\n' "$prefix" 'resume supervision with bin/fm-watch-arm.sh as its own Grok tracked background task, never shell &.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'resume supervision according to the session-start block for this harness; do not use shell &.'
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
if [ "$AFK" -eq 1 ]; then
  printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
else
  printf '%s\n' '- Away mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
printf '%s\n' '- After every handled wake, resume this emitted harness protocol instead of following a hardcoded background-arm recipe.'
printf '\n'
render_snippet
printf '\n'
