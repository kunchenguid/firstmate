#!/usr/bin/env python3
"""fm-jev-decisions.py - classify and triage open Firstmate decisions using Jev System One.

Usage:
  fm-jev-decisions.py [--task <task>] [--status-file <path>] [--all]
                      [--json] [--resolve-cmds] [--category <cat>]
                      [--min-noul <float>] [--max-workers <int>] [--limit <int>]
"""
from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

TS_BASE = os.environ.get("FM_JEV_TS_BASE", "https://api.typesafe.ai")
TS_MODEL = os.environ.get("FM_JEV_TS_MODEL", "jev-latest")
TS_TIMEOUT = float(os.environ.get("FM_JEV_TS_TIMEOUT", "5.0"))

DECISION_CRITERIA = {
    "stale_historical": (
        "Superseded by events, expired timeout, missed pending-reply, or legacy worktree "
        "from a previous phase; safe to resolve/archive without blocking ongoing work."
    ),
    "actionable_now": (
        "Directly and currently blocks active work in flight; requires immediate human or agent resolution today."
    ),
    "external_block": (
        "Blocked by external dependencies, infrastructure, networking, missing credentials, or third-party outages "
        "outside agent control."
    ),
    "policy_spend": (
        "Requires Captain authorization on product strategy, architecture direction, financial spend, or "
        "permanent data discard/retention."
    ),
}


@dataclasses.dataclass
class DecisionItem:
    task: str
    key: str
    verb: str
    note: str
    category: str = "unavailable"
    confidence: float = 0.0
    actionable_noul: float = 0.0
    probabilities: dict[str, float] = dataclasses.field(default_factory=dict)
    suggested_action: str = ""
    resolve_cmd: str = ""
    error: str | None = None


def get_api_key(fm_root: Path) -> str | None:
    # 1. Environment
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key

    # 2. Try vault injection wrapper if available
    run_py = fm_root / "bin" / "jev-typesafe-run.py"
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


def extract_decisions_from_bash(cmd: str) -> list[DecisionItem]:
    try:
        proc = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if proc.returncode != 0:
            print(f"warning: bash extraction failed: {proc.stderr.strip()}", file=sys.stderr)
            return []
        items = []
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) >= 4:
                items.append(DecisionItem(task=parts[0], key=parts[1], verb=parts[2], note="\t".join(parts[3:])))
            elif len(parts) == 3:
                # key, verb, note without task prefix
                items.append(DecisionItem(task="unknown", key=parts[0], verb=parts[1], note=parts[2]))
        return items
    except Exception as exc:
        print(f"warning: error running bash extraction: {exc}", file=sys.stderr)
        return []


def classify_decision(item: DecisionItem, api_key: str | None) -> DecisionItem:
    if not api_key:
        item.category = "unavailable"
        item.error = "TYPESAFE_API_KEY unavailable"
        return item

    clean_note = " ".join(item.note.split())[:600]
    payload = {
        "model": TS_MODEL,
        "state": {
            "task": item.task,
            "key": item.key,
            "verb": item.verb,
            "note": clean_note,
        },
        "questions": {
            "category": {
                "type": "choice",
                "instructions": "Classify this open decision or blocker into exactly one category.",
                "criteria": DECISION_CRITERIA,
            },
            "actionable_now": {
                "type": "noul",
                "instructions": "Is this decision urgently blocking active current work right now?",
            },
        },
    }

    req = urllib.request.Request(
        f"{TS_BASE}/v1/systemone",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=TS_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        answers = data.get("answers", {})

        cat_ans = answers.get("category", {})
        item.category = cat_ans.get("choice", "actionable_now")
        item.confidence = float(cat_ans.get("confidence", 0.0))
        item.probabilities = cat_ans.get("probabilities", {})

        act_ans = answers.get("actionable_now", {})
        item.actionable_noul = float(act_ans.get("noul", 0.0))

        # Assign recommendations
        if item.category == "stale_historical":
            if item.key.startswith("pending-reply-"):
                item.suggested_action = "Auto-resolve expired legacy pending-reply config reread"
                item.resolve_cmd = (
                    f"bin/fm-send.sh {item.task} --resolve-key {item.key} "
                    f"'auto-resolved: expired legacy config reread from previous phase'"
                )
            else:
                item.suggested_action = "Archive or resolve superseded historical decision"
                item.resolve_cmd = (
                    f"bin/fm-send.sh {item.task} --resolve-key {item.key} "
                    f"'auto-resolved: superseded historical decision'"
                )
        elif item.category == "external_block":
            item.suggested_action = "Investigate external host, route, or credentials dependency"
        elif item.category == "policy_spend":
            item.suggested_action = "Escalate to Captain for policy, spend, or architecture guidance"
        elif item.category == "actionable_now":
            item.suggested_action = "Active blocker: requires prompt resolution or steer"

    except Exception as exc:
        item.category = "unavailable"
        item.error = str(exc)

    return item


def format_table(items: list[DecisionItem]) -> str:
    if not items:
        return "No open decisions found."

    lines = []
    header = f"{'TASK':<16} {'KEY':<32} {'VERB':<15} {'CATEGORY':<17} {'NOUL':<6} {'CONF':<6} {'SUGGESTED ACTION'}"
    sep = "=" * len(header)
    lines.append(header)
    lines.append(sep)

    for it in items:
        task_col = it.task[:15]
        key_col = it.key[:30]
        verb_col = it.verb[:14]
        cat_col = it.category[:16]
        noul_col = f"{it.actionable_noul:.2f}" if it.category != "unavailable" else "N/A"
        conf_col = f"{it.confidence:.2f}" if it.category != "unavailable" else "N/A"
        sugg = it.suggested_action or (it.error or "")
        lines.append(f"{task_col:<16} {key_col:<32} {verb_col:<15} {cat_col:<17} {noul_col:<6} {conf_col:<6} {sugg}")

    lines.append(sep)
    # Summary
    counts: dict[str, int] = {}
    for it in items:
        counts[it.category] = counts.get(it.category, 0) + 1

    summary_parts = [f"Total: {len(items)}"]
    for cat in ["stale_historical", "actionable_now", "external_block", "policy_spend", "unavailable"]:
        if cat in counts:
            summary_parts.append(f"{cat}: {counts[cat]}")

    lines.append(" | ".join(summary_parts))
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Triage open Firstmate decisions using Jev System One")
    parser.add_argument("--task", type=str, help="Specific task ID to triage (e.g. websites, verifier)")
    parser.add_argument("--status-file", type=Path, help="Specific status file to inspect")
    parser.add_argument("--input", type=str, help="Path to TSV file or '-' for stdin")
    parser.add_argument("--all", action="store_true", help="Scan all status files in state dir")
    parser.add_argument("--state-dir", type=Path, help="State directory override")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--resolve-cmds", action="store_true", help="Emit copy-pasteable resolve commands for stale items")
    parser.add_argument("--category", type=str, help="Filter output by category (e.g. stale_historical)")
    parser.add_argument("--min-noul", type=float, default=0.0, help="Filter by minimum actionable noul score")
    parser.add_argument("--max-workers", type=int, default=8, help="Max concurrent Jev API requests")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of items triaged (0 = unlimited)")

    # Single item direct evaluation mode
    parser.add_argument("--key", type=str, help="Single decision key")
    parser.add_argument("--verb", type=str, default="needs-decision", help="Single decision verb")
    parser.add_argument("--note", type=str, help="Single decision note text")

    args = parser.parse_args()

    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = args.state_dir or (fm_root / "state")
    classify_lib = fm_root / "bin" / "fm-classify-lib.sh"

    items: list[DecisionItem] = []

    # 1. Direct single item mode
    if args.key and args.note:
        items.append(
            DecisionItem(
                task=args.task or "adhoc",
                key=args.key,
                verb=args.verb,
                note=args.note,
            )
        )
    # 2. Input from TSV or stdin
    elif args.input:
        if args.input == "-":
            content = sys.stdin.read()
        else:
            p = Path(args.input)
            content = p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""
        for line in content.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) >= 4:
                items.append(DecisionItem(task=parts[0], key=parts[1], verb=parts[2], note="\t".join(parts[3:])))
            elif len(parts) == 3:
                items.append(DecisionItem(task=args.task or "unknown", key=parts[0], verb=parts[1], note=parts[2]))
    # 3. Specific status file
    elif args.status_file:
        sf = args.status_file
        if not sf.exists():
            print(f"error: status file {sf} does not exist", file=sys.stderr)
            sys.exit(1)
        task_name = args.task or sf.stem
        cmd = f"source '{classify_lib}' && status_open_decisions '{sf}'"
        raw_items = extract_decisions_from_bash(cmd)
        for it in raw_items:
            it.task = task_name
            items.append(it)
    # 4. Specific task name
    elif args.task:
        sf = state_dir / f"{args.task}.status"
        if not sf.exists():
            print(f"error: status file {sf} does not exist", file=sys.stderr)
            sys.exit(1)
        cmd = f"source '{classify_lib}' && status_open_decisions '{sf}'"
        raw_items = extract_decisions_from_bash(cmd)
        for it in raw_items:
            it.task = args.task
            items.append(it)
    # 5. All status files across state
    elif args.all or not sys.stdin.isatty():
        if not sys.stdin.isatty():
            content = sys.stdin.read().strip()
            if content:
                for line in content.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    parts = line.split("\t")
                    if len(parts) >= 4:
                        items.append(DecisionItem(task=parts[0], key=parts[1], verb=parts[2], note="\t".join(parts[3:])))
                    elif len(parts) == 3:
                        items.append(DecisionItem(task="unknown", key=parts[0], verb=parts[1], note=parts[2]))
        if not items:
            cmd = f"source '{classify_lib}' && scan_open_decisions_incremental '{state_dir}'"
            items = extract_decisions_from_bash(cmd)
    else:
        parser.print_help()
        sys.exit(2)

    if not items:
        if args.json:
            print("[]")
        else:
            print("No open decisions found.")
        sys.exit(0)

    if args.limit > 0:
        items = items[: args.limit]

    api_key = get_api_key(fm_root)

    # Concurrently classify items
    max_workers = min(args.max_workers, len(items)) if len(items) > 0 else 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(classify_decision, item, api_key) for item in items]
        classified_items = [f.result() for f in futures]

    # Filters
    filtered_items = classified_items
    if args.category:
        filtered_items = [it for it in filtered_items if it.category == args.category]
    if args.min_noul > 0.0:
        filtered_items = [it for it in filtered_items if it.actionable_noul >= args.min_noul]

    # Output
    if args.resolve_cmds:
        resolve_lines = [it.resolve_cmd for it in filtered_items if it.resolve_cmd]
        if resolve_lines:
            print("\n".join(resolve_lines))
        else:
            print("# No actionable resolve commands generated.")
        sys.exit(0)

    if args.json:
        payload = [dataclasses.asdict(it) for it in filtered_items]
        print(json.dumps(payload, indent=2))
        sys.exit(0)

    print(format_table(filtered_items))


if __name__ == "__main__":
    main()
