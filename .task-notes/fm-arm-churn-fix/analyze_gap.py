#!/usr/bin/env python3
"""For blocked-despite-bg-arm guard fires: gap between arm launch and guard fire,
plus what the forced continuation did (arm again? how many requests?).
Also: for no-arm fires, check whether a pending wake notification arrived right after."""
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

gaps = []
gap_buckets = Counter()
cont_armed = 0
cont_requests = []
fires_examined = 0
followup_notify_gap = []  # for no-arm fires: seconds until next task-notification

for path in sorted(glob.glob(os.path.join(DIR, "*.jsonl"))):
    entries = []
    with open(path) as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except Exception:
                continue

    # linear walk recording turn structure
    last_external_idx = None
    arm_times_in_turn = []  # timestamps of bg fm-watch-arm tool_use in current turn

    for idx, d in enumerate(entries):
        t = d.get("type")
        msg = d.get("message") or {}
        if t == "user" and not is_tool_result_entry(msg):
            text = content_text(msg)
            if text.startswith("Stop hook feedback") and "TURN WOULD END BLIND" in text:
                fires_examined += 1
                fire_t = ts(d["timestamp"])
                if arm_times_in_turn:
                    gap = fire_t - arm_times_in_turn[-1]
                    gaps.append(gap)
                    if gap < 2: gap_buckets["<2s"] += 1
                    elif gap < 5: gap_buckets["2-5s"] += 1
                    elif gap < 15: gap_buckets["5-15s"] += 1
                    elif gap < 60: gap_buckets["15-60s"] += 1
                    else: gap_buckets[">=60s"] += 1
                else:
                    # no-arm fire: how soon does the next task-notification land?
                    for d2 in entries[idx+1:idx+40]:
                        m2 = d2.get("message") or {}
                        if d2.get("type") == "user" and not is_tool_result_entry(m2):
                            t2 = content_text(m2)
                            if "<task-notification>" in t2:
                                followup_notify_gap.append(ts(d2["timestamp"]) - fire_t)
                                break
                            if not t2.startswith("Stop hook feedback"):
                                break
                # examine forced continuation: until next external user input
                n_req = 0
                armed = False
                for d2 in entries[idx+1:]:
                    m2 = d2.get("message") or {}
                    if d2.get("type") == "assistant":
                        n_req += 1  # approximation: each assistant entry ~ a message chunk
                        c2 = m2.get("content")
                        if isinstance(c2, list):
                            for item in c2:
                                if isinstance(item, dict) and item.get("type") == "tool_use" \
                                   and "fm-watch-arm" in str((item.get("input") or {}).get("command", "")):
                                    armed = True
                    elif d2.get("type") == "user" and not is_tool_result_entry(m2):
                        break
                if armed: cont_armed += 1
                cont_requests.append(n_req)
                arm_times_in_turn = []
                continue
            # normal external input: new turn
            arm_times_in_turn = []
        elif t == "assistant":
            c = msg.get("content")
            if isinstance(c, list):
                for item in c:
                    if isinstance(item, dict) and item.get("type") == "tool_use" \
                       and item.get("name") == "Bash":
                        inp = item.get("input") or {}
                        if "fm-watch-arm" in str(inp.get("command", "")) and inp.get("run_in_background"):
                            arm_times_in_turn.append(ts(d["timestamp"]))

print(f"guard fires examined: {fires_examined}")
print(f"\n=== gap: last bg-arm launch -> guard fire (n={len(gaps)}) ===")
if gaps:
    print(f"min={min(gaps):.1f}s median={statistics.median(gaps):.1f}s max={max(gaps):.1f}s")
    print(dict(gap_buckets))
print(f"\n=== forced continuation ===")
print(f"continuations that re-armed: {cont_armed}/{fires_examined}")
if cont_requests:
    print(f"assistant entries per continuation: median={statistics.median(cont_requests)} max={max(cont_requests)}")
print(f"\n=== no-arm fires: time to next task-notification (n={len(followup_notify_gap)}) ===")
if followup_notify_gap:
    print(f"min={min(followup_notify_gap):.0f}s median={statistics.median(followup_notify_gap):.0f}s max={max(followup_notify_gap):.0f}s")
    print("  <30s:", sum(1 for g in followup_notify_gap if g < 30))
