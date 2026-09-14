#!/usr/bin/env python3
"""fm_task_timeline.py - durable per-task timeline record and its read-only builder.

This module is the single owner of the fm-task-timeline.v1 record schema and of
the phase arithmetic the bridge console's `t` key renders. bin/fm-task-timeline.sh
is the shell entry point spawn and teardown call; bin/fm-bridge-console.py
imports this module directly.

Why the record exists
---------------------
Cleanup (bin/fm-teardown.sh) removes the task's status log, worktree, and task
metadata. The no-mistakes run ledger and the Claude/Codex session logs survive,
but the only join from a task to its runs is the worktree path, and the only join
to its session logs is the worktree cwd - both gone after cleanup. So the task
writes a small record while it is alive, at exactly two checkpoints (captain's
ruling 2026-09-14: "at checkpoints", never on every status update):

  dispatch  bin/fm-spawn.sh, after state/<id>.meta exists. Appends one entry to
            `dispatches` (a relaunch appends another; relaunch count is
            len(dispatches) - 1).
  cleanup   bin/fm-teardown.sh, after every refusal gate has passed and BEFORE
            the first destructive step. Captures what the removals below it
            would otherwise lose.

A checkpoint write failure prints one `warning:` line and exits 0 so it can
never block a spawn or a teardown. The record is written atomically
(tmp + rename) under data/<task-id>/timeline.json, beside brief.md and
report.md, which is why it survives cleanup the way a scout report does.

Record schema: fm-task-timeline.v1  (data/<task-id>/timeline.json)
------------------------------------------------------------------
{
  "schema": "fm-task-timeline.v1",
  "task_id": "<id>",
  "kind": "ship" | "scout" | null,
  "project": "<absolute project path>" | null,
  "mode": "no-mistakes" | "direct-PR" | "local-only" | null,
  "yolo": "on" | "off" | null,
  "dispatches": [
    {
      "at": "<UTC ISO-8601, Z>",     when this checkpoint ran
      "relaunch": false | true,      true when spawn ran with --relaunch
      "spawn_gen": "<meta spawn_gen>",
      "harness": "<meta harness>",
      "model": "<meta model>",
      "effort": "<meta effort>",
      "backend": "<meta backend, tmux when absent>",
      "worktree": "<meta worktree>",
      "window": "<meta window>"
    }
  ],
  "cleanup": null | {
    "at": "<UTC ISO-8601, Z>",
    "status_log": {
      "present": true | false,
      "path": "<state/<id>.status>",
      "last_modified": "<UTC>" | null,   mtime = time of the newest append
      "events": [{"seq": 1, "state": "working", "note": "..."}]
    },
    "no_mistakes": {
      "queried": true | false,
      "reason": "<why not queried, or how the run was matched>",
      "branch": "<worktree branch>" | null,
      "runs": [{"run_id": "...", "branch": "...", "status": "...", "outcome": "..." | null, "head_sha": "..." | null}]
    },
    "session_logs": [
      {"harness": "claude" | "codex", "path": "<jsonl>", "first_at": "<UTC>" | null, "last_at": "<UTC>" | null}
    ],
    "session_logs_reason": "<how they were matched, or why none>",
    "pr": "<https url>" | null
  }
}

Status lines (`<state>: <note>`) carry no per-line timestamp, so `events` records
order only; `last_modified` is the one time the log gives. The builder says so
rather than inventing per-event times.

no-mistakes run ids are ULIDs; their first 10 characters encode the run's start
time in milliseconds, which is how the builder places a run on the timeline. Step
durations come from `no-mistakes axi status --run <id>` at view time, so a run
whose ledger entry is gone reports "step durations unavailable" instead of zero.

Builder output (build_timeline)
-------------------------------
Returns a dict the console formats with format_timeline():
  status:     "missing" | "partial" | "live" | "finished"
  message:    one line for the missing/partial cases
  phases:     [{"name", "seconds", "detail" | None}] in timeline order
  elapsed_seconds, accounted_seconds, unaccounted_seconds, tolerance_seconds
  biggest:    {"name", "seconds", "detail"} | None
  sessions:   [{"harness", "path", "turns", "output_tokens", "peak_context", "window", "model"}]
  runs:       [{"run_id", "start", "seconds", "steps", "outcome", "error"}]
  missing:    [<plain-English line per source that could not be read>]

Phases are consecutive, non-overlapping spans between dispatch and cleanup (or
now, for a live task): startup, working, each validation run and the gap
before it, work after validation, and the wait for merge and cleanup. Their
sum plus `unaccounted_seconds` equals `elapsed_seconds` exactly; the stated
tolerance (TOLERANCE_FRACTION of elapsed, at least TOLERANCE_FLOOR_SECONDS) is
what "phases add up to the real elapsed time" means, because run starts, session
timestamps, and file mtimes come from different clocks.

CLI (used by bin/fm-task-timeline.sh; see its header for the shell contract):
  fm_task_timeline.py checkpoint dispatch <task-id> [--relaunch]
  fm_task_timeline.py checkpoint cleanup <task-id>
  fm_task_timeline.py build <task-id> [--json]

Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE resolve the home the
same way the shell scripts do; HOME locates ~/.claude and ~/.codex;
FM_TIMELINE_NM_TIMEOUT (seconds, default 10) bounds every no-mistakes call.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

BIN_DIR = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("fm_bridge_snapshot", BIN_DIR / "fm_bridge_snapshot.py")
snap = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(snap)

SCHEMA = "fm-task-timeline.v1"
RECORD_NAME = "timeline.json"
NM_TIMEOUT = float(os.environ.get("FM_TIMELINE_NM_TIMEOUT", "10"))
SESSION_LOG_SLACK_SECONDS = 300
TOLERANCE_FRACTION = 0.02
TOLERANCE_FLOOR_SECONDS = 60
STATUS_LINE = re.compile(r"^([a-z][a-z-]*):\s*(.*)$")
ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


# --- home resolution ----------------------------------------------------------


def home_paths(fm_home: str | None = None) -> dict[str, Path]:
    root = Path(fm_home or os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or BIN_DIR.parent)
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or root / "state")
    data = Path(os.environ.get("FM_DATA_OVERRIDE") or root / "data")
    return {"home": root, "state": state, "data": data}


def record_path(data: Path, task_id: str) -> Path:
    return data / task_id / RECORD_NAME


# --- time helpers ---------------------------------------------------------------


def parse_utc(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def seconds_between(start: dt.datetime | None, end: dt.datetime | None) -> float | None:
    if start is None or end is None:
        return None
    return (end - start).total_seconds()


def ulid_start(run_id: str | None) -> dt.datetime | None:
    """Decode the millisecond timestamp a ULID's first 10 characters carry."""
    if not run_id or len(run_id) < 10:
        return None
    value = 0
    for ch in run_id[:10].upper():
        idx = ULID_ALPHABET.find(ch)
        if idx < 0:
            return None
        value = value * 32 + idx
    try:
        return dt.datetime.fromtimestamp(value / 1000.0, dt.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def format_duration(seconds: float | None) -> str:
    if seconds is None:
        return "unknown"
    total = int(round(seconds))
    sign = "-" if total < 0 else ""
    total = abs(total)
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{sign}{hours}h {minutes:02d}m"
    if minutes:
        return f"{sign}{minutes}m {secs:02d}s"
    return f"{sign}{secs}s"


def format_stamp(value: str | None) -> str:
    parsed = parse_utc(value)
    return parsed.strftime("%Y-%m-%d %H:%MZ") if parsed else "unknown"


# --- record I/O -------------------------------------------------------------------


def load_record(path: Path) -> dict[str, Any] | None:
    try:
        text = path.read_text()
    except OSError:
        return None
    try:
        data = json.loads(text)
    except ValueError:
        return None
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        return None
    return data


def write_record(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def new_record(task_id: str, meta: dict[str, str]) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "task_id": task_id,
        "kind": meta.get("kind") or None,
        "project": meta.get("project") or None,
        "mode": meta.get("mode") or None,
        "yolo": meta.get("yolo") or None,
        "dispatches": [],
        "cleanup": None,
    }


# --- source capture ------------------------------------------------------------


def git_branch(worktree: str | None) -> str | None:
    if not worktree or not os.path.isdir(worktree):
        return None
    out, source = snap.run_source("git-branch", ["git", "-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"], timeout=5.0)
    if not source["ok"] or not out:
        return None
    branch = out.strip()
    return branch or None


def status_events(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"present": False, "path": str(path), "last_modified": None, "events": []}
    try:
        stat = path.stat()
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return result
    result["present"] = True
    result["last_modified"] = snap.to_utc(stat.st_mtime)
    seq = 0
    for line in lines:
        line = line.rstrip()
        if not line:
            continue
        seq += 1
        match = STATUS_LINE.match(line)
        if match:
            result["events"].append({"seq": seq, "state": match.group(1), "note": snap.truncate(match.group(2), 400)})
        else:
            result["events"].append({"seq": seq, "state": None, "note": snap.truncate(line, 400)})
    return result


def parse_run_status(text: str | None) -> dict[str, Any] | None:
    parsed = snap.parse_no_mistakes_status(text)
    if not parsed or not parsed.get("run_id"):
        return None
    outcome = head_sha = None
    for line in (text or "").splitlines():
        stripped = line.strip()
        if stripped.startswith("outcome:"):
            outcome = stripped.split(":", 1)[1].strip().strip('"') or None
        elif stripped.startswith("head_sha:"):
            head_sha = stripped.split(":", 1)[1].strip().strip('"') or None
    parsed["outcome"] = outcome
    parsed["head_sha"] = head_sha
    return parsed


def capture_no_mistakes(worktree: str | None, mode: str | None) -> dict[str, Any]:
    result: dict[str, Any] = {"queried": False, "reason": None, "branch": None, "runs": []}
    if not worktree or not os.path.isdir(worktree):
        result["reason"] = "worktree not present, so no run could be matched"
        return result
    branch = git_branch(worktree)
    result["branch"] = branch
    out, source = snap.run_source("no-mistakes", ["no-mistakes", "axi", "status"], cwd=worktree, timeout=NM_TIMEOUT)
    if not source["ok"] and out is None:
        result["reason"] = f"no-mistakes status unavailable: {source['error']}"
        return result
    result["queried"] = True
    run = parse_run_status(out)
    if run is None:
        if not source["ok"]:
            result["reason"] = f"no-mistakes status failed: {source['error']}"
        elif mode == "direct-PR":
            result["reason"] = "no pipeline run: this task shipped direct-PR"
        else:
            result["reason"] = "no-mistakes axi status found no run for this worktree"
        return result
    if branch and run.get("branch") and run["branch"] != branch:
        result["reason"] = f"newest run {run['run_id']} is on branch {run['branch']}, not this task's {branch}; not attributed"
        return result
    result["reason"] = f"no-mistakes axi status in the worktree, branch {branch or 'unknown'}"
    result["runs"].append({
        "run_id": run["run_id"],
        "branch": run.get("branch"),
        "status": run.get("status"),
        "outcome": run.get("outcome"),
        "head_sha": run.get("head_sha"),
    })
    return result


def session_activity(path: str, harness: str) -> dict[str, Any]:
    """Token usage and activity window of one Claude or Codex session log."""
    info: dict[str, Any] = {
        "harness": harness,
        "path": path,
        "turns": 0,
        "output_tokens": 0,
        "peak_context": None,
        "last_context": None,
        "window": None,
        "model": None,
        "first_at": None,
        "last_at": None,
        "cwd_match": None,
    }
    try:
        handle = open(path, errors="replace")
    except OSError as exc:
        info["error"] = str(exc)
        return info
    with handle:
        for line in handle:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(obj, dict):
                continue
            stamp = snap.to_utc(obj.get("timestamp"))
            if harness == "claude":
                msg = obj.get("message")
                if not isinstance(msg, dict) or msg.get("role") != "assistant":
                    continue
                usage = msg.get("usage")
                if not isinstance(usage, dict):
                    continue
                context = sum(int(usage.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                info["turns"] += 1
                info["output_tokens"] += int(usage.get("output_tokens") or 0)
                info["last_context"] = context
                info["peak_context"] = max(info["peak_context"] or 0, context)
                info["model"] = msg.get("model") or info["model"]
                info["window"] = snap.CLAUDE_WINDOWS.get(str(info["model"])) or info["window"]
            elif harness == "codex":
                payload = obj.get("payload")
                if not isinstance(payload, dict):
                    continue
                if obj.get("type") == "session_meta" and payload.get("cwd"):
                    info["cwd"] = payload.get("cwd")
                if payload.get("type") == "task_started":
                    info["window"] = payload.get("model_context_window") or info["window"]
                if payload.get("type") != "token_count":
                    continue
                token_info = payload.get("info") or {}
                last = token_info.get("last_token_usage") or {}
                aggregate = token_info.get("total_token_usage") or {}
                context = last.get("input_tokens")
                info["turns"] += 1
                if isinstance(context, int):
                    info["last_context"] = context
                    info["peak_context"] = max(info["peak_context"] or 0, context)
                if isinstance(aggregate.get("output_tokens"), int):
                    info["output_tokens"] = aggregate["output_tokens"]
                info["window"] = token_info.get("model_context_window") or info["window"]
            else:
                continue
            if stamp:
                info["first_at"] = info["first_at"] or stamp
                info["last_at"] = stamp
    return info


def _mtime_after(path: str, since: dt.datetime | None) -> bool:
    if since is None:
        return True
    try:
        return os.path.getmtime(path) >= since.timestamp() - SESSION_LOG_SLACK_SECONDS
    except OSError:
        return False


def capture_session_logs(worktree: str | None, harness: str | None, since: dt.datetime | None) -> tuple[list[dict[str, Any]], str]:
    harness = (harness or "").lower()
    if not worktree:
        return [], "no worktree recorded, so no session log could be matched"
    logs: list[dict[str, Any]] = []
    if harness == "claude":
        directory = snap.claude_dir_for_path(worktree)
        candidates = [p for p in snap.newest_files(str(directory / "*.jsonl")) if _mtime_after(p, since)]
        reason = f"Claude session logs under {directory} modified since dispatch"
    elif harness == "codex":
        wanted = os.path.realpath(worktree)
        candidates = []
        for path in snap.newest_files(str(Path.home() / ".codex" / "sessions" / "**" / "*.jsonl")):
            if not _mtime_after(path, since):
                continue
            activity = session_activity(path, "codex")
            cwd = activity.get("cwd")
            if cwd and os.path.realpath(str(cwd)) == wanted:
                candidates.append(path)
        reason = "Codex session logs whose cwd is the worktree, modified since dispatch"
    else:
        return [], f"session logs are not read for harness {harness or 'unknown'} (Claude and Codex only)"
    for path in candidates:
        activity = session_activity(path, harness)
        if activity["turns"] == 0:
            continue
        logs.append({"harness": harness, "path": path, "first_at": activity["first_at"], "last_at": activity["last_at"]})
    if not logs:
        reason = f"no session log with assistant activity matched ({reason})"
    logs.sort(key=lambda entry: entry.get("first_at") or "")
    return logs, reason


def capture_cleanup(paths: dict[str, Path], task_id: str, meta: dict[str, str], record: dict[str, Any], now: str | None = None) -> dict[str, Any]:
    """Everything cleanup would otherwise lose, read from the still-live sources."""
    dispatches = record.get("dispatches") or []
    first_dispatch = parse_utc(dispatches[0].get("at")) if dispatches else parse_utc(snap.started_at_from_meta(meta, str(paths["state"] / f"{task_id}.meta")))
    worktree = meta.get("worktree") or (dispatches[-1].get("worktree") if dispatches else None)
    harness = meta.get("harness") or (dispatches[-1].get("harness") if dispatches else None)
    logs, logs_reason = capture_session_logs(worktree, harness, first_dispatch)
    return {
        "at": now or snap.utc_now(),
        "status_log": status_events(paths["state"] / f"{task_id}.status"),
        "no_mistakes": capture_no_mistakes(worktree, record.get("mode") or meta.get("mode")),
        "session_logs": logs,
        "session_logs_reason": logs_reason,
        "pr": meta.get("pr") or None,
    }


# --- checkpoints ------------------------------------------------------------------


def checkpoint_dispatch(paths: dict[str, Path], task_id: str, relaunch: bool) -> Path:
    meta_path = paths["state"] / f"{task_id}.meta"
    meta = snap.meta_from_path(str(meta_path))
    if not meta:
        raise RuntimeError(f"task metadata not readable at {meta_path}")
    path = record_path(paths["data"], task_id)
    record = load_record(path) or new_record(task_id, meta)
    for key in ("kind", "project", "mode", "yolo"):
        if meta.get(key):
            record[key] = meta[key]
    record["dispatches"].append({
        "at": snap.utc_now(),
        "relaunch": bool(relaunch),
        "spawn_gen": meta.get("spawn_gen") or None,
        "harness": meta.get("harness") or None,
        "model": meta.get("model") or None,
        "effort": meta.get("effort") or None,
        "backend": meta.get("backend") or "tmux",
        "worktree": meta.get("worktree") or None,
        "window": meta.get("window") or None,
    })
    write_record(path, record)
    return path


def checkpoint_cleanup(paths: dict[str, Path], task_id: str) -> Path:
    meta_path = paths["state"] / f"{task_id}.meta"
    meta = snap.meta_from_path(str(meta_path))
    if not meta:
        raise RuntimeError(f"task metadata not readable at {meta_path}")
    path = record_path(paths["data"], task_id)
    record = load_record(path) or new_record(task_id, meta)
    for key in ("kind", "project", "mode", "yolo"):
        if meta.get(key) and not record.get(key):
            record[key] = meta[key]
    record["cleanup"] = capture_cleanup(paths, task_id, meta, record)
    write_record(path, record)
    return path


# --- builder ----------------------------------------------------------------------


def run_details(run: dict[str, Any]) -> dict[str, Any]:
    run_id = run.get("run_id")
    detail: dict[str, Any] = {
        "run_id": run_id,
        "branch": run.get("branch"),
        "outcome": run.get("outcome") or run.get("status"),
        "start": None,
        "seconds": None,
        "steps": [],
        "error": None,
    }
    start = ulid_start(run_id)
    detail["start"] = snap.to_utc(start.timestamp()) if start else None
    out, source = snap.run_source("no-mistakes", ["no-mistakes", "axi", "status", "--run", str(run_id)], timeout=NM_TIMEOUT)
    parsed = parse_run_status(out) if (source["ok"] or out) else None
    if parsed is None:
        detail["error"] = f"step durations unavailable ({source['error'] or 'run not reported by no-mistakes'})"
        return detail
    detail["outcome"] = parsed.get("outcome") or parsed.get("status") or detail["outcome"]
    steps = [s for s in parsed.get("steps", []) if s.get("duration_ms") is not None]
    detail["steps"] = [{"step": s["step"], "status": s["status"], "seconds": s["duration_ms"] / 1000.0} for s in steps]
    detail["seconds"] = sum(s["seconds"] for s in detail["steps"])
    if detail["start"] is None:
        detail["error"] = "run start unknown (run id is not a ULID), so the run is not placed on the timeline"
    return detail


def compute_phases(
    t0: dt.datetime,
    t_end: dt.datetime,
    sessions: list[dict[str, Any]],
    runs: list[dict[str, Any]],
    status_last_modified: dt.datetime | None,
    finished: bool,
) -> dict[str, Any]:
    """Consecutive spans from t0 to t_end; sum + unaccounted == elapsed exactly."""
    phases: list[dict[str, Any]] = []
    firsts = [parse_utc(s.get("first_at")) for s in sessions]
    lasts = [parse_utc(s.get("last_at")) for s in sessions]
    first_activity = min((f for f in firsts if f), default=None)
    last_activity = max((l for l in lasts if l), default=None)
    cursor = t0

    def add(name: str, end: dt.datetime, detail: str | None = None) -> None:
        nonlocal cursor
        if end <= cursor:
            return
        phases.append({"name": name, "seconds": (end - cursor).total_seconds(), "detail": detail})
        cursor = end

    if first_activity and first_activity > cursor:
        add("startup (dispatch to first agent turn)", first_activity)
    placed = [r for r in runs if r.get("start") and r.get("seconds") is not None]
    placed.sort(key=lambda r: r["start"])
    for index, run in enumerate(placed, start=1):
        start = parse_utc(run["start"])
        if start is None:
            continue
        if index == 1:
            add("working before validation", start)
        else:
            add(f"fixing between validation runs {index - 1} and {index}", start)
        run_end = start + dt.timedelta(seconds=run["seconds"])
        steps = ", ".join(f"{s['step']} {format_duration(s['seconds'])}" for s in run["steps"] if s["seconds"] >= 1) or "no timed steps"
        label = f"validation run {index} ({run['outcome'] or 'unknown'}, {str(run['run_id'])[:10]})"
        if run_end > t_end:
            # The run outlived the window we are summing; count only what fits and say so.
            add(label, t_end, steps + f"; run extends {format_duration((run_end - t_end).total_seconds())} past the window")
        else:
            add(label, run_end, steps)
    work_end = max((t for t in (last_activity, status_last_modified) if t), default=None)
    if work_end and work_end > t_end:
        work_end = t_end
    if work_end and work_end > cursor:
        if placed:
            add("working after validation", work_end)
        elif sessions:
            add("working (agent session span)", work_end)
        else:
            add("working (until the last status append; no session log found)", work_end)
    if t_end > cursor:
        add("waiting for merge and cleanup" if finished else "since last recorded activity", t_end)
    elapsed = (t_end - t0).total_seconds()
    accounted = sum(p["seconds"] for p in phases)
    return {
        "phases": phases,
        "elapsed_seconds": elapsed,
        "accounted_seconds": accounted,
        "unaccounted_seconds": elapsed - accounted,
        "tolerance_seconds": max(TOLERANCE_FLOOR_SECONDS, TOLERANCE_FRACTION * elapsed),
    }


def biggest_phase(phases: list[dict[str, Any]], runs: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not phases:
        return None
    top = max(phases, key=lambda p: p["seconds"])
    detail = None
    if top["name"].startswith("validation run"):
        index = int(top["name"].split()[2])
        placed = sorted((r for r in runs if r.get("start") and r.get("seconds") is not None), key=lambda r: r["start"])
        if 0 < index <= len(placed) and placed[index - 1]["steps"]:
            step = max(placed[index - 1]["steps"], key=lambda s: s["seconds"])
            detail = f"{step['step']} step, {format_duration(step['seconds'])}"
    return {"name": top["name"], "seconds": top["seconds"], "detail": detail}


def build_timeline(fm_home: str | None, task_id: str, now: dt.datetime | None = None) -> dict[str, Any]:
    paths = home_paths(fm_home)
    now = now or dt.datetime.now(dt.timezone.utc)
    record = load_record(record_path(paths["data"], task_id))
    meta = snap.meta_from_path(str(paths["state"] / f"{task_id}.meta"))
    result: dict[str, Any] = {
        "task_id": task_id,
        "status": "missing",
        "message": None,
        "record_path": str(record_path(paths["data"], task_id)),
        "kind": None,
        "mode": None,
        "dispatched_at": None,
        "end_at": None,
        "relaunches": None,
        "pr": None,
        "phases": [],
        "elapsed_seconds": None,
        "accounted_seconds": None,
        "unaccounted_seconds": None,
        "tolerance_seconds": None,
        "biggest": None,
        "sessions": [],
        "runs": [],
        "status_events": [],
        "status_last_modified": None,
        "missing": [],
    }
    if record is None and not meta:
        result["message"] = (
            f"no timeline record for {task_id}: it finished before timeline records shipped, "
            "was never dispatched from this home, or is not a task"
        )
        return result

    record = record or new_record(task_id, meta)
    result["kind"] = record.get("kind") or meta.get("kind")
    result["mode"] = record.get("mode") or meta.get("mode")
    dispatches = record.get("dispatches") or []
    result["relaunches"] = max(0, len(dispatches) - 1) if dispatches else None
    dispatched_at = parse_utc(dispatches[0]["at"]) if dispatches else None
    if dispatched_at is None and meta:
        dispatched_at = parse_utc(snap.started_at_from_meta(meta, str(paths["state"] / f"{task_id}.meta")))
        if dispatched_at:
            result["missing"].append("no dispatch checkpoint: dispatch time inferred from the task record's incarnation token")
    if dispatched_at is None:
        result["missing"].append("dispatch time unknown: no dispatch checkpoint and no readable task record")

    cleanup = record.get("cleanup")
    if cleanup:
        result["status"] = "finished"
        snapshot = cleanup
        finished = True
    elif meta:
        result["status"] = "live"
        snapshot = capture_cleanup(paths, task_id, meta, record, now=snap.to_utc(now.timestamp()))
        finished = False
    else:
        result["status"] = "partial"
        result["message"] = (
            f"{task_id} was dispatched {format_stamp(dispatches[0]['at']) if dispatches else 'at an unknown time'} "
            "but its cleanup checkpoint never ran, so its status events, validation runs, and session logs were not captured"
        )
        result["dispatched_at"] = snap.to_utc(dispatched_at.timestamp()) if dispatched_at else None
        return result

    result["pr"] = snapshot.get("pr") or meta.get("pr") or None
    status_log = snapshot.get("status_log") or {}
    result["status_events"] = status_log.get("events") or []
    result["status_last_modified"] = status_log.get("last_modified")
    if not status_log.get("present"):
        result["missing"].append("no status log was present at capture time")

    nm = snapshot.get("no_mistakes") or {}
    for run in nm.get("runs") or []:
        result["runs"].append(run_details(run))
    if not nm.get("runs"):
        result["missing"].append(nm.get("reason") or "no validation run recorded")
    for run in result["runs"]:
        if run.get("error"):
            result["missing"].append(f"run {run['run_id']}: {run['error']}")

    for entry in snapshot.get("session_logs") or []:
        activity = session_activity(entry["path"], entry.get("harness") or "")
        if activity.get("error"):
            result["missing"].append(f"session log {entry['path']}: {activity['error']}")
            activity["first_at"] = activity.get("first_at") or entry.get("first_at")
            activity["last_at"] = activity.get("last_at") or entry.get("last_at")
        result["sessions"].append(activity)
    if not snapshot.get("session_logs"):
        result["missing"].append(snapshot.get("session_logs_reason") or "no session log recorded")

    end_at = parse_utc(snapshot.get("at")) or now
    result["end_at"] = snap.to_utc(end_at.timestamp())
    result["dispatched_at"] = snap.to_utc(dispatched_at.timestamp()) if dispatched_at else None
    if dispatched_at is None:
        return result
    for run in result["runs"]:
        start = parse_utc(run.get("start"))
        if start and start < dispatched_at:
            result["missing"].append(f"run {run['run_id']} started {format_stamp(run['start'])}, before dispatch; not placed on the timeline")
        elif start and start > end_at:
            result["missing"].append(f"run {run['run_id']} started {format_stamp(run['start'])}, after the window; not placed on the timeline")
    for index, session in enumerate(result["sessions"], start=1):
        first = parse_utc(session.get("first_at"))
        if first and first < dispatched_at:
            result["missing"].append(f"session {index} began {format_stamp(session['first_at'])}, before dispatch; its earlier turns are not on the timeline")
    computed = compute_phases(dispatched_at, end_at, result["sessions"], result["runs"], parse_utc(result["status_last_modified"]), finished)
    result.update(computed)
    result["biggest"] = biggest_phase(result["phases"], result["runs"])
    return result


# --- formatter --------------------------------------------------------------------


def format_timeline(result: dict[str, Any]) -> str:
    task_id = result.get("task_id")
    status = result.get("status")
    if status in {"missing", "partial"}:
        lines = [result.get("message") or f"no timeline for {task_id}"]
        if status == "partial":
            lines.append(f"record: {result.get('record_path')}")
        return "\n".join(lines)
    head = f"{task_id} ({result.get('kind') or 'task'}, {result.get('mode') or 'no delivery mode'})"
    head += " - finished" if status == "finished" else " - live, so far"
    lines = [head]
    when = f"dispatched {format_stamp(result.get('dispatched_at'))}"
    when += f", {'cleaned up' if status == 'finished' else 'now'} {format_stamp(result.get('end_at'))}"
    when += f": elapsed {format_duration(result.get('elapsed_seconds'))}"
    lines.append(when)
    extras = []
    if result.get("relaunches") is not None:
        extras.append(f"relaunches: {result['relaunches']}")
    if result.get("pr"):
        extras.append(f"PR: {result['pr']}")
    if extras:
        lines.append("   ".join(extras))
    phases = result.get("phases") or []
    elapsed = result.get("elapsed_seconds") or 0
    if phases:
        lines.append(
            f"phases (sum {format_duration(result.get('accounted_seconds'))} of {format_duration(elapsed)}; "
            f"unaccounted {format_duration(result.get('unaccounted_seconds'))}, tolerance {format_duration(result.get('tolerance_seconds'))}):"
        )
        width = max(len(p["name"]) for p in phases)
        for phase in phases:
            pct = f"{(phase['seconds'] / elapsed * 100):5.1f}%" if elapsed > 0 else "     "
            lines.append(f"  {phase['name'].ljust(width)}  {format_duration(phase['seconds']).rjust(8)}  {pct}")
            if phase.get("detail"):
                lines.append(f"  {' ' * width}  {phase['detail']}")
    elif result.get("elapsed_seconds") is not None:
        lines.append(f"phases: none could be placed; all {format_duration(elapsed)} is unaccounted")
    biggest = result.get("biggest")
    if biggest:
        line = f"biggest cost: {biggest['name']}, {format_duration(biggest['seconds'])}"
        if biggest.get("detail"):
            line += f" (largest part: {biggest['detail']})"
        lines.append(line)
    sessions = result.get("sessions") or []
    if sessions:
        lines.append("tokens per session:")
        for index, session in enumerate(sessions, start=1):
            peak = session.get("peak_context")
            window = session.get("window")
            ctx = f"peak context {peak:,}" if isinstance(peak, int) else "peak context unknown"
            if isinstance(peak, int) and isinstance(window, int) and window > 0:
                ctx += f" ({peak / window * 100:.0f}% of {window:,})"
            lines.append(
                f"  {session.get('harness')} session {index}: {session.get('turns', 0)} turns, "
                f"{session.get('output_tokens', 0):,} output tokens, {ctx}"
            )
        top = max(sessions, key=lambda s: s.get("output_tokens") or 0)
        if len(sessions) > 1:
            lines.append(f"  most tokens: session {sessions.index(top) + 1} ({top.get('output_tokens', 0):,} output)")
    events = result.get("status_events") or []
    if events:
        stamp = format_stamp(result.get("status_last_modified"))
        lines.append(f"status events (order only, no per-line timestamps; last append {stamp}):")
        for event in events:
            state = event.get("state") or "?"
            lines.append(f"  {event.get('seq')}. {state}: {snap.truncate(event.get('note'), 120)}")
    missing = result.get("missing") or []
    if missing:
        lines.append("not available:")
        lines.extend(f"  - {item}" for item in missing)
    return "\n".join(lines)


# --- CLI ----------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="fm-task-timeline.v1 checkpoints and builder")
    sub = parser.add_subparsers(dest="command", required=True)
    cp = sub.add_parser("checkpoint")
    cp.add_argument("stage", choices=["dispatch", "cleanup"])
    cp.add_argument("task_id")
    cp.add_argument("--relaunch", action="store_true")
    build = sub.add_parser("build")
    build.add_argument("task_id")
    build.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    paths = home_paths()
    if args.command == "checkpoint":
        try:
            if args.stage == "dispatch":
                path = checkpoint_dispatch(paths, args.task_id, args.relaunch)
            else:
                path = checkpoint_cleanup(paths, args.task_id)
        except Exception as exc:  # noqa: BLE001 - a checkpoint must never block spawn or teardown.
            print(f"warning: timeline {args.stage} checkpoint for {args.task_id} not written: {exc}", file=sys.stderr)
            return 0
        print(f"timeline {args.stage} checkpoint written: {path}")
        return 0
    result = build_timeline(None, args.task_id)
    if args.json:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print(format_timeline(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
