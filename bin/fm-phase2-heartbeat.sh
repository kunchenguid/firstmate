#!/usr/bin/env bash
# Worker heartbeat + optional stale recovery policy.
# Usage:
#   fm-phase2-heartbeat.sh beat <task-id>
#   fm-phase2-heartbeat.sh scan [--grace N] [--recover]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
REG="$FM_HOME/bin/fm-phase2-registry.sh"
CMD="${1:?beat|scan}"
shift || true

case "$CMD" in
  beat)
    ID="${1:?task-id}"
    "$REG" heartbeat "$ID"
    "$FM_HOME/bin/fm-phase2-event.sh" heartbeat --task "$ID" --dedupe "hb-$(date +%s)" --payload "{\"source\":\"worker\"}"
    mkdir -p "$FM_HOME/state"
    date -Is > "$FM_HOME/state/${ID}.heartbeat"
    ;;
  scan)
    GRACE=300
    RECOVER=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --grace) GRACE="${2:?}"; shift 2 ;;
        --recover) RECOVER=1; shift ;;
        *) shift ;;
      esac
    done
    CFG="$FM_HOME/phase2/config/concurrency.json"
    MAX_FAIL=$(python3 -c "import json;print(json.load(open('$CFG')).get('max_failures_before_block',3))")
    MAX_RESTART=$(python3 -c "import json;print(json.load(open('$CFG')).get('max_auto_restarts',1))")
    STALE=$("$REG" stale --grace "$GRACE")
    echo "$STALE"
    if [ "$RECOVER" -eq 1 ]; then
      python3 - "$FM_HOME" "$STALE" "$MAX_FAIL" "$MAX_RESTART" <<'PY'
import json, subprocess, sys
from pathlib import Path
fm, stale_json, max_fail, max_restart = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
reg = [str(Path(fm)/"bin"/"fm-phase2-registry.sh")]
ev = [str(Path(fm)/"bin"/"fm-phase2-event.sh")]
for t in json.loads(stale_json):
    tid = t["id"]
    attempts = int(t.get("attempts") or 0)
    # failure count approximated by attempts / status
    subprocess.run(ev + ["worker_failed", "--task", tid, "--dedupe", f"stale-{tid}-{attempts}",
                         "--payload", json.dumps({"reason":"missing_heartbeat"})], check=False)
    if attempts <= max_restart:
        subprocess.run(reg + ["transition", tid, "failed", "--reason", "stale_restart_once"], check=False)
        subprocess.run(reg + ["transition", tid, "ready", "--reason", "stale_restart_once"], check=False)
        print(f"recover: restart once -> ready {tid}", file=sys.stderr)
    elif attempts < max_fail:
        # create repair marker via next_action
        subprocess.run(reg + ["transition", tid, "blocked", "--reason", "stale_second_failure",
                              "--field", "next_action=create_repair_task",
                              "--field", f"blocker=stale heartbeat after {attempts} attempts"], check=False)
        print(f"recover: repair needed {tid}", file=sys.stderr)
    else:
        subprocess.run(reg + ["transition", tid, "blocked", "--reason", "stale_third_failure",
                              "--field", "blocker=exceeded retry budget"], check=False)
        print(f"recover: blocked {tid}", file=sys.stderr)
PY
    fi
    ;;
  *)
    echo "usage: $0 beat <id> | scan [--grace N] [--recover]" >&2
    exit 2
    ;;
esac
