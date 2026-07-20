#!/usr/bin/env python3
"""Classify every turn-end-guard fire in fm-main sessions.

For each 'Stop hook feedback ... TURN WOULD END BLIND' user entry:
  - what triggered the blocked turn (wake notification / captain / skill / guard / other)
  - did the blocked turn contain a fm-watch-arm Bash tool_use (bg or fg)?
  - if yes, what did its tool_result report (started/attached/FAILED/none-yet)?
  - the beat age printed by the guard.
Also count arm calls per session and how the guard-forced continuation behaved.
"""
import json, glob, os, re, sys
from collections import Counter, defaultdict

DIR = os.path.expanduser("~/.claude/projects/-Users-bytedance-orca-firstmate")

def content_text(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for item in c:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(item.get("text", ""))
        return "\n".join(parts)
    return ""

def is_tool_result_entry(msg):
    c = msg.get("content")
    return isinstance(c, list) and any(
        isinstance(i, dict) and i.get("type") == "tool_result" for i in c)

def classify_trigger(text):
    if text.startswith("Stop hook feedback") and "TURN WOULD END BLIND" in text:
        return "guard"
    if "<task-notification>" in text:
        return "wake-notification"
    if text.startswith("Base directory for this skill"):
        return "skill"
    if text.startswith("Stop hook feedback"):
        return "other-stop-hook"
    return "captain-or-other"

overall = Counter()
beat_ages = []
arm_result_kinds = Counter()
fires = []
arm_calls_total = 0
wake_turns_total = 0
wake_turns_armed = 0

for path in sorted(glob.glob(os.path.join(DIR, "*.jsonl"))):
    entries = []
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            entries.append(d)
    sess = os.path.basename(path)[:8]

    # index tool_use id -> result text (first 200 chars)
    tool_results = {}
    for d in entries:
        if d.get("type") == "user":
            c = (d.get("message") or {}).get("content")
            if isinstance(c, list):
                for item in c:
                    if isinstance(item, dict) and item.get("type") == "tool_result":
                        rc = item.get("content")
                        if isinstance(rc, list):
                            rc = "\n".join(i.get("text", "") for i in rc
                                           if isinstance(i, dict) and i.get("type") == "text")
                        tool_results[item.get("tool_use_id")] = str(rc)[:400]

    # walk turns
    cur_trigger = None
    cur_trigger_text = ""
    cur_arm_uses = []   # list of (tool_use_id, background, command)
    session_has_fm = False

    for d in entries:
        t = d.get("type")
        msg = d.get("message") or {}
        if t == "user":
            if is_tool_result_entry(msg):
                continue
            text = content_text(msg)
            trig = classify_trigger(text)
            # a guard fire ends the PREVIOUS turn: classify it now
            if trig == "guard":
                m = re.search(r"last beat: (\d+)s ago", text)
                mnever = "last beat: never" in text or "no heartbeat" in text
                beat = int(m.group(1)) if m else (-1 if mnever else None)
                bg_arms = [a for a in cur_arm_uses if a[1]]
                fg_arms = [a for a in cur_arm_uses if not a[1]]
                if bg_arms:
                    kind = "blocked-despite-bg-arm"
                    res = tool_results.get(bg_arms[-1][0], "")
                    if "started" in res: rk = "started"
                    elif "attached" in res: rk = "attached"
                    elif "FAILED" in res: rk = "FAILED"
                    elif "healthy" in res: rk = "healthy"
                    elif res == "": rk = "no-result-recorded"
                    else: rk = "other:" + res[:60].replace("\n", " ")
                    arm_result_kinds[rk] += 1
                elif fg_arms:
                    kind = "blocked-despite-fg-arm"
                else:
                    kind = "no-arm-call-in-turn"
                overall[(kind, cur_trigger)] += 1
                if beat is not None:
                    beat_ages.append(beat)
                fires.append({"sess": sess, "kind": kind, "trigger": cur_trigger,
                              "beat": beat, "ts": d.get("timestamp"),
                              "n_arms": len(cur_arm_uses)})
            # start a new turn
            if cur_trigger == "wake-notification":
                wake_turns_total += 1
                if any(a[1] for a in cur_arm_uses):
                    wake_turns_armed += 1
            cur_trigger = trig
            cur_trigger_text = text[:150]
            cur_arm_uses = []
        elif t == "assistant":
            c = msg.get("content")
            if isinstance(c, list):
                for item in c:
                    if isinstance(item, dict) and item.get("type") == "tool_use" \
                       and item.get("name") == "Bash":
                        cmd = (item.get("input") or {}).get("command", "")
                        if "fm-watch-arm" in cmd:
                            bg = bool((item.get("input") or {}).get("run_in_background"))
                            cur_arm_uses.append((item.get("id"), bg, cmd))
                            arm_calls_total += 1
                            session_has_fm = True
    # flush last turn
    if cur_trigger == "wake-notification":
        wake_turns_total += 1
        if any(a[1] for a in cur_arm_uses):
            wake_turns_armed += 1

print("=== guard fires by (kind, trigger-of-blocked-turn) ===")
for (kind, trig), n in sorted(overall.items(), key=lambda kv: -kv[1]):
    print(f"{n:5d}  {kind:28s}  turn-trigger={trig}")
print(f"\ntotal guard fires: {sum(overall.values())}")
print(f"total fm-watch-arm tool calls: {arm_calls_total}")
print(f"wake-notification turns: {wake_turns_total}, of which armed-in-turn (bg): {wake_turns_armed}")

print("\n=== beat age at guard fire (seconds; -1 = never) ===")
if beat_ages:
    import statistics
    known = [b for b in beat_ages if b >= 0]
    print(f"n={len(beat_ages)}  never={sum(1 for b in beat_ages if b<0)}")
    if known:
        print(f"min={min(known)} median={statistics.median(known)} max={max(known)}")
        buckets = Counter()
        for b in known:
            if b < 60: buckets["<60s"] += 1
            elif b < 300: buckets["60-300s"] += 1
            elif b < 900: buckets["300-900s"] += 1
            else: buckets[">=900s"] += 1
        print(dict(buckets))

print("\n=== arm tool_result kind when guard fired despite a bg arm ===")
for k, n in arm_result_kinds.most_common():
    print(f"{n:5d}  {k}")

print("\n=== sample fires ===")
for f in fires[:15]:
    print(f)
