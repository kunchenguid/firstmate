#!/usr/bin/env python3
"""Reconstruct timelines around blocked-despite-bg-arm guard fires:
- did a task-notification arrive after the fire, how soon, with what watcher output?
Print 8 full case timelines, plus aggregate stats."""
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

cases_printed = 0
notify_after = 0
notify_gaps = []
no_notify = 0
notify_reasons = Counter()
total = 0

for path in sorted(glob.glob(os.path.join(DIR, "*.jsonl"))):
    entries = []
    with open(path) as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except Exception:
                continue
    arm_events = []  # (idx, time, cmd) of bg arm launches in current turn
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
                            arm_events.append((idx, ts(d["timestamp"]), inp.get("command", "")[:80]))
        elif t == "user" and not is_tool_result_entry(msg):
            text = content_text(msg)
            if text.startswith("Stop hook feedback") and "TURN WOULD END BLIND" in text:
                if arm_events:
                    total += 1
                    fire_t = ts(d["timestamp"])
                    # find next task-notification within 90s
                    found = None
                    for d2 in entries[idx+1:idx+120]:
                        m2 = d2.get("message") or {}
                        if d2.get("type") == "user" and not is_tool_result_entry(m2):
                            t2 = content_text(m2)
                            if "<task-notification>" in t2:
                                found = (ts(d2["timestamp"]) - fire_t, t2)
                                break
                    if found and found[0] <= 90:
                        notify_after += 1
                        notify_gaps.append(found[0])
                        m = re.search(r"(signal:|stale:|check:|heartbeat)", found[1])
                        notify_reasons[m.group(1) if m else "none-in-text"] += 1
                    else:
                        no_notify += 1
                    if cases_printed < 8:
                        cases_printed += 1
                        print(f"=== case {cases_printed}  sess={os.path.basename(path)[:8]}  fire={d['timestamp']}")
                        for ai, at, cmd in arm_events[-2:]:
                            print(f"  arm launched t-{fire_t-at:.1f}s: {cmd}")
                        m = re.search(r"last beat: (\d+)s ago", text)
                        print(f"  guard: beat={m.group(1) if m else '?'}s  in-flight={re.search(chr(92)+'d+(?= task)', text).group(0) if re.search(chr(92)+'d+(?= task)', text) else '?'}")
                        if found:
                            frag = re.sub(r"\s+", " ", found[1])[:260]
                            print(f"  notification +{found[0]:.0f}s after fire: {frag}")
                        else:
                            print("  no task-notification within window")
                arm_events = []
            else:
                arm_events = []

print(f"\n=== aggregate over {total} blocked-despite-bg-arm fires ===")
print(f"task-notification within 90s after fire: {notify_after}; none: {no_notify}")
if notify_gaps:
    print(f"notify gap after fire: min={min(notify_gaps):.0f}s median={statistics.median(notify_gaps):.0f}s max={max(notify_gaps):.0f}s")
print("reason kinds in those notifications:", dict(notify_reasons))
