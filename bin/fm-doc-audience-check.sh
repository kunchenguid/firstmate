#!/usr/bin/env bash
# fm-doc-audience-check.sh - validate the tracked documentation audience inventory.
#
# Usage:
#   bin/fm-doc-audience-check.sh
#   bin/fm-doc-audience-check.sh --root <repo> [--inventory <path>]
#
# The inventory owns classification and setup routing.
# Canonical agent-only index membership comes from tracked .agents/skills/*/SKILL.md
# frontmatter: name matches its directory, description is a non-empty string,
# user-invocable is a boolean, and metadata.internal is true. The index itself
# and decision-hold-lifecycle compatibility redirect are not members; neither
# are user-invocable skills. Each member has exactly one local Markdown owner
# link in the index. Skill descriptions remain the trigger authority.
# Required frontmatter uses block mappings, plain or quoted strings, and
# folded/literal description blocks; no YAML dependency or trigger-text registry.
# This check validates structure only and does not keyword-lint prose.
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
import textwrap
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlsplit

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
HTML_LINK_RE = re.compile(r"\b(?:href|src)=[\"']([^\"']+)[\"']", re.IGNORECASE)
REQUIRED_TRACKED_PATTERNS = ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]
SKILL_INDEX = ".agents/skills/agent-skill-trigger-index/SKILL.md"
SKILL_INDEX_EXCLUSIONS = {SKILL_INDEX, ".agents/skills/decision-hold-lifecycle/SKILL.md"}


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


def skill_metadata(root: Path, path: str) -> tuple[str, bool]:
    """Normalize the required fields of the repository's block-style frontmatter."""
    def invalid(detail: str) -> None:
        fail(f"invalid skill metadata in {path}: {detail}")

    def fields(lines: list[str]) -> dict[str, tuple[str, list[str]]]:
        result: dict[str, tuple[str, list[str]]] = {}
        key = None
        for line in lines:
            if not line.strip() or line.startswith("#"):
                continue
            match = re.fullmatch(r"([a-zA-Z][\w-]*):(?:\s+(.*))?", line)
            if match:
                key, value = match.groups()
                if key in result:
                    invalid(f"duplicate field {key}")
                result[key] = ((value or "").strip(), [])
            elif line.startswith(" ") and key is not None:
                result[key][1].append(line)
            else:
                invalid("expected a block mapping")
        return result

    def string_value(value: str, continuation: list[str], label: str) -> str:
        if re.fullmatch(r"[>|][+-]?", value):
            value = "\n".join(line.strip() for line in continuation)
        elif value.startswith('"'):
            try:
                value = json.loads(value)
            except (ValueError, TypeError):
                invalid(f"{label} must be a string")
            if continuation:
                invalid(f"{label} has unexpected continuation")
        elif re.fullmatch(r"'(?:[^']|'')*'", value):
            value = value[1:-1].replace("''", "'")
            if continuation:
                invalid(f"{label} has unexpected continuation")
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0]
            if (not value or value[0] in "{[&*!'\"|>" or ": " in value
                    or value.lower() in {"true", "false", "null", "~"}
                    or re.fullmatch(r"[+-]?[\d.]+", value)):
                invalid(f"{label} must be a string")
            value = " ".join([value, *(line.strip() for line in continuation)])
        if not isinstance(value, str) or not value.strip():
            invalid(f"{label} must be a non-empty string")
        return value.strip()

    def boolean_value(value: str, continuation: list[str], label: str) -> bool:
        value = re.split(r"\s+#", value, maxsplit=1)[0].lower()
        if continuation or value not in {"true", "false"}:
            invalid(f"{label} must be a boolean")
        return value == "true"

    try:
        lines = (root / path).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        invalid(f"cannot read frontmatter: {exc}")
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        invalid("missing frontmatter delimiters")
    values = fields(lines[1:lines.index("---", 1)])
    for required in ("name", "description", "user-invocable", "metadata"):
        if required not in values:
            invalid(f"missing {required}")
    name = string_value(*values["name"], "name")
    if name != Path(path).parent.name:
        invalid("name must match the skill directory")
    string_value(*values["description"], "description")
    invocable = boolean_value(*values["user-invocable"], "user-invocable")
    value, continuation = values["metadata"]
    if value:
        invalid("metadata must be a block mapping")
    metadata = fields(textwrap.dedent("\n".join(continuation)).splitlines())
    if "internal" not in metadata or not boolean_value(*metadata["internal"], "metadata.internal"):
        invalid("metadata.internal must be true")
    return name, invocable


def validate_skill_index(root: Path, tracked: set[str]) -> None:
    skill_paths = sorted(path for path in tracked if re.fullmatch(r"\.agents/skills/[^/]+/SKILL\.md", path))
    if not skill_paths:
        return
    expected = set()
    for path in skill_paths:
        _, invocable = skill_metadata(root, path)
        if not invocable and path not in SKILL_INDEX_EXCLUSIONS:
            expected.add((root / path).resolve())
    if SKILL_INDEX not in tracked:
        fail(f"agent skill index must be tracked: {SKILL_INDEX}")
    members = [target for _, target in markdown_local_links(root, root / SKILL_INDEX)
               if target.name == "SKILL.md"]
    duplicates = sorted(str(path.relative_to(root)) for path, count in Counter(members).items() if count > 1)
    if duplicates:
        fail("duplicate agent skill index membership: " + ", ".join(duplicates))
    missing = sorted(str(path.relative_to(root)) for path in expected - set(members))
    extra = sorted(str(path.relative_to(root)) for path in set(members) - expected)
    if missing or extra:
        details = []
        if missing:
            details.append("missing canonical skills: " + ", ".join(missing))
        if extra:
            details.append("non-canonical members: " + ", ".join(extra))
        fail("agent skill index: " + "; ".join(details))


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

    validate_skill_index(root, tracked)
    return len(tracked), checked_links


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
