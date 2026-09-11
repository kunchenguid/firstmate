#!/usr/bin/env python3
# fm-docs-sweep.py - read-only, model-free documentation hygiene scan.
#
# Walks a scoped root and reports, as bounded machine-readable JSON:
#   - inventory (file/byte/estimated-token counts, per top-level bucket)
#   - exact-duplicate groups (sha256)
#   - near-duplicate candidates (Jaccard shingle similarity, same basename only
#     - e.g. AGENTS.md vs AGENTS.md across repos - not all-pairs across every
#     file, which is not bounded at workspace scale)
#   - conflict candidates: pairs of canonical instruction files (AGENTS.md/
#     CLAUDE.md/README.md/CONTRIBUTING.md/SKILL.md by default), in different
#     repos, that carry a section under the same heading whose body is NOT a
#     near-identical copy - the shared heading is the structural "same topic"
#     signal; the file pair, heading, and divergence score are small pointers
#     for a later, separately explicit semantic-model pass, never full
#     section text
#   - broken local relative links
#   - stale inline code-path references (backtick spans that look like a path
#     and do not resolve under the nearest repo root)
#   - open TODO/FIXME/HACK/XXX markers and "- [ ]" checklist items
#
# Every stage here is stdlib-only, local-filesystem-only, and read-only: no
# network call, no model call, no file mutation, no Beads write, no task
# routing. Run it directly or via bin/fm-docs-sweep.sh; see --help for flags.
#
# Output is capped per category via --max-items so a workspace-scale run
# stays small; each category reports both a "total" count and the (possibly
# shorter) "items" list, with "truncated" set when items were dropped.
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from pathlib import Path

DEFAULT_EXCLUDE_DIRS = {
    ".git", "node_modules", ".build", "DerivedData", ".cache", "dist",
    "build", "vendor", "Pods", ".venv", "venv", "__pycache__", ".tox",
}
DEFAULT_CANONICAL_NAMES = {"AGENTS.md", "CLAUDE.md", "README.md", "CONTRIBUTING.md", "SKILL.md"}

MAX_CONTENT_BYTES = 2_000_000
MAX_GROUP_SIZE_FOR_PAIRWISE = 150
MAX_STALE_REF_CHECKS_PER_FILE = 50
SHINGLE_SIZE = 4

LINK_RE = re.compile(r"\[[^\]\n]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
CODE_SPAN_RE = re.compile(r"`([^`\n]{2,200})`")
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*)$")
CHECKLIST_RE = re.compile(r"^\s*[-*]\s*\[\s\]\s*(.*)$")
TODO_RE = re.compile(r"\b(TODO|FIXME|HACK|XXX)\b[:\s]*(.*)$", re.IGNORECASE)
PATH_LIKE_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_./-]*/[A-Za-z0-9_./-]+$")


def eprint(*a, **kw):
    print(*a, file=sys.stderr, **kw)


class FileRecord:
    __slots__ = ("path", "rel", "bucket", "repo", "size", "sha256", "content", "skipped_content")

    def __init__(self, path: Path, rel: str, bucket: str, repo: str, size: int):
        self.path = path
        self.rel = rel
        self.bucket = bucket
        self.repo = repo
        self.size = size
        self.sha256 = ""
        self.content = None
        self.skipped_content = False


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_text(path: Path) -> str:
    with open(path, "rb") as f:
        raw = f.read()
    return raw.decode("utf-8", errors="replace")


def find_repo_root(start_dir: Path, scan_root: Path, cache: dict) -> str:
    """Nearest ancestor of start_dir (inclusive, bounded by scan_root) containing
    a .git entry, as a path relative to scan_root. Falls back to "." when no
    repo boundary is found within scope. Memoized per directory."""
    key = start_dir
    if key in cache:
        return cache[key]
    d = start_dir
    found = None
    while True:
        if (d / ".git").exists():
            found = d
            break
        if d == scan_root or d == d.parent:
            break
        d = d.parent
    result = "." if found is None else str(found.relative_to(scan_root)) or "."
    cache[key] = result
    return result


def shingles(text: str) -> set:
    words = re.findall(r"[a-z0-9]+", text.lower())
    if len(words) < SHINGLE_SIZE:
        return {" ".join(words)} if words else set()
    return {" ".join(words[i:i + SHINGLE_SIZE]) for i in range(len(words) - SHINGLE_SIZE + 1)}


def jaccard(a: set, b: set) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def walk_files(root: Path, exts: set, exclude_dirs: set):
    for dirpath, dirnames, filenames in _os_walk(root):
        dirnames[:] = [d for d in dirnames if d not in exclude_dirs and not d.startswith(".git")]
        for name in filenames:
            if "." not in name:
                continue
            ext = name.rsplit(".", 1)[-1].lower()
            if ext in exts:
                p = Path(dirpath) / name
                if p.is_symlink():
                    continue
                yield p


def _os_walk(root: Path):
    import os
    yield from os.walk(root, topdown=True, followlinks=False)


def scan(root: Path, exts: set, exclude_dirs: set) -> list:
    records = []
    repo_cache: dict = {}
    for p in walk_files(root, exts, exclude_dirs):
        try:
            size = p.stat().st_size
        except OSError:
            continue
        rel = str(p.relative_to(root))
        parts = Path(rel).parts
        bucket = parts[0] if len(parts) > 1 else "."
        repo = find_repo_root(p.parent, root, repo_cache)
        rec = FileRecord(p, rel, bucket, repo, size)
        try:
            rec.sha256 = sha256_of(p)
        except OSError as e:
            eprint(f"fm-docs-sweep: skipping unreadable file {rel}: {e}")
            continue
        if size <= MAX_CONTENT_BYTES:
            try:
                rec.content = read_text(p)
            except OSError:
                rec.skipped_content = True
        else:
            rec.skipped_content = True
        records.append(rec)
    return records


def build_inventory(records: list) -> dict:
    total_bytes = sum(r.size for r in records)
    buckets: dict = {}
    for r in records:
        b = buckets.setdefault(r.bucket, {"files": 0, "bytes": 0})
        b["files"] += 1
        b["bytes"] += r.size
    bucket_list = sorted(
        (
            {
                "bucket": name,
                "files": v["files"],
                "bytes": v["bytes"],
                "estimated_tokens": v["bytes"] // 4,
            }
            for name, v in buckets.items()
        ),
        key=lambda x: -x["bytes"],
    )
    return {
        "files": len(records),
        "bytes": total_bytes,
        "estimated_tokens": total_bytes // 4,
        "buckets": bucket_list,
    }


def bounded(items: list, max_items: int):
    total = len(items)
    listed = items[:max_items] if max_items >= 0 else items
    return {"total": total, "truncated": total > len(listed), "items": listed}


def find_exact_duplicates(records: list, max_items: int) -> dict:
    groups: dict = {}
    for r in records:
        groups.setdefault(r.sha256, []).append(r)
    dup_groups = [g for g in groups.values() if len(g) > 1]
    dup_groups.sort(key=lambda g: -(g[0].size * (len(g) - 1)))
    redundant_files = sum(len(g) - 1 for g in dup_groups)
    items = [
        {
            "sha256": g[0].sha256,
            "size": g[0].size,
            "files": [r.rel for r in g],
        }
        for g in dup_groups
    ]
    result = bounded(items, max_items)
    result["groups"] = len(dup_groups)
    result["redundant_files"] = redundant_files
    return result


def find_near_duplicates(records: list, near_dup_threshold: float, max_items: int) -> tuple:
    """Whole-file candidates: same basename, different repos, high shingle
    Jaccard. This is the redundant-copy signal (dedup/consolidate), not the
    conflict signal - two files that genuinely disagree on a topic tend to
    share very few exact word-order shingles, so they score *low* here, not
    mid-band. See find_conflict_candidates for that case."""
    by_basename: dict = {}
    for r in records:
        if r.skipped_content or r.content is None:
            continue
        by_basename.setdefault(Path(r.rel).name, []).append(r)

    near_dups = []
    skipped_groups = []
    shingle_cache: dict = {}

    def shingles_of(r: FileRecord) -> set:
        if r.rel not in shingle_cache:
            shingle_cache[r.rel] = shingles(r.content)
        return shingle_cache[r.rel]

    for basename, group in by_basename.items():
        if len(group) < 2:
            continue
        if len(group) > MAX_GROUP_SIZE_FOR_PAIRWISE:
            skipped_groups.append({"basename": basename, "files": len(group)})
            continue
        for i in range(len(group)):
            for j in range(i + 1, len(group)):
                a, b = group[i], group[j]
                if a.repo == b.repo or a.sha256 == b.sha256:
                    continue
                sim = jaccard(shingles_of(a), shingles_of(b))
                if sim >= near_dup_threshold:
                    near_dups.append({
                        "basename": basename,
                        "jaccard": round(sim, 4),
                        "file_a": a.rel,
                        "file_b": b.rel,
                        "bytes_a": a.size,
                        "bytes_b": b.size,
                    })

    near_dups.sort(key=lambda x: -x["jaccard"])
    return bounded(near_dups, max_items), skipped_groups


def extract_sections(text: str) -> list:
    """Split text on Markdown heading lines into (normalized_heading, body)
    pairs. Content before the first heading is dropped - it has no heading to
    key a cross-file match on."""
    sections = []
    heading = None
    lines: list = []
    for line in text.splitlines():
        m = HEADING_RE.match(line)
        if m:
            if heading is not None:
                sections.append((heading, "\n".join(lines)))
            heading = re.sub(r"\s+", " ", m.group(1).strip().lower())
            lines = []
        else:
            lines.append(line)
    if heading is not None:
        sections.append((heading, "\n".join(lines)))
    return sections


def find_conflict_candidates(records: list, canonical_names: set, near_dup_threshold: float, max_items: int) -> tuple:
    """Candidates for a later, separately explicit semantic-model pass: pairs
    of canonical instruction files, in different repos, that carry a section
    under the *same* heading (e.g. "## Merge Authority") whose body text is
    NOT a near-identical copy. A shared heading across independent repos is
    the structural signal that they govern the same topic; only a model can
    judge whether the differing bodies actually contradict, so this stage
    outputs the file pair, heading, and divergence score only - never body
    text - keeping the handoff small."""
    heading_index: dict = {}
    for r in records:
        if r.skipped_content or r.content is None:
            continue
        if Path(r.rel).name not in canonical_names:
            continue
        for heading, body in extract_sections(r.content):
            if len(heading.split()) < 2:
                continue  # too generic ("Overview", "Notes") to be a useful key
            heading_index.setdefault(heading, []).append((r, body))

    conflicts = []
    skipped_groups = []
    for heading, entries in heading_index.items():
        if len(entries) < 2:
            continue
        if len(entries) > MAX_GROUP_SIZE_FOR_PAIRWISE:
            skipped_groups.append({"heading": heading, "files": len(entries)})
            continue
        for i in range(len(entries)):
            for j in range(i + 1, len(entries)):
                ra, body_a = entries[i]
                rb, body_b = entries[j]
                if ra.repo == rb.repo:
                    continue
                sim = jaccard(shingles(body_a), shingles(body_b))
                if sim >= near_dup_threshold:
                    continue  # near-identical section text: a copy, not a conflict
                conflicts.append({
                    "heading": heading,
                    "jaccard": round(sim, 4),
                    "file_a": ra.rel,
                    "file_b": rb.rel,
                })

    conflicts.sort(key=lambda x: x["jaccard"])
    return bounded(conflicts, max_items), skipped_groups


def find_broken_links(records: list, root: Path, max_items: int) -> dict:
    items = []
    for r in records:
        if r.skipped_content or r.content is None:
            continue
        for lineno, line in enumerate(r.content.splitlines(), start=1):
            for m in LINK_RE.finditer(line):
                target = m.group(1).strip()
                if not target or "://" in target or target.startswith(("mailto:", "#", "tel:")):
                    continue
                target = target.split("#", 1)[0]
                if not target:
                    continue
                resolved = (r.path.parent / target).resolve()
                try:
                    resolved.relative_to(root.resolve())
                except ValueError:
                    continue  # link escapes scan root; not this tool's business
                if not resolved.exists():
                    items.append({"file": r.rel, "line": lineno, "link": target})
    return bounded(items, max_items)


def find_stale_references(records: list, root: Path, max_items: int) -> dict:
    items = []
    for r in records:
        if r.skipped_content or r.content is None:
            continue
        checked = 0
        repo_dir = root / r.repo if r.repo != "." else root
        for lineno, line in enumerate(r.content.splitlines(), start=1):
            if checked >= MAX_STALE_REF_CHECKS_PER_FILE:
                break
            for m in CODE_SPAN_RE.finditer(line):
                if checked >= MAX_STALE_REF_CHECKS_PER_FILE:
                    break
                token = m.group(1).strip()
                if not PATH_LIKE_RE.match(token) or "://" in token:
                    continue
                checked += 1
                candidate = (repo_dir / token).resolve()
                try:
                    candidate.relative_to(root.resolve())
                except ValueError:
                    continue
                if not candidate.exists():
                    items.append({"file": r.rel, "line": lineno, "ref": token, "checked_against": r.repo})
    return bounded(items, max_items)


def find_todos(records: list, max_items: int) -> dict:
    items = []
    total = 0
    for r in records:
        if r.skipped_content or r.content is None:
            continue
        for lineno, line in enumerate(r.content.splitlines(), start=1):
            cm = CHECKLIST_RE.match(line)
            tm = TODO_RE.search(line)
            if cm:
                total += 1
                if len(items) < max_items or max_items < 0:
                    items.append({"file": r.rel, "line": lineno, "kind": "checklist", "text": cm.group(1).strip()[:200]})
            elif tm:
                total += 1
                if len(items) < max_items or max_items < 0:
                    items.append({"file": r.rel, "line": lineno, "kind": tm.group(1).upper(), "text": line.strip()[:200]})
    return {"total": total, "truncated": total > len(items), "items": items}


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="fm-docs-sweep.py",
        description="Read-only, model-free documentation hygiene scan. Prints bounded JSON (schema fm-docs-sweep.v1) to stdout.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--root", type=Path, default=Path.cwd(), help="Scope root to scan (default: cwd).")
    ap.add_argument("--ext", action="append", default=None, help="File extension to include, repeatable (default: md).")
    ap.add_argument("--exclude", action="append", default=None, help="Directory name to exclude, repeatable (adds to defaults).")
    ap.add_argument("--near-dup-threshold", type=float, default=0.6, help="Whole-file or section Jaccard >= this counts as a duplicate copy rather than a conflict candidate (default 0.6).")
    ap.add_argument("--canonical-name", action="append", default=None, help="Canonical instruction filename to consider for conflict candidates, repeatable (default: AGENTS.md, CLAUDE.md, README.md, CONTRIBUTING.md, SKILL.md).")
    ap.add_argument("--max-items", type=int, default=50, help="Cap on listed items per category; -1 for unbounded (default 50).")
    ap.add_argument("--out", type=Path, default=None, help="Write JSON here instead of stdout.")
    args = ap.parse_args(argv)

    root = args.root.resolve()
    if not root.is_dir():
        eprint(f"fm-docs-sweep: --root is not a directory: {root}")
        return 1

    exts = {e.lower().lstrip(".") for e in (args.ext or ["md"])}
    exclude_dirs = set(DEFAULT_EXCLUDE_DIRS) | set(args.exclude or [])
    canonical_names = set(args.canonical_name or DEFAULT_CANONICAL_NAMES)

    started = time.time()
    records = scan(root, exts, exclude_dirs)
    inventory = build_inventory(records)
    exact = find_exact_duplicates(records, args.max_items)
    near, near_skipped = find_near_duplicates(records, args.near_dup_threshold, args.max_items)
    conflicts, conflict_skipped = find_conflict_candidates(records, canonical_names, args.near_dup_threshold, args.max_items)
    links = find_broken_links(records, root, args.max_items)
    stale = find_stale_references(records, root, args.max_items)
    todos = find_todos(records, args.max_items)

    out = {
        "schema": "fm-docs-sweep.v1",
        "root": str(root),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elapsed_seconds": round(time.time() - started, 3),
        "extensions": sorted(exts),
        "inventory": inventory,
        "exact_duplicates": exact,
        "near_duplicates": near,
        "near_duplicate_groups_skipped_too_large": near_skipped,
        "conflict_candidates": conflicts,
        "conflict_candidate_groups_skipped_too_large": conflict_skipped,
        "broken_links": links,
        "stale_references": stale,
        "todos": todos,
        "notes": [
            "Read-only and model-free: no network call, no model call, no file was written or deleted.",
            "near_duplicates compares files sharing the same basename across different repos only; conflict_candidates compares canonical instruction files (AGENTS.md/CLAUDE.md/README.md/CONTRIBUTING.md/SKILL.md by default) that share a section heading across different repos. Both are bounded to groups of at most "
            f"{MAX_GROUP_SIZE_FOR_PAIRWISE} files; larger groups are listed in the matching *_skipped_too_large field without pairwise comparison.",
            "conflict_candidates names a file pair, its shared heading, and a divergence score only - never section body text; a separately explicit semantic-model pass is required to judge actual contradiction.",
            "broken_links and stale_references are heuristic candidates, not confirmed dead references: a gitignored runtime path documented but never committed, or a package/module name that happens to look like a path, will show up here and needs human or model triage before acting.",
        ],
    }

    text = json.dumps(out, indent=2, sort_keys=False)
    if args.out:
        args.out.write_text(text + "\n")
        eprint(f"fm-docs-sweep: wrote {args.out}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
