#!/usr/bin/env bash
# fm-fabro-trigger.sh - Register/start a Fabro workflow run for a coding task.
# Usage: fm-fabro-trigger.sh <task-id> <worktree> [harness] [kind]
#
# Safe trigger hook: attempts to start or register a Fabro DAG workflow run
# for the task if fabro is available and supported. Fails open / gracefully
# if fabro is unavailable or encounters an error, emitting a clear diagnostic
# without failing the Firstmate/Herdr task execution.

set -euo pipefail

ID="${1:-}"
WT="${2:-}"
HARNESS="${3:-}"
KIND="${4:-ship}"

if [ -z "$ID" ] || [ -z "$WT" ]; then
  echo "Usage: fm-fabro-trigger.sh <task-id> <worktree> [harness] [kind]" >&2
  exit 1
fi

# Only trigger for coding tasks (ship or scout)
if [ "$KIND" != "ship" ] && [ "$KIND" != "scout" ]; then
  exit 0
fi

FABRO_BIN=$(command -v fabro 2>/dev/null || true)
if [ -z "$FABRO_BIN" ] || [ ! -x "$FABRO_BIN" ]; then
  echo "fabro: CLI not found on PATH; skipping Fabro workflow registration for task $ID" >&2
  exit 0
fi

# Determine workflow path in repo
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW_PATH="$REPO_DIR/.fabro/workflows/firstmate-coding/workflow.fabro"

if [ ! -f "$WORKFLOW_PATH" ]; then
  echo "fabro: workflow definition not found at $WORKFLOW_PATH; skipping registration for task $ID" >&2
  exit 0
fi

# Validate workflow definition first
if ! "$FABRO_BIN" validate --quiet --no-upgrade-check "$WORKFLOW_PATH" >/dev/null 2>&1; then
  echo "fabro: workflow validation failed for $WORKFLOW_PATH; skipping run creation for task $ID" >&2
  exit 0
fi

# Attempt to create or run workflow in detached/dry-run mode
# We pass labels to bind the Fabro run to the Firstmate task ID and harness
CREATE_OUT=""
if CREATE_OUT=$("$FABRO_BIN" create --no-upgrade-check --dry-run -d \
    --label "firstmate_task_id=$ID" \
    --label "harness=${HARNESS:-unknown}" \
    --label "worktree=$WT" \
    --label "kind=$KIND" \
    "$WORKFLOW_PATH" 2>&1); then
  echo "fabro: created workflow run for task $ID (${CREATE_OUT##*$'\n'})"
else
  # Check if failure is due to server/environment unavailability
  echo "fabro: run creation skipped for task $ID: ${CREATE_OUT:-unspecified error}" >&2
  exit 0
fi
