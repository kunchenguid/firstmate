#!/usr/bin/env bash
# Check provider five-hour quotas and steer newly affected live tasks.
# Usage: fm-quota-stop-compact.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
THRESHOLD=10

die() { printf 'fm-quota-stop-compact: %s\n' "$1" >&2; exit 2; }
command -v quota-axi >/dev/null 2>&1 || die 'quota-axi is not on PATH'
command -v jq >/dev/null 2>&1 || die 'jq is not on PATH'
snapshot=$(quota-axi --provider claude,codex,agy --json 2>&1) \
  || die "quota-axi snapshot failed: $snapshot"

# Claude and Codex use five_hour. AGY has separate Gemini and Claude/GPT
# five-hour windows, so the lower fresh value governs its mixed-model sessions.
# Ignore stale or missing provider data rather than steering on an unknown value.
while read -r provider windows harness; do
  [ -n "$provider" ] || continue
  percent=$(printf '%s\n' "$snapshot" | jq -er --arg provider "$provider" --arg windows "$windows" '
    .providers[] | select(.provider == $provider and .state.status == "fresh")
    | .windows[] | select(.id as $id | ($windows | split(",") | index($id)) != null)
    | .percentRemaining
    | select(type == "number" and . >= 0 and . <= 100)
  ' 2>/dev/null | sort -n | head -1 || true)
  case "$percent" in ''|*[!0-9.]*|.*|*.) continue ;; esac

  episode_file="$STATE/.quota-stop-compact-$provider-episode"
  previous_episode=$(cat "$episode_file" 2>/dev/null || true)
  if awk -v value="$percent" -v threshold="$THRESHOLD" 'BEGIN { exit !(value > threshold) }'; then
    if [ "$previous_episode" != 0 ] && [ -n "$previous_episode" ]; then
      printf '0\n' > "$episode_file" || die "cannot reset episode state for $provider"
    fi
    continue
  fi

  mkdir -p "$STATE" || die "cannot create state directory: $STATE"
  if [ -z "$previous_episode" ] || [ "$previous_episode" = 0 ]; then
    episode="$(date +%s)-$$"
    printf '%s\n' "$episode" > "$episode_file" || die "cannot record episode state for $provider"
  else
    episode=$previous_episode
  fi

  steer_file="$STATE/.quota-stop-compact-$provider"
  case "$harness" in
    claude|codex)
      instruction="The $provider five-hour quota is at ${percent}%. Finish your current bounded step safely; do not stop mid-edit. At the next clean breakpoint, run /compact, preserving the task scope, decisions, changed files, validation, and next action."
      ;;
    agy)
      instruction="The AGY five-hour quota is at ${percent}%. Finish your current bounded step safely; do not stop mid-edit. Antigravity CLI has no supported context-compaction command. At the next clean breakpoint, write a concise durable checkpoint to your task status/report with decisions, changed files, validation, and next action, then notify firstmate to relaunch you fresh with bin/fm-control.sh relaunch. Do not stop your own session; firstmate owns lifecycle control."
      ;;
  esac

  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    task_harness=$(sed -n 's/^harness=//p' "$meta" | tail -1)
    [ "$task_harness" = "$harness" ] || continue
    current=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$FM_ROOT/bin/fm-crew-state.sh" "$task" 2>&1) \
      || die "cannot read current state for $task: $current"
    case "$current" in 'state: working'*) ;; *) continue ;; esac

    spawn_gen=$(sed -n 's/^spawn_gen=//p' "$meta" | tail -1)
    [ -n "$spawn_gen" ] || spawn_gen=0
    sent="$(cat "$steer_file-$task" 2>/dev/null || true)"
    [ "$sent" != "$episode:$spawn_gen" ] || continue
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$FM_ROOT/bin/fm-send.sh" "$task" "$instruction" \
      || die "steer delivery failed for $task"
    printf '%s\n' "$episode:$spawn_gen" > "$steer_file-$task" \
      || die "cannot record steer delivery for $task"
    printf 'Low quota: %s five-hour=%s%%; steered live task %s.\n' \
      "$provider" "$percent" "$task"
  done
done <<'TABLE'
claude five_hour claude
codex five_hour codex
agy gemini_5h,claude_gpt_5h agy
TABLE

exit 0
