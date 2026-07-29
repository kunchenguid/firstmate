#!/usr/bin/env bash
# Forward-test pre-flight: dispatch a scout crewmate to check everything
# is ready for the 14:30 UTC forward test run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

TS="$(date -u +%Y%m%d-%H%M)"
ID="ft-preflight-${TS}"

PROJECT="strategies_to_test"
REPO_PATH="${STRATEGIES_TO_TEST_PATH:-$HOME/hermes/strategies-to-test}"

if [ ! -d "$REPO_PATH" ]; then
  echo "ft-preflight: project not found at $REPO_PATH" >&2
  exit 1
fi

echo "ft-preflight: dispatching crewmate $ID"

TASK="Pre-flight check for the IG forward test. Verify: 1) python3 available and can import ig_forward, 2) latest signal file exists at results/ig_forward/signals/, 3) IG demo auth works, 4) IB Gateway port 4001 reachable. Fix any issues found. If the crontab entry for ig_forward has broken env vars or missing PATH, fix it. Write findings to the scout report. Do NOT send Telegram — this is a silent pre-flight."

"$SCRIPT_DIR/fm-brief.sh" "$ID" "$PROJECT" --scout
BRIEF_FILE="${FM_HOME}/data/${ID}/brief.md"
if [ -f "$BRIEF_FILE" ]; then
  sed -i "s|{TASK}|${TASK}|" "$BRIEF_FILE"
fi
"$SCRIPT_DIR/fm-spawn.sh" "$ID" "$REPO_PATH" --scout

echo "ft-preflight: $ID dispatched"
echo "$ID"
