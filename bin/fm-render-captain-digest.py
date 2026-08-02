#!/usr/bin/env python3
"""Render a captain-preference digest from per-unit decision records.

A preference is a decision whose retrigger is indefinite. Units and relations
use the agent-harness per-unit decision record form unchanged; see
docs/captain-preference-units.md.

Mirrors the agent-harness scripts/render_harness.py pattern: units are the
source of truth, the digest is a generated projection, write mode updates the
output, and --check reports STALE when the output is missing or drifts.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REQUIRED_UNIT_FIELDS = (
    "id",
    "question",
    "choice",
    "rejected",
    "unknown-then",
    "retrigger",
    "provenance",
)
REQUIRED_RELATION_FIELDS = ("id", "subject", "type", "object", "provenance")
RELATION_TYPES = frozenset({"supersedes", "constrained-by", "enabled-by"})
FIELD_LINE_RE = re.compile(r"^- ([a-z0-9-]+):(.*)$")
NESTED_BULLET_RE = re.compile(r"^  - (.+)$")


class RenderError(Exception):
    """Fail-closed parse or validation error for one unit or relation file."""


@dataclass(frozen=True)
class Unit:
    path: Path
    fields: dict[str, str]


@dataclass(frozen=True)
class Relation:
    path: Path
    fields: dict[str, str]


def parse_field_file(path: Path, required: tuple[str, ...], kind: str) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RenderError(f"{kind} unreadable {path}: {exc}") from exc

    fields: dict[str, str] = {}
    current: str | None = None
    nested: list[str] = []

    def close_current() -> None:
        nonlocal current, nested
        if current is None:
            return
        if nested:
            fields[current] = "\n".join(nested)
        elif current not in fields:
            fields[current] = ""
        current = None
        nested = []

    for line in text.splitlines():
        # Allow a leading title heading; ignore blank lines.
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        field_match = FIELD_LINE_RE.match(line)
        if field_match:
            close_current()
            name = field_match.group(1)
            rest = field_match.group(2).strip()
            if name in fields:
                raise RenderError(
                    f"{kind} {path}: field {name!r} is assigned more than once; "
                    "a later line would silently discard recorded content"
                )
            if rest:
                fields[name] = rest
            else:
                fields[name] = ""
                current = name
                nested = []
            continue
        nested_match = NESTED_BULLET_RE.match(line)
        if nested_match and current is not None:
            nested.append(f"- {nested_match.group(1).strip()}")
            continue
        # Ignore non-field prose only before the first field; afterward it is an error.
        if fields or current is not None:
            raise RenderError(
                f"{kind} {path}: unexpected line while parsing fields: {line!r}"
            )

    close_current()

    missing = [name for name in required if name not in fields]
    if missing:
        raise RenderError(
            f"{kind} {path}: missing required field(s): {', '.join(missing)}"
        )
    extra = sorted(name for name in fields if name not in required)
    if extra:
        raise RenderError(
            f"{kind} {path}: unknown field(s) {', '.join(extra)}; "
            "the decision unit form is fixed and must not grow a preference fork"
        )
    for name in required:
        if not str(fields[name]).strip():
            raise RenderError(
                f"{kind} {path}: field {name!r} is empty; "
                "use the literal token UNKNOWN when a value cannot be stated honestly"
            )
    return fields


def load_units(units_dir: Path) -> dict[str, Unit]:
    if not units_dir.is_dir():
        raise RenderError(f"units directory missing: {units_dir}")
    units: dict[str, Unit] = {}
    for path in sorted(units_dir.glob("*.md")):
        fields = parse_field_file(path, REQUIRED_UNIT_FIELDS, "unit")
        unit_id = fields["id"].strip()
        if path.name != f"{unit_id}.md":
            raise RenderError(
                f"unit {path}: filename must be {{id}}.md (expected {unit_id}.md)"
            )
        if unit_id in units:
            raise RenderError(f"duplicate unit id {unit_id}: {path} and {units[unit_id].path}")
        units[unit_id] = Unit(path=path, fields=fields)
    return units


def load_relations(relations_dir: Path | None) -> list[Relation]:
    if relations_dir is None:
        return []
    if not relations_dir.is_dir():
        raise RenderError(f"relations path is not a directory: {relations_dir}")
    relations: list[Relation] = []
    seen: set[str] = set()
    for path in sorted(relations_dir.glob("*.md")):
        fields = parse_field_file(path, REQUIRED_RELATION_FIELDS, "relation")
        rel_id = fields["id"].strip()
        if path.name != f"{rel_id}.md":
            raise RenderError(
                f"relation {path}: filename must be {{id}}.md (expected {rel_id}.md)"
            )
        if rel_id in seen:
            raise RenderError(f"duplicate relation id {rel_id}")
        rel_type = fields["type"].strip()
        if rel_type not in RELATION_TYPES:
            raise RenderError(
                f"relation {path}: type must be one of "
                f"{', '.join(sorted(RELATION_TYPES))}, got {rel_type!r}"
            )
        seen.add(rel_id)
        relations.append(Relation(path=path, fields=fields))
    return relations


def validate_relation_graph(
    units: dict[str, Unit], relations: list[Relation]
) -> None:
    """Single owner of relation-graph well-formedness, run before the active set.

    The active set is a projection of this graph, so an ill-formed graph silently
    changes which preferences an agent is shown. Every way the graph can be
    malformed fails closed here rather than case by case at the consumer:

    - an endpoint that names no unit (any relation type)
    - a self edge, subject == object (any relation type)
    - a cycle of supersedes edges, which would retire every unit on the cycle
    """
    for rel in relations:
        subject = rel.fields["subject"].strip()
        obj = rel.fields["object"].strip()
        for endpoint, unit_id in (("subject", subject), ("object", obj)):
            if unit_id not in units:
                raise RenderError(
                    f"relation {rel.path}: {endpoint} {unit_id!r} does not name "
                    "an existing unit"
                )
        if subject == obj:
            raise RenderError(
                f"relation {rel.path}: subject and object are both {subject!r}; "
                "a unit cannot relate to itself"
            )
    refuse_supersedes_cycle(relations)


def refuse_supersedes_cycle(relations: list[Relation]) -> None:
    edges: dict[str, list[str]] = {}
    for rel in relations:
        if rel.fields["type"].strip() != "supersedes":
            continue
        edges.setdefault(rel.fields["subject"].strip(), []).append(
            rel.fields["object"].strip()
        )

    unvisited, on_path, settled = 0, 1, 2
    state: dict[str, int] = {}
    for start in sorted(edges):
        if state.get(start, unvisited) != unvisited:
            continue
        state[start] = on_path
        path = [start]
        stack = [(start, iter(sorted(edges.get(start, ()))))]
        while stack:
            node, successors = stack[-1]
            descended = False
            for nxt in successors:
                if state.get(nxt, unvisited) == on_path:
                    cycle = path[path.index(nxt):] + [nxt]
                    raise RenderError(
                        "supersedes relations form a cycle: "
                        f"{' -> '.join(cycle)}; every unit on it would be "
                        "dropped from the digest"
                    )
                if state.get(nxt, unvisited) == unvisited:
                    state[nxt] = on_path
                    path.append(nxt)
                    stack.append((nxt, iter(sorted(edges.get(nxt, ())))))
                    descended = True
                    break
            if not descended:
                state[node] = settled
                path.pop()
                stack.pop()


def active_unit_ids(units: dict[str, Unit], relations: list[Relation]) -> list[str]:
    superseded = {
        rel.fields["object"].strip()
        for rel in relations
        if rel.fields["type"].strip() == "supersedes"
    }
    return sorted(unit_id for unit_id in units if unit_id not in superseded)


def refuse_empty_active_set(units: dict[str, Unit], active: list[str]) -> None:
    """Separate an empty input tree from an input tree that renders to nothing.

    Zero units is a legitimate empty tree and renders normally. Units that all
    supersede away is a data error: the digest would be indistinguishable from
    "the captain has no preferences" while the unit files still hold them.
    """
    if units and not active:
        raise RenderError(
            f"all {len(units)} unit(s) are superseded, so the digest would be "
            "empty while units exist; check the supersedes relations"
        )


def display_path(path: Path | None, anchor: Path) -> str:
    """Stable path text for the generated banner.

    Anchored to the digest's own directory, never to the process cwd, so the
    rendered bytes are identical from any working directory.
    """
    if path is None:
        return "(none)"
    return Path(os.path.relpath(path.resolve(), anchor.resolve())).as_posix()


def format_field(name: str, value: str) -> list[str]:
    """Render one field, keeping a multi-line value nested under its own name.

    A value recorded as nested bullets must not be interpolated onto the field
    line: its continuation bullets would then read as sibling top-level fields.
    """
    parts = [part.strip() for part in value.strip().split("\n") if part.strip()]
    if len(parts) == 1 and not parts[0].startswith("- "):
        return [f"- {name}: {parts[0]}"]
    return [f"- {name}:"] + [f"  {part}" for part in parts]


def render_digest(
    *,
    units: dict[str, Unit],
    active: list[str],
    units_dir: Path,
    relations_dir: Path | None,
    out: Path,
) -> str:
    anchor = out.parent
    units_display = display_path(units_dir, anchor)
    relations_display = display_path(relations_dir, anchor)
    lines = [
        "<!--",
        "==============================================================================",
        "GENERATED FILE - DO NOT EDIT BY HAND",
        "==============================================================================",
        "Produced by: bin/fm-render-captain-digest.py",
        "Source paths below are relative to the directory of this file.",
        f"Units:       {units_display}",
        f"Relations:   {relations_display}",
        "Hand edits are discarded on the next render.",
        "Edit unit or relation files only, then re-run the generator.",
        "==============================================================================",
        "-->",
        "",
        "# GENERATED - DO NOT EDIT",
        "",
        "This file is a projection of per-unit captain-preference records.",
        "If you are about to edit it by hand, stop and edit a unit file instead.",
        "",
        "# Captain preferences (generated digest)",
        "",
        "Active preferences only.",
        "A unit that is the object of a `supersedes` edge is omitted.",
        "Rejected options, unknown-then, and provenance live in the unit files, not here.",
        "",
    ]
    if not active:
        lines.append("_No preference units are recorded._")
        lines.append("")
        return "\n".join(lines)

    for unit_id in active:
        unit = units[unit_id]
        lines.extend([f"## {unit_id}", ""])
        for name in ("question", "choice", "retrigger"):
            lines.extend(format_field(name, unit.fields[name]))
        lines.append("")
    return "\n".join(lines)


def default_relations_dir(units_dir: Path) -> Path | None:
    sibling = units_dir.parent / "relations"
    if sibling.is_dir():
        return sibling
    return None


def build_digest_text(
    units_dir: Path, relations_dir: Path | None, out: Path
) -> tuple[str, dict[str, Unit], list[Relation]]:
    units = load_units(units_dir)
    if relations_dir is not None:
        # Only the implicit sibling default may be absent: a relations path the
        # operator named must exist, or supersedes filtering silently vanishes.
        if not relations_dir.exists():
            raise RenderError(f"relations directory missing: {relations_dir}")
        if not relations_dir.is_dir():
            raise RenderError(f"relations path is not a directory: {relations_dir}")
        resolved_relations: Path | None = relations_dir
    else:
        resolved_relations = default_relations_dir(units_dir)
    relations = load_relations(resolved_relations)
    validate_relation_graph(units, relations)
    active = active_unit_ids(units, relations)
    refuse_empty_active_set(units, active)
    text = render_digest(
        units=units,
        active=active,
        units_dir=units_dir,
        relations_dir=resolved_relations,
        out=out,
    )
    return text, units, relations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--units-dir",
        type=Path,
        required=True,
        help="directory of {id}.md preference unit files",
    )
    parser.add_argument(
        "--relations-dir",
        type=Path,
        default=None,
        help="directory of relation files (default: sibling relations/ when present)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        required=True,
        help="path of the generated digest markdown file",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 when --out is missing or does not match a fresh render",
    )
    args = parser.parse_args(argv)

    units_dir = args.units_dir
    relations_dir = args.relations_dir
    out = args.out
    try:
        text, _units, _relations = build_digest_text(units_dir, relations_dir, out)
    except RenderError as exc:
        print(f"fm-render-captain-digest: {exc}", file=sys.stderr)
        return 2

    if args.check:
        if not out.is_file() or out.read_text(encoding="utf-8") != text:
            print(f"STALE {out}", file=sys.stderr)
            return 1
        print(f"OK {out}")
        return 0

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(f"WROTE {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
