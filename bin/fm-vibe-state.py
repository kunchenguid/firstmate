#!/usr/bin/env python3
"""Read Vibe 3 session turn state for one recorded task work directory.

Usage: fm-vibe-state.py <session-root> <work-directory>
Only a unique matching session is accepted; absent/ambiguous data is unknown.
Session metadata, not rendered output, owns busy/idle classification.
"""
import json
from pathlib import Path
import sys


def classify(root, work):
    matches = []
    for meta in Path(root).glob("*/meta.json"):
        try:
            data = json.loads(meta.read_text())
            if Path(data.get("origin_directory", "")).resolve() == Path(work).resolve():
                matches.append(meta.parent)
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    if len(matches) != 1:
        return "unknown"
    try:
        session = matches[0]
        current = json.loads((session / "CURRENT").read_text())
        generation = current["generation"]
        if not isinstance(generation, str) or not generation.isdigit():
            return "unknown"
        data = json.loads((session / "generations" / generation / "projection-state.json").read_text())
        snapshot = data["snapshot"]
        # Checkpoints can precede an entire active turn; committed projection
        # deltas in the journal carry the current public session envelope.
        sequence = data["snapshot_sequence"]
        for journal in sorted((session / "journal").glob("*.jsonl")):
            for line in journal.read_text().splitlines():
                record = json.loads(line)
                if record["sequence"] <= sequence:
                    continue
                sequence = record["sequence"]
                payload = record.get("payload", {})
                for delta in payload.get("delta", []):
                    if delta.get("op") == "set_envelope":
                        snapshot = delta["state"]
        turn = snapshot["latestTurn"]
        if turn is None:
            return "unknown"
        status = turn["status"]
        if status in ("running", "in_progress"):
            return "busy"
        if status in ("completed", "interrupted", "failed", "cancelled"):
            return "idle"
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        pass
    return "unknown"


if __name__ == "__main__":
    print(classify(sys.argv[1], sys.argv[2]))
