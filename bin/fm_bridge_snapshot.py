#!/usr/bin/env python3
"""Read-only bridge snapshot collector for fm-bridge-snapshot.sh."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import glob
import json
import os
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


SCHEMA = "fm-bridge-snapshot.v1"
SOURCE_TIMEOUT = float(os.environ.get("FM_BRIDGE_SOURCE_TIMEOUT", "3"))
LOG_FILE_CAP = int(os.environ.get("FM_BRIDGE_LOG_FILE_CAP", "80"))
CLAUDE_WINDOWS = {
    "claude-sonnet-4": 200000,
    "claude-opus-4": 200000,
}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def to_utc(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return dt.datetime.fromtimestamp(value, dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return text
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return None


def elapsed_since(value: str | None) -> int | None:
    if not value:
        return None
    try:
        started = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if started.tzinfo is None:
        started = started.replace(tzinfo=dt.timezone.utc)
    return max(0, int((dt.datetime.now(dt.timezone.utc) - started.astimezone(dt.timezone.utc)).total_seconds()))


def started_at_from_meta(meta: dict[str, str], meta_path: str | None) -> str | None:
    spawn_gen = meta.get("spawn_gen") or ""
    match = re.match(r"^s(\d+)(?:\.|$)", spawn_gen)
    if match:
        return to_utc(int(match.group(1)))
    if meta_path:
        try:
            return to_utc(Path(meta_path).stat().st_mtime)
        except OSError:
            pass
    return None


def elapsed_ms(start: float) -> int:
    return int(round((time.monotonic() - start) * 1000))


def truncate(value: Any, limit: int) -> str:
    text = "" if value is None else str(value)
    return text if len(text) <= limit else text[: max(0, limit - 1)] + "…"


def run_source(name: str, argv: list[str], cwd: str | None = None, timeout: float = SOURCE_TIMEOUT, env: dict[str, str] | None = None) -> tuple[str | None, dict[str, Any]]:
    start = time.monotonic()
    record = {"name": name, "ok": False, "elapsed_ms": 0, "error": None}
    try:
        proc = subprocess.run(
            argv,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except FileNotFoundError as exc:
        record["elapsed_ms"] = elapsed_ms(start)
        record["error"] = f"not found: {exc.filename}"
        return None, record
    except subprocess.TimeoutExpired:
        record["elapsed_ms"] = elapsed_ms(start)
        record["error"] = f"timed out after {timeout:g}s"
        return None, record
    record["elapsed_ms"] = elapsed_ms(start)
    if proc.returncode != 0:
        err = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
        record["error"] = truncate(err, 240)
        return proc.stdout, record
    record["ok"] = True
    return proc.stdout, record


def run_memory_source(name: str, func, timeout: float = SOURCE_TIMEOUT) -> tuple[Any, dict[str, Any]]:
    start = time.monotonic()
    record = {"name": name, "ok": False, "elapsed_ms": 0, "error": None}
    previous_handler = signal.getsignal(signal.SIGALRM)
    def alarm_handler(_signum, _frame):
        raise TimeoutError()

    signal.signal(signal.SIGALRM, alarm_handler)
    previous_timer = signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        value = func()
    except TimeoutError:
        record["elapsed_ms"] = elapsed_ms(start)
        record["error"] = f"timed out after {timeout:g}s"
        return None, record
    except Exception as exc:  # noqa: BLE001 - source isolation is deliberate.
        record["elapsed_ms"] = elapsed_ms(start)
        record["error"] = truncate(str(exc), 240)
        return None, record
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_timer[0] > 0:
            signal.setitimer(signal.ITIMER_REAL, previous_timer[0], previous_timer[1])
    record["ok"] = True
    record["elapsed_ms"] = elapsed_ms(start)
    return value, record


def parse_json(text: str | None) -> Any | None:
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def parse_source_json(text: str | None, source: dict[str, Any], label: str) -> Any | None:
    value = parse_json(text)
    if value is None and source["ok"]:
        source["ok"] = False
        source["error"] = f"{label} returned invalid JSON"
    return value


def meta_from_path(path: str | None) -> dict[str, str]:
    if not path:
        return {}
    out: dict[str, str] = {}
    try:
        for line in Path(path).read_text(errors="replace").splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
    except OSError:
        return out
    return out


def path_value(item: Any) -> str | None:
    if isinstance(item, dict):
        value = item.get("path")
        return str(value) if value else None
    if item:
        return str(item)
    return None


def last_status_from_task(task: dict[str, Any]) -> dict[str, Any] | None:
    event = (((task.get("paths") or {}).get("status_log") or {}).get("last_event"))
    if not isinstance(event, dict):
        return None
    raw = event.get("raw")
    note = event.get("note")
    state = event.get("state")
    at = event.get("at") or event.get("observed_at")
    return {"state": state, "note": truncate(note or raw or "", 200), "at": to_utc(at)}


def backlog_counts(fleet: dict[str, Any] | None) -> dict[str, int]:
    counts = {"in_flight": 0, "held": 0, "ready": 0, "blocked": 0}
    if not fleet:
        return counts
    for record in ((fleet.get("backlog") or {}).get("records") or []):
        if not isinstance(record, dict):
            continue
        state = record.get("state")
        if state == "in_flight":
            counts["in_flight"] += 1
        elif state == "queued":
            if record.get("unresolved_blocker_ids") or record.get("blocked_by_ids") or record.get("blocked_reason"):
                counts["blocked"] += 1
            elif record.get("hold_reason") or record.get("hold_kind") or record.get("hold_bucket"):
                counts["held"] += 1
            else:
                counts["ready"] += 1
    return counts


def map_runway(status: Any) -> str:
    text = str(status or "unknown")
    return text if text in {"through_reset", "projected_exhaustion", "exhausted_now"} else "unknown"


def quota_snapshot(raw: dict[str, Any] | None, source_ok: bool, source_error: str | None) -> dict[str, Any]:
    quota = {"ok": bool(source_ok and raw), "error": source_error, "observed_at": utc_now(), "providers": [], "attention": []}
    if not isinstance(raw, dict):
        return quota
    quota["observed_at"] = to_utc(raw.get("generatedAt")) or quota["observed_at"]
    for provider in raw.get("providers") or []:
        if not isinstance(provider, dict):
            continue
        name = provider.get("provider")
        state = provider.get("state") or {}
        if isinstance(state, dict) and state.get("status") not in (None, "fresh"):
            quota["attention"].append({"provider": name, "kind": str(state.get("status")), "detail": truncate(state.get("detail") or state.get("reason") or state, 200)})
        windows = provider.get("windows") or []
        window_by_id = {w.get("id"): w for w in windows if isinstance(w, dict)}
        effective = (((provider.get("quotaSemantics") or {}).get("effectiveAvailability")) or [])
        for item in effective:
            if not isinstance(item, dict):
                continue
            limiting = item.get("limitingWindowIds") or []
            limited_by = limiting[0] if limiting else None
            window = window_by_id.get(limited_by, {})
            runway = item.get("runway") if isinstance(item.get("runway"), dict) else {}
            selection = item.get("selection") if isinstance(item.get("selection"), dict) else {}
            quota["providers"].append({
                "provider": name,
                "scope": item.get("scope"),
                "percent_remaining": item.get("effectivePercentRemaining"),
                "spend_priority": selection.get("spendPriority"),
                "runway": map_runway(runway.get("status")),
                "limited_by": limited_by,
                "resets_at": to_utc(window.get("resetsAt") if isinstance(window, dict) else None),
                "projected_exhausted_at": to_utc(runway.get("projectedExhaustedAt") or runway.get("exhaustsAt")),
            })
    return quota


def parse_no_mistakes_status(text: str | None) -> dict[str, Any] | None:
    if not text:
        return None
    lines = text.splitlines()
    current_runs = next((int(line.split(":", 1)[1].strip()) for line in lines if line.startswith("runs_on_current_branch:") and line.split(":", 1)[1].strip().isdigit()), None)
    if current_runs == 0:
        return None
    run_line = None
    for line in lines:
        if "current_run:" in line or "other_branch_run:" in line:
            run_line = line.strip()
            break
    if not run_line and not any(l.startswith("runs_on_current_branch:") for l in lines):
        return None
    data: dict[str, Any] = {"run_id": None, "branch": None, "status": None, "current_step": None, "steps": []}
    for line in lines:
        stripped = line.strip()
        for key, field in (("id:", "run_id"), ("branch:", "branch"), ("status:", "status")):
            if stripped.startswith(key):
                data[field] = stripped.split(":", 1)[1].strip().strip('"')
    step_header = next((i for i, line in enumerate(lines) if re.match(r"\s*steps\[\d+\]", line)), None)
    if step_header is not None:
        for line in lines[step_header + 1 :]:
            stripped = line.strip()
            if not stripped or not re.match(r"[A-Za-z0-9_-]+,", stripped):
                if stripped.startswith("outcome:"):
                    break
                continue
            parts = [part.strip() for part in stripped.split(",")]
            if len(parts) < 4:
                continue
            findings = re.match(r"(\d+)", parts[2])
            duration = re.match(r"(\d+)", parts[3])
            data["steps"].append({
                "step": parts[0],
                "status": parts[1],
                "findings": int(findings.group(1)) if findings else None,
                "duration_ms": int(duration.group(1)) if duration else None,
            })
    for step in data["steps"]:
        if step.get("status") not in {"completed", "skipped"}:
            data["current_step"] = step.get("step")
            break
    return data


def claude_dir_for_path(path: str) -> Path:
    return Path.home() / ".claude" / "projects" / path.replace("/", "-").replace(".", "-")


def newest_files(pattern: str, cap: int = LOG_FILE_CAP) -> list[str]:
    files = [p for p in glob.glob(pattern, recursive=True) if os.path.isfile(p)]
    files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return files[:cap]


def claude_context(paths: list[str]) -> tuple[dict[str, Any] | None, dict[str, Any] | None, str]:
    for base in paths:
        directory = claude_dir_for_path(base)
        for path in newest_files(str(directory / "*.jsonl")):
            current = None
            peak = 0
            output = 0
            model = None
            measured_at = None
            try:
                handle = open(path, errors="replace")
            except OSError:
                continue
            with handle:
                for line in handle:
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    msg = obj.get("message") if isinstance(obj, dict) else None
                    if not isinstance(msg, dict) or msg.get("role") != "assistant":
                        continue
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    context_tokens = sum(int(usage.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                    current = context_tokens
                    peak = max(peak, context_tokens)
                    output += int(usage.get("output_tokens") or 0)
                    model = msg.get("model") or model
                    measured_at = to_utc(obj.get("timestamp")) or measured_at
            if current is None:
                continue
            window = CLAUDE_WINDOWS.get(str(model))
            percent = round((current / window) * 100, 1) if window else None
            return (
                {"current_tokens": current, "peak_tokens": peak, "window_tokens": window, "percent": percent, "session_log": path, "measured_at": measured_at or utc_now()},
                {"total": None, "output": output},
                "claude assistant usage in newest matching session log",
            )
    return None, None, "no matching Claude assistant usage log"


def codex_context(paths: list[str]) -> tuple[dict[str, Any] | None, dict[str, Any] | None, str]:
    wanted = {os.path.realpath(p) for p in paths if p}
    for path in newest_files(str(Path.home() / ".codex" / "sessions" / "**" / "*.jsonl")):
        cwd_match = False
        current = peak = window = total = output = None
        measured_at = None
        try:
            handle = open(path, errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                payload = obj.get("payload") if isinstance(obj, dict) else None
                if not isinstance(payload, dict):
                    continue
                if obj.get("type") == "session_meta":
                    session_cwd = payload.get("cwd")
                    if session_cwd and os.path.realpath(str(session_cwd)) in wanted:
                        cwd_match = True
                state = payload.get("state") if isinstance(payload.get("state"), dict) else None
                session_cwd = payload.get("cwd") or (state or {}).get("cwd")
                if session_cwd and os.path.realpath(str(session_cwd)) in wanted:
                    cwd_match = True
                if payload.get("type") == "task_started":
                    window = payload.get("model_context_window") or window
                if payload.get("type") == "token_count":
                    info = payload.get("info") or {}
                    last = info.get("last_token_usage") or {}
                    aggregate = info.get("total_token_usage") or {}
                    current = last.get("input_tokens")
                    if isinstance(current, int):
                        peak = max(peak or 0, current)
                    window = info.get("model_context_window") or window
                    total = aggregate.get("total_tokens") or total
                    output = aggregate.get("output_tokens") or output
                    measured_at = to_utc(obj.get("timestamp")) or measured_at
        if not cwd_match:
            continue
        if current is None:
            return None, None, f"matching Codex session has no token_count: {path}"
        percent = round((current / window) * 100, 1) if isinstance(window, int) and window > 0 else None
        return (
            {"current_tokens": current, "peak_tokens": peak, "window_tokens": window, "percent": percent, "session_log": path, "measured_at": measured_at or utc_now()},
            {"total": total, "output": output},
            "codex token_count events in newest matching session log",
        )
    return None, None, "no matching Codex session log"


def process_fixture() -> list[dict[str, Any]] | None:
    fixture = os.environ.get("FM_BRIDGE_PROCESS_FIXTURE")
    if not fixture:
        return None
    return json.loads(Path(fixture).read_text())


def process_cwd(pid: int) -> str | None:
    out, record = run_source("lsof-cwd", ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], timeout=0.5)
    if not record["ok"] or not out:
        return None
    for line in out.splitlines():
        if line.startswith("n"):
            return line[1:]
    return None


def is_agent_process(process: dict[str, Any]) -> bool:
    command = process.get("command") or ""
    comm = os.path.basename(str(process.get("comm") or ""))
    return comm in {"claude", "codex", "opencode", "agy"} or bool(re.search(r"(^|/)(claude|codex|opencode|agy)(\s|$)", command))


def is_claude_host_helper(process: dict[str, Any]) -> bool:
    command = process.get("command") or ""
    return bool(re.search(r"\bclaude\s+(bg-pty-host|bg-spare|daemon\s+run)\b", command))


def elapsed_process_time(value: str) -> int | None:
    text = value.strip()
    if not text:
        return None
    days = 0
    if "-" in text:
        day_text, text = text.split("-", 1)
        if not day_text.isdigit():
            return None
        days = int(day_text)
    parts = text.split(":")
    if not all(part.isdigit() for part in parts):
        return None
    numbers = [int(part) for part in parts]
    if len(numbers) == 3:
        hours, minutes, seconds = numbers
    elif len(numbers) == 2:
        hours, minutes, seconds = 0, numbers[0], numbers[1]
    elif len(numbers) == 1:
        hours, minutes, seconds = 0, 0, numbers[0]
    else:
        return None
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def list_processes() -> list[dict[str, Any]]:
    fixture = process_fixture()
    if fixture is not None:
        return fixture
    out, record = run_source("ps", ["ps", "-axo", "pid=,ppid=,etime=,comm=,command="], timeout=1.5)
    if not record["ok"] or not out:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) < 5 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        process = {"pid": int(parts[0]), "ppid": int(parts[1]), "elapsed_seconds": elapsed_process_time(parts[2]), "comm": parts[3], "command": parts[4]}
        if not is_agent_process(process) or is_claude_host_helper(process):
            continue
        process["cwd"] = process_cwd(process["pid"])
        rows.append(process)
    return rows


def under(path: str | None, roots: set[str]) -> bool:
    if not path:
        return False
    real = os.path.realpath(path)
    for root in roots:
        if real == root or real.startswith(root + os.sep):
            return True
    return False


def unrecorded_agents(known_paths: set[str]) -> list[dict[str, Any]]:
    no_mistakes = os.path.realpath(str(Path.home() / ".no-mistakes"))
    processes = list_processes()
    listed_pids = {proc.get("pid") for proc in processes}
    records = []
    for proc in processes:
        command = proc.get("command") or ""
        if not is_agent_process(proc):
            continue
        if is_claude_host_helper(proc) or proc.get("ppid") in listed_pids:
            continue
        cwd = proc.get("cwd")
        if under(cwd, known_paths) or under(cwd, {no_mistakes}):
            continue
        records.append({"pid": proc.get("pid"), "command": truncate(command, 160), "elapsed_seconds": proc.get("elapsed_seconds")})
    return records


def agent_from_task(task: dict[str, Any], fm_home: str) -> dict[str, Any]:
    paths = task.get("paths") or {}
    meta_path = path_value((paths.get("meta") or {}))
    meta = meta_from_path(meta_path)
    worktree = path_value(paths.get("worktree")) or meta.get("worktree")
    home = path_value(paths.get("home")) or meta.get("home")
    current_state = task.get("current_state") or {}
    endpoint = task.get("endpoint") or {}
    backlog = task.get("backlog") if isinstance(task.get("backlog"), dict) else {}
    pr = task.get("pr") if isinstance(task.get("pr"), dict) else {}
    started_at = started_at_from_meta(meta, meta_path)
    return {
        "id": task.get("id"),
        "kind": task.get("kind"),
        "parent": meta.get("parent") or None,
        "project": task.get("project") or backlog.get("repo"),
        "harness": task.get("harness") or meta.get("harness"),
        "model": meta.get("model") or None,
        "effort": meta.get("effort") or None,
        "backend": task.get("backend") or meta.get("backend"),
        "endpoint_alive": True if endpoint.get("status") == "alive" or endpoint.get("agent_alive") == "alive" else (False if endpoint.get("status") in {"dead", "missing", "absent"} or endpoint.get("agent_alive") in {"dead", "missing"} else None),
        "current_state": current_state.get("state") if isinstance(current_state, dict) else None,
        "last_status": last_status_from_task(task),
        "started_at": started_at,
        "elapsed_seconds": elapsed_since(started_at),
        "pr": pr.get("url") or backlog.get("pr_url"),
        "worktree": worktree,
        "context": None,
        "tokens": None,
        "validation": None,
        "sources": {"context": "not measured yet", "validation": "not measured yet"},
        "_home": home,
        "_endpoint_target": endpoint.get("target"),
        "_fm_home": fm_home,
    }


def agents_from_secondmates(fleet: dict[str, Any] | None, fm_home: str) -> list[dict[str, Any]]:
    current = (fleet or {}).get("secondmate_current") or {}
    result = []
    for record in current.get("records") or []:
        if not isinstance(record, dict):
            continue
        current_state = record.get("current") or {}
        result.append({
            "id": record.get("id"),
            "kind": "secondmate",
            "parent": "primary",
            "project": None,
            "harness": None,
            "model": None,
            "effort": None,
            "backend": None,
            "endpoint_alive": None,
            "current_state": current_state.get("state") if isinstance(current_state, dict) else None,
            "last_status": None,
            "started_at": None,
            "elapsed_seconds": None,
            "pr": None,
            "worktree": None,
            "context": None,
            "tokens": None,
            "validation": None,
            "sources": {"context": "secondmate session logs are not exposed by fleet snapshot", "validation": "secondmate has no local worktree in fleet snapshot"},
            "_home": record.get("home"),
            "_endpoint_target": None,
            "_fm_home": fm_home,
        })
    return result


def primary_agent(fm_home: str) -> dict[str, Any]:
    return {
        "id": "primary",
        "kind": "primary",
        "parent": None,
        "project": fm_home,
        "harness": None,
        "model": None,
        "effort": None,
        "backend": None,
        "endpoint_alive": True,
        "current_state": None,
        "last_status": None,
        "started_at": None,
        "elapsed_seconds": None,
        "pr": None,
        "worktree": fm_home,
        "context": None,
        "tokens": None,
        "validation": None,
        "sources": {"context": "not measured yet", "validation": "primary has no per-worktree no-mistakes status"},
        "_home": fm_home,
        "_fm_home": fm_home,
    }


def measure_context(agent: dict[str, Any]) -> None:
    candidates = []
    for key in ("worktree", "_home"):
        value = agent.get(key)
        if value and value not in candidates:
            candidates.append(value)
    harness = str(agent.get("harness") or "").lower()
    if harness == "claude":
        context, tokens, source = claude_context(candidates)
    elif harness == "codex":
        context, tokens, source = codex_context(candidates)
    elif agent.get("kind") == "primary":
        context, tokens, source = claude_context(candidates)
        if context is not None:
            agent["harness"] = "claude"
        else:
            context, tokens, source = codex_context(candidates)
            if context is not None:
                agent["harness"] = "codex"
    else:
        context = tokens = None
        source = "unsupported or unknown harness for session-log context"
    agent["context"] = context
    agent["tokens"] = tokens
    agent["sources"]["context"] = source


def merge_secondmate_agents(agents: list[dict[str, Any]], secondmates: list[dict[str, Any]]) -> None:
    by_id = {agent.get("id"): agent for agent in agents}
    for secondmate in secondmates:
        existing = by_id.get(secondmate.get("id"))
        if existing is None:
            agents.append(secondmate)
            by_id[secondmate.get("id")] = secondmate
            continue
        for key in ("parent", "project", "harness", "model", "effort", "backend", "started_at", "worktree", "_home"):
            if existing.get(key) in (None, "") and secondmate.get(key) not in (None, ""):
                existing[key] = secondmate[key]
        if existing.get("current_state") in (None, "unknown") and secondmate.get("current_state") is not None:
            existing["current_state"] = secondmate["current_state"]
        if existing.get("endpoint_alive") is None and secondmate.get("endpoint_alive") is not None:
            existing["endpoint_alive"] = secondmate["endpoint_alive"]


def upstream_status(line: str | None, ok: bool, skipped: bool) -> dict[str, Any]:
    checked_at = utc_now()
    if skipped:
        return {"status": "skipped", "new_commits": 0, "line": None, "checked_at": checked_at}
    if not ok:
        return {"status": "error", "new_commits": None, "line": truncate(line, 240) if line else None, "checked_at": checked_at}
    text = (line or "").strip()
    if not text:
        return {"status": "up_to_date", "new_commits": 0, "line": None, "checked_at": checked_at}
    match = re.search(r"upstream:\s+(\d+)\s+new commits", text)
    return {"status": "behind" if match else "error", "new_commits": int(match.group(1)) if match else None, "line": truncate(text, 240), "checked_at": checked_at}


def clean_agent(agent: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in agent.items() if not k.startswith("_")}


def measure_endpoint(agent: dict[str, Any], root: Path, fm_home: str) -> tuple[bool | None, dict[str, Any] | None]:
    backend = agent.get("backend")
    target = agent.get("_endpoint_target")
    if not backend or not target:
        return agent.get("endpoint_alive"), None
    env = os.environ.copy()
    env["FM_HOME"] = fm_home
    env["FM_ROOT_OVERRIDE"] = str(root)
    command = '. "$1/bin/fm-backend.sh"; fm_backend_agent_alive "$2" "$3"'
    output, source = run_source(
        f"endpoint:{agent.get('id')}",
        ["bash", "-c", command, "fm-bridge-endpoint", str(root), str(backend), str(target)],
        timeout=SOURCE_TIMEOUT,
        env=env,
    )
    if not source["ok"]:
        return None, source
    state = (output or "").strip()
    return (True if state == "alive" else False if state == "dead" else None), source


def build_snapshot(no_network: bool) -> dict[str, Any]:
    root = Path(__file__).resolve().parent.parent
    fm_home = os.path.realpath(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or str(root))
    generated = utc_now()
    sources: list[dict[str, Any]] = []

    fleet_bin = os.environ.get("FM_BRIDGE_FLEET_SNAPSHOT_BIN") or str(root / "bin" / "fm-fleet-snapshot.sh")
    upstream_bin = os.environ.get("FM_BRIDGE_UPSTREAM_SYNC_BIN") or str(root / "bin" / "fm-upstream-sync.sh")
    fleet_env = os.environ.copy()
    with tempfile.TemporaryDirectory(prefix="fm-bridge-fleet-cache-") as fleet_cache:
        fleet_env["FM_SNAPSHOT_CACHE_DIR"] = fleet_cache
        fleet_out, fleet_source = run_source("fm-fleet-snapshot", [fleet_bin, "--json"], timeout=SOURCE_TIMEOUT, env=fleet_env)
    sources.append(fleet_source)
    fleet = parse_source_json(fleet_out, fleet_source, "fm-fleet-snapshot") if fleet_source["ok"] else None

    quota_out, quota_source = run_source("quota-axi", ["quota-axi", "--json", "--no-credential-refresh"], timeout=SOURCE_TIMEOUT)
    sources.append(quota_source)
    quota_raw = parse_source_json(quota_out, quota_source, "quota-axi") if quota_source["ok"] else None
    quota = quota_snapshot(quota_raw, quota_source["ok"], quota_source["error"])

    agents = [primary_agent(fm_home)]
    if isinstance(fleet, dict):
        fm_home = os.path.realpath(str(fleet.get("fm_home") or fm_home))
        agents = [primary_agent(fm_home)] + [agent_from_task(task, fm_home) for task in (fleet.get("tasks") or []) if isinstance(task, dict)]

    context_value, context_source = run_memory_source("session-logs", lambda: [measure_context(agent) for agent in agents])
    del context_value
    sources.append(context_source)
    if not context_source["ok"]:
        for agent in agents:
            agent["context"] = None
            agent["tokens"] = None
            agent["sources"]["context"] = context_source["error"] or "session-log source failed"

    if isinstance(fleet, dict):
        merge_secondmate_agents(agents, agents_from_secondmates(fleet, fm_home))

    for agent in agents:
        endpoint_alive, endpoint_source = measure_endpoint(agent, root, fm_home)
        agent["endpoint_alive"] = endpoint_alive
        if endpoint_source is not None:
            sources.append(endpoint_source)
        worktree = agent.get("worktree")
        if not worktree:
            agent["sources"]["validation"] = "no worktree recorded"
            continue
        status_out, nm_source = run_source(f"no-mistakes:{agent['id']}", ["no-mistakes", "axi", "status"], cwd=str(worktree), timeout=SOURCE_TIMEOUT)
        sources.append(nm_source)
        if nm_source["ok"]:
            agent["validation"] = parse_no_mistakes_status(status_out)
            agent["sources"]["validation"] = "no-mistakes axi status" if agent["validation"] else "no no-mistakes run for this worktree"
        else:
            agent["sources"]["validation"] = nm_source["error"] or "no-mistakes status failed"

    known = {os.path.realpath(fm_home)}
    for agent in agents:
        for key in ("worktree", "_home"):
            value = agent.get(key)
            if value:
                known.add(os.path.realpath(str(value)))
    unrecorded_value, unrecorded_source = run_memory_source("unrecorded-agents", lambda: unrecorded_agents(known))
    sources.append(unrecorded_source)

    if no_network:
        upstream = upstream_status(None, True, True)
        sources.append({"name": "fm-upstream-sync", "ok": True, "elapsed_ms": 0, "error": "skipped"})
    else:
        upstream_out, upstream_source = run_source("fm-upstream-sync", [upstream_bin, "--check"], timeout=SOURCE_TIMEOUT)
        sources.append(upstream_source)
        upstream = upstream_status(upstream_out, upstream_source["ok"], False)

    return {
        "schema": SCHEMA,
        "generated": generated,
        "host": platform.node(),
        "fm_home": fm_home,
        "quota": quota,
        "agents": [clean_agent(agent) for agent in agents],
        "unrecorded_agents": unrecorded_value or [],
        "backlog": backlog_counts(fleet),
        "upstream": upstream,
        "sources": sources,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--no-network", action="store_true")
    args = parser.parse_args(argv)
    if not args.json:
        parser.error("--json is required")
    json.dump(build_snapshot(args.no_network), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
