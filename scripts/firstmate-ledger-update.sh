#!/usr/bin/env bash
# Regenerate docs/IMPLEMENTATION-EXECUTION-LEDGER.md from programme.db
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
REG="$FM_HOME/bin/fm-phase2-registry.sh"
OUT="$FM_HOME/docs/IMPLEMENTATION-EXECUTION-LEDGER.md"
"$REG" init >/dev/null
SNAP=$("$REG" snapshot)
python3 - "$SNAP" "$OUT" <<'PY'
import json, sys
from datetime import datetime, timezone
snap = json.loads(sys.argv[1])
out = sys.argv[2]
prog = snap.get("programme") or {}
lines = [
  "# Implementation Execution Ledger",
  "",
  f"_Updated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')}_",
  "",
  "## Programme",
  "",
  f"- **ID:** {prog.get('id','(none)')}",
  f"- **Title:** {prog.get('title','')}",
  f"- **Phase:** {prog.get('phase','')}",
  f"- **Status:** {prog.get('status','')}",
  "",
  "## Counts",
  "",
  "```json",
  json.dumps(snap.get("counts") or {}, indent=2),
  "```",
  "",
  "## Tasks",
  "",
  "| ID | Status | Worker | Priority | Branch | PR | CI | Blocker |",
  "|----|--------|--------|----------|--------|----|----|---------|",
]
for t in snap.get("tasks") or []:
    lines.append(
      f"| {t['id']} | {t['status']} | {t.get('worker_type','')} | {t.get('priority','')} | {t.get('branch','')} | {t.get('pull_request','')} | {t.get('ci_run','')} | {t.get('blocker','')} |"
    )
lines += ["", "## Ready queue", ""]
for t in snap.get("ready") or []:
    lines.append(f"- `{t['id']}` — {t['title']}")
lines += ["", "---", "", "_Machine authority: `state/programme.db`. This ledger is the human view._", ""]
open(out, "w").write("\n".join(lines))
print(out)
PY
