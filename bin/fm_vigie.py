#!/usr/bin/env python3
"""Build a bounded, read-only Vigie digest from native producers."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
from collections import defaultdict
from pathlib import Path
from typing import Any

CATEGORY_PRIORITY = {
    name: rank
    for rank, name in enumerate(
        (
            "captain_hold",
            "blocked_work",
            "client_gate",
            "ready_pr",
            "keyed_decision",
            "credential_attention",
            "pending_service_update",
            "dead_worker_endpoint",
            "kanban_ready",
        )
    )
}
ACTIONABLE_CATEGORIES = set(CATEGORY_PRIORITY)
SOURCE_CATEGORY = {
    "firstmate.fleet_snapshot": {
        "captain_hold",
        "blocked_work",
        "client_gate",
        "ready_pr",
        "keyed_decision",
        "credential_attention",
        "pending_service_update",
        "dead_worker_endpoint",
    },
    "hermes.kanban.stats": {"kanban_ready"},
    "hermes.doctor": {"credential_attention"},
    "hermes.cron.doctor": {"pending_service_update"},
    "firstmate.watched_tools": {"pending_service_update"},
}


def env_int(name: str, default: int, *, allow_zero: bool = False) -> int:
    raw = os.environ.get(name, str(default))
    if not raw.isdigit() or (not allow_zero and int(raw) == 0):
        qualifier = "non-negative" if allow_zero else "positive"
        raise ValueError(f"{name} must be a {qualifier} integer")
    return int(raw)


def now_text() -> str:
    configured = os.environ.get("FM_VIGIE_NOW")
    if configured:
        return configured
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def producer_time(value: Any, fallback: str) -> str:
    if isinstance(value, str) and value:
        return value
    if isinstance(value, (int, float)):
        return dt.datetime.fromtimestamp(value, dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return fallback


def encode_identity(value: Any) -> str:
    return str(value).replace("%", "%25").replace(":", "%3A")


def bounded_text(data: bytes, maximum: int) -> tuple[str, bool]:
    truncated = len(data) > maximum
    return data[:maximum].decode("utf-8", "replace"), truncated


def redact_text(value: str) -> str:
    value = re.sub(r"(?i)\b(bearer)\s+\S+", r"\1 [redacted]", value)
    value = re.sub(
        r'''(?i)(["'](?:token|access_token|refresh_token|client_secret|secret|api_key|password|cookie|authorization)["']\s*:\s*)["'][^"']*["']''',
        r'\1"[redacted]"',
        value,
    )
    return re.sub(
        r"(?i)\b(token|access_token|refresh_token|client_secret|secret|api[_ -]?key|password|cookie|authorization)\s*[:=]\s*\S+",
        r"\1=[redacted]",
        value,
    )


def executable(command: str) -> str | None:
    if os.path.sep in command:
        return command if os.path.isfile(command) and os.access(command, os.X_OK) else None
    return shutil.which(command)


def run_source(source_id: str, argv: list[str] | None, observed_at: str, timeout: int, maximum: int, extra_env: dict[str, str] | None = None) -> dict[str, Any]:
    record: dict[str, Any] = {
        "source_id": source_id,
        "command": argv,
        "status": "unknown",
        "reason_code": None,
        "exit_code": None,
        "timed_out": False,
        "stdout": "",
        "stderr": "",
        "stdout_truncated": False,
        "stderr_truncated": False,
        "observed_at": observed_at,
    }
    if argv is None:
        return record
    resolved = executable(argv[0])
    if resolved is None:
        record.update(status="unavailable", reason_code="command_missing")
        return record
    actual = [resolved, *argv[1:]]
    try:
        process = subprocess.Popen(
            actual,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            env={**os.environ, **(extra_env or {})},
        )
    except OSError:
        record.update(status="unavailable", reason_code="command_missing")
        return record

    captured = {"stdout": bytearray(), "stderr": bytearray()}
    truncated = {"stdout": False, "stderr": False}

    def drain(name: str, stream: Any) -> None:
        while True:
            chunk = stream.read(4096)
            if not chunk:
                break
            room = maximum - len(captured[name])
            if room > 0:
                captured[name].extend(chunk[:room])
            if len(chunk) > room:
                truncated[name] = True

    threads = [
        threading.Thread(target=drain, args=("stdout", process.stdout), daemon=True),
        threading.Thread(target=drain, args=("stderr", process.stderr), daemon=True),
    ]
    for thread in threads:
        thread.start()
    try:
        exit_code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        record["timed_out"] = True
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        exit_code = process.wait()
    for thread in threads:
        thread.join(timeout=1)
    record.update(
        exit_code=exit_code,
        stdout=redact_text(bytes(captured["stdout"]).decode("utf-8", "replace")),
        stderr=redact_text(bytes(captured["stderr"]).decode("utf-8", "replace")),
        stdout_truncated=truncated["stdout"],
        stderr_truncated=truncated["stderr"],
    )
    if record["timed_out"]:
        record.update(status="unavailable", reason_code="timeout")
    elif exit_code != 0:
        record.update(status="unavailable", reason_code="nonzero_exit")
    elif truncated["stdout"] or truncated["stderr"]:
        record.update(status="unknown", reason_code="output_truncated")
    return record


def source_unusable(record: dict[str, Any]) -> bool:
    return record["status"] == "unavailable" or record["stdout_truncated"] or record["stderr_truncated"]


def set_parse_outcome(record: dict[str, Any], status: str, reason_code: str | None, capped: bool) -> None:
    if capped:
        record.update(status="unknown", reason_code="record_cap_reached")
    else:
        record.update(status=status, reason_code=reason_code)


def parse_json_source(record: dict[str, Any], *, schema: str | None = None) -> Any | None:
    if source_unusable(record):
        return None
    try:
        value = json.loads(record["stdout"])
    except (json.JSONDecodeError, TypeError):
        record.update(status="unavailable", reason_code="invalid_json")
        return None
    if schema is not None and (not isinstance(value, dict) or value.get("schema") != schema):
        record.update(status="unavailable", reason_code="invalid_json")
        return None
    record.update(status="observed", reason_code=None)
    return value


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def redact_secrets(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: "[redacted]" if key.lower() in {"secret", "token", "api_key", "password", "cookie", "authorization"} else redact_secrets(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact_secrets(item) for item in value]
    return value


def clean_line(value: Any) -> str:
    return re.sub(r"[\r\n]+", " ", str(value or "")).strip()


def age(value: Any) -> int | None:
    return value if isinstance(value, int) and value >= 0 else None


def observation(
    key: str,
    category: str,
    source_id: str,
    source_identity: Any,
    title: Any,
    reason_code: str,
    evidence: dict[str, Any],
    observed_at: str,
    *,
    action: str | None = None,
    age_days: int | None = None,
    unknowns: list[str] | None = None,
    status: str = "observed",
) -> dict[str, Any]:
    return {
        "key": key,
        "category": category,
        "status": status,
        "source_id": source_id,
        "source_identity": str(source_identity),
        "actionable": action is not None and status == "observed",
        "action": action if status == "observed" else None,
        "title": clean_line(title),
        "reason_code": reason_code,
        "age_days": age_days,
        "observed_at": observed_at,
        "evidence": [evidence],
        "unknowns": sorted(set(unknowns or [])),
    }


def limited_array(value: Any, limit: int) -> list[Any]:
    return value[:limit] if isinstance(value, list) else []


def parse_snapshot(snapshot: dict[str, Any], source: dict[str, Any], limit: int) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    observations: list[dict[str, Any]] = []
    source_id = source["source_id"]
    seen_at = source["observed_at"]
    inventory: dict[str, dict[str, Any]] = {}
    backlog_value = snapshot.get("backlog")
    backlog: dict[str, Any] = backlog_value if isinstance(backlog_value, dict) else {}
    secondmate_value = snapshot.get("secondmate_current")
    secondmate: dict[str, Any] = secondmate_value if isinstance(secondmate_value, dict) else {}
    remaining = limit
    record_cap_reached = False

    def consume_records(value: Any) -> list[Any]:
        nonlocal record_cap_reached, remaining
        if not isinstance(value, list):
            return []
        rows = value[:remaining]
        if len(rows) < len(value):
            record_cap_reached = True
        remaining -= len(rows)
        return rows

    records = consume_records(backlog.get("records"))
    tasks = consume_records(snapshot.get("tasks"))
    secondmate_records = consume_records(secondmate.get("records"))

    def field_records(field: str) -> tuple[list[Any], str]:
        if field not in snapshot:
            return [], "unknown"
        if not isinstance(snapshot[field], list):
            return [], "unknown"
        rows = consume_records(snapshot[field])
        return rows, "empty" if not snapshot[field] else "observed"

    ready_rows, ready_status = field_records("ready_prs")
    derived_prs = [
        row for row in records
        if isinstance(row, dict)
        and row.get("id") is not None
        and row.get("pr_url") is not None
        and str(row.get("state", "")).lower().replace(" ", "_") in {"queued", "in_flight"}
    ]
    if derived_prs:
        ready_rows = ready_rows + derived_prs
        ready_status = "observed"
    elif ready_status == "unknown" and backlog.get("present") is True and isinstance(backlog.get("records"), list):
        ready_status = "empty"
    for row in ready_rows:
        if not isinstance(row, dict) or row.get("id") is None:
            continue
        ident = str(row["id"])
        evidence = {
            "source_id": source_id,
            "source_identity": ident,
            "id": ident,
            "url": row.get("url", row.get("pr_url")),
            "title": row.get("title"),
            "state": row.get("state"),
            "gate": row.get("gate"),
            "age_days": age(row.get("age_days")),
        }
        observations.append(observation(
            f"pr:{encode_identity(ident)}", "ready_pr", source_id, ident,
            row.get("title", ident), "ready_pr_recorded", evidence, seen_at,
            action=f"review-pr:{ident}", age_days=age(row.get("age_days")),
        ))
    inventory["ready_prs"] = {"count": len(ready_rows), "status": ready_status, "source_ids": [source_id]}

    gates, gate_status = field_records("client_gates")
    for row in gates:
        if not isinstance(row, dict):
            continue
        ident = row.get("id", row.get("key"))
        if ident is None:
            continue
        evidence = {key: row.get(key) for key in ("id", "key", "title", "name", "status", "due", "due_at", "reason", "age_days") if key in row}
        evidence.update(source_id=source_id, source_identity=str(ident))
        observations.append(observation(
            f"gate:{encode_identity(ident)}", "client_gate", source_id, ident,
            row.get("title", row.get("name", ident)), "client_gate_pending", evidence, seen_at,
            action=f"stage-gate:{ident}", age_days=age(row.get("age_days")),
        ))
    inventory["client_gates"] = {"count": len(gates), "status": gate_status, "source_ids": [source_id]}

    decision_count = 0
    decision_complete = isinstance(snapshot.get("tasks"), list)
    for task in tasks:
        if not isinstance(task, dict) or task.get("id") is None:
            continue
        hints = task.get("hints") if isinstance(task.get("hints"), dict) else {}
        decisions = consume_records(hints.get("open_decisions"))
        if "open_decisions" not in hints:
            decision_complete = False
        for row in decisions:
            if not isinstance(row, dict) or row.get("key") is None:
                continue
            task_id, decision_key = str(task["id"]), str(row["key"])
            source_identity = f"{task_id}:{decision_key}"
            evidence = {key: row.get(key) for key in ("key", "summary", "owner", "deadline", "age_days") if key in row}
            evidence.update(source_id=source_id, source_identity=source_identity, task_id=task_id)
            observations.append(observation(
                f"decision:task:{encode_identity(task_id)}:{encode_identity(decision_key)}",
                "keyed_decision", source_id, source_identity,
                row.get("summary", decision_key), "task_decision_open", evidence, seen_at,
                action=f"decide:{task_id}:{decision_key}", age_days=age(row.get("age_days")),
            ))
            decision_count += 1
    if "secondmate_current" not in snapshot or not isinstance(snapshot.get("secondmate_current"), dict):
        decision_complete = False
    for mate in secondmate_records:
        if not isinstance(mate, dict) or mate.get("id") is None:
            continue
        if "decisions_open" not in mate:
            decision_complete = False
        for row in consume_records(mate.get("decisions_open")):
            if not isinstance(row, dict) or row.get("key") is None:
                continue
            mate_id, decision_key = str(mate["id"]), str(row["key"])
            source_identity = f"{mate_id}:{decision_key}"
            evidence = {key: row.get(key) for key in ("key", "summary", "owner", "age_days", "hold_age_days") if key in row}
            evidence.update(source_id=source_id, source_identity=source_identity, record_id=mate_id)
            observations.append(observation(
                f"decision:secondmate:{encode_identity(mate_id)}:{encode_identity(decision_key)}",
                "keyed_decision", source_id, source_identity,
                row.get("summary", decision_key), "secondmate_decision_open", evidence, seen_at,
                action=f"decide:{mate_id}:{decision_key}", age_days=age(row.get("age_days", row.get("hold_age_days"))),
            ))
            decision_count += 1
    decision_status = "observed" if decision_count else ("empty" if decision_complete else "unknown")
    inventory["keyed_decisions"] = {"count": decision_count, "status": decision_status, "source_ids": [source_id]}

    credentials, credential_status = field_records("credential_evidence")
    credential_count = 0
    for row in credentials:
        if not isinstance(row, dict) or row.get("status") == "ok":
            continue
        ident = row.get("id", row.get("source"))
        if ident is None:
            continue
        evidence = {key: row.get(key) for key in ("id", "source", "status", "observed_at", "reason", "age_days") if key in row}
        evidence.update(source_id=source_id, source_identity=str(ident))
        observations.append(observation(
            f"credential:{encode_identity(ident)}", "credential_attention", source_id, ident,
            row.get("title", row.get("source", ident)), "credential_attention_recorded", evidence, seen_at,
            action=f"inspect-credential:{ident}", age_days=age(row.get("age_days")),
        ))
        credential_count += 1
    inventory["credential_evidence"] = {"count": credential_count, "status": credential_status, "source_ids": [source_id, "hermes.doctor"]}

    pending, pending_status = field_records("pending_services")
    pending_count = 0
    for row in pending:
        if not isinstance(row, dict):
            continue
        ident = row.get("id", row.get("key", row.get("name")))
        if ident is None:
            continue
        evidence = {key: row.get(key) for key in ("id", "key", "name", "title", "status", "reason", "age_days") if key in row}
        evidence.update(source_id=source_id, source_identity=str(ident))
        observations.append(observation(
            f"pending:{encode_identity(ident)}", "pending_service_update", source_id, ident,
            row.get("title", row.get("name", ident)), "pending_service_recorded", evidence, seen_at,
            action=f"resolve-pending:{ident}", age_days=age(row.get("age_days")),
        ))
        pending_count += 1
    inventory["pending_service_updates"] = {"count": pending_count, "status": pending_status, "source_ids": [source_id, "hermes.cron.doctor", "firstmate.watched_tools"]}

    for row in records:
        if not isinstance(row, dict) or row.get("id") is None:
            continue
        ident = str(row["id"])
        if row.get("captain_actionable") is True:
            evidence = {key: row.get(key) for key in ("id", "title", "state", "hold_kind", "captain_actionable", "hold_age_days") if key in row}
            evidence.update(source_id=source_id, source_identity=ident)
            observations.append(observation(
                f"hold:{encode_identity(ident)}", "captain_hold", source_id, ident,
                row.get("title", ident), "captain_hold_actionable", evidence, seen_at,
                action=f"answer:{ident}", age_days=age(row.get("hold_age_days")),
            ))
        blockers = row.get("blocked_by_ids")
        if str(row.get("state", "")).lower() != "done" and isinstance(blockers, list) and blockers:
            sorted_blockers = sorted({str(item) for item in blockers})
            evidence = {"source_id": source_id, "source_identity": ident, "id": ident, "title": row.get("title"), "state": row.get("state"), "blocked_by_ids": sorted_blockers, "age_days": age(row.get("age_days"))}
            observations.append(observation(
                f"blocked:{encode_identity(ident)}", "blocked_work", source_id, ident,
                row.get("title", ident), "unresolved_blockers", evidence, seen_at,
                action=f"unblock:{ident}", age_days=age(row.get("age_days")),
            ))
    for task in tasks:
        if not isinstance(task, dict) or task.get("id") is None:
            continue
        endpoint = task.get("endpoint") if isinstance(task.get("endpoint"), dict) else {}
        if endpoint.get("agent_alive") is False:
            ident = str(task["id"])
            evidence = {"source_id": source_id, "source_identity": ident, "task_id": ident, "agent_alive": False, "observed_at": endpoint.get("observed_at"), "age_days": age(task.get("age_days"))}
            observations.append(observation(
                f"worker:{encode_identity(ident)}", "dead_worker_endpoint", source_id, ident,
                ident, "endpoint_inactive", evidence, seen_at,
                action=f"inspect:{ident}", age_days=age(task.get("age_days")),
            ))
    if record_cap_reached:
        source.update(status="unknown", reason_code="record_cap_reached")
    unknown_prefixes = []
    for inventory_name, prefix in (
        ("ready_prs", "pr:"),
        ("client_gates", "gate:"),
        ("keyed_decisions", "decision:"),
        ("credential_evidence", "credential:"),
        ("pending_service_updates", "pending:"),
    ):
        if inventory[inventory_name]["status"] == "unknown":
            unknown_prefixes.append(prefix)
    if backlog.get("present") is not True or not isinstance(backlog.get("records"), list):
        unknown_prefixes.extend(("hold:", "blocked:"))
    if not isinstance(snapshot.get("tasks"), list):
        unknown_prefixes.append("worker:")
    source["unknown_key_prefixes"] = sorted(set(unknown_prefixes))
    return observations, inventory


def parse_kanban_task(record: dict[str, Any]) -> list[dict[str, Any]]:
    value = parse_json_source(record)
    if not isinstance(value, dict) or not isinstance(value.get("task"), dict) or value["task"].get("id") is None:
        if not source_unusable(record):
            record.update(status="unknown", reason_code="required_fields_missing")
        return []
    task = value["task"]
    ident = str(task["id"])
    evidence = {"source_id": record["source_id"], "source_identity": ident, "task_id": ident, "status": task.get("status"), "events": value.get("events"), "runs": value.get("runs"), "latest_summary": value.get("latest_summary")}
    return [observation(f"kanban-task:{encode_identity(ident)}", "kanban_task", record["source_id"], ident, ident, "current_task_observed", evidence, record["observed_at"])]


def parse_kanban_stats(record: dict[str, Any]) -> list[dict[str, Any]]:
    value = parse_json_source(record)
    if not isinstance(value, dict) or not isinstance(value.get("by_status"), dict) or not isinstance(value["by_status"].get("ready"), (int, float)):
        if not source_unusable(record):
            record.update(status="unknown", reason_code="required_fields_missing")
        return []
    ready = int(value["by_status"]["ready"])
    record["observed_at"] = producer_time(value.get("now"), record["observed_at"])
    if ready == 0:
        record["status"] = "empty"
        return []
    seconds = value.get("oldest_ready_age_seconds")
    age_days = int(seconds // 86400) if isinstance(seconds, (int, float)) and seconds >= 0 else None
    evidence = {"source_id": record["source_id"], "source_identity": "ready", "ready": ready, "by_status": value.get("by_status"), "by_assignee": value.get("by_assignee"), "oldest_ready_age_seconds": seconds, "now": value.get("now")}
    return [observation("kanban:ready", "kanban_ready", record["source_id"], "ready", "File Kanban prête", "kanban_ready_count", evidence, record["observed_at"], action="inspect:kanban-ready", age_days=age_days)]


def parse_notify(record: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    if source_unusable(record):
        return []
    pattern = re.compile(r"^\s*(\S+)\s+(\S+)\s+\(since event ([^)]+)\)\s+owner=(\S+)(?:\s+chat_type=(\S+))?(?:\s+mode=(\S+))?")
    rows = []
    lines = record["stdout"].splitlines()
    capped = len(lines) > limit
    for line in lines[:limit]:
        match = pattern.match(line)
        if not match:
            continue
        task, channel, marker, owner, chat_type, mode = match.groups()
        mode = mode or "unknown"
        identity = f"{task}:{channel}:{owner}:{mode}"
        evidence = {"source_id": record["source_id"], "source_identity": identity, "task_id": task, "channel": channel, "owner": owner, "chat_type": chat_type, "mode": mode, "since_event": marker}
        rows.append(observation(f"notify:{encode_identity(task)}:{encode_identity(channel)}:{encode_identity(owner)}:{encode_identity(mode)}", "notification_subscription", record["source_id"], identity, task, "subscription_observed", evidence, record["observed_at"]))
    status = "observed" if rows else "unknown"
    reason = None if rows else ("silent_completion_not_complete" if not record["stdout"].strip() else "unparseable_output")
    set_parse_outcome(record, status, reason, capped)
    return rows


def parse_monitoring(record: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    if source_unusable(record):
        return []
    mappings = (
        ("Health export:", "health-export", "health_export_disabled"),
        ("OTLP endpoint:", "otlp-endpoint", "otlp_not_configured"),
        ("OTel SDK:", "otel-sdk", "otel_sdk_missing"),
        ("Scope:", "health-scope", "health_scope_reported"),
    )
    rows = []
    lines = record["stdout"].splitlines()
    capped = len(lines) > limit
    for line in lines[:limit]:
        stripped = line.strip()
        for prefix, token, reason in mappings:
            if stripped.startswith(prefix):
                evidence = {"source_id": record["source_id"], "source_identity": token, "check": token, "label": clean_line(stripped)}
                rows.append(observation(f"monitoring:{token}", "monitoring", record["source_id"], token, prefix.rstrip(":"), reason, evidence, record["observed_at"]))
                break
    set_parse_outcome(record, "observed" if rows else "unknown", None if rows else "unparseable_output", capped)
    return rows


def parse_insights(record: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    if source_unusable(record):
        return []
    labels = ("Period:", "Sessions:", "Messages:", "Tool calls:", "Total tokens:", "Model ", "Platform ")
    facts = [clean_line(line) for line in record["stdout"].splitlines() if clean_line(line).startswith(labels)]
    capped = len(facts) > limit
    facts = facts[:limit]
    if not facts:
        record.update(status="unknown", reason_code="unparseable_output")
        return []
    set_parse_outcome(record, "observed", None, capped)
    evidence = {"source_id": record["source_id"], "source_identity": "day-window", "reported": facts}
    return [observation("insights:day-window", "operational_insights", record["source_id"], "day-window", "Fenêtre quotidienne", "usage_window_reported", evidence, record["observed_at"])]


def parse_doctor(record: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    if source_unusable(record):
        return []
    mappings = (
        (re.compile(r"MiniMax OAuth \(not logged in\)"), "minimax-oauth", "provider_not_logged_in"),
        (re.compile(r"No API key found"), "profile-api-key", "api_key_unavailable"),
        (re.compile(r"OpenRouter API \(not configured\)"), "openrouter-api", "provider_not_configured"),
    )
    rows = []
    lines = record["stdout"].splitlines()
    capped = len(lines) > limit
    for line in lines[:limit]:
        for pattern, token, reason in mappings:
            if pattern.search(line):
                evidence = {"source_id": record["source_id"], "source_identity": token, "check": token, "display_label": pattern.pattern, "normalized_status": "attention", "issue_label": reason}
                rows.append(observation(f"credential:doctor:{token}", "credential_attention", record["source_id"], token, token, reason, evidence, record["observed_at"], action=f"inspect-credential:{token}", unknowns=["authoritative_age_unavailable"]))
                break
    set_parse_outcome(record, "observed" if rows else "unknown", None if rows else "no_known_attention_labels", capped)
    return rows


def parse_cron_list(record: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    if source_unusable(record):
        return []
    jobs: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for line in record["stdout"].splitlines():
        match = re.match(r"^\s{2}(\S+) \[(active|disabled)\]", line)
        if match:
            if current:
                jobs.append(current)
            current = {"job_id": match.group(1), "status": match.group(2)}
            continue
        if current:
            field = re.match(r"^\s{4}(Name|Schedule|Next run|Deliver|Script|Last run|Execution):\s+(.*)$", line)
            if field:
                current[field.group(1).lower().replace(" ", "_")] = clean_line(field.group(2))
    if current:
        jobs.append(current)
    capped = len(jobs) > limit
    jobs = jobs[:limit]
    rows = []
    for job in jobs:
        ident = str(job["job_id"])
        evidence = {"source_id": record["source_id"], "source_identity": ident, **job}
        rows.append(observation(f"cron-job:{encode_identity(ident)}", "cron_job", record["source_id"], ident, job.get("name", ident), "cron_job_listed", evidence, record["observed_at"]))
    status = "observed" if rows else ("empty" if "No scheduled jobs" in record["stdout"] else "unknown")
    set_parse_outcome(record, status, None if status != "unknown" else "unparseable_output", capped)
    return rows


def parse_cron_doctor(record: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    if source_unusable(record):
        return []
    rows = []
    current_id: str | None = None
    current_name: str | None = None
    lines = record["stdout"].splitlines()
    capped = len(lines) > limit
    for line in lines[:limit]:
        job = re.match(r"^\s{2}(\S+)\s+(.+)$", line)
        if job and not line.lstrip().startswith(("Cron doctor", "Next:")):
            current_id, current_name = job.group(1), clean_line(job.group(2))
            continue
        issue = re.match(r"^\s+-\s+(last run failed|script not found):\s*(.*)$", line, re.I)
        if not issue or current_id is None:
            continue
        code = "last_run_failed" if issue.group(1).lower().startswith("last") else "missing_script"
        identity = f"{current_id}:{code}"
        evidence = {"source_id": record["source_id"], "source_identity": identity, "job_id": current_id, "job_name": current_name, "issue_code": code, "path": clean_line(issue.group(2)), "source_issue_label": issue.group(1).lower()}
        rows.append(observation(f"cron:{encode_identity(current_id)}:{code}", "pending_service_update", record["source_id"], identity, current_name or current_id, code, evidence, record["observed_at"], action=f"resolve-pending:cron:{current_id}:{code}", unknowns=["authoritative_age_unavailable"]))
    status = "observed" if rows else ("empty" if "found 0 issue" in record["stdout"] else "unknown")
    set_parse_outcome(record, status, None if status != "unknown" else "unparseable_output", capped)
    return rows


def parse_tool_updates(record: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    if source_unusable(record):
        return []
    if record["status"] != "unavailable" and not record["stdout"].strip():
        record.update(status="unknown", reason_code="silent_completion_not_complete")
        return []
    value = parse_json_source(record)
    if value is None:
        return []
    alerts = value.get("alerts") if isinstance(value, dict) else None
    if not isinstance(alerts, list):
        record.update(status="unknown", reason_code="required_fields_missing")
        return []
    source_timestamp = value.get("observed_at") if isinstance(value, dict) else None
    if source_timestamp is None:
        source_timestamp = next((alert.get("observed_at") for alert in alerts if isinstance(alert, dict) and alert.get("observed_at")), None)
    record["observed_at"] = producer_time(source_timestamp, record["observed_at"])
    if not alerts:
        record.update(status="empty", reason_code=None)
        return []
    capped = len(alerts) > limit
    rows = []
    for alert in alerts[:limit]:
        if not isinstance(alert, dict) or alert.get("tool_id") is None:
            continue
        ident = str(alert["tool_id"])
        evidence = {"source_id": record["source_id"], "source_identity": ident, **{key: alert.get(key) for key in ("tool_id", "installed_version", "available_version", "status", "observed_at") if key in alert}}
        rows.append(observation(f"tool-update:{encode_identity(ident)}", "pending_service_update", record["source_id"], ident, ident, "tool_update_available", evidence, record["observed_at"], action=f"resolve-pending:tool-update:{ident}", unknowns=["authoritative_age_unavailable"]))
    set_parse_outcome(record, "observed" if rows else "unknown", None if rows else "required_fields_missing", capped)
    return rows


def merge_observations(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_pair: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    categories_by_key: dict[str, set[str]] = defaultdict(set)
    for row in rows:
        by_pair[(row["category"], row["key"])].append(row)
        categories_by_key[row["key"]].add(row["category"])
    merged: list[dict[str, Any]] = []
    for (category, key), group in by_pair.items():
        if len(categories_by_key[key]) > 1:
            continue
        base = dict(group[0])
        evidence_by_json = {canonical(item): item for row in group for item in row["evidence"]}
        base["evidence"] = [evidence_by_json[token] for token in sorted(evidence_by_json)]
        base["unknowns"] = sorted({token for row in group for token in row["unknowns"]})
        ages = {row["age_days"] for row in group if row["age_days"] is not None}
        if len(ages) > 1:
            base["age_days"] = None
            base["unknowns"] = sorted(set(base["unknowns"] + ["conflicting_authoritative_age"]))
        elif ages:
            base["age_days"] = next(iter(ages))
        merged.append(base)
    for key, categories in categories_by_key.items():
        if len(categories) <= 1:
            continue
        evidence = [{"key": key, "categories": sorted(categories)}]
        merged.append(observation(key, "identity_collision", "vigie.normalizer", key, key, "identity_collision", evidence[0], rows[0]["observed_at"] if rows else now_text(), unknowns=["conflicting_category_identity"], status="unknown"))
    return sorted(merged, key=lambda row: (row["category"].encode(), row["key"].encode(), row["source_id"].encode()))


def source_for_prior(key: str, item: dict[str, Any]) -> str | None:
    evidence = item.get("evidence")
    if isinstance(evidence, list):
        for fact in evidence:
            if isinstance(fact, dict) and isinstance(fact.get("source_id"), str):
                return fact["source_id"]
    if isinstance(item.get("source_id"), str):
        return item["source_id"]
    source_prefixes = (
        ("credential:doctor:", "hermes.doctor"),
        ("tool-update:", "firstmate.watched_tools"),
        ("cron:", "hermes.cron.doctor"),
        ("kanban:ready", "hermes.kanban.stats"),
        ("pr:", "firstmate.fleet_snapshot"),
        ("gate:", "firstmate.fleet_snapshot"),
        ("decision:", "firstmate.fleet_snapshot"),
        ("credential:", "firstmate.fleet_snapshot"),
        ("pending:", "firstmate.fleet_snapshot"),
        ("hold:", "firstmate.fleet_snapshot"),
        ("blocked:", "firstmate.fleet_snapshot"),
        ("worker:", "firstmate.fleet_snapshot"),
    )
    for prefix, source_id in source_prefixes:
        if key == prefix or key.startswith(prefix):
            return source_id
    return None


def deltas(recommendations: list[dict[str, Any]], prior: Any, daily: bool, age_days: int, source_records: dict[str, dict[str, Any]], cap: int) -> tuple[dict[str, Any], list[str]]:
    current_keys = [row["key"] for row in recommendations]
    unknowns: list[str] = []
    prior_keys: list[str] = []
    allow_resolutions = False
    prior_items: dict[str, dict[str, Any]] = {}
    prior_recommendation_keys: list[str] = []
    if isinstance(prior, dict):
        prior_observations = prior.get("observations")
        if isinstance(prior_observations, list):
            prior_items.update({row["key"]: row for row in prior_observations if isinstance(row, dict) and isinstance(row.get("key"), str)})
        prior_recs = prior.get("recommendations")
        if isinstance(prior_recs, list):
            prior_recommendations = {row["key"]: row for row in prior_recs if isinstance(row, dict) and isinstance(row.get("key"), str)}
            prior_items.update(prior_recommendations)
            prior_recommendation_keys = list(prior_recommendations)
        observed_keys = prior.get("observed_keys")
        if isinstance(observed_keys, list) and all(isinstance(item, str) for item in observed_keys) and len(observed_keys) == len(set(observed_keys)):
            prior_keys = list(observed_keys)
            allow_resolutions = True
        else:
            prior_keys = prior_recommendation_keys
            unknowns.append("baseline_uncapped_keys_unavailable")
    current_set, prior_set = set(current_keys), set(prior_keys)
    new = [key for key in current_keys if key not in prior_set]
    resolved: list[str] = []
    indeterminate: list[dict[str, str]] = []
    if allow_resolutions:
        for key in prior_keys:
            if key in current_set:
                continue
            source_id = source_for_prior(key, prior_items.get(key, {}))
            source = source_records.get(source_id or "")
            prefix_unknown = source and any(key.startswith(prefix) for prefix in source.get("unknown_key_prefixes", []))
            if source and (source["status"] in {"unknown", "unavailable"} or prefix_unknown):
                reason = "category_unknown" if prefix_unknown and source["status"] not in {"unknown", "unavailable"} else source.get("reason_code") or source["status"]
                indeterminate.append({"key": key, "source_id": source_id or "unknown", "reason_code": reason})
            else:
                resolved.append(key)
    resurfaced = [row["key"] for row in recommendations if daily and row["key"] in prior_set and row["key"] not in new and row["age_days"] is not None and row["age_days"] >= age_days]

    def bounded(values: list[Any]) -> dict[str, Any]:
        return {"items": values[:cap], "all_items": values, "total": len(values), "truncated": len(values) > cap}

    return {
        "new": bounded(new),
        "resolved": bounded(resolved),
        "resurfaced": bounded(resurfaced),
        "indeterminate": bounded(indeterminate),
    }, unknowns


def flatten_changes(changes: dict[str, Any]) -> dict[str, Any]:
    return {name: value["items"] for name, value in changes.items()} | {"meta": {name: {"total": value["total"], "truncated": value["truncated"]} for name, value in changes.items()}}


def recommendation_from(row: dict[str, Any]) -> dict[str, Any]:
    return {key: row[key] for key in ("key", "category", "action", "title", "reason_code", "evidence", "unknowns", "age_days", "source_identity")}


def build_digest(args: argparse.Namespace) -> tuple[dict[str, Any], bool]:
    maximum = env_int("FM_VIGIE_MAX", 10)
    age_days = env_int("FM_VIGIE_AGE_DAYS", 14, allow_zero=True)
    timeout = env_int("FM_VIGIE_NATIVE_TIMEOUT", 20)
    native_bytes = env_int("FM_VIGIE_NATIVE_MAX_BYTES", 12000)
    record_cap = env_int("FM_VIGIE_SOURCE_RECORD_MAX", 500)
    observed_at = now_text()
    prior = None
    if args.event:
        try:
            with open(args.event, encoding="utf-8") as handle:
                prior = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"event baseline is not readable valid JSON: {exc}") from exc
    root = Path(__file__).resolve().parent.parent
    snapshot_bin = os.environ.get("FM_FLEET_SNAPSHOT_BIN", str(root / "bin" / "fm-fleet-snapshot.sh"))
    hermes = os.environ.get("FM_VIGIE_HERMES_BIN") or shutil.which("hermes") or "hermes"
    tool_bin = os.environ.get("FM_VIGIE_TOOL_UPDATE_BIN", str(root / "bin" / "fm-tool-update-check.sh"))
    task_id = os.environ.get("HERMES_KANBAN_TASK", "")
    commands: list[tuple[str, list[str] | None, dict[str, str] | None]] = [
        ("firstmate.fleet_snapshot", [snapshot_bin, "--json"], None),
        ("hermes.kanban.task", [hermes, "kanban", "show", "--json", task_id] if task_id else None, None),
        ("hermes.kanban.stats", [hermes, "kanban", "stats", "--json"], None),
        ("hermes.kanban.notify_list", [hermes, "kanban", "notify-list"], None),
        ("hermes.monitoring.status", [hermes, "monitoring", "status"], None),
        ("hermes.insights.day", [hermes, "insights", "--days", "1"], None),
        ("hermes.doctor", [hermes, "doctor"], None),
        ("hermes.cron.list", [hermes, "cron", "list"], None),
        ("hermes.cron.doctor", [hermes, "cron", "doctor"], None),
        ("firstmate.watched_tools", [tool_bin, "check"], {"FM_TOOL_UPDATE_READ_ONLY": "1"}),
    ]
    native = {source_id: run_source(source_id, argv, observed_at, timeout, native_bytes, extra_env) for source_id, argv, extra_env in commands}
    if not task_id:
        native["hermes.kanban.task"].update(status="unknown", reason_code="task_id_not_supplied")
    for source_id in ("firstmate.dossier", "firstmate.reflex"):
        native[source_id] = {
            "source_id": source_id,
            "command": None,
            "status": "unavailable",
            "reason_code": "no_registered_reader",
            "exit_code": None,
            "timed_out": False,
            "stdout": "",
            "stderr": "",
            "stdout_truncated": False,
            "stderr_truncated": False,
            "observed_at": observed_at,
        }

    rows: list[dict[str, Any]] = []
    inventory: dict[str, dict[str, Any]] = {
        name: {"count": 0, "status": "unknown", "source_ids": sorted(sources)}
        for name, sources in {
            "ready_prs": {"firstmate.fleet_snapshot"},
            "client_gates": {"firstmate.fleet_snapshot"},
            "keyed_decisions": {"firstmate.fleet_snapshot"},
            "credential_evidence": {"firstmate.fleet_snapshot", "hermes.doctor"},
            "pending_service_updates": {"firstmate.fleet_snapshot", "hermes.cron.doctor", "firstmate.watched_tools"},
        }.items()
    }
    snapshot = parse_json_source(native["firstmate.fleet_snapshot"], schema="fm-fleet-snapshot.v1")
    if isinstance(snapshot, dict):
        snapshot = redact_secrets(snapshot)
        native["firstmate.fleet_snapshot"]["stdout"] = canonical(snapshot)
        native["firstmate.fleet_snapshot"]["observed_at"] = producer_time(snapshot.get("generated"), observed_at)
        snapshot_rows, inventory = parse_snapshot(snapshot, native["firstmate.fleet_snapshot"], record_cap)
        rows.extend(snapshot_rows)
    rows.extend(parse_kanban_task(native["hermes.kanban.task"]) if task_id else [])
    rows.extend(parse_kanban_stats(native["hermes.kanban.stats"]))
    rows.extend(parse_notify(native["hermes.kanban.notify_list"], record_cap))
    rows.extend(parse_monitoring(native["hermes.monitoring.status"], record_cap))
    rows.extend(parse_insights(native["hermes.insights.day"], record_cap))
    doctor_rows = parse_doctor(native["hermes.doctor"], record_cap)
    rows.extend(doctor_rows)
    rows.extend(parse_cron_list(native["hermes.cron.list"], record_cap))
    cron_rows = parse_cron_doctor(native["hermes.cron.doctor"], record_cap)
    rows.extend(cron_rows)
    tool_rows = parse_tool_updates(native["firstmate.watched_tools"], record_cap)
    rows.extend(tool_rows)

    if doctor_rows:
        inventory["credential_evidence"]["count"] += len(doctor_rows)
        inventory["credential_evidence"]["status"] = "observed"
    if cron_rows or tool_rows:
        inventory["pending_service_updates"]["count"] += len(cron_rows) + len(tool_rows)
        inventory["pending_service_updates"]["status"] = "observed"
    observations = merge_observations(rows)
    all_recommendations = [recommendation_from(row) for row in observations if row["actionable"] and row["status"] == "observed"]
    raw_changes, unknowns = deltas(all_recommendations, prior, args.daily, age_days, native, record_cap)
    changes = flatten_changes(raw_changes)
    new_set = set(raw_changes["new"]["all_items"])
    resurfaced_set = set(raw_changes["resurfaced"]["all_items"])
    all_recommendations.sort(key=lambda row: (
        0 if row["key"] in new_set else 1 if row["key"] in resurfaced_set else 2,
        -(row["age_days"] if row["age_days"] is not None else -1),
        CATEGORY_PRIORITY.get(row["category"], 99),
        row["key"].encode(),
    ))
    observed_keys = sorted(row["key"] for row in all_recommendations)
    digest = {
        "schema": "fm-vigie.v1",
        "generated": observed_at,
        "cadence": "daily" if args.daily or not args.event else "event",
        "bounded": True,
        "max": maximum,
        "recommendation_total": len(all_recommendations),
        "observed_keys": observed_keys,
        "recommendations": all_recommendations[:maximum],
        "changes": changes,
        "inventory": inventory,
        "observations": observations,
        "native": {key: native[key] for key in sorted(native)},
        "unknowns": sorted(set(unknowns)),
        "delivery": {"pilot_channel": "approved pilot only", "desktop": "future; not activated", "scheduled": False},
    }
    producer_available = any(record["status"] in {"observed", "empty"} for source_id, record in native.items() if source_id not in {"firstmate.dossier", "firstmate.reflex"})
    return digest, producer_available


def plural(count: int, singular: str, plural_form: str) -> str:
    return f"{count} {singular if count == 1 else plural_form}"


def french_line(row: dict[str, Any]) -> str:
    identity = clean_line(row["source_identity"])
    title = clean_line(row["title"])
    evidence = row["evidence"][0] if row["evidence"] else {}
    suffix = "" if row["age_days"] is None else f", âge : {row['age_days']} j"
    category = row["category"]
    if category == "ready_pr":
        return f"- Relire la PR {identity} : {title}{suffix}"
    if category == "client_gate":
        return f"- Traiter l’étape client {identity} : {title}{suffix}"
    if category == "keyed_decision":
        return f"- Décider {identity} : {title}{suffix}"
    if category == "credential_attention":
        return f"- Vérifier les éléments d’accès {identity} : {clean_line(row['reason_code'])}{suffix}"
    if category == "pending_service_update":
        return f"- Résoudre l’attente {identity} : {clean_line(row['reason_code'])}{suffix}"
    if category == "captain_hold":
        return f"- Répondre au blocage capitaine {identity} : {title}{suffix}"
    if category == "blocked_work":
        blockers = ", ".join(evidence.get("blocked_by_ids", []))
        return f"- Débloquer {identity} : dépend de {blockers}{suffix}"
    if category == "dead_worker_endpoint":
        return f"- Inspecter le worker {identity} : endpoint déclaré inactif{suffix}"
    return f"- Examiner la file Kanban : {evidence.get('ready', 0)} tâche(s) prête(s){suffix}"


def render_french(digest: dict[str, Any]) -> str:
    displayed = len(digest["recommendations"])
    cadence = "quotidienne" if digest["cadence"] == "daily" else "événementielle"
    lines = [f"Vigie {cadence} ({displayed}/{digest['recommendation_total']}, plafond {digest['max']})"]
    if displayed:
        lines.extend(french_line(row) for row in digest["recommendations"])
    else:
        lines.append("Aucune recommandation actionnable.")
    changes = digest["changes"]
    if changes["new"]:
        lines.append(plural(changes["meta"]["new"]["total"], "nouvel élément", "nouveaux éléments"))
    if changes["resolved"]:
        lines.append(plural(changes["meta"]["resolved"]["total"], "élément résolu", "éléments résolus"))
    if changes["resurfaced"]:
        lines.append(plural(changes["meta"]["resurfaced"]["total"], "élément ancien remis en avant", "éléments anciens remis en avant"))
    if changes["indeterminate"]:
        lines.append(plural(changes["meta"]["indeterminate"]["total"], "élément sans état actuel vérifiable", "éléments sans état actuel vérifiable"))
    unknown = sum(1 for record in digest["native"].values() if record["status"] == "unknown")
    unavailable = sum(1 for record in digest["native"].values() if record["status"] == "unavailable")
    if unknown or unavailable:
        lines.append(f"Sources incomplètes : {unknown} inconnue(s), {unavailable} indisponible(s).")
    lines.append("Livraison : pilote approuvé uniquement ; bureau futur non activé ; planification désactivée.")
    return "\n".join(lines)


def render_toon(digest: dict[str, Any]) -> str:
    lines = [
        f"schema:{digest['schema']}",
        f"generated:{digest['generated']}",
        f"cadence:{digest['cadence']}",
        f"bounded:true max:{digest['max']}",
        f"recommendations[{len(digest['recommendations'])}/{digest['recommendation_total']}]:",
    ]
    lines.extend(f"{row['action']} | {row['reason_code']}" for row in digest["recommendations"])
    lines.append(f"delivery:pilot={digest['delivery']['pilot_channel']} desktop={digest['delivery']['desktop']}")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only bounded recommendation digest over native Firstmate and Hermes producers.")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_const", dest="format", const="json")
    output.add_argument("--fr", action="store_const", dest="format", const="fr")
    parser.set_defaults(format="toon")
    parser.add_argument("--event", metavar="PREVIOUS_JSON")
    parser.add_argument("--daily", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        digest, available = build_digest(args)
    except ValueError as exc:
        print(f"fm-vigie: {exc}", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(digest, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    elif args.format == "fr":
        print(render_french(digest))
    else:
        print(render_toon(digest))
    return 0 if available else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
