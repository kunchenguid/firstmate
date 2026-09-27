#!/usr/bin/env python3
"""
fm-jev-token-budget.py - Jev Memory & Instruction Token Budget Enforcer (Pattern 16)

Calculates token counts for repository always-loaded instruction files (AGENTS.md,
CLAUDE.md) and skill descriptions, enforcing the strict 5,000-token ceiling.
Provides section-by-section breakdown to identify instruction bloat.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_MAX_TOKENS = 5000

def calculate_tokens(text: str) -> int:
    """Calculates tokens using the standard Firstmate metric: ceil(bytes / 4)."""
    raw_bytes = text.encode("utf-8")
    return math.ceil(len(raw_bytes) / 4)

def parse_skill_frontmatter(skill_path: Path) -> Dict[str, Any]:
    """Extracts name and description from a SKILL.md YAML frontmatter."""
    try:
        content = skill_path.read_text(encoding="utf-8")
    except Exception:
        return {}

    match = re.search(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
    if not match:
        return {}

    frontmatter = match.group(1)
    name = ""
    description = ""
    for line in frontmatter.splitlines():
        if line.startswith("name:"):
            name = line.split("name:", 1)[1].strip().strip("\"'")
        elif line.startswith("description:"):
            description = line.split("description:", 1)[1].strip().strip("\"'")

    combined_desc = f"{name}: {description}" if name and description else (description or name)
    tokens = calculate_tokens(combined_desc)
    return {
        "path": str(skill_path),
        "name": name or skill_path.parent.name,
        "description": description,
        "tokens": tokens,
    }

def analyze_sections(content: str) -> List[Dict[str, Any]]:
    """Splits Markdown by H1/H2 headers and computes token metrics per section."""
    sections: List[Dict[str, Any]] = []
    lines = content.splitlines()
    current_title = "Preamble"
    current_lines: List[str] = []

    for line in lines:
        if line.startswith("# ") or line.startswith("## "):
            if current_lines:
                sec_text = "\n".join(current_lines)
                sections.append({
                    "title": current_title,
                    "lines": len(current_lines),
                    "tokens": calculate_tokens(sec_text),
                })
            current_title = line.lstrip("#").strip()
            current_lines = [line]
        else:
            current_lines.append(line)

    if current_lines:
        sec_text = "\n".join(current_lines)
        sections.append({
            "title": current_title,
            "lines": len(current_lines),
            "tokens": calculate_tokens(sec_text),
        })

    return sections

def audit_repository(repo_path: Path, max_tokens: int = DEFAULT_MAX_TOKENS) -> Dict[str, Any]:
    """Audits a repository root for AGENTS.md / CLAUDE.md and skill descriptions."""
    if not repo_path.is_dir():
        return {"repo": str(repo_path), "error": "Repository path is not an existing directory"}
    agents_file: Optional[Path] = None
    for candidate in ("AGENTS.md", "CLAUDE.md"):
        p = repo_path / candidate
        if p.is_file():
            agents_file = p
            break

    agents_tokens = 0
    agents_bytes = 0
    agents_lines = 0
    sections: List[Dict[str, Any]] = []

    if agents_file:
        try:
            content = agents_file.read_text(encoding="utf-8")
            agents_bytes = len(content.encode("utf-8"))
            agents_lines = len(content.splitlines())
            agents_tokens = calculate_tokens(content)
            sections = analyze_sections(content)
        except Exception as e:
            return {
                "repo": str(repo_path),
                "error": f"Failed to read {agents_file.name}: {e}",
            }

    # Discover skills
    skills: List[Dict[str, Any]] = []
    skill_dirs = [
        repo_path / ".agents" / "skills",
        repo_path / ".cursor" / "skills",
        repo_path / "skills",
    ]
    for sdir in skill_dirs:
        if sdir.is_dir():
            for skill_file in sorted(sdir.glob("*/SKILL.md")):
                fm = parse_skill_frontmatter(skill_file)
                if fm:
                    skills.append(fm)

    skills_tokens = sum(s["tokens"] for s in skills)
    total_tokens = agents_tokens + skills_tokens
    status = "COMPLIANT" if total_tokens <= max_tokens else "OVER_BUDGET"

    return {
        "repo": str(repo_path),
        "agents_file": str(agents_file.name) if agents_file else None,
        "agents_tokens": agents_tokens,
        "agents_bytes": agents_bytes,
        "agents_lines": agents_lines,
        "skills_count": len(skills),
        "skills_tokens": skills_tokens,
        "total_tokens": total_tokens,
        "max_tokens": max_tokens,
        "status": status,
        "headroom": max_tokens - total_tokens,
        "sections": sections,
        "skills": skills,
    }

def format_summary(results: List[Dict[str, Any]]) -> str:
    lines = []
    lines.append(f"Jev Memory & Instruction Token Budget Audit ({len(results)} repo{'s' if len(results) != 1 else ''} scanned):")
    for r in results:
        if "error" in r:
            lines.append(f"  ❌ {Path(r['repo']).name}: ERROR ({r['error']})")
            continue

        symbol = "✓" if r["status"] == "COMPLIANT" else "❌"
        repo_name = Path(r["repo"]).name
        f_name = r.get("agents_file") or "NO_AGENTS_FILE"
        lines.append(
            f"  {symbol} {repo_name} [{f_name}]: {r['status']} "
            f"({r['total_tokens']:,} / {r['max_tokens']:,} tokens, "
            f"headroom: {r['headroom']:,} tok)"
        )
        lines.append(
            f"     ↳ AGENTS.md: {r['agents_tokens']:,} tok ({r['agents_lines']} lines) | "
            f"Skills ({r['skills_count']}): {r['skills_tokens']:,} tok"
        )

        if r["status"] == "OVER_BUDGET" and r.get("sections"):
            # Top 3 largest sections
            top_sections = sorted(r["sections"], key=lambda s: s["tokens"], reverse=True)[:3]
            top_str = ", ".join(f"'{s['title']}' ({s['tokens']} tok)" for s in top_sections)
            lines.append(f"     ! Heaviest sections to offload: {top_str}")

    return "\n".join(lines)

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Memory & Instruction Token Budget Enforcer (Pattern 16)"
    )
    parser.add_argument("--repo-path", default=None, help="Repository path to audit")
    parser.add_argument("--scan-all", action="store_true", help="Scan active fleet repositories")
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS, help="Ceiling for always-loaded tokens")
    parser.add_argument("--json", action="store_true", help="Output JSON format")

    args = parser.parse_args()

    repos: List[Path] = []
    if args.repo_path:
        repos.append(Path(args.repo_path))
    elif args.scan_all:
        repos.append(Path("/opt/ra/firstmate"))
        git_root = Path("/home/jon/git")
        if git_root.exists():
            for p in sorted(git_root.glob("wt-*")):
                if p.is_dir() and ((p / "AGENTS.md").exists() or (p / "CLAUDE.md").exists()):
                    repos.append(p)
            for name in ("Portal", "Zeta", "beads"):
                p = git_root / name
                if p.is_dir() and ((p / "AGENTS.md").exists() or (p / "CLAUDE.md").exists()):
                    repos.append(p)
    else:
        repos.append(Path(os.getcwd()))

    results = [audit_repository(r, max_tokens=args.max_tokens) for r in repos]

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print(format_summary(results))

    over_budget_count = sum(1 for r in results if r.get("status") == "OVER_BUDGET" or "error" in r)
    return 1 if over_budget_count > 0 else 0

if __name__ == "__main__":
    sys.exit(main())
