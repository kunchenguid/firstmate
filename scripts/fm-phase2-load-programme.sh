#!/usr/bin/env bash
# Load a programme JSON into the Phase 2 registry + packets.
# Usage: fm-phase2-load-programme.sh <programme-id>
set -euo pipefail
FM_HOME="${FM_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
export FM_HOME
ID="${1:?programme id}"
CFG="$FM_HOME/phase2/config/programmes/${ID}.json"
[ -f "$CFG" ] || { echo "missing $CFG" >&2; exit 1; }

python3 - "$FM_HOME" "$CFG" <<'PY'
import json, subprocess, sys
from pathlib import Path

fm = Path(sys.argv[1])
cfg = json.loads(Path(sys.argv[2]).read_text())
reg = [str(fm / "bin" / "fm-phase2-registry.sh")]
packet = [str(fm / "bin" / "fm-phase2-packet.sh")]

def run(args, check=True):
    return subprocess.run(reg + args, check=check, capture_output=True, text=True)

run(["init"])
pid = cfg["id"]
title = cfg.get("title") or pid
phase = cfg.get("phase") or "overnight"
r = run(["create-programme", pid, title, "--phase", phase], check=False)
if r.returncode != 0 and "UNIQUE" not in (r.stderr + r.stdout):
    # already exists is fine
    pass
run(["set-phase", pid, phase], check=False)

for t in cfg.get("tasks") or []:
    tid = t["id"]
    subprocess.run(packet + [tid, "--title", t.get("title") or tid, "--objective", t.get("objective") or t.get("title") or tid], check=False)
    pkt = fm / "data" / tid / "packet"
    if t.get("acceptance"):
        lines = ["# Acceptance criteria", ""]
        for i, ac in enumerate(t["acceptance"], 1):
            lines.append(f"- [ ] AC-{i:03d}: {ac}")
        (pkt / "ACCEPTANCE.md").write_text("\n".join(lines) + "\n")
    if t.get("ownership"):
        owns = "\n".join(f"- `{g}`" for g in t["ownership"])
        (pkt / "FILE-OWNERSHIP.md").write_text(f"# File ownership\n\n## Allowed\n{owns}\n\n## Prohibited\n- .env\n- secrets\n- force-push\n")
    if t.get("context"):
        (pkt / "CONTEXT.md").write_text("# Context\n\n" + t["context"].strip() + "\n")
    args = [
        "add-task", tid, pid, t.get("title") or tid,
        "--worker-type", t.get("worker_type") or "backend_engineer",
        "--priority", str(t.get("priority") or 100),
        "--packet-dir", str(pkt),
        "--risk", t.get("risk") or "normal",
    ]
    for dep in t.get("deps") or []:
        args += ["--dep", dep]
    for own in t.get("ownership") or []:
        args += ["--own", own]
    r = run(args, check=False)
    # promote first wave with no deps to ready
    if not t.get("deps"):
        run(["transition", tid, "ready", "--reason", "programme_load"], check=False)
    print(f"loaded {tid}")
print("programme", pid, "ready")
PY
