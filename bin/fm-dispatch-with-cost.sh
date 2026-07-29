#!/bin/bash
# fm-dispatch-with-cost.sh - Spawn crewmate with dynamic model selection based on quota
# Usage: fm-dispatch-with-cost.sh <task-id> <repo-name> [--scout]
# Reads config/crew-dispatch.json to select optimal model based on current budget

set -euo pipefail

TASKID="${1:-}"
REPO="${2:-}"
SCOUT_FLAG="${3:-}"

[ -z "$TASKID" ] || [ -z "$REPO" ] && {
    echo "Usage: fm-dispatch-with-cost.sh <task-id> <repo-name> [--scout]"
    exit 1
}

# Check if config exists
CONFIG_FILE="config/crew-dispatch.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "error: $CONFIG_FILE not found"
    exit 1
fi

# Get current quota status
echo "Checking quota..." >&2
QUOTA_JSON=$(quota-axi --json 2>/dev/null || echo '{}')
REMAINING_K=$(echo "$QUOTA_JSON" | jq -r '.quota.remaining // 0' 2>/dev/null || echo "0")

echo "Budget remaining: ${REMAINING_K}k tokens" >&2

# Find best matching profile from config
echo "Matching dispatch profile..." >&2
PROFILE=$(jq -r ".profiles[] | select(.match.budget_remaining_k.min <= $REMAINING_K and ($REMAINING_K <= .match.budget_remaining_k.max // 999999)) | .name" "$CONFIG_FILE" 2>/dev/null | head -1)

if [ -z "$PROFILE" ]; then
    PROFILE=$(jq -r '.fallback_profile.name // "default"' "$CONFIG_FILE" 2>/dev/null)
    echo "Using fallback profile: $PROFILE" >&2
fi

# Extract model and effort from selected profile
MODEL=$(jq -r ".profiles[] | select(.name == \"$PROFILE\") | .model" "$CONFIG_FILE" 2>/dev/null || echo "sonnet")
EFFORT=$(jq -r ".profiles[] | select(.name == \"$PROFILE\") | .effort" "$CONFIG_FILE" 2>/dev/null || echo "medium")

echo "Selected: $PROFILE (model=$MODEL, effort=$EFFORT)" >&2

# Generate brief with resolved model/effort
echo "Generating brief..." >&2
if [ "$SCOUT_FLAG" = "--scout" ]; then
    bin/fm-brief.sh "$TASKID" "$REPO" --scout
else
    bin/fm-brief.sh "$TASKID" "$REPO"
fi

# Spawn the task with resolved model
echo "Spawning with model=$MODEL, effort=$EFFORT" >&2
bin/fm-spawn.sh "$TASKID" --model="$MODEL" --effort="$EFFORT"

