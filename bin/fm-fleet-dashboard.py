#!/usr/bin/env python3
"""Render the Firstmate fleet dashboard Markdown, pointer, and Lavish HTML."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


def esc(value: Any) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def trim(value: Any, limit: int = 140) -> str:
    text = re.sub(r"\s+", " ", "" if value is None else str(value)).strip()
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "..."


def load_snapshot(path: str) -> dict[str, Any]:
    if path == "-":
        return json.load(sys.stdin)
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def first(value: Any, default: str = "-") -> str:
    if value is None or value == "":
        return default
    return str(value)


def date_days_since(value: Any, generated: str) -> str:
    if not value:
        return "unknown"
    raw = str(value)
    try:
        start = dt.date.fromisoformat(raw[:10])
    except ValueError:
        return "unknown"
    try:
        end = dt.datetime.fromisoformat(generated.replace("Z", "+00:00")).date()
    except ValueError:
        end = dt.date.today()
    days = (end - start).days
    if days < 0:
        return "future"
    if days == 0:
        return "today"
    if days == 1:
        return "1 day"
    return f"{days} days"


def badge_class(value: Any) -> str:
    text = str(value or "").lower()
    if text in {"done", "landed", "merged", "complete", "checks-passed", "passed", "no_active_work"}:
        return "g"
    if text in {"working", "active_child_work", "running", "queued"}:
        return "b"
    if text in {"parked", "paused", "externally_held", "captain_decision"}:
        return "a"
    if text in {"blocked", "failed", "unknown"}:
        return "r"
    if "avoidable" in text:
        return "r"
    if "dependency" in text:
        return "p"
    return "d"


def pill(value: Any) -> str:
    label = first(value)
    return f'<span class="pill {badge_class(label)}">{esc(label)}</span>'


def is_web_url(target: str) -> bool:
    """PR urls come from worker-reported text, so only http(s) may become a link."""
    return target.lower().startswith(("http://", "https://"))


def link(url: Any, label: str | None = None) -> str:
    if not url:
        return "-"
    target = str(url)
    text = label or target
    if not is_web_url(target):
        return esc(text)
    return f'<a href="{esc(target)}">{esc(text)}</a>'


def md_link(url: Any, label: str | None = None) -> str:
    if not url:
        return "-"
    target = str(url)
    text = label or target
    if not is_web_url(target):
        return text
    return f"[{text}]({target})"


def task_state(task: dict[str, Any]) -> str:
    return first(((task.get("current_state") or {}).get("state")), "unknown")


def backlog_by_id(records: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {str(r.get("id")): r for r in records if r.get("id")}


def collect_decisions(snapshot: dict[str, Any]) -> list[dict[str, str]]:
    decisions: list[dict[str, str]] = []
    for task in snapshot.get("tasks", []):
        for item in ((task.get("hints") or {}).get("open_decisions") or []):
            decisions.append(
                {
                    "where": str(task.get("id") or "-"),
                    "source": "worker status",
                    "kind": str(item.get("verb") or "decision"),
                    "summary": trim(item.get("summary") or item.get("reason") or item.get("key") or "decision needed", 220),
                }
            )
    for record in ((snapshot.get("backlog") or {}).get("records") or []):
        if record.get("state") not in {"queued", "in_flight"}:
            continue
        if record.get("kind") == "captain" or record.get("hold_kind") == "captain" or record.get("hold_reason"):
            decisions.append(
                {
                    "where": str(record.get("id") or "-"),
                    "source": "backlog hold",
                    "kind": str(record.get("hold_kind") or record.get("kind") or "captain"),
                    "summary": trim(record.get("hold_reason") or record.get("title") or record.get("raw") or "captain decision", 220),
                }
            )
    for mate in ((snapshot.get("secondmate_current") or {}).get("records") or []):
        for item in mate.get("decisions_open") or []:
            decisions.append(
                {
                    "where": f"{mate.get('id')}/{item.get('id') or '-'}",
                    "source": "secondmate",
                    "kind": str(item.get("verb") or "decision"),
                    "summary": trim(item.get("summary") or item.get("reason") or item.get("key") or "decision needed", 220),
                }
            )
    return decisions


def collect_underway(snapshot: dict[str, Any], records_by_id: dict[str, dict[str, Any]]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for task in snapshot.get("tasks", []):
        state = task_state(task)
        if state not in {"working", "parked", "blocked", "paused", "unknown"}:
            continue
        record = records_by_id.get(str(task.get("id")))
        rows.append(
            {
                "id": str(task.get("id") or "-"),
                "kind": str(task.get("kind") or "-"),
                "state": state,
                "project": first((record or {}).get("repo") or task.get("project")),
                "detail": trim(((task.get("current_state") or {}).get("detail")) or ((task.get("hints") or {}).get("last_event_text")) or "-", 180),
            }
        )
    for mate in ((snapshot.get("secondmate_current") or {}).get("records") or []):
        state = first(((mate.get("current") or {}).get("state")), "unknown")
        if state == "no_active_work":
            continue
        rows.append(
            {
                "id": str(mate.get("id") or "-"),
                "kind": "secondmate",
                "state": state,
                "project": first(mate.get("home")),
                "detail": trim(((mate.get("current") or {}).get("reason")) or f"{(mate.get('counts') or {}).get('active_children', 0)} active child work item(s)", 180),
            }
        )
    return rows


def collect_pr_rows(snapshot: dict[str, Any], records_by_id: dict[str, dict[str, Any]]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for record in (snapshot.get("backlog") or {}).get("records") or []:
        url = record.get("pr_url")
        if not url:
            continue
        seen.add(str(url))
        completion = record.get("completion") or {}
        actual = f"{completion.get('verb')} {completion.get('date')}".strip() if completion.get("verb") else first(record.get("state"))
        rows.append(
            {
                "pr": str(url),
                "id": str(record.get("id") or "-"),
                "decided": trim(record.get("hold_reason") or record.get("blocked_reason") or record.get("title") or "recorded PR", 140),
                "actual": actual,
                "next": trim(record.get("blocked_reason") or record.get("body_excerpt") or "-", 180),
            }
        )
    for task in snapshot.get("tasks", []):
        url = (task.get("pr") or {}).get("url")
        if not url or str(url) in seen:
            continue
        record = records_by_id.get(str(task.get("id")))
        rows.append(
            {
                "pr": str(url),
                "id": str(task.get("id") or "-"),
                "decided": trim((record or {}).get("title") or "worker-reported PR", 140),
                "actual": task_state(task),
                "next": trim(((task.get("current_state") or {}).get("detail")) or "-", 180),
            }
        )
    return rows


def mq_class(record: dict[str, Any]) -> str:
    text = " ".join(
        str(record.get(key) or "")
        for key in ("blocked_by", "blocked_reason", "hold_reason", "title", "body_excerpt")
    ).lower()
    if not text:
        return "-"
    dependency_terms = ("depend", "blocked-by", "stack", "parent", "base branch", "mq prerequisite")
    queue_terms = ("mq", "merge queue", "queue", "serial", "serialization")
    if any(term in text for term in dependency_terms):
        return "dependency-forced"
    if any(term in text for term in queue_terms):
        return "avoidable"
    if record.get("blocked_by"):
        return "dependency-forced"
    return "-"


def collect_mq_rows(records: list[dict[str, Any]]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for record in records:
        if record.get("state") not in {"queued", "in_flight"}:
            continue
        cls = mq_class(record)
        if cls == "-":
            continue
        rows.append(
            {
                "id": str(record.get("id") or "-"),
                "class": cls,
                "blocked_by": first(record.get("blocked_by")),
                "reason": trim(record.get("blocked_reason") or record.get("hold_reason") or record.get("title") or "-", 180),
            }
        )
    return rows


def collect_rot_rows(records: list[dict[str, Any]], generated: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for record in records:
        if record.get("state") not in {"queued", "in_flight"}:
            continue
        rows.append(
            {
                "id": str(record.get("id") or "-"),
                "state": first(record.get("state")),
                "age": date_days_since(record.get("since"), generated),
                "title": trim(record.get("title") or record.get("raw") or "-", 140),
                "blocker": trim(record.get("blocked_reason") or record.get("hold_reason") or record.get("blocked_by") or "-", 140),
            }
        )
    return rows


def collect_landed(snapshot: dict[str, Any]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for record in (snapshot.get("backlog") or {}).get("records") or []:
        if record.get("state") != "done" or not record.get("structured", False):
            continue
        completion = record.get("completion") or {}
        rows.append(
            {
                "id": str(record.get("id") or "-"),
                "home": "main",
                "title": trim(record.get("title") or "-", 140),
                "artifact": first(record.get("pr_url") or record.get("report_path") or record.get("local_note")),
                "date": first(completion.get("date")),
            }
        )
    for record in (snapshot.get("secondmate_landed") or {}).get("records") or []:
        completion = record.get("completion") or {}
        rows.append(
            {
                "id": str(record.get("id") or "-"),
                "home": str(record.get("home_id") or record.get("home") or "secondmate"),
                "title": trim(record.get("title") or "-", 140),
                "artifact": first(record.get("pr_url") or record.get("report_path") or record.get("local_note")),
                "date": first(completion.get("date")),
            }
        )
    return rows[:20]


def table(headers: list[str], rows: list[list[str]], empty: str) -> str:
    if not rows:
        return f'<p class="muted">{esc(empty)}</p>'
    head = "".join(f"<th>{esc(h)}</th>" for h in headers)
    body = "\n".join("<tr>" + "".join(f"<td>{cell}</td>" for cell in row) + "</tr>" for row in rows)
    return f"<table><tr>{head}</tr>{body}</table>"


def md_table(headers: list[str], rows: list[list[str]], empty: str) -> str:
    if not rows:
        return empty
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        clean = [re.sub(r"<[^>]+>", "", cell).replace("|", "\\|") for cell in row]
        lines.append("| " + " | ".join(clean) + " |")
    return "\n".join(lines)


def render_markdown(data: dict[str, Any]) -> str:
    lines = [
        f"# Fleet Dashboard - {data['generated']}",
        "",
        f"Home: `{data['home']}`.",
        "Lavish is the primary read surface; ask-tool remains the decision input.",
        "",
        "## Summary",
        "",
        f"- Active workers: {data['counts']['active']}.",
        f"- Pending captain decisions: {data['counts']['decisions']}.",
        f"- PR rows: {data['counts']['prs']}.",
        f"- MQ serialization rows: {data['counts']['mq']}.",
        "",
        "## Pending Captain Decisions",
        "",
        md_table(["Where", "Source", "Kind", "Summary"], data["md"]["decisions"], "No pending captain decisions found."),
        "",
        "## Underway",
        "",
        md_table(["ID", "Kind", "State", "Project", "Detail"], data["md"]["underway"], "Nothing is underway."),
        "",
        "## PR Decided Vs Actual",
        "",
        md_table(["PR", "Lane", "Decided", "Actual", "Next"], data["md"]["prs"], "No PR rows found."),
        "",
        "## SLA And Rot Clocks",
        "",
        md_table(["ID", "State", "Age", "Title", "Blocker"], data["md"]["rot"], "No queued or in-flight backlog rows found."),
        "",
        "## MQ Serialization",
        "",
        md_table(["ID", "Class", "Blocked By", "Reason"], data["md"]["mq"], "No MQ serialization rows found."),
        "",
        "## Recently Landed",
        "",
        md_table(["ID", "Home", "Title", "Artifact", "Date"], data["md"]["landed"], "No recent landed work in the current baseline."),
        "",
    ]
    return "\n".join(lines) + "\n"


def render_html(data: dict[str, Any], markdown_path: Path) -> str:
    counts = data["counts"]
    decisions_table = table(
        ["Where", "Source", "Kind", "Summary"],
        data["html"]["decisions"],
        "No pending captain decisions found.",
    )
    underway_table = table(
        ["ID", "Kind", "State", "Project", "Detail"],
        data["html"]["underway"],
        "Nothing is underway.",
    )
    pr_table = table(
        ["PR", "Lane", "Decided", "Actual now", "Blocker / next"],
        data["html"]["prs"],
        "No PR rows found.",
    )
    rot_table = table(
        ["ID", "State", "Age", "Title", "Blocker"],
        data["html"]["rot"],
        "No queued or in-flight backlog rows found.",
    )
    mq_table = table(
        ["ID", "Class", "Blocked by", "Reason"],
        data["html"]["mq"],
        "No MQ serialization rows found.",
    )
    landed_table = table(
        ["ID", "Home", "Title", "Artifact", "Date"],
        data["html"]["landed"],
        "No recent landed work in the current baseline.",
    )
    secondmate_table = table(
        ["Secondmate", "State", "Active", "Decisions", "Queued", "Reason"],
        data["html"]["secondmates"],
        "No secondmate records found.",
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fleet Dashboard - {esc(data['generated'])}</title>
<style>
  :root {{ --bg:#0e1116; --card:#161b22; --line:#2d333b; --tx:#e6edf3; --dim:#8b949e;
          --green:#3fb950; --amber:#d29922; --red:#f85149; --blue:#58a6ff; --purple:#bc8cff; }}
  * {{ box-sizing:border-box; }}
  body {{ background:var(--bg); color:var(--tx); font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; margin:0; padding:28px; }}
  h1 {{ font-size:26px; margin:0 0 4px; letter-spacing:0; }}
  h2 {{ font-size:17px; margin:0 0 12px; color:var(--blue); letter-spacing:0; }}
  code {{ color:var(--tx); background:#0b0d12; border:1px solid var(--line); border-radius:4px; padding:1px 5px; }}
  .sub {{ color:var(--dim); margin-bottom:22px; }}
  .row {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,340px),1fr)); gap:16px; margin-bottom:16px; }}
  .card {{ background:var(--card); border:1px solid var(--line); border-radius:8px; padding:18px 20px; min-width:0; }}
  .stat {{ display:inline-block; margin:0 26px 8px 0; vertical-align:top; }}
  .stat b {{ font-size:30px; display:block; line-height:1.1; }}
  .g{{color:var(--green)}} .a{{color:var(--amber)}} .r{{color:var(--red)}} .b{{color:var(--blue)}} .p{{color:var(--purple)}} .d{{color:var(--dim)}}
  table {{ border-collapse:collapse; width:100%; font-size:13.5px; table-layout:fixed; }}
  th,td {{ text-align:left; padding:7px 10px; border-bottom:1px solid var(--line); vertical-align:top; overflow-wrap:anywhere; }}
  th {{ color:var(--dim); font-weight:600; }}
  .pill {{ display:inline-block; padding:1px 9px; border-radius:20px; font-size:12px; font-weight:600; white-space:nowrap; }}
  .pill.g{{background:#12261c; color:var(--green)}} .pill.a{{background:#2b2111; color:var(--amber)}}
  .pill.r{{background:#2d1517; color:var(--red)}} .pill.b{{background:#12222d; color:var(--blue)}}
  .pill.p{{background:#211a2e; color:var(--purple)}} .pill.d{{background:#21262d; color:var(--dim)}}
  a {{ color:var(--blue); text-decoration:none; }} a:hover{{ text-decoration:underline; }}
  .muted {{ color:var(--dim); font-size:13px; }}
  .full {{ margin-bottom:16px; }}
  @media (max-width: 720px) {{ body {{ padding:16px; }} th,td {{ padding:6px 7px; }} }}
</style>
</head>
<body>
<h1>Fleet Dashboard</h1>
<div class="sub">Generated {esc(data['generated'])} from <code>fm-fleet-snapshot.sh --json</code> for <code>{esc(data['home'])}</code>. Canonical generated Markdown: <code>{esc(str(markdown_path))}</code>. Lavish is the read surface; ask-tool remains the decision input.</div>

<div class="row">
  <div class="card"><h2>Fleet Truth</h2>
    <span class="stat"><b class="b">{counts['active']}</b>active workers</span>
    <span class="stat"><b class="a">{counts['decisions']}</b>captain decisions</span>
    <span class="stat"><b class="b">{counts['prs']}</b>PR rows</span>
    <span class="stat"><b class="p">{counts['secondmates']}</b>secondmates</span>
  </div>
  <div class="card"><h2>SLA And Serialization</h2>
    <span class="stat"><b class="a">{counts['rot']}</b>clocked backlog rows</span>
    <span class="stat"><b class="p">{counts['mq_dependency']}</b>dependency-forced MQ</span>
    <span class="stat"><b class="r">{counts['mq_avoidable']}</b>avoidable MQ</span>
    <span class="stat"><b class="g">{counts['landed']}</b>recently landed</span>
  </div>
</div>

<div class="card full"><h2>Pending Captain Decisions</h2>{decisions_table}</div>
<div class="card full"><h2>Underway</h2>{underway_table}</div>
<div class="card full"><h2>PR Decided Vs Actual</h2>{pr_table}</div>
<div class="row">
  <div class="card"><h2>SLA And Rot Clocks</h2>{rot_table}</div>
  <div class="card"><h2>MQ Serialization</h2>{mq_table}</div>
</div>
<div class="row">
  <div class="card"><h2>Secondmates</h2>{secondmate_table}</div>
  <div class="card"><h2>Recently Landed</h2>{landed_table}</div>
</div>
</body>
</html>
"""


def build_render_data(snapshot: dict[str, Any]) -> dict[str, Any]:
    generated = str(snapshot.get("generated") or dt.datetime.now(dt.timezone.utc).isoformat())
    home = str(snapshot.get("fm_home") or "")
    records = (snapshot.get("backlog") or {}).get("records") or []
    records_by_id = backlog_by_id(records)
    decisions = collect_decisions(snapshot)
    underway = collect_underway(snapshot, records_by_id)
    prs = collect_pr_rows(snapshot, records_by_id)
    mq = collect_mq_rows(records)
    rot = collect_rot_rows(records, generated)
    landed = collect_landed(snapshot)
    secondmates = (snapshot.get("secondmate_current") or {}).get("records") or []

    html_decisions = [[esc(r["where"]), esc(r["source"]), pill(r["kind"]), esc(r["summary"])] for r in decisions]
    md_decisions = [[r["where"], r["source"], r["kind"], r["summary"]] for r in decisions]
    html_underway = [[esc(r["id"]), esc(r["kind"]), pill(r["state"]), esc(r["project"]), esc(r["detail"])] for r in underway]
    md_underway = [[r["id"], r["kind"], r["state"], r["project"], r["detail"]] for r in underway]
    html_prs = [[link(r["pr"], re.sub(r".*/pull/", "#", r["pr"])), esc(r["id"]), esc(r["decided"]), pill(r["actual"]), esc(r["next"])] for r in prs]
    md_prs = [[md_link(r["pr"], re.sub(r".*/pull/", "#", r["pr"])), r["id"], r["decided"], r["actual"], r["next"]] for r in prs]
    html_rot = [[esc(r["id"]), pill(r["state"]), esc(r["age"]), esc(r["title"]), esc(r["blocker"])] for r in rot]
    md_rot = [[r["id"], r["state"], r["age"], r["title"], r["blocker"]] for r in rot]
    html_mq = [[esc(r["id"]), pill(r["class"]), esc(r["blocked_by"]), esc(r["reason"])] for r in mq]
    md_mq = [[r["id"], r["class"], r["blocked_by"], r["reason"]] for r in mq]
    html_landed = [
        [esc(r["id"]), esc(r["home"]), esc(r["title"]), link(r["artifact"]), esc(r["date"])]
        for r in landed
    ]
    md_landed = [[r["id"], r["home"], r["title"], r["artifact"], r["date"]] for r in landed]
    html_secondmates = [
        [
            esc(mate.get("id") or "-"),
            pill((mate.get("current") or {}).get("state") or "unknown"),
            esc((mate.get("counts") or {}).get("active_children", 0)),
            esc((mate.get("counts") or {}).get("decisions_open", 0)),
            esc((mate.get("counts") or {}).get("queued", 0)),
            esc(trim((mate.get("current") or {}).get("reason") or "-", 160)),
        ]
        for mate in secondmates
    ]

    active_count = len([r for r in underway if r["state"] not in {"done", "failed", "no_active_work"}])
    mq_dependency = len([r for r in mq if r["class"] == "dependency-forced"])
    mq_avoidable = len([r for r in mq if r["class"] == "avoidable"])
    return {
        "generated": generated,
        "home": home,
        "counts": {
            "active": active_count,
            "decisions": len(decisions),
            "prs": len(prs),
            "rot": len(rot),
            "mq": len(mq),
            "mq_dependency": mq_dependency,
            "mq_avoidable": mq_avoidable,
            "landed": len(landed),
            "secondmates": len(secondmates),
        },
        "html": {
            "decisions": html_decisions,
            "underway": html_underway,
            "prs": html_prs,
            "rot": html_rot,
            "mq": html_mq,
            "landed": html_landed,
            "secondmates": html_secondmates,
        },
        "md": {
            "decisions": md_decisions,
            "underway": md_underway,
            "prs": md_prs,
            "rot": md_rot,
            "mq": md_mq,
            "landed": md_landed,
        },
    }


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def pointer_text(html_path: Path, markdown_path: Path) -> str:
    return (
        "# Fleet Dashboard\n\n"
        "This file is a pointer, not the dashboard source of truth.\n"
        "Refresh the Lavish read surface with `bin/fm-fleet-dashboard-refresh.sh`.\n\n"
        f"- Latest Lavish HTML: `{html_path}`\n"
        f"- Generated Markdown companion: `{markdown_path}`\n"
        "- Decisions still flow through ask-tool; Lavish is the read surface.\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-json", required=True, help="Snapshot JSON file, or '-' for stdin.")
    parser.add_argument("--html", required=True, help="HTML output path.")
    parser.add_argument("--markdown", required=True, help="Generated Markdown output path.")
    parser.add_argument("--pointer", help="Optional data/dashboard.md pointer path.")
    args = parser.parse_args()

    snapshot = load_snapshot(args.snapshot_json)
    data = build_render_data(snapshot)
    html_path = Path(args.html)
    markdown_path = Path(args.markdown)
    write_text(markdown_path, render_markdown(data))
    write_text(html_path, render_html(data, markdown_path))
    if args.pointer:
        write_text(Path(args.pointer), pointer_text(html_path, markdown_path))
    print(f"dashboard html: {html_path}")
    print(f"dashboard markdown: {markdown_path}")
    if args.pointer:
        print(f"dashboard pointer: {args.pointer}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
