#!/usr/bin/env bash
# Resume / reconstruct programme state after restart (no chat history required).
# Usage: firstmate-resume.sh [--programme <id>] [--json]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ -> FM_HOME
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
REG="$FM_HOME/bin/fm-phase2-registry.sh"
PROGRAMME=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --programme) PROGRAMME="${2:?}"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) shift ;;
  esac
done

"$REG" init >/dev/null
ARGS=(snapshot)
[ -n "$PROGRAMME" ] && ARGS+=(--programme "$PROGRAMME")
SNAP=$("$REG" "${ARGS[@]}")
STALE=$("$REG" stale --grace "$(python3 -c "import json;print(json.load(open('$FM_HOME/phase2/config/concurrency.json')).get('heartbeat_grace_secs',300))")")

if [ "$JSON" -eq 1 ]; then
  python3 -c "import json,sys; s=json.load(sys.stdin); st=json.loads(sys.argv[1]); s['stale_workers']=st; print(json.dumps(s,indent=2))" "$STALE" <<<"$SNAP"
  exit 0
fi

python3 - "$SNAP" "$STALE" "$FM_HOME" <<'PY'
import json, sys, os
from pathlib import Path
snap = json.loads(sys.argv[1])
stale = json.loads(sys.argv[2])
fm = Path(sys.argv[3])
prog = snap.get("programme") or {}
print("=== FirstMate Phase 2 Resume ===")
print(f"home: {fm}")
print(f"programme: {prog.get('id','(none)')} — {prog.get('title','')}")
print(f"phase: {prog.get('phase','')}")
print(f"counts: {snap.get('counts')}")
print()
print("Ready tasks:")
for t in snap.get("ready") or []:
    print(f"  - {t['id']}: {t['title']} [{t.get('worker_type')}]")
print()
print("Active / in-flight:")
for t in snap.get("tasks") or []:
    if t["status"] in {"assigned","implementing","awaiting_tests","awaiting_review","awaiting_ci","changes_requested"}:
        print(f"  - {t['id']}: {t['status']} branch={t.get('branch')} wt={t.get('worktree')} hb={t.get('heartbeat_at')}")
print()
print("Blocked / failed:")
for t in snap.get("tasks") or []:
    if t["status"] in {"blocked","failed"}:
        print(f"  - {t['id']}: {t['status']} blocker={t.get('blocker')} next={t.get('next_action')}")
print()
print("Stale workers:")
for t in stale:
    print(f"  - {t.get('id')}: attempts={t.get('attempts')}")
print()
print("Next safe actions:")
print("  1. bin/fm-phase2-heartbeat.sh scan --recover")
print("  2. bin/fm-phase2-schedule.sh --spawn")
print("  3. bin/fm-watch-arm.sh   # polling fallback")
print("  4. scripts/firstmate-ledger-update.sh")
# worktrees hint
meta_dir = fm / "state"
metas = list(meta_dir.glob("*.meta"))
print(f"meta files: {len(metas)}")
PY

# Update human ledger
"$FM_HOME/scripts/firstmate-ledger-update.sh" 2>/dev/null || true
