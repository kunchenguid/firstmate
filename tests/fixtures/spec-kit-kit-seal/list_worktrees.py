"""Hermetic kit-seal predicate for fm-teardown tests.

Mirrors list_worktrees.py::_unsealed_linked_run and its module layout - including
the sibling record_outcome import - so CI does not depend on the captain's Spec
Kit plugin install.
"""

import json
from pathlib import Path

from record_outcome import SEALED_OUTCOMES, _read_outcomes

TEARDOWN_PHASES = frozenset({"done", "decompose-done"})


def _linked_run_path(value):
    if isinstance(value, dict):
        value = value.get("path")
    if not isinstance(value, str) or not Path(value).is_absolute():
        return None
    try:
        return str(Path(value).resolve(strict=True))
    except OSError:
        return None


def _run_worktree_paths(run_json):
    paths = []
    top_level = _linked_run_path(run_json.get("worktree"))
    if top_level is not None:
        paths.append(top_level)
    slices = run_json.get("slices") or {}
    metas = slices.values() if isinstance(slices, dict) else slices
    for meta in metas:
        if not isinstance(meta, dict):
            continue
        dispatch = meta.get("dispatch")
        if isinstance(dispatch, dict):
            path = _linked_run_path(dispatch.get("worktree"))
            if path is not None:
                paths.append(path)
    return set(paths)


def _unsealed_linked_run(worktree_path, scratch_root):
    scratch_root = Path(scratch_root)
    if not scratch_root.is_dir() or scratch_root.is_symlink():
        return None
    target = str(Path(worktree_path).resolve())
    for run_dir in sorted(scratch_root.glob("*/")):
        run_path = run_dir / "run.json"
        if not run_path.is_file() or run_path.is_symlink():
            continue
        try:
            run_json = json.loads(run_path.read_text(encoding="utf-8"))
            if not isinstance(run_json, dict) or target not in _run_worktree_paths(run_json):
                continue
            if run_json.get("phase") not in TEARDOWN_PHASES:
                continue
            outcomes = _read_outcomes(run_dir / "outcomes.jsonl")
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            return f"unsealed-outcome: linked run {run_dir} cannot be verified ({exc})"
        if not any(event.get("event") in SEALED_OUTCOMES for event in outcomes):
            return f"unsealed-outcome: linked run {run_dir} must be sealed before worktree cleanup"
    return None
