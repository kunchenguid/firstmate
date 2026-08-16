"""Hermetic stand-in for the Spec Kit record_outcome module.

Owns the sealed-outcome vocabulary and the bounded outcomes reader, which
list_worktrees.py imports as a sibling module exactly as the real scripts do.
"""

import json
import stat
from pathlib import Path

SEALED_OUTCOMES = {
    "shipped",
    "merged",
    "reverted",
    "abandoned",
    "transferred",
    "unknown-historical",
}
MAX_OUTCOMES_BYTES = 1024 * 1024
MAX_OUTCOME_ROWS = 4096


def _regular_file(path):
    try:
        return stat.S_ISREG(Path(path).lstat().st_mode) and not Path(path).is_symlink()
    except OSError:
        return False


def _read_outcomes(path):
    path = Path(path)
    if not path.exists():
        return []
    if not _regular_file(path):
        raise ValueError("outcomes.jsonl must be a regular non-symlink file")
    if path.stat().st_size > MAX_OUTCOMES_BYTES:
        raise ValueError("outcomes.jsonl exceeds the bounded ledger size")
    events = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if not isinstance(event, dict):
            raise ValueError("outcomes.jsonl entries must be objects")
        events.append(event)
        if len(events) > MAX_OUTCOME_ROWS:
            raise ValueError("outcomes.jsonl exceeds the bounded row count")
    return events
