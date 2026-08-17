#!/usr/bin/env python3
"""Compile the Pi-only initial prompt for one supported Firstmate role."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROLES = ("primary", "secondmate", "firstmate-ship", "firstmate-scout", "project-worker")
RUNTIMES = ("tmux", "herdr", "zellij", "orca", "cmux")
WORKER_ROLES = set(ROLES[2:])
PRIMARY_ONLY_MARKERS = (
    "captain's only point of contact",
    "Run `bin/fm-session-start.sh`",
    "Whenever work is under way, keep exactly one live supervision cycle",
)


class Refusal(RuntimeError):
    pass


def read_required(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise Refusal(f"prompt source is unavailable or unsafe: {path}")
    return path.read_text()


def compile_prompt(args: argparse.Namespace) -> str:
    root = Path(args.root).resolve()
    if args.harness != "pi":
        raise Refusal("live role compilation is Pi-only; other harnesses retain their existing structural transports")
    if args.runtime not in RUNTIMES:
        raise Refusal(f"unsupported runtime: {args.runtime}")
    if args.role == "secondmate" and args.runtime in {"orca", "cmux"}:
        raise Refusal(f"{args.runtime} does not support secondmate launches")
    if args.role == "primary":
        if args.brief:
            raise Refusal("a primary prompt cannot include a worker brief")
        body = read_required(root / "AGENTS.md")
        prefix = "<!-- compiled-role: primary; harness: pi -->\n"
    elif args.role == "secondmate":
        if not args.brief:
            raise Refusal("a secondmate prompt requires its exact generated charter")
        boundary = read_required(root / ".agents/prompt-roles/secondmate.md")
        charter = read_required(Path(args.brief).resolve())
        body = boundary.rstrip() + "\n\n" + charter
        prefix = "<!-- compiled-role: secondmate; harness: pi -->\n"
    else:
        if not args.brief:
            raise Refusal(f"{args.role} requires an exact generated brief")
        body = read_required(Path(args.brief).resolve())
        if "You are a crewmate" not in body:
            raise Refusal("worker brief does not carry the generated crewmate role boundary")
        if args.role == "firstmate-scout" and "report" not in body.lower():
            raise Refusal("scout brief does not define its report-only deliverable")
        if args.role == "firstmate-ship" and "Delivery contract: mode=" not in body:
            raise Refusal("ship brief does not bind its delivery mode")
        if args.role == "project-worker" and "firstmate-coding-guidelines" in body:
            raise Refusal("non-Firstmate project worker received Firstmate tracked-material instructions")
        prefix = f"<!-- compiled-role: {args.role}; harness: pi -->\n"
    result = prefix + body
    if args.role != "primary":
        leak = next((marker for marker in PRIMARY_ONLY_MARKERS if marker in result), None)
        if leak:
            raise Refusal(f"primary-only instruction leaked into {args.role}: {leak}")
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--role", required=True, choices=ROLES)
    result.add_argument("--harness", required=True)
    result.add_argument("--runtime", required=True)
    result.add_argument("--brief")
    result.add_argument("--root", default=os.environ.get("FM_ROOT_OVERRIDE", Path(__file__).resolve().parent.parent))
    result.add_argument("--output")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        prompt = compile_prompt(args)
        if args.output:
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(prompt)
        else:
            sys.stdout.write(prompt)
    except (OSError, Refusal) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
