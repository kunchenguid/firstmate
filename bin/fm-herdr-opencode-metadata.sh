#!/usr/bin/env bash
# Report OpenCode agent metadata to herdr's display-only panel.
#
# Usage: fm-herdr-opencode-metadata.sh <pane-id> <model-id> [--ttl-ms <N>]
#
# Takes the herdr pane ID and the raw OpenCode model ID (e.g.
# "muse-spark-1.3-contributor-free") and reports it via herdr pane
# report-metadata with a human-readable short name as the "model" token.
#
# The --ttl-ms flag (default 120000 = 2 minutes) controls how long the
# metadata stays visible before expiring.  Two minutes is long enough that
# active-turn updates keep the panel populated, and short enough that a dead
# worker's stale metadata disappears within a few minutes.
#
# Called by the OpenCode firstmate plugins (both the crewmate fm-busy-state.js
# installed by fm-spawn.sh and the primary fm-primary-herdr-metadata.js).
# Fails silently when herdr is not available - the panel staying empty is the
# honest default.
set -eu

PANE_ID=${1:-}
MODEL_ID=${2:-}
shift 2 || true

TTL_MS=120000
while [ $# -gt 0 ]; do
  case "$1" in
    --ttl-ms) TTL_MS=${2:?--ttl-ms requires a value}; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$PANE_ID" ] || [ -z "$MODEL_ID" ]; then
  exit 0
fi

command -v herdr >/dev/null 2>&1 || exit 0

# Shorten the raw model ID to a human-readable display name.
# Examples:
#   muse-spark-1.3-contributor-free  ->  muse 1.3 free
#   big-pickle                       ->  big-pickle
#   nemotron-3-ultra-free            ->  nemotron 3 ultra free
#   ling-3.0-flash-fin-free          ->  ling 3.0 flash free
#   mimo-v2.5-free                   ->  mimo 2.5 free
# Strategy: drop known noise words (spark, contributor, fin, lightning),
# replace dashes with spaces.  Keep version numbers and meaningful qualifiers.
shorten_model() {
  local raw=$1
  local short
  # Strip common noise segments.
  short=$(printf '%s' "$raw" \
    | sed -E 's/-spark//g; s/-contributor//g; s/-fin//g; s/-lightning//g' \
    | tr '-' ' ')
  # Collapse double spaces.
  short=$(printf '%s' "$short" | sed -E 's/  +/ /g; s/^ //; s/ $//')
  printf '%s' "$short"
}

SHORT_MODEL=$(shorten_model "$MODEL_ID")

exec herdr pane report-metadata "$PANE_ID" \
  --source "user:fm-opencode" \
  --agent opencode \
  --token "model=$SHORT_MODEL" \
  --ttl-ms "$TTL_MS"
