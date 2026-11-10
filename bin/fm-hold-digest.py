#!/usr/bin/env python3
"""fm-hold-digest.py - the one captain-facing surface for held work.

Layer 4 of the decider lane. It turns a scan into a digest the captain can
answer in one sitting: Class A rulings the lane already made (no action from
him), then every Class B item as exactly one line carrying its single smallest
act. Grouped by class, capped per group, no menus.

The digest is the only thing that reaches the captain about holds. It never
asks him to choose between options the lane could have chosen itself, and it
never lists an item twice.

Usage:
  fm-hold-digest.py [--scan PATH] [--rulings PATH] [--out PATH] [--cap N]

  --scan     JSONL from fm-hold-scan.py (default: stdin)
  --rulings  the append-only ruling ledger (default: $FM_HOME/data/decider/rulings.md)
  --out      write the digest here instead of stdout
  --cap      maximum lines per Class B group (default 15)

A ruling ledger line is:

  <id> | <ruling> | <reason> | <evidence> | <revert>

Blank lines and lines starting with `#` are ignored, so the ledger can carry
dated section headers.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# A colon is required: "option" appears in ordinary prose far more often than
# as a list marker, and a false match here produces a nonsense line.
OPTIONS_RE = re.compile(r"\bOptions?\s*:\s*(.+)$", re.IGNORECASE)
OPTION_SPLIT_RE = re.compile(r";\s*(?:[bB]\s*[-:]|option\s*[bB]\b)")
# The verb must be followed by real content: a bare "send" at the end of a
# clause names no act, so the reason's own opening clause is the better line.
SMALLEST_RE = re.compile(
    r"\b(?:reply|say|send|merge|arm|flip|run|order|mark|record|approve|confirm)\b"
    r"[^;]{3,200}",
    re.IGNORECASE,
)
QUOTED_RE = re.compile(r"'[^']*'|\"[^\"]*\"")

GROUP_TITLES = {
    "money": "Money and vendor commitments",
    "legal": "Legal, signatures, and sends under your name",
    "secrets": "Credentials and secrets only you hold",
    "destructive": "Irreversible data destruction",
    "customer-facing": "Customer-facing copy and notices",
    "edge": "Edge, DNS, and firewall changes",
    "his-accounts": "Consoles and logins only you can reach",
    "captain-instruction": "Your own instructions and switches",
}


def default_rulings() -> Path:
    home = os.environ.get("FM_HOME")
    if home:
        return Path(home) / "data" / "decider" / "rulings.md"
    return Path(__file__).resolve().parent.parent / "data" / "decider" / "rulings.md"


def first_clause(text: str, limit: int = 220) -> str:
    """Cut at the first sentence boundary that is not inside a quote or a number.

    A naive cut at the first period turns "say 'run 9.1'" into "say 'run 9" and
    a version number into a fragment, so quoted spans and digit-adjacent periods
    are skipped.
    """
    quoted = [(m.start(), m.end()) for m in QUOTED_RE.finditer(text)]
    for index, char in enumerate(text):
        if char not in ".;":
            continue
        if any(start <= index < end for start, end in quoted):
            continue
        if char == "." and 0 < index < len(text) - 1:
            if text[index - 1].isdigit() and text[index + 1].isdigit():
                continue
        return text[:index].strip()[:limit]
    return text.strip()[:limit]


def smallest_act(reason: str) -> str:
    """The single smallest act that clears this hold."""
    options = OPTIONS_RE.search(reason)
    if options:
        first = OPTION_SPLIT_RE.split(options.group(1))[0]
        return first_clause(first)
    match = SMALLEST_RE.search(reason)
    if match:
        act = first_clause(match.group(0))
        if len(act) >= 12:
            return act
    return first_clause(reason)


def read_rulings(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rulings: list[dict] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        parts = [p.strip() for p in text.split("|")]
        if len(parts) < 2:
            continue
        rulings.append(
            {
                "id": parts[0],
                "ruling": parts[1],
                "reason": parts[2] if len(parts) > 2 else "",
                "evidence": parts[3] if len(parts) > 3 else "",
                "revert": parts[4] if len(parts) > 4 else "",
            }
        )
    return rulings


def render(rows: list[dict], rulings: list[dict], cap: int) -> str:
    now = datetime.now(timezone.utc)
    class_a = [r for r in rows if r["class"] == "A"]
    class_b = [r for r in rows if r["class"] == "B"]
    class_b.sort(key=lambda r: -(r.get("age_days") or 0.0))

    out: list[str] = []
    out.append(f"# Captain holds - {now.strftime('%Y-%m-%d %H:%MZ')}")
    out.append("")
    out.append(
        f"**{len(rows)} held.** {len(class_a)} are the fleet's to decide, "
        f"{len(class_b)} need your word."
    )
    out.append("")

    out.append("## Class B - your word, one line each")
    out.append("")
    if not class_b:
        out.append("_Nothing needs your word._")
        out.append("")
    else:
        groups: dict[str, list[dict]] = {}
        for row in class_b:
            groups.setdefault(row["rule"], []).append(row)
        for rule in sorted(groups, key=lambda k: (-len(groups[k]), k)):
            items = groups[rule]
            out.append(f"### {GROUP_TITLES.get(rule, rule)} ({len(items)})")
            out.append("")
            for row in items[:cap]:
                age = row.get("age_days")
                age_text = f"{age:.0f}d" if age is not None else "no date"
                out.append(
                    f"- **{row['id']}** ({age_text}) - {smallest_act(row['reason'])}"
                )
            if len(items) > cap:
                out.append(f"- _...and {len(items) - cap} more in this group_")
            out.append("")

    out.append("## Class A - decided, no action from you")
    out.append("")
    if not class_a:
        out.append("_Nothing outstanding._")
        out.append("")
    else:
        decided = {r["id"]: r for r in rulings}
        for row in class_a:
            age = row.get("age_days")
            age_text = f"{age:.0f}d" if age is not None else "no date"
            ruling = decided.get(row["id"])
            if ruling:
                out.append(
                    f"- {row['id']} ({age_text}) - {ruling['ruling']}"
                    f" - revert: {ruling['revert'] or 'unhold'}"
                )
            else:
                out.append(
                    f"- {row['id']} ({age_text}) - awaiting a ruling"
                    f" - {row['title'][:110]}"
                )
        out.append("")

    out.append(
        "_Answer any line with its id and a word. Silence is consent for Class A only._"
    )
    out.append("")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-hold-digest.py",
        description="Render the one captain-facing digest of held work.",
    )
    parser.add_argument("--scan", type=Path, default=None)
    parser.add_argument("--rulings", type=Path, default=None)
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--cap", type=int, default=15)
    args = parser.parse_args(argv)

    if args.scan:
        try:
            text = args.scan.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"fm-hold-digest: cannot read {args.scan}: {exc}", file=sys.stderr)
            return 2
    else:
        text = sys.stdin.read()

    rows: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    digest = render(rows, read_rulings(args.rulings or default_rulings()), args.cap)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(digest, encoding="utf-8")
    else:
        sys.stdout.write(digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
