#!/usr/bin/env python3
"""Validate the local Agent Skill package structure without external dependencies."""
from __future__ import annotations

from pathlib import Path
import re
import sys

REQUIRED = [
    "SKILL.md",
    "references/review-protocol-v8.2.md",
    "references/full-v7-source-prompt.md",
    "assets/jsonl-schemas.md",
    "assets/review-report-template.md",
]
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def parse_frontmatter(text: str) -> dict[str, str]:
    if not text.startswith("---\n"):
        raise ValueError("SKILL.md missing YAML frontmatter")
    end = text.find("\n---", 4)
    if end == -1:
        raise ValueError("SKILL.md frontmatter not closed")
    fm = {}
    for line in text[4:end].splitlines():
        if not line or line.startswith(" ") or ":" not in line:
            continue
        k, v = line.split(":", 1)
        value = v.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        fm[k.strip()] = value
    return fm


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    missing = [p for p in REQUIRED if not (root / p).exists()]
    if missing:
        print("missing required files:", ", ".join(missing), file=sys.stderr)
        return 1
    skill = (root / "SKILL.md").read_text(encoding="utf-8")
    fm = parse_frontmatter(skill)
    for field in ["name", "description"]:
        if field not in fm or not fm[field]:
            print(f"missing frontmatter field: {field}", file=sys.stderr)
            return 1
    if not NAME_RE.match(fm["name"]):
        print("invalid skill name", file=sys.stderr)
        return 1
    if fm["name"] != root.name:
        print(f"warning: directory name {root.name!r} does not match skill name {fm['name']!r}", file=sys.stderr)
    if len(fm["description"]) > 1024:
        print("description exceeds 1024 chars", file=sys.stderr)
        return 1
    print("skill package OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
