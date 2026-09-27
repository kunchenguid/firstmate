#!/usr/bin/env python3
"""fm-jev-pending-reply-reconciler.py - Stale Bookkeeping Pending-Reply Auto-Reconciler.

Inspects blocked pending-reply lines across seat status logs, distinguishing
expired automated infrastructure/config pings from genuine actionable Captain
work orders, and resolving superseded bookkeeping blocks.

Usage:
  fm-jev-pending-reply-reconciler.py [--seat <name>] [--all] [--reconcile] [--json]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TS_BASE = "https://api.typesafe.ai"
TS_MODEL = "jev-latest"
TS_TIMEOUT = 4.0

BLOCKED_RE = re.compile(
    r"^blocked\s+\[key=(pending-reply-[a-zA-Z0-9]+)\]:\s+pending-reply-missed:\s+task=([a-zA-Z0-9._-]+)\s+pending-reply-id=([a-zA-Z0-9]+)\s+request=(.+)$"
)

RESOLVED_RE = re.compile(
    r"^resolved\s+\[key=(pending-reply-[a-zA-Z0-9]+)\]"
)

# Tier 1 Bookkeeping Patterns
ROUTINE_BOOKKEEPING_RES = [
    re.compile(r"CONFIG_REREAD:", re.IGNORECASE),
    re.compile(r"please re-read your AGENTS\.md", re.IGNORECASE),
    re.compile(r"auto-resolved: expired legacy config reread", re.IGNORECASE),
    re.compile(r"Doorbell re-ring after", re.IGNORECASE),
    re.compile(r"firstmate was updated to", re.IGNORECASE),
]


def get_api_key() -> str | None:
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key
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


def log_telemetry(action: str, tier: str, code: str, seat: str, corr_id: str, reason: str) -> None:
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))
    telem_file = state_dir / ".jev-pending-reply-telemetry"
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        clean_reason = " ".join(reason.split())[:120]
        line = f"{ts}\t{action}\t{tier}\t{code}\t{seat}\t{corr_id}\t{clean_reason}\n"
        with open(telem_file, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def classify_request_tier1(request_text: str) -> tuple[bool, str, str]:
    for pattern in ROUTINE_BOOKKEEPING_RES:
        if pattern.search(request_text):
            return True, "routine_bookkeeping", "Matches routine config/AGENTS.md reread notification"
    return False, "unmatched", "Does not match static routine bookkeeping patterns"


def classify_request_tier3(request_text: str, key: str) -> tuple[str, str, str]:
    clean_sample = " ".join(request_text.split())[:800]
    payload = {
        "model": TS_MODEL,
        "state": {"request": clean_sample},
        "questions": {
            "is_routine_bookkeeping": {
                "type": "choice",
                "instructions": "Classify this pending reply request message:",
                "criteria": {
                    "routine_bookkeeping": "Automated config reload, AGENTS.md re-read ping, heartbeat ping, or doorbell bounce with no pending human question.",
                    "actionable_work_order": "A substantive task, decision request, design instruction, or specific directive from the Captain/user.",
                },
            },
            "safety_noul": {
                "type": "noul",
                "instructions": "Is it completely safe to auto-resolve and dismiss this unacknowledged message without losing any work order or direction?",
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
            data = json.loads(resp.read().decode("utf-8"))
        answers = data.get("answers", {})
        choice = answers.get("is_routine_bookkeeping", {}).get("choice", "actionable_work_order")
        noul = float(answers.get("safety_noul", {}).get("noul", 0.0))

        if choice == "routine_bookkeeping" or noul >= 0.7:
            return "reconcile", "semantic_routine_bookkeeping", f"Jev identified routine bookkeeping ping (noul={noul:.2f})"
        else:
            return "preserve", "actionable_work_order", f"Jev identified actionable instruction (noul={noul:.2f})"
    except Exception as exc:
        return "preserve", "jev_fail_open", f"Jev API error ({exc}); preserving block safely"


def scan_status_file(status_path: Path) -> list[dict]:
    if not status_path.exists():
        return []

    lines = status_path.read_text(encoding="utf-8", errors="replace").splitlines()
    resolved_keys = set()
    open_blocks = []

    for line in lines:
        m_res = RESOLVED_RE.match(line)
        if m_res:
            resolved_keys.add(m_res.group(1))

    for line in lines:
        m_blk = BLOCKED_RE.match(line)
        if m_blk:
            key, seat, corr_id, request_text = m_blk.groups()
            if key not in resolved_keys:
                open_blocks.append({
                    "key": key,
                    "seat": seat,
                    "corr_id": corr_id,
                    "request": request_text,
                    "line": line,
                    "file": str(status_path),
                })

    return open_blocks


def main() -> None:
    parser = argparse.ArgumentParser(description="Stale Bookkeeping Pending-Reply Auto-Reconciler")
    parser.add_argument("--seat", type=str, help="Specific seat status log to inspect")
    parser.add_argument("--all", action="store_true", help="Inspect all status files in state/")
    parser.add_argument("--reconcile", action="store_true", help="Write resolution lines to unblock seats")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))

    status_files = []
    if args.seat:
        sf = state_dir / f"{args.seat}.status"
        if sf.exists():
            status_files.append(sf)
    elif args.all:
        status_files = sorted(state_dir.glob("*.status"))
    else:
        # Default to checking active status files
        status_files = sorted(state_dir.glob("*.status"))

    all_open_blocks = []
    for sf in status_files:
        all_open_blocks.extend(scan_status_file(sf))

    key = get_api_key()
    reconciled_count = 0
    preserved_count = 0
    results = []

    for block in all_open_blocks:
        seat = block["seat"]
        corr_id = block["corr_id"]
        req_text = block["request"]
        sf_path = Path(block["file"])

        # Tier 1 Static Check
        is_routine, t1_code, t1_reason = classify_request_tier1(req_text)
        action = "reconcile" if is_routine else "preserve"
        tier = "tier1"
        code = t1_code
        reason = t1_reason

        # Tier 3 Semantic Check if Tier 1 did not match
        if not is_routine and key:
            t3_action, t3_code, t3_reason = classify_request_tier3(req_text, key)
            action = t3_action
            tier = "tier3"
            code = t3_code
            reason = t3_reason

        block_res = {
            "seat": seat,
            "key": block["key"],
            "corr_id": corr_id,
            "action": action,
            "tier": tier,
            "code": code,
            "reason": reason,
            "request_preview": req_text[:80],
        }

        if action == "reconcile":
            reconciled_count += 1
            log_telemetry("reconcile", tier, code, seat, corr_id, reason)
            if args.reconcile:
                resolution_line = f"resolved [key={block['key']}]: pending-reply-resolved: task={seat} pending-reply-id={corr_id} via=jev-auto-reconcile {code}\n"
                with open(sf_path, "a", encoding="utf-8") as f:
                    f.write(resolution_line)
                block_res["applied"] = True
        else:
            preserved_count += 1
            log_telemetry("preserve", tier, code, seat, corr_id, reason)

        results.append(block_res)

    if args.json:
        print(json.dumps({
            "total_open_blocks": len(all_open_blocks),
            "reconciled": reconciled_count,
            "preserved": preserved_count,
            "applied": args.reconcile,
            "items": results,
        }, indent=2))
        sys.exit(0)

    print(f"=== Jev Pending-Reply Reconciler ===")
    print(f"Total open blocked keys inspected: {len(all_open_blocks)}")
    print(f"Superseded bookkeeping identified: {reconciled_count}")
    print(f"Actionable instructions preserved:  {preserved_count}")
    print(f"Reconcile applied to status logs:  {'YES' if args.reconcile else 'NO (dry run)'}")
    print(f"====================================")
    for r in results:
        status_tag = "[RECONCILE]" if r["action"] == "reconcile" else "[PRESERVE]"
        print(f"  {status_tag} {r['seat']} ({r['corr_id']}) [{r['tier']}:{r['code']}] {r['request_preview']}")


if __name__ == "__main__":
    main()
