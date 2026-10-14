#!/usr/bin/env python3
"""Wait up to a poll budget for a home-local input doorbell to change.

Usage: fm-input-wait.py <notification-file> <observed-value> <seconds>
No queue reads, writes, process signalling, or delivery: the owning watcher
checks its durable queue after this bounded wait. A missing hint is harmless.
"""
import sys
import time
from pathlib import Path


def wait(path, observed, seconds):
    deadline = time.monotonic() + seconds
    while True:
        try:
            current = path.read_text().rstrip("\n")
        except OSError:
            current = ""
        if current != observed:
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(0.1, remaining))


if __name__ == "__main__":
    wait(Path(sys.argv[1]), sys.argv[2], float(sys.argv[3]))
