#!/usr/bin/env bash
# fm-skill-check.sh - validate internal skill frontmatter and AGENTS.md routing.
#
# Usage:
#   bin/fm-skill-check.sh [--root <repo>] [--route] <skill-dir>...
#
# Each selected directory must contain a SKILL.md with a matching name, a
# non-empty description, user-invocable=false, and metadata.internal=true.
# --route additionally requires the skill to have a section-13 AGENTS.md
# trigger. Local Markdown links are owned by bin/fm-doc-audience-check.sh.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


class CheckError(Exception):
    pass


def fail(message: str) -> None:
    raise CheckError(message)


def frontmatter(path: Path) -> tuple[str, bool, bool]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"{path}: cannot read SKILL.md: {exc}")
    if not lines or lines[0].strip() != "---":
        fail(f"{path}: frontmatter must start with ---")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        fail(f"{path}: frontmatter has no closing ---")

    name = None
    description = []
    user_invocable = None
    metadata_internal = False
    in_description = False
    in_metadata = False
    for line in lines[1:end]:
        top = re.match(r"^([A-Za-z0-9_-]+):(?:[ \t]*(.*))?$", line)
        if top:
            key, value = top.group(1), (top.group(2) or "").strip()
            in_description = key == "description"
            in_metadata = key == "metadata"
            if key == "name":
                name = value
            elif key == "description":
                description.append(value.removesuffix(">-").strip())
            elif key == "user-invocable":
                user_invocable = value
            continue
        if in_description and line.strip():
            description.append(line.strip())
        if in_metadata and re.fullmatch(r"[ \t]+internal:[ \t]*true", line):
            metadata_internal = True

    expected_name = path.parent.name
    if name != expected_name:
        fail(f"{path}: frontmatter name {name!r} does not match {expected_name!r}")
    if not any(description):
        fail(f"{path}: frontmatter description is empty")
    if user_invocable != "false":
        fail(f"{path}: frontmatter user-invocable must be false")
    if not metadata_internal:
        fail(f"{path}: frontmatter metadata.internal must be true")
    return expected_name, user_invocable == "false", metadata_internal


def routed(root: Path, name: str) -> bool:
    agents = root / "AGENTS.md"
    try:
        text = agents.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"{agents}: cannot read routing owner: {exc}")
    pattern = re.compile(rf"^- `{re.escape(name)}` - .+$", re.MULTILINE)
    return bool(pattern.search(text))


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="fm-skill-check.sh",
        description="Validate Firstmate internal skill frontmatter and routing.",
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--route",
        action="store_true",
        help="require a section-13 AGENTS.md trigger for every selected skill",
    )
    parser.add_argument("skill_dirs", nargs="+")
    args = parser.parse_args()
    root = args.root.resolve()
    names = []
    for raw in args.skill_dirs:
        directory = Path(raw)
        if not directory.is_absolute():
            directory = root / directory
        directory = directory.resolve()
        try:
            directory.relative_to(root)
        except ValueError:
            fail(f"skill directory escapes repository: {raw}")
        if not directory.is_dir():
            fail(f"skill directory is missing: {raw}")
        name, _, _ = frontmatter(directory / "SKILL.md")
        if args.route and not routed(root, name):
            fail(f"{name}: no section-13 AGENTS.md routing trigger")
        names.append(name)
    if len(set(names)) != len(names):
        fail("the same skill directory was selected more than once")
    print(f"fm-skill-check: ok skills={len(names)} routed={len(names) if args.route else 0}")
    return 0


try:
    raise SystemExit(main())
except CheckError as exc:
    print(f"fm-skill-check: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
