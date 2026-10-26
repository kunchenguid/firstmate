#!/usr/bin/env python3
"""Read one direct report's latest conversation usage without contacting a model.

fm-context-size.sh owns invocation. Only the newest log's last TAIL_BYTES are
read. Account roots come from recorded launch pins, not current configuration;
unpinned agents use vendor defaults (ambient launch overrides are not recorded).
Remote reads use fm-on's existing selected-home transport with a hard deadline.
No transcript text, log paths, or transport diagnostics enter the observation.
"""
import datetime
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

TAIL_BYTES = 4_000_000
CONTEXT_THRESHOLD_PERCENT = 20
CLAUDE_CONTEXT_WINDOWS = {
    "claude-opus-5-5": 1_000_000,
    "claude-sonnet-5-5": 1_000_000,
    "claude-fable-5-1": 1_000_000,
}


def unknown(reason, status="unknown"):
    return dict(status=status, tokens=None, context_window=None, percentage=None,
                over_threshold=None, age_seconds=None, model=None, reason=reason)


def read_meta(path):
    with open(path, encoding="utf-8") as stream:
        return dict(line.rstrip("\n").split("=", 1) for line in stream if "=" in line)


def positive_number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and value > 0)


def call_age(event, message):
    # Pi supplies a millisecond message timestamp; both formats also have an
    # ISO event timestamp. File mtime can advance for non-model events.
    for stamp in (message.get("timestamp"), event.get("timestamp")):
        try:
            if positive_number(stamp):
                epoch = stamp / 1000
            elif isinstance(stamp, str):
                parsed = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    continue
                epoch = parsed.timestamp()
            else:
                continue
            age = time.time() - epoch
            return int(age) if age >= 0 else None
        except (ValueError, OverflowError, OSError):
            continue
    return None


def pi_window(root, model, provider):
    try:
        with (root / "models-store.json").open(encoding="utf-8") as stream:
            store = json.load(stream)
        windows = []
        for name, body in store.items():
            if provider and name != provider:
                continue
            if not isinstance(body, dict):
                continue
            for item in body.get("models", []):
                if (isinstance(item, dict) and item.get("id") == model
                        and positive_number(item.get("contextWindow"))):
                    windows.append(item["contextWindow"])
        # A bare id shared by providers with different windows is ambiguous.
        return windows[0] if windows and len(set(windows)) == 1 else None
    except (OSError, ValueError, AttributeError, TypeError):
        return None


def local_observation(meta):
    harness = meta.get("harness")
    if harness not in ("claude", "pi", "pi-signed"):
        return unknown("unsupported harness", "not_read")
    cwd = meta.get("home") if meta.get("kind") == "secondmate" else meta.get("worktree")
    if not cwd or not os.path.isabs(cwd):
        return unknown("missing working directory")
    account = meta.get("account")
    if account and account != "ordinary" and not os.path.isabs(account):
        return unknown("invalid recorded account root")
    root = Path(account) if account and account != "ordinary" else (
        Path.home() / (".claude" if harness == "claude" else ".pi/agent"))
    if harness == "claude":
        directory = root / "projects" / re.sub(r"[^A-Za-z0-9]", "-", cwd)
        keys = ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
    else:
        directory = root / "sessions" / ("--" + cwd.lstrip("/").replace("/", "-") + "--")
        keys = ("input", "cacheRead", "cacheWrite")
    try:
        newest = max(directory.glob("*.jsonl"), key=lambda path: path.stat().st_mtime)
    except ValueError:
        return unknown("no session log")
    with newest.open("rb") as stream:
        size = stream.seek(0, os.SEEK_END)
        start = max(0, size - TAIL_BYTES)
        stream.seek(start)
        tail = stream.read(TAIL_BYTES)
    if start:
        # The first fragment may be a truncated JSON object.
        tail = tail.partition(b"\n")[2]
    for line in reversed(tail.splitlines()):
        if b'"usage"' not in line:
            continue
        try:
            event = json.loads(line)
            message = event.get("message")
            if not isinstance(message, dict) or message.get("role") != "assistant":
                continue
            usage = message.get("usage")
            if not isinstance(usage, dict) or keys[0] not in usage:
                continue
            values = [usage.get(key, 0) for key in keys]
            if not all((not isinstance(value, bool) and value == 0) or positive_number(value)
                       for value in values):
                continue
            tokens = sum(values)
            model = message.get("model") or meta.get("model") or None
            if not isinstance(model, str):
                model = None
            if harness == "claude":
                window = CLAUDE_CONTEXT_WINDOWS.get(model)
            else:
                provider = message.get("provider")
                model_id = model
                if not message.get("model") and model and "/" in model:
                    provider, model_id = model.split("/", 1)
                window = pi_window(root, model_id, provider)
            percent = tokens * 100 / window if window else None
            return dict(status="read", tokens=tokens, context_window=window,
                        percentage=percent,
                        over_threshold=percent > CONTEXT_THRESHOLD_PERCENT if window else None,
                        age_seconds=call_age(event, message), model=model,
                        reason=None if window else "unknown model window")
        except (ValueError, AttributeError, TypeError):
            continue
    return unknown("no assistant usage in bounded tail")


def observe(args):
    if len(args) == 2 and args[0] == "--remote-self":
        task_id = args[1]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", task_id):
            return unknown("invalid secondmate id")
        home = Path(os.environ["FM_HOME"])
        if (home / ".fm-secondmate-home").read_text().strip() != task_id:
            return unknown("secondmate identity mismatch")
        meta = read_meta(home / "state" / "parent-route" / (task_id + ".meta"))
        if meta.get("kind") != "secondmate" or meta.get("home") != str(home):
            return unknown("secondmate metadata mismatch")
        return local_observation(meta)
    if len(args) != 1:
        return unknown("expected task metadata")
    meta = read_meta(args[0])
    if meta.get("harness") not in ("claude", "pi", "pi-signed"):
        return unknown("unsupported harness", "not_read")
    if not meta.get("remote_host"):
        return local_observation(meta)
    if meta.get("kind") != "secondmate":
        return unknown("unsupported remote task")
    task_id = Path(args[0]).stem
    command = str(Path(__file__).with_name("fm-on.sh"))
    try:
        result = subprocess.run([command, task_id, "fm-context-size.sh", "--remote-self", task_id],
                                capture_output=True, text=True, check=True)
        row = json.loads(result.stdout)
        if not isinstance(row, dict) or row.get("status") not in ("read", "unknown", "not_read"):
            return unknown("invalid remote conversation observation")
        return row
    except (subprocess.CalledProcessError, ValueError):
        return unknown("remote conversation read unavailable")


if __name__ == "__main__":
    try:
        observation = observe(sys.argv[1:])
    except (OSError, ValueError, KeyError):
        observation = unknown("conversation read unavailable")
    print(json.dumps(observation, allow_nan=False))
