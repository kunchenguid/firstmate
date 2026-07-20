#!/usr/bin/env python3
"""For each blocked-despite-bg-arm fire: map the in-turn arm tool_use -> its background
task id (from tool_result) -> that task's notification (anywhere in transcript).
Classify: notification BEFORE fire (model ignored pending wake), AFTER fire (handoff
in flight), or never. Also extract watcher output embedded in notifications."""
import json, glob, os, re, statistics
from collections import Counter
from datetime import datetime

DIR = os.path.expanduser("~/.claude/projects/-Users-bytedance-orca-firstmate")

def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

def content_text(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(i.get("text", "") for i in c
                         if isinstance(i, dict) and i.get("type") == "text")
    return ""

def is_tool_result_entry(msg):
    c = msg.get("content")
    return isinstance(c, list) and any(
        isinstance(i, dict) and i.get("type") == "tool_result" for i in c)

klass = Counter()
after_gaps = []
watcher_out = Counter()
examples = []

for path in sorted(glob.glob(os.path.join(DIR, "*.jsonl"))):
    entries = []
    with open(path) as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except Exception:
                continue

    # tool_use id -> (bg task id or None, result text)
    result_by_use = {}
    notif_by_task = {}  # task-id -> (time, full text)
    for d in entries:
        if d.get("type") != "user":
            continue
        msg = d.get("message") or {}
        c = msg.get("content")
        if isinstance(c, list):
            for item in c:
                if isinstance(item, dict) and item.get("type") == "tool_result":
                    rc = item.get("content")
                    if isinstance(rc, list):
                        rc = "\n".join(i.get("text", "") for i in rc
                                       if isinstance(i, dict) and i.get("type") == "text")
                    rc = str(rc)
                    m = re.search(r"background with ID: (\S+)", rc)
                    result_by_use[item.get("tool_use_id")] = (m.group(1) if m else None, rc[:300])
        text = content_text(msg)
        if "<task-notification>" in text:
            m = re.search(r"<task-id>(\S+)</task-id>", text)
            if m:
                notif_by_task.setdefault(m.group(1), (ts(d["timestamp"]), text))

    arm_uses = []  # (tool_use_id, time)
    for idx, d in enumerate(entries):
        t = d.get("type")
        msg = d.get("message") or {}
        if t == "assistant":
            c = msg.get("content")
            if isinstance(c, list):
                for item in c:
                    if isinstance(item, dict) and item.get("type") == "tool_use" \
                       and item.get("name") == "Bash":
                        inp = item.get("input") or {}
                        if "fm-watch-arm" in str(inp.get("command", "")) and inp.get("run_in_background"):
                            arm_uses.append((item.get("id"), ts(d["timestamp"])))
        elif t == "user" and not is_tool_result_entry(msg):
            text = content_text(msg)
            if text.startswith("Stop hook feedback") and "TURN WOULD END BLIND" in text and arm_uses:
                fire_t = ts(d["timestamp"])
                use_id, arm_t = arm_uses[-1]
                task_id, res = result_by_use.get(use_id, (None, ""))
                if task_id is None:
                    if "hook error" in res or "denied" in res.lower():
                        klass["arm-denied-by-pretool"] += 1
                    else:
                        klass["no-task-id(fg or error)"] += 1
                else:
                    notif = notif_by_task.get(task_id)
                    if notif is None:
                        klass["task-never-notified"] += 1
                    elif notif[0] > fire_t:
                        klass["notified-AFTER-fire"] += 1
                        after_gaps.append(notif[0] - fire_t)
                        mo = re.search(r"(watcher: [^\n<]*)", notif[1])
                        watcher_out[mo.group(1)[:70] if mo else "no-watcher-line-in-notif"] += 1
                        if len(examples) < 6:
                            frag = re.sub(r"\s+", " ", notif[1])
                            examples.append((os.path.basename(path)[:8],
                                             f"arm t-{fire_t-arm_t:.0f}s, notif +{notif[0]-fire_t:.0f}s: {frag[:420]}"))
                    else:
                        klass["notified-BEFORE-fire"] += 1
                arm_uses = []
                continue
            arm_uses = []

print("=== classification of the last in-turn bg arm at each blocked-despite-bg-arm fire ===")
for k, n in klass.most_common():
    print(f"{n:5d}  {k}")
if after_gaps:
    print(f"\nnotified-AFTER-fire gap: min={min(after_gaps):.0f}s median={statistics.median(after_gaps):.0f}s max={max(after_gaps):.0f}s")
print("\n=== watcher line in after-fire notifications ===")
for k, n in watcher_out.most_common(10):
    print(f"{n:5d}  {k}")
print("\n=== examples ===")
for s, e in examples:
    print(f"[{s}] {e}\n")
