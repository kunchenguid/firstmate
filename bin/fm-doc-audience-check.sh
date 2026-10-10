#!/usr/bin/env bash
# fm-doc-audience-check.sh - validate the tracked documentation audience inventory.
#
# Usage:
#   bin/fm-doc-audience-check.sh
#   bin/fm-doc-audience-check.sh --root <repo> [--inventory <path>]
#
# The inventory owns classification and setup routing.
# This check validates that structure, local links, and docs/scripts.md toolbelt
# rows. It does not keyword-lint prose.
# When docs/scripts.md is tracked, every tracked file under bin/ needs exactly
# one row in the toolbelt table, and every such row must name a tracked bin/ file.
# Within the unfenced # The bin/ toolbelt section, exactly one unfenced table
# must have Script as its first header cell and a separator under it.
# The section ends at the next level-one heading; missing headings or missing
# or ambiguous table candidates are refused explicitly.
# Backtick and tilde fences (up to three leading spaces) are ignored, closing
# only with the same delimiter and at least the opening length.
# The selected table ends at the first line that is not a table row.
# Tables with other headers and pipe-prefixed examples are ignored.
# A table row may begin with up to three spaces before its opening pipe.
# A row counts only when its filename is in backticks and the purpose cell
# between the next two pipes is non-empty. A filename that is not in backticks,
# or an empty purpose cell, is refused rather than ignored.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlsplit

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
HTML_LINK_RE = re.compile(r"\b(?:href|src)=[\"']([^\"']+)[\"']", re.IGNORECASE)
TOOLBELT_SCRIPT_CELL_RE = re.compile(
    r"^\s*(?:\[`([^`]+)`\]\([^)]+\)|`([^`]+)`)\s*$"
)
TOOLBELT_SEPARATOR_CELL_RE = re.compile(r"^\s*:?-{3,}:?\s*$")
# GFM tables allow a row to be indented by up to three spaces.
# Four spaces is a code block.
TOOLBELT_TABLE_LINE_RE = re.compile(r"^ {0,3}(\|.*)$")
REQUIRED_TRACKED_PATTERNS = ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]


class CheckError(Exception):
    """One deterministic audience-check failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def git_tracked(root: Path, patterns: list[str]) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", *patterns],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"git ls-files failed: {detail or 'unknown error'}")
    return sorted(p for p in proc.stdout.decode("utf-8").split("\0") if p)


def load_inventory(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"inventory is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"inventory is unreadable: {exc}")
    if not isinstance(data, dict):
        fail("inventory root must be an object")
    if data.get("version") != 1:
        fail("inventory version must be 1")
    return data


def list_of_strings(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(isinstance(v, str) and v for v in value):
        fail(f"{label} must be a non-empty string array")
    return value


def normalized_link_value(raw: str) -> str:
    value = raw.strip()
    if value.startswith("<") and value.endswith(">"):
        value = value[1:-1].strip()
    if " " in value:
        value = value.split()[0]
    return value


def resolve_local_target(root: Path, source: Path, raw: str) -> Path | None:
    split = urlsplit(normalized_link_value(raw))
    if split.scheme or split.netloc:
        return None
    if not split.path:
        return source.resolve(strict=False) if split.fragment else None
    decoded = unquote(split.path)
    if decoded.startswith("/"):
        fail(f"absolute local link in {source.relative_to(root)}: {raw}")
    target = (source.parent / decoded).resolve(strict=False)
    try:
        target.relative_to(root.resolve())
    except ValueError:
        fail(f"local link escapes repository in {source.relative_to(root)}: {raw}")
    return target


def markdown_local_links(root: Path, source: Path) -> list[tuple[str, Path]]:
    try:
        text = source.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read prose surface {source.relative_to(root)}: {exc}")
    raw_links = MARKDOWN_LINK_RE.findall(text) + HTML_LINK_RE.findall(text)
    result: list[tuple[str, Path]] = []
    for raw in raw_links:
        target = resolve_local_target(root, source, raw)
        if target is not None:
            result.append((raw, target))
    return result


def github_heading_slug(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("`", "").strip().lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return re.sub(r"\s", "-", value)


def markdown_anchors(path: Path) -> set[str]:
    anchors: set[str] = set()
    counts: Counter[str] = Counter()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read link target {path}: {exc}")
    for line in lines:
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if match:
            base = github_heading_slug(match.group(1))
            if base:
                count = counts[base]
                anchors.add(base if count == 0 else f"{base}-{count}")
                counts[base] += 1
        for explicit in re.findall(r"<(?:a|span)\s+(?:name|id)=[\"']([^\"']+)[\"']", line, re.IGNORECASE):
            anchors.add(explicit)
    return anchors


def validate(root: Path, inventory_path: Path) -> tuple[int, int]:
    data = load_inventory(inventory_path)
    scope = data.get("scope")
    if not isinstance(scope, dict):
        fail("scope must be an object")
    patterns = list_of_strings(scope.get("trackedPatterns"), "scope.trackedPatterns")
    if patterns != REQUIRED_TRACKED_PATTERNS:
        fail("scope.trackedPatterns must match the fixed maintained-prose scope")
    audiences = set(list_of_strings(data.get("allowedAudiences"), "allowedAudiences"))
    setup_audiences = set(list_of_strings(data.get("setupAudiences"), "setupAudiences"))
    if not setup_audiences <= audiences:
        fail("setupAudiences contains an audience outside allowedAudiences")

    surfaces = data.get("surfaces")
    if not isinstance(surfaces, list):
        fail("surfaces must be an array")
    paths: list[str] = []
    classifications: dict[str, str] = {}
    for index, entry in enumerate(surfaces):
        if not isinstance(entry, dict):
            fail(f"surfaces[{index}] must be an object")
        path = entry.get("path")
        audience = entry.get("audience")
        if not isinstance(path, str) or not path:
            fail(f"surfaces[{index}].path must be a non-empty string")
        if audience not in audiences:
            fail(f"{path}: unsupported audience {audience!r}")
        paths.append(path)
        classifications[path] = audience

    duplicates = sorted(path for path, count in Counter(paths).items() if count != 1)
    if duplicates:
        fail("surfaces classified more than once: " + ", ".join(duplicates))

    tracked = set(git_tracked(root, patterns))
    classified = set(paths)
    missing = sorted(tracked - classified)
    extra = sorted(classified - tracked)
    if missing or extra:
        details = []
        if missing:
            details.append("unclassified: " + ", ".join(missing))
        if extra:
            details.append("not tracked/in scope: " + ", ".join(extra))
        fail("; ".join(details))

    readme_path = root / "README.md"
    readme_targets = {
        os.path.relpath(target, root).replace(os.sep, "/")
        for _, target in markdown_local_links(root, readme_path)
    }
    setup_targets = list_of_strings(data.get("readmeSetupTargets"), "readmeSetupTargets")
    for target in setup_targets:
        if target not in readme_targets:
            fail(f"README setup target is not linked from README.md: {target}")
        if classifications.get(target) not in setup_audiences:
            fail(
                f"README setup target {target} has disallowed audience "
                f"{classifications.get(target)!r}"
            )

    pointers = data.get("requiredOwnerPointers")
    if not isinstance(pointers, list) or not pointers:
        fail("requiredOwnerPointers must be a non-empty array")
    for index, pointer in enumerate(pointers):
        if not isinstance(pointer, dict):
            fail(f"requiredOwnerPointers[{index}] must be an object")
        source = pointer.get("source")
        target = pointer.get("target")
        if not isinstance(source, str) or not isinstance(target, str) or not source or not target:
            fail(f"requiredOwnerPointers[{index}] needs non-empty source and target")
        source_path = root / source
        target_path = root / target
        if not source_path.exists():
            fail(f"owner-pointer source is missing: {source}")
        if not target_path.exists():
            fail(f"owner-pointer target is missing: {target}")
        try:
            source_text = source_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"owner-pointer source is unreadable {source}: {exc}")
        linked_targets: set[str] = set()
        if source_path.suffix.lower() in {".md", ".mdx"}:
            linked_targets = {
                os.path.relpath(linked, root).replace(os.sep, "/")
                for _, linked in markdown_local_links(root, source_path)
            }
        if target not in source_text and target not in linked_targets:
            fail(f"required owner pointer missing: {source} -> {target}")

    checked_links = 0
    anchor_cache: dict[Path, set[str]] = {}
    for path in sorted(tracked):
        if Path(path).suffix.lower() not in {".md", ".mdx"}:
            continue
        source = root / path
        for raw, target in markdown_local_links(root, source):
            checked_links += 1
            if not target.exists():
                fail(f"unresolved local link in {path}: {raw}")
            fragment = unquote(urlsplit(normalized_link_value(raw)).fragment)
            if fragment and target.is_file() and target.suffix.lower() in {".md", ".mdx"}:
                anchors = anchor_cache.setdefault(target, markdown_anchors(target))
                if fragment not in anchors:
                    fail(f"unresolved local anchor in {path}: {raw}")

    validate_toolbelt(root)
    return len(tracked), checked_links


def validate_toolbelt(root: Path) -> None:
    if "docs/scripts.md" not in set(git_tracked(root, ["docs/scripts.md"])):
        return
    tracked = {
        path.removeprefix("bin/")
        for path in git_tracked(root, ["bin"])
        if path.startswith("bin/")
    }
    try:
        text = (root / "docs/scripts.md").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read docs/scripts.md: {exc}")
    rows = toolbelt_row_names(text)
    duplicates = sorted(name for name, count in Counter(rows).items() if count != 1)
    if duplicates:
        fail("bin toolbelt rows repeated: " + ", ".join(duplicates))
    documented = set(rows)
    missing = sorted(tracked - documented)
    extra = sorted(documented - tracked)
    if missing or extra:
        details: list[str] = []
        if missing:
            details.append("missing rows: " + ", ".join(missing))
        if extra:
            details.append("rows without a tracked bin file: " + ", ".join(extra))
        fail("bin toolbelt coverage: " + "; ".join(details))


def toolbelt_script_name(cell: str) -> str | None:
    match = TOOLBELT_SCRIPT_CELL_RE.match(cell)
    if not match:
        return None
    return match.group(1) or match.group(2)


def toolbelt_table_body(line: str) -> str | None:
    match = TOOLBELT_TABLE_LINE_RE.match(line)
    if match is None:
        return None
    return match.group(1)


def toolbelt_row_names(text: str) -> list[str]:
    lines = text.splitlines()
    # Keep line positions intact so headers cannot pair across fenced blocks.
    fence: tuple[str, int] | None = None
    for index, line in enumerate(lines):
        if fence is not None:
            delimiter, length = fence
            if re.fullmatch(r" {0,3}" + re.escape(delimiter) + r"{" + str(length) + r",}[ \t]*", line):
                fence = None
            lines[index] = ""
            continue
        opening = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if opening and (opening.group(1)[0] == "~" or "`" not in opening.group(2)):
            fence = (opening.group(1)[0], len(opening.group(1)))
            lines[index] = ""

    section_start = None
    section_end = len(lines)
    for index, line in enumerate(lines):
        heading = re.match(r"^ {0,3}#\s+(.+?)\s*#*\s*$", line)
        if heading is None:
            continue
        if section_start is not None:
            section_end = index
            break
        if heading.group(1) == "The bin/ toolbelt":
            section_start = index + 1
    if section_start is None:
        fail("bin toolbelt section missing: expected # The bin/ toolbelt")
    # Preserve original line numbers while excluding tables outside this section.
    lines = lines[:section_end]

    candidates: list[int] = []
    for index in range(section_start, section_end):
        header = toolbelt_table_body(lines[index])
        if header is None:
            continue
        header_cells = header.split("|")
        if len(header_cells) < 2 or header_cells[1].strip().lower() != "script":
            continue
        if index + 1 >= len(lines):
            continue
        separator = toolbelt_table_body(lines[index + 1])
        if separator is None:
            continue
        separator_cells = separator.split("|")
        if len(separator_cells) < 2 or not TOOLBELT_SEPARATOR_CELL_RE.match(separator_cells[1]):
            continue
        candidates.append(index + 2)
    if not candidates:
        fail("bin toolbelt table missing: expected exactly one unfenced Script table")
    if len(candidates) != 1:
        fail("bin toolbelt table ambiguous: found " + str(len(candidates)) + " unfenced Script tables")
    data_start = candidates[0]

    rows: list[str] = []
    for line_number, line in enumerate(lines[data_start:], start=data_start + 1):
        body = toolbelt_table_body(line)
        if body is None:
            break
        cells = body.split("|")
        if len(cells) < 2:
            continue
        script_cell = cells[1]
        if script_cell.strip().lower() == "script" or TOOLBELT_SEPARATOR_CELL_RE.match(script_cell):
            continue
        name = toolbelt_script_name(script_cell)
        if name is None:
            label = script_cell.strip() or f"line {line_number}"
            fail(f"bin toolbelt row filename is not in backticks: {label}")
        purpose = cells[2] if len(cells) > 2 else ""
        # A complete row is `| name | purpose |`, so split() yields a trailing
        # empty field and the purpose sits strictly between the second and third pipes.
        if len(cells) < 4 or not purpose.strip():
            fail(f"bin toolbelt row missing purpose: {name}")
        rows.append(name)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Firstmate documentation audiences and local links.")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--inventory", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    inventory_path = args.inventory or (root / "docs/documentation-audiences.json")
    if not inventory_path.is_absolute():
        inventory_path = root / inventory_path
    try:
        surfaces, links = validate(root, inventory_path)
    except CheckError as exc:
        print(f"fm-doc-audience-check: {exc}", file=sys.stderr)
        return 1
    print(f"fm-doc-audience-check: ok surfaces={surfaces} local_links={links}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
