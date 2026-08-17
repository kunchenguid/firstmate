#!/usr/bin/env python3
"""Forward-port upstream instruction semantics into one proven optimized owner.

Interface:
  fm-prompt-semantic-refresh.py refresh --previous-upstream COMMIT
      --upstream COMMIT --overlay COMMIT --lineage PATH --output PATH

The command is read-only. It emits a canonical JSON transformation consumed by
fm-prompt-overlay.py. Every semantic change is either represented exactly once
or reported as unresolved; there is no whole-file overlay fallback.
"""

from __future__ import annotations

import argparse
import base64
import difflib
import gzip
import hashlib
import io
import json
import re
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath

SCHEMA = 1
AGENTS = "AGENTS.md"
UPSTREAM_ARTIFACT = "docs/verification/prompt-preservation/upstream/AGENTS.md.txt"
PARITY_MEMBERS = (
    ".claude/settings.json", ".codex/hooks.json", "bin/fm-brief.sh",
    "bin/fm-classify-lib.sh", "bin/fm-harness.sh", "bin/fm-marker-lib.sh",
    "bin/fm-operational-input.sh", "bin/fm-supervision-instructions.sh",
    "docs/supervision-protocols/claude.md", "docs/supervision-protocols/codex.md",
    "docs/supervision-protocols/cursor.md", "docs/supervision-protocols/grok.md",
    "docs/supervision-protocols/opencode.md", "docs/supervision-protocols/pi.md",
    "docs/supervision-protocols/unknown.md",
)


class Refusal(RuntimeError):
    pass


def git(repo: Path, *args: str, binary: bool = False) -> bytes | str:
    result = subprocess.run(("git", *args), cwd=repo, capture_output=True)
    if result.returncode:
        raise Refusal(result.stderr.decode(errors="replace").strip() or "Git command failed")
    return result.stdout if binary else result.stdout.decode().strip()


def commit(repo: Path, revision: str) -> str:
    value = git(repo, "rev-parse", "--verify", f"{revision}^{{commit}}")
    if not isinstance(value, str) or len(value) != 40:
        raise Refusal(f"missing commit object: {revision}")
    return value


def file_at(repo: Path, revision: str, path: str) -> bytes | None:
    result = subprocess.run(("git", "show", f"{revision}:{path}"), cwd=repo, capture_output=True)
    if result.returncode:
        return None
    return result.stdout


def changed_semantic_paths(repo: Path, previous: str, upstream: str) -> list[str]:
    output = git(repo, "diff", "--name-only", previous, upstream, "--", AGENTS, ".agents/skills", ".agents/prompt-roles")
    assert isinstance(output, str)
    return sorted(filter(None, output.splitlines()))


def split_frontmatter(content: bytes, path: str) -> tuple[list[bytes], list[bytes]]:
    lines = content.splitlines(keepends=True)
    if not lines or lines[0].rstrip() != b"---":
        raise Refusal(f"unmapped semantic owner: {path} has no skill frontmatter")
    try:
        end = next(index for index, line in enumerate(lines[1:], 1) if line.rstrip() == b"---" and not line.startswith((b" ", b"\t")))
    except StopIteration:
        raise Refusal(f"unmapped semantic owner: {path} has malformed skill frontmatter") from None
    return lines[: end + 1], lines[end + 1 :]


def scalar_field_end(frontmatter: list[bytes], start: int, path: str) -> int:
    end = start + 1
    while end < len(frontmatter):
        line = frontmatter[end]
        if line[:1] in (b" ", b"\t") or not line.strip():
            end += 1
            continue
        if line.strip() == b"---" or line.startswith(b"#") or re.match(rb"[A-Za-z0-9_-]+\s*:", line):
            break
        raise Refusal(f"unmapped semantic owner: {path} has ambiguous description boundary")
    return end


def quoted_scalar_is_closed(value: bytes, quote: int) -> bool:
    index = 1
    while index < len(value):
        if value[index] == quote:
            if quote == ord("'") and index + 1 < len(value) and value[index + 1] == quote:
                index += 2
                continue
            if quote == ord('"') and (len(value[:index]) - len(value[:index].rstrip(b"\\"))) % 2:
                index += 1
                continue
            return not value[index + 1 :].strip() or value[index + 1 :].lstrip().startswith(b"#")
        index += 1
    return False


def validate_description_scalar(lines: list[bytes], path: str) -> None:
    value = lines[0].split(b":", 1)[1].strip()
    continuation = b"".join(lines[1:])
    if any(line.startswith(b"\t") for line in lines[1:] if line.strip()):
        raise Refusal(f"unmapped semantic owner: {path} has malformed description indentation")
    if value.startswith((b">", b"|")):
        if not re.fullmatch(rb"[>|](?:[+-]|[1-9]|[+-][1-9]|[1-9][+-])?", value):
            raise Refusal(f"unmapped semantic owner: {path} has malformed description block scalar")
        indicator = next((byte - ord("0") for byte in value[1:] if ord("1") <= byte <= ord("9")), 1)
        for line in lines[1:]:
            if line.strip() and len(line) - len(line.lstrip(b" ")) < indicator:
                raise Refusal(f"unmapped semantic owner: {path} has malformed description indentation")
        return
    if value.startswith((b"'", b'"')):
        quote = value[0]
        joined = value + (b"\n" + continuation if continuation else b"")
        if not quoted_scalar_is_closed(joined, quote):
            raise Refusal(f"unmapped semantic owner: {path} has malformed quoted description")
        return
    if value[:1] in (b"[", b"{", b"&", b"*", b"!"):
        raise Refusal(f"unmapped semantic owner: {path} has unsupported description scalar")
    for line in lines[1:]:
        stripped = line.strip()
        if stripped and not stripped.startswith(b"#") and re.match(rb"[^:#]+:\s", stripped):
            raise Refusal(f"unmapped semantic owner: {path} has ambiguous description scalar")


def description_span(frontmatter: list[bytes], path: str) -> tuple[int, int]:
    starts = [index for index, line in enumerate(frontmatter) if line.startswith(b"description:")]
    if len(starts) != 1:
        raise Refusal(f"unmapped semantic owner: {path} has ambiguous description")
    start = starts[0]
    end = scalar_field_end(frontmatter, start, path)
    validate_description_scalar(frontmatter[start:end], path)
    return start, end


def skill_refresh(upstream: bytes, overlay: bytes, path: str, preserve_compact: bool) -> bytes:
    upstream_front, upstream_body = split_frontmatter(upstream, path)
    overlay_front, _ = split_frontmatter(overlay, path)
    u0, u1 = description_span(upstream_front, path)
    o0, o1 = description_span(overlay_front, path)
    description = overlay_front[o0:o1] if preserve_compact else upstream_front[u0:u1]
    refreshed = upstream_front[:u0] + description + upstream_front[u1:] + upstream_body
    if len(b"".join(description).decode("utf-8")) > 1100:
        raise Refusal(f"unmapped semantic owner: {path} compact discovery description exceeds its bound")
    return b"".join(refreshed)


def owner_paths(lineage: dict) -> list[str]:
    paths = lineage.get("live_authority_sha256", {}).keys()
    owners = [path for path in paths if path == AGENTS or path.startswith("FIRSTMATE_") or path.startswith(".agents/prompt-roles/")]
    if AGENTS not in owners:
        owners.append(AGENTS)
    return sorted(set(owners))


def occurrences(lines: list[bytes], needle: list[bytes]) -> list[int]:
    if not needle:
        return []
    width = len(needle)
    return [index for index in range(len(lines) - width + 1) if lines[index : index + width] == needle]


def locate_edit(contents: dict[str, list[bytes]], old: list[bytes], before: list[bytes], after: list[bytes]) -> tuple[str, int, int]:
    direct = [(path, index, index + len(old)) for path, lines in contents.items() for index in occurrences(lines, old)] if old else []
    if len(direct) == 1:
        return direct[0]
    anchors: list[tuple[str, int, int]] = []
    for path, lines in contents.items():
        for width in range(min(4, len(before)), 0, -1):
            left = before[-width:]
            for index in occurrences(lines, left):
                point = index + width
                if after and lines[point : point + min(4, len(after))] != after[:4]:
                    continue
                anchors.append((path, point, point))
            if anchors:
                break
    unique = list(dict.fromkeys(anchors))
    if len(unique) != 1:
        raise Refusal("unmapped or ambiguous upstream AGENTS.md semantic change")
    return unique[0]


def agents_refresh(previous: bytes, upstream: bytes, owners: dict[str, bytes]) -> tuple[dict[str, bytes], list[dict]]:
    old_lines = previous.splitlines(keepends=True)
    new_lines = upstream.splitlines(keepends=True)
    contents = {path: value.splitlines(keepends=True) for path, value in owners.items()}
    evidence: list[dict] = []
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        old, new = old_lines[i1:i2], new_lines[j1:j2]
        represented = [(path, index) for path, lines in contents.items() for index in occurrences(lines, new)] if new else []
        old_present = [(path, index) for path, lines in contents.items() for index in occurrences(lines, old)] if old else []
        if len(represented) == 1 and not old_present:
            path = represented[0][0]
        else:
            path, start, end = locate_edit(contents, old, old_lines[max(0, i1 - 4):i1], old_lines[i2:i2 + 4])
            contents[path][start:end] = new
        count = sum(len(occurrences(lines, new)) for lines in contents.values()) if new else 0
        if new and count != 1:
            raise Refusal("upstream AGENTS.md semantic change is not represented exactly once")
        evidence.append({"source_path": AGENTS, "source_lines": [i1 + 1, i2], "owner": path, "kind": tag})
    return ({path: b"".join(lines) for path, lines in contents.items()}, evidence)


def parity_archive(repo: Path, upstream: str) -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as archive:
        directories: set[str] = set()
        for path in PARITY_MEMBERS:
            content = file_at(repo, upstream, path)
            if content is None:
                raise Refusal(f"generated role surface missing upstream owner: {path}")
            parent = PurePosixPath(path).parent
            while str(parent) != ".":
                directories.add(str(parent))
                parent = parent.parent
            info = tarfile.TarInfo(path)
            info.size = len(content)
            info.mode = 0o755 if path.startswith("bin/") else 0o644
            info.mtime = 0
            archive.addfile(info, io.BytesIO(content))
    # Directories are unnecessary to extraction and omitting them makes output deterministic.
    return gzip.compress(raw.getvalue(), mtime=0)


def encoded_update(path: str, content: bytes, mode: str = "100644") -> dict:
    return {"path": path, "mode": mode, "sha256": hashlib.sha256(content).hexdigest(), "content_base64": base64.b64encode(content).decode("ascii")}


def transform_sources(
    repo: Path, previous: str, upstream: str, overlay: str, lineage: dict, changes: list[str]
) -> tuple[dict[str, bytes], list[dict]]:
    updates: dict[str, bytes] = {}
    evidence: list[dict] = []
    if AGENTS in changes:
        owners = {path: file_at(repo, overlay, path) for path in owner_paths(lineage)}
        if any(value is None for value in owners.values()):
            missing = next(path for path, value in owners.items() if value is None)
            raise Refusal(f"unmapped semantic owner: {missing}")
        refreshed, mapped = agents_refresh(
            file_at(repo, previous, AGENTS) or b"",
            file_at(repo, upstream, AGENTS) or b"",
            owners,  # type: ignore[arg-type]
        )
        updates.update({path: value for path, value in refreshed.items() if value != owners[path]})
        evidence.extend(mapped)
    compact_description_owners = lineage.get("compact_skill_description_owners", [])
    if not isinstance(compact_description_owners, list) or any(not isinstance(path, str) for path in compact_description_owners):
        raise Refusal("lineage has malformed compact skill description ownership")
    compact_description_owners = set(compact_description_owners)
    for path in changes:
        if path == AGENTS:
            continue
        old = file_at(repo, previous, path)
        new = file_at(repo, upstream, path)
        current = file_at(repo, overlay, path)
        if path.startswith(".agents/skills/") and path.endswith("/SKILL.md") and None not in (old, new, current):
            updates[path] = skill_refresh(new, current, path, path in compact_description_owners)  # type: ignore[arg-type]
            evidence.append({"source_path": path, "owner": path, "kind": "skill-body-with-compact-description"})
        elif old != new and new != current:
            raise Refusal(f"unmapped semantic owner: {path}")
    if not evidence:
        raise Refusal("semantic source changes produced no preservation evidence")
    return updates, evidence


def refresh_bindings(
    repo: Path, previous: str, upstream: str, overlay: str, lineage_path: Path,
    lineage: dict, changes: list[str], updates: dict[str, bytes], evidence: list[dict],
) -> bytes:
    live = next((item for item in lineage.get("generations", []) if item.get("kind") == "live-overlay"), None)
    if not isinstance(live, dict):
        raise Refusal("lineage has no live overlay generation")
    if AGENTS in changes and live.get("upstream_artifact"):
        artifact = file_at(repo, upstream, AGENTS) or b""
        updates[live["upstream_artifact"]] = artifact
        live["upstream_artifact_sha256"] = hashlib.sha256(artifact).hexdigest()
    if live.get("generated_parity_artifact"):
        archive = parity_archive(repo, upstream)
        encoded = base64.b64encode(archive) + b"\n"
        updates[live["generated_parity_artifact"]] = encoded
        live["generated_parity_artifact_sha256"] = hashlib.sha256(encoded).hexdigest()
        live["generated_parity_archive_sha256"] = hashlib.sha256(archive).hexdigest()
    live["upstream_commit"] = upstream
    for path in lineage.get("live_authority_sha256", {}):
        content = updates.get(path, file_at(repo, overlay, path))
        if content is None:
            raise Refusal(f"live semantic owner disappeared: {path}")
        lineage["live_authority_sha256"][path] = hashlib.sha256(content).hexdigest()
    transformer = file_at(repo, overlay, "bin/fm-prompt-semantic-refresh.py")
    if transformer is None:
        raise Refusal("installed overlay does not bind the semantic refresh implementation")
    transformer_hash = hashlib.sha256(transformer).hexdigest()
    lineage["semantic_refresh"] = {
        "schema_version": SCHEMA, "previous_upstream": previous,
        "upstream": upstream, "overlay": overlay, "transformer_sha256": transformer_hash,
        "changes": evidence,
    }
    updates[lineage_path.as_posix()] = (json.dumps(lineage, indent=2) + "\n").encode()
    return transformer_hash


def refresh(repo: Path, args: argparse.Namespace) -> dict:
    previous, upstream, overlay = (commit(repo, value) for value in (args.previous_upstream, args.upstream, args.overlay))
    lineage = json.loads((repo / args.lineage).read_text())
    changes = changed_semantic_paths(repo, previous, upstream)
    updates: dict[str, bytes] = {}
    evidence: list[dict] = []
    if changes:
        updates, evidence = transform_sources(repo, previous, upstream, overlay, lineage, changes)
    transformer_hash = refresh_bindings(repo, previous, upstream, overlay, args.lineage, lineage, changes, updates, evidence)
    return {
        "schema_version": SCHEMA, "previous_upstream": previous, "upstream": upstream,
        "overlay": overlay, "transformer_sha256": transformer_hash, "changes": evidence,
        "updates": [encoded_update(path, content) for path, content in sorted(updates.items())],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("refresh", help="prove and emit one semantic forward-port transformation")
    command.add_argument("--previous-upstream", required=True)
    command.add_argument("--upstream", required=True)
    command.add_argument("--overlay", required=True)
    command.add_argument("--lineage", type=Path, default=Path("docs/verification/prompt-lineage.json"))
    command.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        repo = Path(git(Path.cwd(), "rev-parse", "--show-toplevel")).resolve()
        result = refresh(repo, args)
        (repo / args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(f"REFRESHED semantic_changes={len(result['changes'])} updates={len(result['updates'])}")
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, Refusal) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
