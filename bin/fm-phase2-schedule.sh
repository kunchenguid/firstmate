#!/usr/bin/env bash
# Phase 2 scheduler: assign ready tasks under concurrency + ownership rules.
# Usage: fm-phase2-schedule.sh [--programme <id>] [--dry-run] [--spawn]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
REG="$FM_HOME/bin/fm-phase2-registry.sh"
CFG="$FM_HOME/phase2/config/concurrency.json"
PROGRAMME=""
DRY=0
DO_SPAWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --programme) PROGRAMME="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --spawn) DO_SPAWN=1; shift ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
done

python3 - "$FM_HOME" "$CFG" "$PROGRAMME" "$DRY" "$DO_SPAWN" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

fm, cfg_path, programme, dry, do_spawn = sys.argv[1:6]
dry = dry == "1"
do_spawn = do_spawn == "1"
cfg = json.loads(Path(cfg_path).read_text())
reg = [str(Path(fm) / "bin" / "fm-phase2-registry.sh")]

def run(args):
    out = subprocess.check_output(reg + args, text=True)
    return json.loads(out)

snap_args = ["snapshot"]
if programme:
    snap_args += ["--programme", programme]
snap = run(snap_args)
ready = snap.get("ready") or []
active = [t for t in snap.get("tasks") or [] if t["status"] in {
    "assigned", "implementing", "awaiting_tests", "awaiting_review", "awaiting_ci", "changes_requested"
}]

def profile_bucket(worker_type: str) -> str:
    wt = worker_type.lower()
    if "review" in wt or "no_mistake" in wt:
        return "reviewer"
    if "database" in wt or "migration" in wt:
        return "migration"
    if "release" in wt or "deploy" in wt:
        return "deployment"
    return "implementation"

counts = {"implementation": 0, "reviewer": 0, "migration": 0, "deployment": 0}
owned = []
for t in active:
    counts[profile_bucket(t.get("worker_type", ""))] = counts.get(profile_bucket(t.get("worker_type", "")), 0) + 1
    owned.extend(t.get("ownership_globs") or [])

limits = {
    "implementation": cfg.get("max_implementation_workers", 3),
    "reviewer": cfg.get("max_reviewer_workers", 1),
    "migration": cfg.get("max_migration_workers", 1),
    "deployment": 1 if cfg.get("deployment_workers_enabled") else 0,
}

def overlaps(a, b):
    # naive glob-ish overlap: identical or prefix match on directory segments
    for x in a:
        for y in b:
            if x == y or x.startswith(y.rstrip("*")) or y.startswith(x.rstrip("*")):
                return True
    return False

selected = []
for task in ready:
    bucket = profile_bucket(task.get("worker_type", ""))
    if counts.get(bucket, 0) >= limits.get(bucket, 0):
        continue
    globs = task.get("ownership_globs") or []
    if overlaps(globs, owned):
        continue
    if task.get("risk") == "migration" and counts["migration"] >= limits["migration"]:
        continue
    selected.append(task)
    counts[bucket] = counts.get(bucket, 0) + 1
    owned.extend(globs)

print(json.dumps({"selected": selected, "active_counts": counts, "limits": limits}, indent=2))

if dry or not selected:
    sys.exit(0)

for task in selected:
    tid = task["id"]
    run(["transition", tid, "assigned", "--reason", "scheduler"])
    # mirror STATE.json
    pkt = Path(task.get("packet_dir") or f"{fm}/data/{tid}/packet")
    state = pkt / "STATE.json"
    if state.parent.is_dir():
        data = {"task_id": tid, "status": "assigned", "updated_at": __import__("datetime").datetime.utcnow().isoformat() + "Z"}
        state.write_text(json.dumps(data, indent=2) + "\n")
    if do_spawn:
        # Caller must have brief + project; spawn is best-effort via meta project path
        print(f"schedule: assigned {tid} (spawn left to fm-phase2-dispatch.sh)", file=sys.stderr)
PY
