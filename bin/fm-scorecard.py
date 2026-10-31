#!/usr/bin/env python3
"""Arithmetic for fm-scorecard.sh, the advisory outcome scorecard.

The shell wrapper owns the command line and home resolution; it passes each
ledger as --ledger <label> <path> and each unread remote home as
--remote <label> <host>. docs/fleet-ledger.md owns the record contract and the
column definitions. This reads files only and writes nothing but stdout.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import sys
import time
from dataclasses import dataclass, field

SMALL_SAMPLE = 5
LIMITS = [
    "validation rounds are not in the ledger, so that column is always n/a",
    "the ledger records no dispatch profile name, so a profile is harness/model",
    "the share of captain-requested changes is not in the ledger",
    "tasks dispatched before a home turned its ledger on have no dispatch record and are left out",
]


@dataclass
class Task:
    home: str
    task: str
    dispatched: int | None = None
    kind: str | None = None
    harness: str | None = None
    model: str | None = None
    pr_ready: int | None = None
    first_done: int | None = None
    blocked: bool = False
    relaunches: int = 0
    merged: bool = False
    cleaned_up: bool = False

    def ready_seconds(self) -> int | None:
        ready = self.pr_ready if self.pr_ready is not None else self.first_done
        if self.dispatched is None or ready is None or ready < self.dispatched:
            return None
        return ready - self.dispatched

    def outcome(self) -> str:
        if self.kind == "scout":
            landed = self.cleaned_up and self.first_done is not None
        else:
            landed = self.merged
        if landed:
            return "landed"
        return "abandoned" if self.cleaned_up else "open"


@dataclass
class Group:
    profile: str
    kind: str
    tasks: list[Task] = field(default_factory=list)


def read_ledger(label: str, path: str) -> tuple[dict, list[Task]]:
    info = {"label": label, "ledger": path, "status": "", "records": 0, "skipped": 0}
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        info["status"] = "no ledger"
        return info, []
    except OSError as exc:
        info["status"] = f"unreadable: {exc.strerror}"
        return info, []
    tasks: list[Task] = []
    current: dict[str, Task] = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
            ts = int(rec["ts"])
            name = str(rec["task"])
            event = rec["event"]
        except (ValueError, KeyError, TypeError):
            info["skipped"] += 1
            continue
        info["records"] += 1
        t = current.get(name)
        if event == "task.dispatched":
            # A reused task id starts a new task; a status line that raced
            # ahead of its own dispatch record belongs to this dispatch.
            if t is None or t.dispatched is not None:
                t = Task(label, name)
                tasks.append(t)
                current[name] = t
            t.dispatched = ts
            t.kind = rec.get("kind")
            t.harness = rec.get("harness")
            t.model = rec.get("model")
            continue
        if t is None:
            t = Task(label, name)
            tasks.append(t)
            current[name] = t
        if event == "task.status":
            state = rec.get("state")
            if state == "blocked":
                t.blocked = True
            elif state == "done" and t.first_done is None:
                t.first_done = ts
        elif event == "task.relaunched":
            t.relaunches += 1
        elif event == "task.pr_ready" and t.pr_ready is None:
            t.pr_ready = ts
        elif event == "task.merged":
            t.merged = True
        elif event == "task.cleaned_up":
            t.cleaned_up = True
    if info["records"] == 0:
        info["status"] = "empty"
    else:
        info["status"] = f"{info['records']} records"
    if info["skipped"]:
        info["status"] += f", {info['skipped']} unreadable lines skipped"
    return info, tasks


def parse_since(value: str) -> int:
    if value.isdigit():
        return int(value)
    try:
        return int(time.mktime(time.strptime(value, "%Y-%m-%d")))
    except ValueError:
        print(f"fm-scorecard: --since wants YYYY-MM-DD or a Unix time, got {value!r}", file=sys.stderr)
        sys.exit(2)


def p90(values: list[int]) -> int:
    ordered = sorted(values)
    return ordered[math.ceil(0.9 * len(ordered)) - 1]


def duration(seconds: float | None) -> str:
    if seconds is None:
        return "-"
    minutes = int(seconds) // 60
    if minutes < 1:
        return "<1m"
    if minutes < 60:
        return f"{minutes}m"
    if minutes < 48 * 60:
        return f"{minutes // 60}h{minutes % 60:02d}m"
    return f"{minutes // 1440}d{minutes % 1440 // 60:02d}h"


def summarize(group: Group) -> dict:
    ready = [s for s in (t.ready_seconds() for t in group.tasks) if s is not None]
    outcomes = [t.outcome() for t in group.tasks]
    harness, _, model = group.profile.partition("/")
    return {
        "profile": group.profile,
        "harness": harness,
        "model": model,
        "kind": group.kind,
        "tasks": len(group.tasks),
        "small_sample": len(group.tasks) < SMALL_SAMPLE,
        "ready_seconds": {
            "samples": len(ready),
            "median": statistics.median(ready) if ready else None,
            "p90": p90(ready) if ready else None,
        },
        "validation_rounds": None,
        "blocked": sum(1 for t in group.tasks if t.blocked),
        "relaunched": sum(1 for t in group.tasks if t.relaunches),
        "landed": outcomes.count("landed"),
        "abandoned": outcomes.count("abandoned"),
        "open": outcomes.count("open"),
    }


def render_text(report: dict) -> str:
    out = ["Outcome scorecard - advisory only; it never changes routing."]
    out.append("Homes:")
    width = max(len(h["label"]) for h in report["homes"])
    for h in report["homes"]:
        out.append(f"  {h['label']:<{width}}  {h['status']}")
    if report["since"] is not None:
        out.append("Since: " + time.strftime("%Y-%m-%d %H:%M", time.localtime(report["since"])))
    out.append("")
    if not report["groups"]:
        out.append("No dispatched tasks in range.")
    else:
        head = ["profile", "kind", "tasks", "ready-med", "ready-p90", "val-rounds",
                "blocked", "relaunched", "landed", "abandoned", "open"]
        rows = [head]
        for g in report["groups"]:
            rows.append([
                g["profile"], g["kind"], f"{g['tasks']}{'*' if g['small_sample'] else ''}",
                duration(g["ready_seconds"]["median"]), duration(g["ready_seconds"]["p90"]),
                "n/a", str(g["blocked"]), str(g["relaunched"]),
                str(g["landed"]), str(g["abandoned"]), str(g["open"]),
            ])
        widths = [max(len(r[i]) for r in rows) for i in range(len(head))]
        for r in rows:
            out.append("  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip())
        out.append("")
        if any(g["small_sample"] for g in report["groups"]):
            out.append(f"* fewer than {SMALL_SAMPLE} tasks: an anecdote, not a trend.")
        out.append("ready: dispatch to first PR-ready record, or to first done: status when no PR was recorded.")
        out.append("blocked, relaunched: tasks that did so at least once.")
        out.append("landed: merged (ship) or cleaned up after done: (scout); abandoned: cleaned up otherwise.")
    if report["undispatched_tasks"]:
        out.append(f"{report['undispatched_tasks']} task(s) with no dispatch record were left out.")
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(prog="fm-scorecard.py")
    parser.add_argument("--ledger", nargs=2, action="append", default=[], metavar=("LABEL", "PATH"))
    parser.add_argument("--remote", nargs=2, action="append", default=[], metavar=("LABEL", "HOST"))
    parser.add_argument("--since")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    since = parse_since(args.since) if args.since else None

    homes: list[dict] = []
    tasks: list[Task] = []
    for label, path in args.ledger:
        info, found = read_ledger(label, os.path.abspath(path))
        homes.append(info)
        tasks.extend(found)
    for label, host in args.remote:
        homes.append({"label": label, "ledger": None, "status": f"remote on {host}, not read",
                      "records": 0, "skipped": 0})

    groups: dict[tuple[str, str], Group] = {}
    undispatched = 0
    for t in tasks:
        if t.dispatched is None:
            undispatched += 1
            continue
        if t.kind == "secondmate" or (since is not None and t.dispatched < since):
            continue
        profile = f"{t.harness or '?'}/{t.model or 'default'}"
        kind = t.kind or "?"
        groups.setdefault((profile, kind), Group(profile, kind)).tasks.append(t)

    report = {
        "advisory": True,
        "since": since,
        "homes": homes,
        "groups": [summarize(groups[k]) for k in sorted(groups)],
        "undispatched_tasks": undispatched,
        "limits": LIMITS,
    }
    if args.json:
        json.dump(report, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
