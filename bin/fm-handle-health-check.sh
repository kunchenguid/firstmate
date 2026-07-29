#!/usr/bin/env bash
# Handle a health-check wake: dispatch a scout crewmate to check ingestion
# health, fix anything broken, and alert via Telegram.
# Called by firstmate when it processes a "check: health-check:" wake.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TS="$(date -u +%Y%m%d-%H%M)"
ID="health-check-${TS}"

PROJECT="stock_data"
REPO_PATH="${STOCK_DATA_PATH:-$HOME/hermes/stock_data}"

if [ ! -d "$REPO_PATH" ]; then
  echo "health-check: project not found at $REPO_PATH — skipping" >&2
  exit 1
fi

echo "health-check: dispatching crewmate $ID"

TASK="Run the ingestion health check: execute \`hermes_ingest/health_check.py\` in the stock_data project. Check IB Gateway, QuestDB, daemons, and data freshness. If anything is broken, fix it. Send the full health report to the captain via Telegram using the FMTG_BOT_TOKEN and FMTG_ALLOWED_USERS from the firstmate .env file. Write findings to the scout report."

"$SCRIPT_DIR/fm-brief.sh" "$ID" "$PROJECT" --scout

# Replace {TASK} in the brief
BRIEF_FILE="${FM_HOME}/data/${ID}/brief.md"
if [ -f "$BRIEF_FILE" ]; then
  sed -i "s|{TASK}|${TASK}|" "$BRIEF_FILE"
fi

"$SCRIPT_DIR/fm-spawn.sh" "$ID" "$REPO_PATH" --scout --model hy3

echo "health-check: crewmate $ID dispatched"
echo "$ID"
