#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
#
# --read-only 1 replaces the harness wake protocol with a read-only operating
# block instead of rendering it. The protocol is a mutating instruction set -
# every harness snippet opens by draining the wake queue and running the watcher
# - so a lock-refused session must not receive it. See read_only_operating_block
# for the boundary and the reason the idle turn is the correct outcome.
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
AFK_MODE=away
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--afk-mode away|quiet] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.
--afk-mode only matters when --afk 1 (present); it selects the away-mode vs
quiet-mode (kunchenguid/firstmate#2356) wording, and defaults to away.
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
    --afk-mode)
      [ "$#" -gt 1 ] || { echo "error: --afk-mode requires away or quiet" >&2; exit 2; }
      case "$2" in
        away|quiet) AFK_MODE=$2 ;;
        *) AFK_MODE=away ;;
      esac
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
  claude|codex|opencode|pi|grok|cursor|omp) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  pi-signed) SNIPPET="$DOC_DIR/pi.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"
HOST_SNIPPET=
grok_arm='bin/fm-watch-arm.sh'
case "$HARNESS" in
  claude|cursor|opencode|omp|grok|codex)
    # shellcheck source=bin/fm-supervision-engine-lib.sh
    . "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
    if fm_supervision_host_enabled "$CONFIG" "$HARNESS"; then
      HOST_SNIPPET="$DOC_DIR/supervision-host.md"
      grok_arm='bin/fm-supervision-host.sh park'
    fi
    ;;
esac

checkpoint_seconds=${FM_CODEX_WATCH_CHECKPOINT:-180}
pi_ext="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
omp_ext="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
omp_turnend_ext="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
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

render_snippet() {  # [snippet]
  local line tags snippet=${1:-$SNIPPET}
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '{'*'} '*)
        tags=${line%%\} *}
        tags=${tags#\{}
        case ",$tags," in *",$HARNESS,"*) ;; *) continue ;; esac
        line=${line#*\} }
        ;;
    esac
    line=${line//__FM_PI_EXT__/$pi_ext}
    line=${line//__FM_PI_TURNEND_EXT__/$pi_turnend_ext}
    line=${line//__FM_OMP_EXT__/$omp_ext}
    line=${line//__FM_OMP_TURNEND_EXT__/$omp_turnend_ext}
    line=${line//__FM_X_MODE_ENV_SH__/$x_mode_env_sh}
    line=${line//__FM_X_MODE_ENV__/$x_mode_env}
    line=${line//__FM_GROK_ARM__/$grok_arm}
    printf '%s\n' "$line"
  done < "$snippet"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf '%s\n' 'Quiet mode owns watcher supervision; load /quiet and ensure the daemon is running instead of starting normal supervision directly.'
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
    omp)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the omp tool fm_watch_arm_omp, or restart omp inside this home so ' "$omp_turnend_ext" ' and ' "$omp_ext" ' auto-load from .omp/extensions/ (use -e with both paths only when starting omp from another directory).'
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with ' "$grok_arm" ' as its own Grok tracked background task, never shell &.'
      ;;
    cursor)
      printf '%s%s\n' "$prefix" 'watcher supervision is owned by the stop-hook park; inspect the hook registration and watcher startup path before ending the turn.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

# A lock-refused session owns no fleet state, so it must not receive the wake
# protocol at all. The protocol is a mutating instruction set - every harness
# snippet opens by draining the wake queue and running the watcher - so
# rendering it here told a read-only session to perform exactly the mutations
# the read-only boundary forbids, and on a foreground-checkpoint harness it
# looked like a wedged session stuck in an endless blocking checkpoint.
# This is the full-block counterpart of the read-only repair line above: it
# states the same boundary in operating terms, and names the idle turn as the
# correct outcome so the session reports the conflict instead of retrying.
read_only_operating_block() {
  printf '%s\n' 'This session does not own fleet supervision and must not perform any of it:'
  printf '%s\n' 'another live session holds the fleet lock. The harness wake protocol that'
  printf '%s\n' 'normally follows is intentionally omitted here. Do not drain queued wakes,'
  printf '%s\n' 'arm or repair a watcher, spawn, steer, merge, or run a foreground watcher'
  printf '%s\n' 'checkpoint from this session - each is a fleet mutation this session has no'
  printf '%s\n' 'authority over. Queued wakes stay queued for the lock holder: report them'
  printf '%s\n' 'rather than draining them. An idle turn here is the correct outcome, not a'
  printf '%s\n' 'wedged session - say so plainly instead of waiting on work you may not do.'
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
    omp)
      printf '%s\n' '- Ordinary wake: the omp extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s%s%s\n' '- Ordinary wake: re-arm exactly one ' "$grok_arm" ' Grok tracked background task as directed below.'
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
if [ "$AFK" -eq 1 ]; then
  if [ "$AFK_MODE" = quiet ]; then
    printf '%s\n' '- Quiet mode: active; load /quiet and keep normal harness supervision paused while the daemon owns the watcher. Ordinary captain chat does NOT exit it - only an explicit /quiet off does.'
  else
    printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
  fi
else
  printf '%s\n' '- Away/quiet mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
if [ "$READ_ONLY" -eq 1 ]; then
  read_only_operating_block
  printf '\n'
  exit 0
fi
ordinary_wake_line
printf '\n'
render_snippet
printf '\n'
if [ -n "$HOST_SNIPPET" ]; then
  render_snippet "$HOST_SNIPPET"
  printf '\n'
fi
