#!/usr/bin/env python3
"""Verify that Codex receives Firstmate's complete protected instructions.

Runs ``codex debug prompt-input`` by default. ``--input-json`` accepts a saved
prompt-input response for portable tests and incident diagnosis.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


BLOCK_SENTINEL = "FLEET_FIRSTMATE_INSTRUCTIONS_START"
END_SENTINEL = "FLEET_FIRSTMATE_INSTRUCTIONS_END"
# 2026-09-03 protected baseline: 14,643 estimated tokens plus 15% headroom.
DEFAULT_BUDGET = 17_000
PROTECTED_IDS = (
    "FM-HARD-1",
    "FM-HARD-2",
    "FM-HARD-3",
    "FM-HARD-4",
    "FM-HARD-5",
    "FM-SESSION-START",
    "FM-LOCK-REFUSAL",
    "FM-CAPTAIN-PRECEDENCE",
)


def fail(message: str) -> None:
    print(f"instruction-context: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_prompt(path: str | None) -> object:
    try:
        if path:
            raw = sys.stdin.read() if path == "-" else Path(path).read_text()
        else:
            command = [os.environ.get("CODEX_BIN", "codex"), "debug", "prompt-input"]
            raw = subprocess.run(command, check=True, capture_output=True, text=True).stdout
        return json.loads(raw)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        fail(f"cannot read Codex prompt input: {exc}")


def instruction_block(payload: object) -> str:
    if not isinstance(payload, list):
        fail("prompt input must be a JSON array")
    matches = []
    for message in payload:
        if not isinstance(message, dict) or not isinstance(message.get("content"), list):
            continue
        for item in message["content"]:
            if isinstance(item, dict) and item.get("type") == "input_text":
                text = item.get("text")
                if isinstance(text, str) and BLOCK_SENTINEL in text:
                    matches.append(text)
    if len(matches) != 1:
        fail(f"expected one instruction block with {BLOCK_SENTINEL}, found {len(matches)}")
    return matches[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-json", help="read prompt-input JSON from a file, or - for stdin")
    parser.add_argument(
        "--budget", type=int, default=DEFAULT_BUDGET, help="estimated-token ceiling"
    )
    args = parser.parse_args()
    if args.budget < 1:
        parser.error("--budget must be positive")

    text = instruction_block(load_prompt(args.input_json))
    ordered_markers = (BLOCK_SENTINEL, *PROTECTED_IDS, END_SENTINEL)
    missing = [marker for marker in ordered_markers if marker not in text]
    if missing:
        fail(f"model-visible instructions are incomplete; missing {', '.join(missing)}")

    last_index = -1
    last_marker = None
    for marker in ordered_markers:
        index = text.index(marker)
        if index <= last_index:
            fail(f"model-visible instructions are out of order; {marker} did not follow {last_marker}")
        last_index, last_marker = index, marker

    words = len(text.split())
    estimated_tokens = (words * 4 + 2) // 3
    if estimated_tokens > args.budget:
        fail(f"estimated {estimated_tokens} tokens exceeds budget {args.budget}")
    print(
        f"instruction-context: ok words={words} "
        f"estimated_tokens={estimated_tokens} budget={args.budget}"
    )


if __name__ == "__main__":
    main()
