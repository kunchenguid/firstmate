#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def emit(value: dict[str, str]) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")


def parse_meta(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    try:
        with path.open(encoding="utf-8") as handle:
            for raw in handle:
                line = raw.rstrip("\n")
                if "=" in line:
                    key, value = line.split("=", 1)
                    fields[key] = value
    except OSError:
        pass
    return fields


def parse_crew_state(output: str) -> tuple[str, str, str]:
    first = output.strip().splitlines()[0] if output.strip() else ""
    state_match = re.fullmatch(r"state:\s*([A-Za-z0-9_-]+)(?:\s+.*)?", first)
    source_match = re.search(r"(?:^|[·|;])\s*source:\s*([A-Za-z0-9_-]+)", first)
    return (
        state_match.group(1) if state_match else "validating",
        source_match.group(1) if source_match else "",
        first[:500],
    )


def worktree_head(meta: dict[str, str]) -> str:
    worktree = meta.get("worktree", "")
    if worktree:
        result = subprocess.run(
            ["git", "-C", worktree, "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    return meta.get("worktree_head") or meta.get("head") or ""


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: fm-pavel-status.py <task-id>\n")
        return 2
    task_id = sys.argv[1]
    root = Path(os.environ.get("FM_ROOT_OVERRIDE", Path(__file__).resolve().parent.parent)).resolve()
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", root))).resolve()
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", home / "state")).resolve()
    crew_state = os.environ.get("FM_PAVEL_OPS_CREW_STATE", str(root / "bin" / "fm-crew-state.sh"))
    result = subprocess.run(
        [crew_state, task_id],
        cwd=home,
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, "FM_HOME": str(home)},
    )
    if result.returncode != 0:
        sys.stderr.write((result.stderr or result.stdout)[:500])
        return result.returncode
    state, source, evidence = parse_crew_state(result.stdout)
    base = {
        "state": state,
        "source": source,
        "format": "fm-pavel-status-json",
        "evidence": evidence,
    }
    if state not in {"delivery_ready", "done"}:
        emit(base)
        return 0
    if source != "run-step":
        base["state"] = "validating"
        base["evidence"] = f"readiness source {source or 'unknown'} is not run-step"
        emit(base)
        return 0
    meta = parse_meta(state_dir / f"{task_id}.meta")
    pr_url = meta.get("pr", "")
    pr_head = meta.get("pr_head", "")
    current_head = worktree_head(meta)
    if not pr_url or not pr_head or not current_head or current_head.lower() != pr_head.lower():
        base["state"] = "validating"
        base["evidence"] = "run-step readiness is not bound to the canonical PR head"
        emit(base)
        return 0
    base["pr_url"] = pr_url
    base["pr_head"] = pr_head
    base["worktree_head"] = current_head
    emit(base)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
