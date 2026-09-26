#!/usr/bin/env python3
"""fm-route-domain.py - route incoming task or message to a secondmate domain using Jev.

Usage:
  fm-route-domain.py [--task <text>] [--brief <file>] [--registry <file>] [--json]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

TS_BASE = "https://api.typesafe.ai"
TS_MODEL = "jev-latest"
TS_TIMEOUT = 5.0

LOCAL_RE = re.compile(
    r"^- ([A-Za-z0-9._-]+) - (.+?) \((?:host: [^;]+; root: [^;]+; )?home: [^;]+; scope: (.*?); projects: [^;]*; added \d{4}-\d{2}-\d{2}\)",
    re.MULTILINE,
)


def get_api_key() -> str | None:
    # 1. Environment
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key

    # 2. Try vault injection wrapper if available
    run_py = Path(__file__).resolve().parent / "jev-typesafe-run.py"
    if not run_py.exists():
        run_py = Path("/opt/ra/firstmate/bin/jev-typesafe-run.py")
    if run_py.exists():
        try:
            res = subprocess.run(
                ["sudo", "-n", str(run_py), "--", "env"],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
            for line in res.stdout.splitlines():
                if line.startswith("TYPESAFE_API_KEY="):
                    k = line.split("=", 1)[1].strip()
                    if k:
                        return k
        except Exception:
            pass

    return None


def parse_registry(reg_path: Path) -> dict[str, str]:
    if not reg_path.exists():
        return {}
    content = reg_path.read_text(encoding="utf-8", errors="replace")
    criteria = {}
    for sm_id, summary, scope in LOCAL_RE.findall(content):
        clean_scope = " ".join(scope.split())[:140]
        criteria[sm_id] = clean_scope

    criteria["new_domain"] = (
        "No existing second mate covers this domain; requires creating a new dedicated second mate."
    )
    criteria["captain_direct"] = (
        "A personal note, direct conversation, question, or directive specifically for Jon / the Captain."
    )
    return criteria


def emit_result(
    action: str,
    route: str,
    confidence: float | None = None,
    noul: float | None = None,
    probabilities: dict[str, float] | None = None,
    reason: str | None = None,
    task_text: str = "",
    as_json: bool = False,
    exit_code: int = 0,
) -> None:
    if as_json:
        payload = {
            "action": action,
            "route": route,
            "confidence": confidence,
            "needs_new_noul": noul,
            "probabilities": probabilities or {},
            "reason": reason,
        }
        print(json.dumps(payload, indent=2))
        sys.exit(exit_code)

    print(f"action={action}")
    print(f"route={route}")
    if confidence is not None:
        print(f"confidence={confidence:.3f}")
    if noul is not None:
        print(f"needs_new_noul={noul:.3f}")
    if reason:
        print(f"reason={reason}")
    if action == "dispatch" and route and route not in ("new_domain", "captain_direct"):
        escaped_task = task_text.replace('"', '\\"').replace("\n", " ")[:200]
        print(f'dispatch_cmd=FM_HOME=/opt/ra/firstmate bin/fm-send.sh {route} "[fm-from-firstmate] {escaped_task}"')
    sys.exit(exit_code)


def main() -> None:
    parser = argparse.ArgumentParser(description="Route task to secondmate via Jev System One")
    parser.add_argument("--task", type=str, help="Task text to classify")
    parser.add_argument("--brief", type=Path, help="Path to brief file")
    parser.add_argument("--registry", type=Path, help="Path to secondmates.md")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    reg_path = args.registry or (fm_root / "data" / "secondmates.md")

    task_text = ""
    if args.task:
        task_text = args.task
    elif args.brief and args.brief.exists():
        task_text = args.brief.read_text(encoding="utf-8", errors="replace")
    elif not sys.stdin.isatty():
        task_text = sys.stdin.read()

    task_text = task_text.strip()
    if not task_text:
        emit_result("unavailable", "captain_direct", reason="empty task input", as_json=args.json)

    key = get_api_key()
    if not key:
        emit_result(
            "unavailable",
            "captain_direct",
            reason="TYPESAFE_API_KEY unavailable",
            task_text=task_text,
            as_json=args.json,
        )

    criteria = parse_registry(reg_path)
    if not criteria:
        emit_result(
            "unavailable",
            "captain_direct",
            reason="secondmate registry empty or not found",
            task_text=task_text,
            as_json=args.json,
        )

    clean_task = " ".join(task_text.split())[:500]
    payload = {
        "model": TS_MODEL,
        "state": {"task": clean_task},
        "questions": {
            "route": {
                "type": "choice",
                "instructions": "Which second mate domain should handle this incoming task or message?",
                "criteria": criteria,
            },
            "needs_new_secondmate": {
                "type": "noul",
                "instructions": "Is this task clearly outside all existing second mate domains, requiring the creation of a new dedicated second mate?",
            },
        },
    }

    req = urllib.request.Request(
        f"{TS_BASE}/v1/systemone",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=TS_TIMEOUT) as resp:
            body = resp.read().decode("utf-8")
            data = json.loads(body)
    except Exception as exc:
        emit_result(
            "unavailable",
            "captain_direct",
            reason=f"Jev API call failed: {exc}",
            task_text=task_text,
            as_json=args.json,
        )

    answers = data.get("answers", {})
    route_ans = answers.get("route", {})
    choice = route_ans.get("choice", "captain_direct")
    confidence = float(route_ans.get("confidence", 0.0))
    probs = route_ans.get("probabilities", {})

    noul_ans = answers.get("needs_new_secondmate", {})
    noul_val = float(noul_ans.get("noul", 0.0))

    if choice == "captain_direct":
        action = "handle_direct"
    elif choice == "new_domain" or noul_val >= 0.7:
        action = "create_secondmate"
    else:
        action = "dispatch"

    emit_result(
        action=action,
        route=choice,
        confidence=confidence,
        noul=noul_val,
        probabilities=probs,
        task_text=task_text,
        as_json=args.json,
    )


if __name__ == "__main__":
    main()
