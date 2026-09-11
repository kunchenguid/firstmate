#!/usr/bin/env python3
# fm-context-bundle.py - deterministic, read-only, model-free scoped
# workspace context bundle.
#
# Given a scope root, walks it exactly the way bin/fm-docs-sweep.py does
# (same file-inventory scan and byte//4 token estimate) and reports, as
# bounded JSON:
#   - inventory: file/byte/estimated-token counts for the whole scope, by
#     top-level bucket - reused verbatim from fm_docs_sweep.build_inventory
#   - tree: a nested directory/file listing of the scope, sorted and bounded
#   - selected_files: a deterministic subset of the scope's files (sorted by
#     relative path) chosen to fit an optional token/file budget, each with
#     its path, size, estimated tokens, and sha256
#
# This never calls a model, never touches the network, never writes into
# the scanned tree, and never mutates any tracked file (unless --out names
# a path the caller chose, which is the caller's responsibility to keep
# outside tracked material). Selection is a pure function of --root,
# --ext/--include/--exclude, and --budget-tokens/--max-files: the same
# inputs against an unchanged tree always produce the same bundle.
#
# A follow-on stage that packs full file *contents* into one blob (e.g. a
# Repomix-style packer) is out of scope for this command by design and would
# add a new install dependency; propose that separately for review rather
# than bundling it here.
from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import sys
import time
from pathlib import Path

_SWEEP_PATH = Path(__file__).resolve().with_name("fm-docs-sweep.py")


def _load_sweep():
    spec = importlib.util.spec_from_file_location("fm_docs_sweep", _SWEEP_PATH)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {_SWEEP_PATH}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def eprint(*a, **kw):
    print(*a, file=sys.stderr, **kw)


def build_tree(rel_paths: list, max_items: int) -> tuple:
    """Nested {name, type, children:[...]} tree from sorted relative paths.
    Bounded by the number of *files* inserted (directories are free - they
    only exist to route to the files that were kept), so the bound tracks
    the same "how many leaves did you actually get" question every other
    bounded() category in fm-docs-sweep answers."""
    root = {"name": ".", "type": "dir", "children": {}}
    inserted = 0
    truncated = False
    for rel in rel_paths:
        if max_items >= 0 and inserted >= max_items:
            truncated = True
            break
        parts = Path(rel).parts
        node = root
        for i, part in enumerate(parts):
            if i == len(parts) - 1:
                node["children"][part] = {"name": part, "type": "file"}
            else:
                node = node["children"].setdefault(part, {"name": part, "type": "dir", "children": {}})
        inserted += 1

    def finalize(node: dict) -> dict:
        if node["type"] == "file":
            return {"name": node["name"], "type": "file"}
        children = sorted(node["children"].values(), key=lambda c: (c["type"] != "dir", c["name"]))
        return {"name": node["name"], "type": "dir", "children": [finalize(c) for c in children]}

    return finalize(root), truncated


def select_files(records: list, budget_tokens: int, max_files: int) -> dict:
    """Deterministic, sorted-by-path selection bounded by an optional token
    budget and/or file count. Both -1 (default) means "no cap": every
    candidate in scope is selected. Selection order is lexicographic by
    relative path, so the same scope always yields the same prefix."""
    ordered = sorted(records, key=lambda r: r.rel)
    items = []
    total_tokens = 0
    for r in ordered:
        tokens = r.size // 4
        if max_files >= 0 and len(items) >= max_files:
            break
        if budget_tokens >= 0 and items and total_tokens + tokens > budget_tokens:
            break
        items.append({
            "path": r.rel,
            "bytes": r.size,
            "estimated_tokens": tokens,
            "sha256": r.sha256,
        })
        total_tokens += tokens
    truncated = len(items) < len(ordered)
    return {
        "total_candidates": len(ordered),
        "selected": len(items),
        "truncated": truncated,
        "estimated_tokens": total_tokens,
        "items": items,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="fm-context-bundle.py",
        description=(
            "Deterministic, read-only, model-free scoped workspace context bundle. "
            "Prints bounded JSON (schema fm-context-bundle.v1) to stdout."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--root", type=Path, default=Path.cwd(), help="Scope root to bundle (default: cwd).")
    ap.add_argument("--scope", default=None, help="Label for this bundle in the output (default: --root's basename).")
    ap.add_argument("--ext", action="append", default=None, help="File extension to include, repeatable (default: md).")
    ap.add_argument("--exclude", action="append", default=None, help="Directory name to exclude, repeatable (adds to defaults).")
    ap.add_argument("--include", action="append", default=None, help="Glob (fnmatch, matched against the file's path relative to --root), repeatable. Default: every file matched by --ext.")
    ap.add_argument("--budget-tokens", type=int, default=-1, help="Stop selecting files once the running estimated-token total would exceed this (default: -1, unbounded).")
    ap.add_argument("--max-files", type=int, default=-1, help="Cap the number of selected files (default: -1, unbounded).")
    ap.add_argument("--max-tree-items", type=int, default=500, help="Cap on files listed in the tree; -1 for unbounded (default 500).")
    ap.add_argument("--out", type=Path, default=None, help="Write JSON here instead of stdout. Callers must not point this at a tracked file.")
    args = ap.parse_args(argv)

    root = args.root.resolve()
    if not root.is_dir():
        eprint(f"fm-context-bundle: --root is not a directory: {root}")
        return 1

    sweep = _load_sweep()

    exts = {e.lower().lstrip(".") for e in (args.ext or ["md"])}
    exclude_dirs = set(sweep.DEFAULT_EXCLUDE_DIRS) | set(args.exclude or [])

    started = time.time()
    records = sweep.scan(root, exts, exclude_dirs)

    if args.include:
        records = [r for r in records if any(fnmatch.fnmatch(r.rel, pat) for pat in args.include)]

    inventory = sweep.build_inventory(records)
    rel_sorted = sorted((r.rel for r in records))
    tree, tree_truncated = build_tree(rel_sorted, args.max_tree_items)
    selected = select_files(records, args.budget_tokens, args.max_files)

    out = {
        "schema": "fm-context-bundle.v1",
        "scope": args.scope or root.name,
        "root": str(root),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elapsed_seconds": round(time.time() - started, 3),
        "extensions": sorted(exts),
        "include": sorted(args.include) if args.include else [],
        "inventory": inventory,
        "tree": tree,
        "tree_truncated": tree_truncated,
        "selected_files": selected,
        "notes": [
            "Read-only and model-free: no network call, no model call, no file in the scope was written or deleted.",
            "Deterministic: the same --root, --ext/--include/--exclude, and --budget-tokens/--max-files against an unchanged tree always produce the same bundle.",
            "inventory and the estimated_tokens field reuse fm-docs-sweep's scan and byte//4 estimate rather than a second implementation; run fm-docs-sweep.sh directly for duplicate/conflict/link/TODO analysis over this same scope.",
            "selected_files is a manifest (path/bytes/tokens/sha256), never file contents - a full-content packer (e.g. a Repomix-style tool) is a separate, explicitly-invoked follow-up, not this command.",
        ],
    }

    import json
    text = json.dumps(out, indent=2, sort_keys=False)
    if args.out:
        args.out.write_text(text + "\n")
        eprint(f"fm-context-bundle: wrote {args.out}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
