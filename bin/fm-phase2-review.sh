#!/usr/bin/env bash
# Independent review gate: require per-AC verdicts in REVIEW.md.
# Usage:
#   fm-phase2-review.sh init <task-id>
#   fm-phase2-review.sh submit <task-id> --file REVIEW.md
#   fm-phase2-review.sh check <task-id>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
REG="$FM_HOME/bin/fm-phase2-registry.sh"
CMD="${1:?}"; shift
TID="${1:?}"; shift || true
PKT="$FM_HOME/data/$TID/packet"
REV="$PKT/REVIEW.md"

case "$CMD" in
  init)
    "$REG" transition "$TID" awaiting_review --reason "review_init" || true
    mkdir -p "$PKT"
    python3 - "$PKT" <<'PY'
from pathlib import Path
import re, sys
pkt = Path(sys.argv[1])
acc = (pkt/"ACCEPTANCE.md").read_text() if (pkt/"ACCEPTANCE.md").exists() else ""
acs = re.findall(r"AC-\d+", acc)
if not acs:
    acs = ["AC-001"]
lines = ["# Independent review", "Status: IN PROGRESS", "", "| Criterion | Verdict | Notes |", "|-----------|---------|-------|"]
for a in acs:
    lines.append(f"| {a} | NOT TESTED | |")
lines.append("")
lines.append("Allowed verdicts: PASS, FAIL, NOT TESTED, PASS WITH WARNING")
(pkt/"REVIEW.md").write_text("\n".join(lines) + "\n")
print(pkt/"REVIEW.md")
PY
    ;;
  submit)
    FILE=""
    while [ $# -gt 0 ]; do case "$1" in --file) FILE="${2:?}"; shift 2 ;; *) shift ;; esac; done
    [ -n "$FILE" ] && cp "$FILE" "$REV"
    "$0" check "$TID"
    ;;
  check)
    python3 - "$REV" "$TID" "$FM_HOME" <<'PY'
import re, sys, subprocess, json
from pathlib import Path
rev_path, tid, fm = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = rev_path.read_text() if rev_path.exists() else ""
rows = re.findall(r"\|\s*(AC-\d+)\s*\|\s*([^|]+)\|", text)
if not rows:
    print("review: no AC rows found", file=sys.stderr)
    sys.exit(2)
bad = []
for ac, verdict in rows:
    v = verdict.strip().upper()
    if v not in {"PASS", "FAIL", "NOT TESTED", "PASS WITH WARNING"}:
        bad.append((ac, verdict))
    if v in {"FAIL", "NOT TESTED"}:
        bad.append((ac, v))
reg = [f"{fm}/bin/fm-phase2-registry.sh"]
if bad:
    subprocess.check_call(reg + ["transition", tid, "changes_requested", "--reason", "review_failed",
                                 "--field", f"review={rev_path}", "--field", "blocker=review AC incomplete"])
    print(json.dumps({"ok": False, "failed": bad}))
    sys.exit(1)
subprocess.check_call(reg + ["set", tid, "--field", f"review={rev_path}"])
# move toward CI
subprocess.run(reg + ["transition", tid, "awaiting_ci", "--reason", "review_passed"], check=False)
print(json.dumps({"ok": True, "criteria": len(rows)}))
PY
    "$FM_HOME/bin/fm-phase2-event.sh" review_completed --task "$TID" --dedupe "review-$TID-$(date +%s)" --payload "{\"path\":\"$REV\"}"
    ;;
  *)
    echo "unknown" >&2; exit 2 ;;
esac
