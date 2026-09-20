#!/usr/bin/env bash
# Render bounded worker and Open questions sections from one fleet snapshot.
# Read-only: it never drains wakes, changes records, or reconciles worker state.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_WORKERS=${FM_WORKER_SUMMARY_MAX_WORKERS:-20}
MAX_QUESTIONS=${FM_WORKER_SUMMARY_MAX_QUESTIONS:-20}
MAX_LINE=${FM_WORKER_SUMMARY_LINE_CAP:-220}
case "$MAX_WORKERS:$MAX_QUESTIONS:$MAX_LINE" in
  *[!0-9:]*|0:*|*:0:*|*:*:0) echo "fm-worker-summary: bounds must be positive integers" >&2; exit 2 ;;
esac
TMP=$(mktemp "${TMPDIR:-/tmp}/fm-worker-summary.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT
"$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$TMP" || exit $?
MAX_WORKERS="$MAX_WORKERS" MAX_QUESTIONS="$MAX_QUESTIONS" MAX_LINE="$MAX_LINE" python3 - "$TMP" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as f:
    root = json.load(f)
workers = root.get("tasks", [])
max_workers = int(os.environ["MAX_WORKERS"])
max_questions = int(os.environ["MAX_QUESTIONS"])
max_line = int(os.environ["MAX_LINE"])
def cap(value):
    value = " ".join(str(value or "").split())
    return value if len(value) <= max_line else value[:max_line - 12] + " [truncated]"
def state(t):
    current = t.get("current_state", {}).get("state", "unknown")
    hints = t.get("hints", {})
    if current == "working": return "working"
    if current == "blocked" or hints.get("blocked_event"): return "blocked"
    if current in ("parked", "paused"): return "waiting"
    if current in ("done", "failed"): return current
    if t.get("pr", {}).get("url") or hints.get("pending_decision"): return "review-ready"
    return "unknown"
def next_action(t):
    s = state(t)
    if s == "blocked": return "Inspect the recorded blocker and decide whether Firstmate or the worker acts next."
    if s == "waiting": return "Recheck at the declared expiry or external wait boundary."
    if t.get("hints", {}).get("pending_decision"): return "Present the recorded decision to the captain and resolve its key."
    if s == "review-ready": return "Review the recorded artifact or PR."
    if s == "working": return "Continue the worker and recheck its durable current state."
    if s == "done": return "No worker action; retain the recorded result."
    if s == "failed": return "Inspect the recorded failure before retrying or escalating."
    return "Gather missing durable evidence before retrying or escalating."
print("Worker summary\n--------------")
if not workers:
    print("None.")
for t in workers[:max_workers]:
    hints = t.get("hints", {})
    detail = cap(t.get("current_state", {}).get("detail") or hints.get("last_event_text") or "No current detail recorded.")
    required = "required" if hints.get("pending_decision") or hints.get("blocked_event") else "not required"
    print(f"- {t.get('id', 'unknown')}\n  State: {state(t)}\n  What: {detail}\n  Next: {cap(next_action(t))}\n  Captain input: {required}")
    if t.get("pr", {}).get("url"):
        print(f"  PR: {t['pr']['url']}")
if len(workers) > max_workers:
    print(f"- ... {len(workers) - max_workers} more worker(s) omitted by bound")
questions = []
for t in workers:
    for q in t.get("hints", {}).get("open_decisions", []) or []:
        questions.append({"id": t.get("id", "unknown"), "summary": q.get("summary"), "source": "worker"})
for record in root.get("backlog", {}).get("records", []) or []:
    if record.get("captain_actionable"):
        questions.append({"id": record.get("id", "unknown"), "summary": record.get("title") or record.get("raw"), "reason": record.get("hold_reason"), "source": "backlog"})
if not root.get("main_inventory", {}).get("valid", True):
    inventory = root["main_inventory"]
    questions.append({"id": "fleet", "summary": inventory.get("reason") or "Fleet inventory is contradictory.", "source": "inventory"})
print("\nOpen questions\n--------------")
if not questions:
    print("None.")
for q in questions[:max_questions]:
    action = "Present the recorded question and resolve its key." if q.get("source") == "worker" else "Inspect the durable record and create or resolve the structured captain decision."
    print(f"{q['id']}: {cap(q.get('summary') or q.get('reason') or 'Worker input is incomplete.')}\n   Next: {action}")
if len(questions) > max_questions:
    print("... further questions omitted by bound")
PY
