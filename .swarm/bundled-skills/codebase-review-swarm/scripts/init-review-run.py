#!/usr/bin/env python3
"""Create a codebase-review-swarm run directory without touching source files."""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import subprocess
import sys

ARTIFACTS = [
    "claims.jsonl",
    "surfaces.jsonl",
    "boundaries.jsonl",
    "ai-surfaces.jsonl",
    "ui-inventory.jsonl",
    "test-inventory.jsonl",
    "coverage.jsonl",
    "candidates.jsonl",
    "validations.jsonl",
    "critic.jsonl",
    "disproven.jsonl",
    "commands.jsonl",
]
LEDGERS = [
    "inventory-summary.md",
    "candidate-summary.md",
    "validation-summary.md",
    "test-drift-review.md",
    "strengths-ledger.md",
    "final-critic-check.md",
]
RUN_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def run(cmd: list[str], cwd: Path) -> str | None:
    try:
        return subprocess.check_output(
            cmd,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        ).strip()
    except Exception:
        return None


def git_root(cwd: Path) -> Path:
    out = run(["git", "rev-parse", "--show-toplevel"], cwd)
    return Path(out) if out else cwd


def validate_run_id(raw: str) -> str:
    if not RUN_ID_RE.fullmatch(raw) or raw in {".", ".."}:
        raise ValueError(
            "Invalid --run-id. Use 1-128 letters, numbers, dot, underscore, or dash; path segments are not allowed."
        )
    return raw


def resolve_run_dir(repo: Path, run_id: str) -> Path:
    runs_root = (repo / ".swarm" / "review-v8" / "runs").resolve()
    run_dir = (runs_root / run_id).resolve()
    try:
        run_dir.relative_to(runs_root)
    except ValueError as exc:
        raise ValueError("Invalid --run-id. Resolved run directory escapes .swarm/review-v8/runs.") from exc
    if run_dir == runs_root:
        raise ValueError("Invalid --run-id. Run id must name a child directory.")
    return run_dir


def is_swarm_ignored(repo: Path) -> bool:
    gitignore = repo / ".gitignore"
    if not gitignore.exists():
        return False
    lines = [line.strip() for line in gitignore.read_text(errors="ignore").splitlines()]
    return any(line in {".swarm", ".swarm/", "/.swarm", "/.swarm/"} for line in lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="repository root or working directory")
    parser.add_argument("--run-id", default=None, help="explicit run id; default UTC timestamp")
    parser.add_argument("--review-type", default="fresh", choices=["fresh", "continuation", "update"])
    args = parser.parse_args()

    cwd = Path(args.root).resolve()
    repo = git_root(cwd)
    try:
        run_id = validate_run_id(args.run_id or dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ"))
        run_dir = resolve_run_dir(repo, run_id)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    artifacts_dir = run_dir / "artifacts"
    ledgers_dir = run_dir / "ledgers"
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    ledgers_dir.mkdir(parents=True, exist_ok=True)

    for name in ARTIFACTS:
        (artifacts_dir / name).touch(exist_ok=True)
    for name in LEDGERS:
        p = ledgers_dir / name
        if not p.exists():
            p.write_text("", encoding="utf-8")

    metadata = {
        "run_id": run_id,
        "created_at_utc": dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
        "review_type": args.review_type,
        "repo_root": str(repo),
        "git_branch": run(["git", "branch", "--show-current"], repo),
        "git_head": run(["git", "rev-parse", "HEAD"], repo),
        "dirty_worktree": bool(run(["git", "status", "--porcelain"], repo)),
        "swarm_ignored": is_swarm_ignored(repo),
        "source_files_modified_by_skill": False,
    }
    (run_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    (run_dir / "source-of-truth-packet.md").touch(exist_ok=True)
    (run_dir / "repository-context-packet.md").touch(exist_ok=True)

    print(str(run_dir))
    if not metadata["swarm_ignored"]:
        print("WARNING: .swarm/ was not found in .gitignore; record this in metadata and avoid committing review artifacts.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
