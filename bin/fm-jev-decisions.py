#!/usr/bin/env python3
"""fm-jev-decisions.py - classify and triage open Firstmate decisions using Jev System One.

Usage:
  fm-jev-decisions.py [--task <task>] [--status-file <path>] [--all]
                      [--input <tsv-path> | --input -] [--state-dir <dir>]
                      [--key <key> [--verb <verb>] --note <note>]
                      [--json] [--resolve-cmds] [--category <cat>]
                      [--min-noul <float>] [--max-workers <int>] [--limit <int>]
"""
from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import json
import os
import re
import shlex
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

    # 2. The home's .env, read with the same accessor as fm-dispatch-resolve.sh
    env_lib = Path(__file__).resolve().parent / "fm-env-lib.sh"
    try:
        res = subprocess.run(
            ["bash", "-c", 'source "$1" && fmx_env_get TYPESAFE_API_KEY "$2"', "_",
             str(env_lib), str(fm_root / ".env")],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        key = res.stdout.strip() if res.returncode == 0 else ""
        if key:
            return key
    except Exception:
        pass

    # 3. Try vault injection wrapper if available
    run_py = fm_root / "bin" / "jev-typesafe-run.py"

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


class NeverSendUnreadable(Exception):
    pass


def load_never_send(config_dir: Path) -> list[str]:
    path = config_dir / "dispatch-never-send"
    if not path.exists() and not path.is_symlink():
        return []
    if not path.is_file() or not os.access(path, os.R_OK):
        raise NeverSendUnreadable(f"{path} is not a readable regular file")
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise NeverSendUnreadable(f"could not read {path}: {exc}") from exc
    values = []
    for line in lines:
        value = " ".join(line.split())
        if value and not value.startswith("#"):
            values.append(value)
    return values


def withhold(text: str, never_send: list[str]) -> str:
    text = " ".join(text.split())
    spans = []
    for value in sorted(never_send, key=len, reverse=True):
        for m in re.finditer(f"(?=({re.escape(value)}))", text, flags=re.IGNORECASE):
            spans.append((m.start(1), m.end(1)))
    merged: list[list[int]] = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    for start, end in reversed(merged):
        text = text[:start] + "[withheld]" + text[end:]
    return text


def parse_decision_lines(content: str, task: str | None) -> list[DecisionItem]:
    """Parse key<TAB>verb<TAB>note lines, prefixed by a task column when task is None."""
    items = []
    skipped = 0
    for line in content.splitlines():
        if not line.strip():
            continue
        if task is None:
            parts = line.split("\t", 3)
            if len(parts) == 4:
                items.append(DecisionItem(task=parts[0], key=parts[1], verb=parts[2], note=parts[3]))
                continue
        else:
            parts = line.split("\t", 2)
            if len(parts) == 3:
                items.append(DecisionItem(task=task, key=parts[0], verb=parts[1], note=parts[2]))
                continue
        skipped += 1
    if skipped:
        expected = "task<TAB>key<TAB>verb<TAB>note" if task is None else "key<TAB>verb<TAB>note"
        print(f"warning: skipped {skipped} malformed line(s); expected {expected}", file=sys.stderr)
    return items


def extract_decisions_from_bash(func: str, classify_lib: Path, target: Path, task: str | None) -> list[DecisionItem]:
    try:
        proc = subprocess.run(
            ["bash", "-c", f'source "$1" && {func} "$2"', "_", str(classify_lib), str(target)],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except Exception as exc:
        sys.exit(f"error: running {func}: {exc}")
    if proc.returncode != 0:
        sys.exit(f"error: {func} failed via {classify_lib}: {proc.stderr.strip()}")
    return parse_decision_lines(proc.stdout, task)


def classify_decision(
    item: DecisionItem, api_key: str | None, never_send: list[str], send_prefix: str
) -> DecisionItem:
    if not api_key:
        item.category = "unavailable"
        item.error = "TYPESAFE_API_KEY unavailable"
        return item

    payload = {
        "model": TS_MODEL,
        "state": {
            "task": withhold(item.task, never_send),
            "key": withhold(item.key, never_send),
            "verb": withhold(item.verb, never_send),
            "note": withhold(item.note, never_send)[:600],
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

        cat_ans = answers.get("category") or {}
        choice = cat_ans.get("choice")
        if choice not in DECISION_CRITERIA:
            item.category = "unavailable"
            item.error = f"Jev returned no valid category choice: {choice!r}"
            return item
        item.category = choice
        item.confidence = float(cat_ans.get("confidence", 0.0))
        item.probabilities = cat_ans.get("probabilities", {})

        act_ans = answers.get("actionable_now", {})
        item.actionable_noul = float(act_ans.get("noul", 0.0))

        # Assign recommendations
        if item.category == "stale_historical":
            if item.key.startswith("pending-reply-"):
                # A pending reply may still be owed; closing it is a judgment, not a stale sweep.
                item.suggested_action = "Confirm the pending reply is no longer owed before closing it"
            else:
                item.suggested_action = "Archive or resolve superseded historical decision"
                item.resolve_cmd = send_prefix + shlex.join(
                    ["bin/fm-send.sh", item.task, "--resolve-key", item.key,
                     "auto-resolved: superseded historical decision"]
                )
        elif item.category == "external_block":
            item.suggested_action = "Investigate external host, route, or credentials dependency"
        elif item.category == "policy_spend":
            item.suggested_action = "Escalate to Captain for policy, spend, or architecture guidance"
        elif item.category == "actionable_now":
            item.suggested_action = "Active blocker: requires prompt resolution or steer"

    except Exception as exc:
        item.category = "unavailable"
        item.suggested_action = ""
        item.resolve_cmd = ""
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
    state_dir = args.state_dir or Path(os.environ.get("FM_STATE_OVERRIDE") or fm_root / "state")
    classify_lib = fm_root / "bin" / "fm-classify-lib.sh"
    config_dir = Path(os.environ.get("FM_CONFIG_OVERRIDE") or fm_root / "config")
    send_state = args.status_file.parent if args.status_file else state_dir

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
            if not p.exists():
                print(f"error: input file {p} does not exist", file=sys.stderr)
                sys.exit(1)
            content = p.read_text(encoding="utf-8", errors="replace")
        items = parse_decision_lines(content, args.task)
    # 3. Specific status file
    elif args.status_file:
        sf = args.status_file
        if not sf.exists():
            print(f"error: status file {sf} does not exist", file=sys.stderr)
            sys.exit(1)
        items = extract_decisions_from_bash("status_open_decisions", classify_lib, sf, args.task or sf.stem)
    # 4. Specific task name
    elif args.task:
        sf = state_dir / f"{args.task}.status"
        if not sf.exists():
            print(f"error: status file {sf} does not exist", file=sys.stderr)
            sys.exit(1)
        items = extract_decisions_from_bash("status_open_decisions", classify_lib, sf, args.task)
    # 5. All status files across state
    elif args.all:
        items = extract_decisions_from_bash("scan_open_decisions", classify_lib, state_dir, None)
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
    withheld_reason = None
    try:
        never_send = load_never_send(config_dir)
    except NeverSendUnreadable as exc:
        withheld_reason = f"{exc}; nothing sent"
        never_send = []
    send_prefix = (
        f"FM_HOME={shlex.quote(str(fm_root.resolve()))} "
        f"FM_STATE_OVERRIDE={shlex.quote(str(send_state.resolve()))} "
    )

    # Concurrently classify items
    if withheld_reason:
        print(f"warning: {withheld_reason}", file=sys.stderr)
        for item in items:
            item.error = withheld_reason
        classified_items = items
    else:
        max_workers = min(args.max_workers, len(items))
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = [executor.submit(classify_decision, item, api_key, never_send, send_prefix) for item in items]
            classified_items = [f.result() for f in futures]
        # fm-send resolves its target through state/<task>.meta; a torn-down task has none.
        for item in classified_items:
            if item.resolve_cmd and not (send_state / f"{item.task}.meta").is_file():
                item.resolve_cmd = ""
                item.suggested_action += " (task metadata gone; close it by hand)"

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
