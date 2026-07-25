#!/usr/bin/env bash
# Emit a durable, idempotent Phase 2 event (filesystem + SQLite).
# Usage: fm-phase2-event.sh <kind> --task <id> --dedupe <key> [--payload '{...}']
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
KIND="${1:?kind required}"
shift
TASK=""
DEDUPE=""
PAYLOAD='{}'
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2:?}"; shift 2 ;;
    --dedupe) DEDUPE="${2:?}"; shift 2 ;;
    --payload) PAYLOAD="${2:?}"; shift 2 ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DEDUPE" ] || { echo "--dedupe required" >&2; exit 2; }

EVDIR="$FM_HOME/state/events"
PROCDIR="$FM_HOME/state/events-processed"
mkdir -p "$EVDIR" "$PROCDIR"
TS=$(date +%s%N)
SAFE_KIND=$(printf '%s' "$KIND" | tr -c 'A-Za-z0-9._-' '_')
SAFE_TASK=$(printf '%s' "${TASK:-none}" | tr -c 'A-Za-z0-9._-' '_')
FILE="$EVDIR/${TS}-${SAFE_TASK}-${SAFE_KIND}.json"
python3 - "$FILE" "$KIND" "$TASK" "$DEDUPE" "$PAYLOAD" <<'PY'
import json, pathlib, sys, time
path, kind, task, dedupe, payload = sys.argv[1:6]
obj = {
  "kind": kind,
  "task_id": task,
  "dedupe_key": dedupe,
  "payload": json.loads(payload),
  "created_at": time.time(),
}
pathlib.Path(path).write_text(json.dumps(obj, indent=2) + "\n")
print(path)
PY

"$FM_HOME/bin/fm-phase2-registry.sh" event "$KIND" --task "$TASK" --dedupe "$DEDUPE" --payload "$PAYLOAD"

# Optional unix socket nudge (ignore failures)
if [ -S "$FM_HOME/state/phase2.sock" ]; then
  printf '%s\n' "$FILE" | nc -U -w 1 "$FM_HOME/state/phase2.sock" 2>/dev/null || true
fi
