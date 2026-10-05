#!/usr/bin/env bash
# Record repeated captain instructions from task briefs in the private workflow input.
# Schema: one JSON object per repeated instruction, with key, class, first_seen,
# count, instruction_summary, and ladder_level_hint. The key is task-scoped so a
# relaunch cannot append the same signal twice.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: fm-captain-reminder.sh <task-id> <current-brief> <data-dir>" >&2
  exit 2
fi

exec uv run --no-project - "$@" <<'PY'
import datetime
import fcntl
import hashlib
import json
import os
import re
import sys
from pathlib import Path

task_id, current_path, data_dir = sys.argv[1:]
data = Path(data_dir)
signals = data / "captain-reminders.jsonl"


def intent(path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    headings = ("## Captain's intent", "## Captain intent authorized for --intent")
    for heading in headings:
        match = re.search(r"(?m)^" + re.escape(heading) + r"\s*\n(.*?)(?=^#{1,6}\s|\Z)", text, re.S)
        if match:
            value = match.group(1).strip()
            if value:
                return value
    legacy = re.findall(r"(?m)^\[captain\]\s+(.*)$", text)
    return "\n".join(legacy).strip()


def normalized(value):
    return " ".join(value.casefold().split())


current = intent(Path(current_path))
needle = normalized(current)
if not needle:
    raise SystemExit(0)

matches = []
for path in sorted(data.glob("*/brief.md")):
    if path.parent.name == task_id:
        continue
    previous = intent(path)
    if normalized(previous) == needle:
        matches.append((path, previous))
if not matches:
    raise SystemExit(0)

key = "captain-reminder:" + task_id + ":" + hashlib.sha256(needle.encode()).hexdigest()[:16]
first_path = min(matches, key=lambda item: item[0].stat().st_mtime)[0]
first_seen = datetime.datetime.fromtimestamp(first_path.stat().st_mtime, datetime.timezone.utc).isoformat(timespec="seconds")
record = {
    "key": key,
    "class": "mistakes",
    "first_seen": first_seen,
    "count": len(matches) + 1,
    "instruction_summary": " ".join(current.split()),
    "ladder_level_hint": "automation",
}
data.mkdir(parents=True, exist_ok=True)
with signals.open("a+", encoding="utf-8") as stream:
    fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
    stream.seek(0)
    for line in stream:
        try:
            if json.loads(line).get("key") == key:
                raise SystemExit(0)
        except (ValueError, AttributeError):
            raise SystemExit("captain reminder signal file contains an invalid record")
    stream.seek(0, os.SEEK_END)
    stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    stream.flush()
    os.fsync(stream.fileno())
PY
