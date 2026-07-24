#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
# A non-owned lock state (LIVE_OTHER, STALE_RECLAIMABLE, IDENTITY_UNAVAILABLE)
# withholds the harness protocol and every other fleet-mutating instruction;
# the only offered mutation is the atomic stale-lock reclaim path, so a proven
# stale lock stays recoverable from the same session.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
LOCK_STATE=
AFK=0
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--lock-state <result>] [--afk 0|1] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

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
    --lock-state)
      [ "$#" -gt 1 ] || { echo "error: --lock-state requires a result" >&2; exit 2; }
      LOCK_STATE=$2
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

if [ -z "$LOCK_STATE" ]; then
  if [ "$READ_ONLY" -eq 1 ]; then
    LOCK_STATE=LIVE_OTHER
  else
    LOCK_STATE=OWNED
  fi
fi
case "$LOCK_STATE" in
  OWNED|LIVE_OTHER|STALE_RECLAIMABLE|IDENTITY_UNAVAILABLE) ;;
  *) echo "error: unsupported lock state: $LOCK_STATE" >&2; exit 2 ;;
esac

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

case "$HARNESS" in
  claude|codex|opencode|pi|grok) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
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
  if [ "$LOCK_STATE" = LIVE_OTHER ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$LOCK_STATE" != OWNED ]; then
    printf '%s\n' 'Watcher repair is disabled because this session did not acquire the fleet lock; resolve the reported lock outcome first.'
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
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Claude Code background task, never shell &.'
      ;;
    codex)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    pi)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Grok tracked background task, never shell &.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

# Non-owned lock states get no ordinary mutation instructions at all: emitting
# the normal supervision recipe there would contradict the lock contract those
# instructions exist to protect. The one deliberate exception is the atomic
# reclaim offer in STALE_RECLAIMABLE, so a stale lock stays recoverable without
# a new window.
render_non_owned_block() {
  printf 'Mode: non-owned lock state (%s) - supervision withheld.\n\n' "$LOCK_STATE"
  printf '%s\n' 'The ordinary supervision protocol and every other fleet-mutating instruction'
  printf '%s\n' 'are withheld: no non-owned lock state may mutate fleet state.'
  printf '\n'
  case "$LOCK_STATE" in
    LIVE_OTHER)
      printf '%s\n' 'Another live firstmate session holds the fleet lock; operate read-only.'
      printf '%s\n' 'Do not drain, arm, spawn, steer, merge, or repair fleet state from this session.'
      printf '%s\n' 'The session holding the lock owns supervision and every mutating follow-up.'
      ;;
    STALE_RECLAIMABLE)
      printf '%s\n' 'The recorded owner is proven stale, but the automatic reclaim did not complete.'
      printf '%s\n' 'The one permitted mutation is the atomic lock reclaim itself:'
      printf '%s\n' '  1. Read the recorded owner with bin/fm-lock.sh status.'
      printf '%s\n' '  2. Run bin/fm-lock.sh reclaim --expected <recorded-owner>.'
      printf '%s\n' '  3. On LOCK_RESULT=OWNED, re-run bin/fm-session-start.sh; it continues as the'
      printf '%s\n' "     owner into the wake-queue drain and this harness's normal supervision protocol."
      printf '%s\n' 'Every other mutation stays withheld until this session owns the lock.'
      ;;
    IDENTITY_UNAVAILABLE)
      printf '%s\n' 'Neither a live rival nor a stale owner is proven; treat this state as neither.'
      printf '%s\n' 'Do not mutate fleet state and do not force the lock free.'
      printf '%s\n' 'Restore identity evidence (readable process ancestry, or CODEX_THREAD_ID for'
      printf '%s\n' 'Codex), then re-run bin/fm-session-start.sh.'
      printf '%s\n' 'For a foreign codex-thread owner, only the captain explicitly confirming that'
      printf '%s\n' 'its old window is closed authorizes:'
      printf '%s\n' '  bin/fm-lock.sh reclaim --expected codex-thread:<id> --confirmed-closed'
      ;;
  esac
}

ordinary_wake_line() {
  if [ "$LOCK_STATE" != OWNED ]; then
    printf '%s\n' '- Ordinary wake: none; this session does not own the fleet lock and takes no supervision action.'
    return 0
  fi
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    codex)
      printf '%s\n' '- Ordinary wake: take the next foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
      ;;
    pi)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Grok tracked background task as directed below.'
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
if [ "$LOCK_STATE" = LIVE_OTHER ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
elif [ "$LOCK_STATE" != OWNED ]; then
  printf '%s\n' "- Lock: not acquired ($LOCK_STATE); do not drain, arm, spawn, steer, merge, or repair fleet state here."
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ]; then
  if [ "$LOCK_STATE" = OWNED ]; then
    printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
  else
    printf '%s\n' '- Away mode: active; the daemon is not started or repaired from a session that does not own the fleet lock.'
  fi
else
  printf '%s\n' '- Away mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  if [ "$LOCK_STATE" = OWNED ]; then
    printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
  else
    printf '%s%s%s\n' '- X mode: active; the cadence config ' "$x_mode_env" ' applies once a session owns the fleet lock.'
  fi
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
ordinary_wake_line
printf '\n'
if [ "$LOCK_STATE" = OWNED ]; then
  render_snippet
else
  render_non_owned_block
fi
printf '\n'
