#!/usr/bin/env python3
"""Import native model receipts and report quota-routing outcomes.

Usage:
  fm-routing-outcomes.py import --manifest <json> [--store <jsonl>] [--prices <json>] [--json]
  fm-routing-outcomes.py shadow --manifest <json> [--shadow-store <jsonl>] [--json]
  fm-routing-outcomes.py scorecard [--store <jsonl>] [--shadow-store <jsonl>] [--legacy-log <tsv>] [--format markdown|json]
  fm-routing-outcomes.py inspect --task <id> [--store <jsonl>] [--json]

The importer is a measurement adapter, not a dispatcher or task lifecycle.
A manifest links one existing Firstmate task and attempt to a native Pi,
Claude Code, or agy receipt. It extracts only route, timing, token, usage, and
completeness facts; prompt and response bodies are never copied to the outcome
store. Re-importing an identical manifest is a no-op. A changed manifest for
the same attempt appends a new full revision, and readers fold only the latest
revision, so replay and resume cannot double-count cost or accepted work.

Default stores live below FM_DATA_OVERRIDE/model-routing when that override is
set, otherwise below $FM_HOME/data/model-routing (or this checkout's data when
FM_HOME is absent). --store and --shadow-store exist for isolated tests and
explicit private evidence stores. Scorecard also reads a compatible legacy
`data/dispatch-log.tsv` when present, reports it as incomplete pre-measurement
history, and never mixes those rows into receipt-backed totals.

Import manifest, schema fm-routing-attempt.v1:
  {
    "schema": "fm-routing-attempt.v1",
    "task_id": "task-id", "attempt_id": "attempt-1",
    "phase": "measurement", "category": "1", "task_shape": "code-change",
    "route": {
      "harness": "pi", "provider": "openai-codex",
      "auth_category": "subscription", "requested_model": "gpt-5.6-luna",
      "requested_effort": "max", "context_tier": "all",
      "service_tier": "standard"
    },
    "native_receipt": {"kind": "pi-session", "path": "/private/session.jsonl"},
    "requirements": {"effective_model": "gpt-5.6-luna", "effective_effort": "max"},
    "started_at": "2030-01-01T00:00:00Z", "finished_at": "2030-01-01T00:01:00Z",
    "time_ms": {"queue": 1, "model": 2, "tool": 3, "review": 4,
                 "retry": null, "handoff": null, "human": null},
    "billing": {"actual_incremental_usd": null, "fixed_subscription_usd": null},
    "quota": {"provider": "codex", "before_path": "/private/before.json",
              "after_path": "/private/after.json", "concurrent_activity": true,
              "attribution": "shared"},
    "grading": {"method": "deterministic", "independent": true,
                "first_pass": "pass", "final_result": "pass",
                "defect_count": 0, "fix_count": 0, "retry_count": 0,
                "receipts": [{"kind": "test", "id": "suite", "passed": true}],
                "overhead": {"duration_ms": 10, "tokens": null,
                             "actual_incremental_usd": null}},
    "outcome": "accepted"
  }

Native receipt kinds are pi-session (Pi v3 JSONL with fm-routing-request
entries), claude-result (Claude Code --output-format json), claude-session
(Claude Code session JSONL), and agy-result (agy --output-format json). An agy
receipt may add native_log_path; only its native selected-model lines are read.

A comparison block is optional. It must declare a low-risk, non-private,
non-time-critical task with no external action. At most two distinct pair_id
values per category are admitted to the initial store. A handoff block is also
optional and admits exactly one alternative only after side effects are absent
or reconciled and quality/privacy preservation is explicit.

Price catalog, schema fm-routing-prices.v1, is private input. Every entry names
an exact provider/model/context_tier/service_tier, timestamped source_url,
effective interval, USD-per-million input/output/cache rates, and declares
reasoning "included_in_output". API-equivalent cost remains unknown unless all
native model rows have one exact applicable entry. Actual incremental charges
and fixed subscription expense are separate manifest facts; neither is inferred
from quota or list price.

Shadow manifest, schema fm-routing-shadow.v1, records a recommendation without
executing it. It must account for every candidate's eligibility, capability
class fit, runway feasibility, spend priority (number or null), uncertainty,
and explanation. The scorecard reports those explanations; it does not create
a weighted ranking or claim a winner.
"""

from __future__ import annotations

import argparse
import copy
import csv
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, Iterable

ATTEMPT_SCHEMA = "fm-routing-attempt.v1"
EVENT_SCHEMA = "fm-routing-outcome-event.v1"
SHADOW_SCHEMA = "fm-routing-shadow.v1"
SHADOW_EVENT_SCHEMA = "fm-routing-shadow-event.v1"
PRICE_SCHEMA = "fm-routing-prices.v1"
PHASES = {"measurement", "shadow", "bounded"}
OUTCOMES = {"accepted", "unresolved", "failed", "abandoned"}
RESULTS = {"pass", "fail", "unknown"}
AUTH_CATEGORIES = {"subscription", "oauth", "api-key", "unknown"}
TIME_KEYS = ("queue", "model", "tool", "review", "retry", "handoff", "human")
TOKEN_KEYS = ("input", "output", "cache_read", "cache_write", "reasoning", "total")
MAX_SOURCE_BYTES = 64 * 1024 * 1024
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
AGY_MODEL_RE = re.compile(r'Propagating selected model override to backend: label="([^"]+)"')
AGY_REQUESTED_RE = re.compile(r"Resolving model ([A-Za-z0-9._:/-]+)\s*$", re.MULTILINE)


class RoutingError(Exception):
    """An input or durable-record error that should stop without mutation."""


def fail(message: str) -> None:
    raise RoutingError(message)


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value: Any) -> str:
    raw = value if isinstance(value, bytes) else canonical(value).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(value: Any, field: str) -> dt.datetime:
    if not isinstance(value, str) or not value:
        fail(f"{field} must be an ISO-8601 timestamp")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{field} must be an ISO-8601 timestamp")
    if parsed.tzinfo is None:
        fail(f"{field} must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def nullable_number(value: Any, field: str, *, integer: bool = False) -> Any:
    if value is None:
        return None
    valid = isinstance(value, int) and not isinstance(value, bool) if integer else isinstance(value, (int, float)) and not isinstance(value, bool)
    if not valid or not math.isfinite(float(value)) or value < 0:
        kind = "non-negative integer or null" if integer else "non-negative number or null"
        fail(f"{field} must be a {kind}")
    return value


def need_object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{field} must be an object")
    return value


def need_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{field} must be a non-empty string")
    return value


def need_id(value: Any, field: str) -> str:
    text = need_text(value, field)
    if not ID_RE.fullmatch(text):
        fail(f"{field} contains unsupported characters")
    return text


def default_data_dir() -> Path:
    if os.environ.get("FM_DATA_OVERRIDE"):
        return Path(os.environ["FM_DATA_OVERRIDE"])
    home = Path(os.environ.get("FM_HOME", Path(__file__).resolve().parent.parent))
    return home / "data"


def default_store() -> Path:
    return default_data_dir() / "model-routing" / "outcomes.jsonl"


def default_shadow_store() -> Path:
    return default_data_dir() / "model-routing" / "shadow-decisions.jsonl"


def default_legacy_log() -> Path:
    return default_data_dir() / "dispatch-log.tsv"


def read_private(path_value: Any, field: str, *, text: bool = True) -> tuple[Any, str]:
    path = Path(need_text(path_value, field)).expanduser()
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"cannot read {field}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(f"{field} must name a regular non-symlink file")
    if info.st_size > MAX_SOURCE_BYTES:
        fail(f"{field} exceeds the {MAX_SOURCE_BYTES}-byte safety bound")
    try:
        raw = path.read_bytes()
    except OSError as exc:
        fail(f"cannot read {field}: {exc}")
    if text:
        try:
            return raw.decode("utf-8"), hashlib.sha256(raw).hexdigest()
        except UnicodeDecodeError:
            fail(f"{field} is not UTF-8 text")
    return raw, hashlib.sha256(raw).hexdigest()


def load_json_file(path_value: Any, field: str) -> tuple[Any, str]:
    raw, source_digest = read_private(path_value, field)
    try:
        return json.loads(raw), source_digest
    except json.JSONDecodeError as exc:
        fail(f"{field} is not valid JSON: {exc}")


def json_lines(raw: str, field: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"{field} line {number} is not valid JSON: {exc}")
        if not isinstance(row, dict):
            fail(f"{field} line {number} must be a JSON object")
        rows.append(row)
    return rows


def all_or_unknown(values: Iterable[Any]) -> Any:
    items = list(values)
    if not items or any(not isinstance(value, (int, float)) or isinstance(value, bool) for value in items):
        return None
    return sum(items)


def one_or_unknown(values: Iterable[Any]) -> Any:
    found = {value for value in values if value is not None}
    return next(iter(found)) if len(found) == 1 else None


def token_row(model: Any, provider: Any, usage: dict[str, Any], mapping: dict[str, str], *, service_tier: Any = None) -> dict[str, Any]:
    tokens: dict[str, Any] = {}
    for target, source in mapping.items():
        value = usage.get(source)
        tokens[target] = value if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0 else None
    return {
        "model": model if isinstance(model, str) and model else None,
        "provider": provider if isinstance(provider, str) and provider else None,
        "service_tier": service_tier if isinstance(service_tier, str) and service_tier else None,
        "tokens": tokens,
    }


def total_tokens(models: list[dict[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key in TOKEN_KEYS:
        result[key] = all_or_unknown(row["tokens"].get(key) for row in models)
    return result


def parse_pi(source: dict[str, Any]) -> dict[str, Any]:
    raw, source_digest = read_private(source.get("path"), "native_receipt.path")
    rows = json_lines(raw, "native_receipt.path")
    requests = [row for row in rows if row.get("type") == "custom" and row.get("customType") == "fm-routing-request" and isinstance(row.get("data"), dict)]
    latest: dict[str, dict[str, Any]] = {}
    anonymous = 0
    for row in rows:
        message = row.get("message")
        if row.get("type") != "message" or not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        key = row.get("id")
        if not isinstance(key, str):
            anonymous += 1
            key = f"anonymous:{anonymous}"
        latest[key] = row
    assistants = list(latest.values())
    models: list[dict[str, Any]] = []
    for row in assistants:
        message = row["message"]
        usage = message.get("usage") if isinstance(message.get("usage"), dict) else {}
        models.append(token_row(message.get("model"), message.get("provider"), usage, {
            "input": "input", "output": "output", "cache_read": "cacheRead",
            "cache_write": "cacheWrite", "reasoning": "reasoning", "total": "totalTokens",
        }))
    request_data = [row["data"] for row in requests]
    timestamps = [row.get("timestamp") for row in rows if isinstance(row.get("timestamp"), str)]
    return {
        "kind": "pi-session",
        "source_sha256": source_digest,
        "session_id": next((row.get("id") for row in rows if row.get("type") == "session"), None),
        "request_count": len(request_data),
        "response_count": len(assistants),
        "task_id_receipt": one_or_unknown(item.get("taskId") for item in request_data),
        "requested_model_receipt": one_or_unknown(item.get("selectedModel") or item.get("requestedModel") for item in request_data),
        "selected_effort_receipt": one_or_unknown(item.get("selectedThinkingLevel") for item in request_data),
        "effective_model": one_or_unknown((item.get("payloadModel") for item in request_data)) or one_or_unknown(row["message"].get("model") for row in assistants),
        "effective_effort": one_or_unknown(item.get("payloadReasoningEffort") for item in request_data),
        "provider": one_or_unknown((item.get("provider") for item in request_data)) or one_or_unknown(row["message"].get("provider") for row in assistants),
        "api": one_or_unknown((item.get("api") for item in request_data)) or one_or_unknown(row["message"].get("api") for row in assistants),
        "models": models,
        "tokens": total_tokens(models),
        "first_native_at": min(timestamps) if timestamps else None,
        "last_native_at": max(timestamps) if timestamps else None,
        "native_duration_ms": None,
        "native_reported_cost_usd": all_or_unknown(
            row["message"].get("usage", {}).get("cost", {}).get("total")
            if isinstance(row["message"].get("usage"), dict) and isinstance(row["message"].get("usage", {}).get("cost"), dict) else None
            for row in assistants
        ),
        "completeness": {
            "request_payload": "complete" if request_data else "missing",
            "usage": "complete" if assistants and all(value is not None for value in total_tokens(models).values()) else "partial",
            "effort": "provider-request" if request_data and one_or_unknown(item.get("payloadReasoningEffort") for item in request_data) else "unknown",
            "attribution": "task-entry" if request_data and one_or_unknown(item.get("taskId") for item in request_data) else "manifest-only",
        },
    }


def parse_claude_result(source: dict[str, Any]) -> dict[str, Any]:
    receipt, source_digest = load_json_file(source.get("path"), "native_receipt.path")
    receipt = need_object(receipt, "native_receipt.path")
    model_usage = receipt.get("modelUsage")
    models: list[dict[str, Any]] = []
    if isinstance(model_usage, dict):
        for model, usage in sorted(model_usage.items()):
            if not isinstance(usage, dict):
                continue
            row = token_row(usage.get("canonicalModel") or model, "anthropic" if usage.get("provider") == "firstParty" else usage.get("provider"), usage, {
                "input": "inputTokens", "output": "outputTokens",
                "cache_read": "cacheReadInputTokens", "cache_write": "cacheCreationInputTokens",
                "reasoning": "thinkingTokens",
            }, service_tier=receipt.get("usage", {}).get("service_tier") if isinstance(receipt.get("usage"), dict) else None)
            row["tokens"]["total"] = None
            models.append(row)
    if not models and isinstance(receipt.get("usage"), dict):
        usage = receipt["usage"]
        model = source.get("requested_model")
        models.append(token_row(model, "anthropic", usage, {
            "input": "input_tokens", "output": "output_tokens",
            "cache_read": "cache_read_input_tokens", "cache_write": "cache_creation_input_tokens",
        }, service_tier=usage.get("service_tier")))
        models[-1]["tokens"]["reasoning"] = usage.get("output_tokens_details", {}).get("thinking_tokens") if isinstance(usage.get("output_tokens_details"), dict) else None
        models[-1]["tokens"]["total"] = None
    usage = receipt.get("usage") if isinstance(receipt.get("usage"), dict) else {}
    requested_model = source.get("requested_model")
    native_models = {row.get("model") for row in models if row.get("model")}
    main_model = requested_model if requested_model in native_models else (next(iter(native_models)) if len(native_models) == 1 else None)
    return {
        "kind": "claude-result", "source_sha256": source_digest,
        "session_id": receipt.get("session_id"), "request_count": receipt.get("num_turns"),
        "response_count": receipt.get("num_turns"), "task_id_receipt": None,
        "requested_model_receipt": source.get("requested_model"),
        "selected_effort_receipt": source.get("requested_effort"),
        "effective_model": main_model, "effective_effort": None,
        "provider": "anthropic", "api": "claude-code",
        "models": models, "tokens": total_tokens(models),
        "first_native_at": None, "last_native_at": None,
        "native_duration_ms": receipt.get("duration_api_ms") if isinstance(receipt.get("duration_api_ms"), (int, float)) else None,
        "native_reported_cost_usd": receipt.get("total_cost_usd") if isinstance(receipt.get("total_cost_usd"), (int, float)) else None,
        "completeness": {"request_payload": "unavailable", "usage": "complete" if models else "missing", "effort": "requested-only", "attribution": "manifest-plus-session"},
    }


def parse_claude_session(source: dict[str, Any]) -> dict[str, Any]:
    raw, source_digest = read_private(source.get("path"), "native_receipt.path")
    rows = json_lines(raw, "native_receipt.path")
    latest: dict[str, dict[str, Any]] = {}
    anonymous = 0
    for row in rows:
        message = row.get("message")
        if row.get("type") != "assistant" or not isinstance(message, dict):
            continue
        key = message.get("id") or row.get("uuid")
        if not isinstance(key, str):
            anonymous += 1
            key = f"anonymous:{anonymous}"
        latest[key] = row
    models: list[dict[str, Any]] = []
    for row in latest.values():
        message = row["message"]
        usage = message.get("usage") if isinstance(message.get("usage"), dict) else {}
        model_row = token_row(message.get("model"), "anthropic", usage, {
            "input": "input_tokens", "output": "output_tokens",
            "cache_read": "cache_read_input_tokens", "cache_write": "cache_creation_input_tokens",
        }, service_tier=usage.get("service_tier"))
        model_row["tokens"]["reasoning"] = usage.get("output_tokens_details", {}).get("thinking_tokens") if isinstance(usage.get("output_tokens_details"), dict) else None
        model_row["tokens"]["total"] = None
        models.append(model_row)
    timestamps = [row.get("timestamp") for row in latest.values() if isinstance(row.get("timestamp"), str)]
    return {
        "kind": "claude-session", "source_sha256": source_digest,
        "session_id": one_or_unknown(row.get("sessionId") for row in latest.values()),
        "request_count": len(latest), "response_count": len(latest), "task_id_receipt": None,
        "requested_model_receipt": source.get("requested_model"),
        "selected_effort_receipt": source.get("requested_effort"),
        "effective_model": one_or_unknown(row["message"].get("model") for row in latest.values()),
        "effective_effort": None, "provider": "anthropic", "api": "claude-code",
        "models": models, "tokens": total_tokens(models),
        "first_native_at": min(timestamps) if timestamps else None,
        "last_native_at": max(timestamps) if timestamps else None,
        "native_duration_ms": None, "native_reported_cost_usd": None,
        "completeness": {"request_payload": "unavailable", "usage": "complete" if models else "missing", "effort": "requested-only", "attribution": "manifest-plus-session"},
    }


def parse_agy(source: dict[str, Any]) -> dict[str, Any]:
    receipt, source_digest = load_json_file(source.get("path"), "native_receipt.path")
    receipt = need_object(receipt, "native_receipt.path")
    usage = receipt.get("usage") if isinstance(receipt.get("usage"), dict) else {}
    effective_model = None
    effective_effort = None
    log_digest = None
    if source.get("native_log_path") is not None:
        log, log_digest = read_private(source.get("native_log_path"), "native_receipt.native_log_path")
        requested = AGY_REQUESTED_RE.findall(log)
        labels = AGY_MODEL_RE.findall(log)
        effective_model = requested[-1] if requested else None
        if labels:
            suffix = re.search(r"\((Low|Medium|High)\)$", labels[-1])
            effective_effort = suffix.group(1).lower() if suffix else None
    model_row = token_row(effective_model, "google", usage, {
        "input": "input_tokens", "output": "output_tokens", "cache_read": "cache_read_tokens",
        "reasoning": "thinking_tokens", "total": "total_tokens",
    })
    model_row["tokens"]["cache_write"] = None
    duration = receipt.get("duration_seconds")
    return {
        "kind": "agy-result", "source_sha256": source_digest,
        "supporting_source_sha256": log_digest,
        "session_id": receipt.get("conversation_id"), "request_count": receipt.get("num_turns"),
        "response_count": receipt.get("num_turns"), "task_id_receipt": None,
        "requested_model_receipt": source.get("requested_model"),
        "selected_effort_receipt": source.get("requested_effort"),
        "effective_model": effective_model, "effective_effort": effective_effort,
        "provider": "google", "api": "agy",
        "models": [model_row], "tokens": total_tokens([model_row]),
        "first_native_at": None, "last_native_at": None,
        "native_duration_ms": duration * 1000 if isinstance(duration, (int, float)) else None,
        "native_reported_cost_usd": None,
        "completeness": {"request_payload": "selected-model-log" if log_digest else "unavailable", "usage": "complete" if usage else "missing", "effort": "native-model-label" if effective_effort else "requested-only", "attribution": "manifest-plus-conversation"},
    }


def parse_native(source_value: Any) -> dict[str, Any]:
    source = need_object(source_value, "native_receipt")
    kind = source.get("kind")
    if kind == "pi-session":
        return parse_pi(source)
    if kind == "claude-result":
        return parse_claude_result(source)
    if kind == "claude-session":
        return parse_claude_session(source)
    if kind == "agy-result":
        return parse_agy(source)
    fail("native_receipt.kind must be pi-session, claude-result, claude-session, or agy-result")


def sanitize_quota(path_value: Any, provider: str, field: str) -> dict[str, Any]:
    snapshot, source_digest = load_json_file(path_value, field)
    snapshot = need_object(snapshot, field)
    if snapshot.get("schemaVersion") != 5:
        fail(f"{field} must be a quota-axi schemaVersion 5 snapshot")
    rows = snapshot.get("providers")
    if not isinstance(rows, list):
        fail(f"{field}.providers must be an array")
    matches = [row for row in rows if isinstance(row, dict) and row.get("provider") == provider]
    if len(matches) != 1:
        fail(f"{field} must contain exactly one provider row for {provider}")
    row = matches[0]
    windows = []
    for window in row.get("windows", []) if isinstance(row.get("windows"), list) else []:
        if not isinstance(window, dict):
            continue
        windows.append({key: window.get(key) for key in ("id", "label", "kind", "resetsAt", "percentRemaining")})
    semantics = row.get("quotaSemantics") if isinstance(row.get("quotaSemantics"), dict) else None
    return {"source_sha256": source_digest, "generated_at": snapshot.get("generatedAt"), "provider": provider, "windows": windows, "quota_semantics": semantics}


def quota_record(value: Any) -> Any:
    if value is None:
        return None
    quota = need_object(value, "quota")
    provider = need_text(quota.get("provider"), "quota.provider")
    before = sanitize_quota(quota.get("before_path"), provider, "quota.before_path")
    after = sanitize_quota(quota.get("after_path"), provider, "quota.after_path")
    concurrent = quota.get("concurrent_activity")
    if concurrent not in (True, False, None):
        fail("quota.concurrent_activity must be true, false, or null")
    attribution = quota.get("attribution")
    if attribution not in {"exclusive", "shared", "unknown"}:
        fail("quota.attribution must be exclusive, shared, or unknown")
    before_windows = {row.get("id"): row for row in before["windows"] if row.get("id")}
    after_windows = {row.get("id"): row for row in after["windows"] if row.get("id")}
    deltas = []
    reset_crossed = False
    for window_id in sorted(before_windows.keys() & after_windows.keys()):
        left, right = before_windows[window_id], after_windows[window_id]
        same_reset = left.get("resetsAt") == right.get("resetsAt")
        if not same_reset:
            reset_crossed = True
        left_percent, right_percent = left.get("percentRemaining"), right.get("percentRemaining")
        attributable = concurrent is False and attribution == "exclusive" and same_reset
        delta = left_percent - right_percent if attributable and isinstance(left_percent, (int, float)) and isinstance(right_percent, (int, float)) else None
        deltas.append({"window_id": window_id, "before_percent_remaining": left_percent, "after_percent_remaining": right_percent, "reset_crossed": not same_reset, "attributed_consumption_percent_points": delta})
    return {"provider": provider, "before": before, "after": after, "concurrent_activity": concurrent, "attribution": attribution, "reset_crossed": reset_crossed, "window_deltas": deltas,
            "note": "Window deltas are never summed; shared and model windows may describe the same allowance use."}


def validate_route(value: Any) -> dict[str, Any]:
    route = copy.deepcopy(need_object(value, "route"))
    for key in ("harness", "provider", "requested_model", "requested_effort"):
        route[key] = need_text(route.get(key), f"route.{key}")
    auth = route.get("auth_category")
    if auth not in AUTH_CATEGORIES:
        fail("route.auth_category must be subscription, oauth, api-key, or unknown")
    route["context_tier"] = need_text(route.get("context_tier"), "route.context_tier")
    route["service_tier"] = need_text(route.get("service_tier"), "route.service_tier")
    return route


def validate_time(manifest: dict[str, Any]) -> tuple[str, str, dict[str, Any]]:
    started = need_text(manifest.get("started_at"), "started_at")
    finished = need_text(manifest.get("finished_at"), "finished_at")
    start_time, finish_time = parse_time(started, "started_at"), parse_time(finished, "finished_at")
    if finish_time < start_time:
        fail("finished_at must not precede started_at")
    values = need_object(manifest.get("time_ms"), "time_ms")
    cleaned = {key: nullable_number(values.get(key), f"time_ms.{key}") for key in TIME_KEYS}
    cleaned["end_to_end"] = round((finish_time - start_time).total_seconds() * 1000)
    return started, finished, cleaned


def validate_grading(value: Any, outcome: str) -> dict[str, Any]:
    grade = copy.deepcopy(need_object(value, "grading"))
    method = grade.get("method")
    if method not in {"deterministic", "blind-review", "none"}:
        fail("grading.method must be deterministic, blind-review, or none")
    independent = grade.get("independent")
    if independent not in (True, False, None):
        fail("grading.independent must be true, false, or null")
    for key in ("first_pass", "final_result"):
        if grade.get(key) not in RESULTS:
            fail(f"grading.{key} must be pass, fail, or unknown")
    for key in ("defect_count", "fix_count", "retry_count"):
        grade[key] = nullable_number(grade.get(key), f"grading.{key}", integer=True)
    receipts = grade.get("receipts")
    if not isinstance(receipts, list):
        fail("grading.receipts must be an array")
    cleaned_receipts = []
    for index, receipt in enumerate(receipts):
        item = need_object(receipt, f"grading.receipts[{index}]")
        cleaned = {"kind": need_text(item.get("kind"), f"grading.receipts[{index}].kind"),
                   "id": need_text(item.get("id"), f"grading.receipts[{index}].id"),
                   "passed": item.get("passed")}
        if cleaned["passed"] not in (True, False):
            fail(f"grading.receipts[{index}].passed must be boolean")
        if item.get("sha256") is not None:
            sha = need_text(item.get("sha256"), f"grading.receipts[{index}].sha256")
            if not re.fullmatch(r"[0-9a-f]{64}", sha):
                fail(f"grading.receipts[{index}].sha256 must be lowercase SHA-256")
            cleaned["sha256"] = sha
        cleaned_receipts.append(cleaned)
    grade["receipts"] = cleaned_receipts
    overhead = need_object(grade.get("overhead"), "grading.overhead")
    overhead_tokens = overhead.get("tokens")
    if overhead_tokens is not None:
        overhead_tokens = need_object(overhead_tokens, "grading.overhead.tokens")
        overhead_tokens = {key: nullable_number(overhead_tokens.get(key), f"grading.overhead.tokens.{key}", integer=True) for key in TOKEN_KEYS}
    grade["overhead"] = {
        "duration_ms": nullable_number(overhead.get("duration_ms"), "grading.overhead.duration_ms"),
        "tokens": overhead_tokens,
        "actual_incremental_usd": nullable_number(overhead.get("actual_incremental_usd"), "grading.overhead.actual_incremental_usd"),
    }
    if outcome == "accepted":
        if method == "none" or independent is not True:
            fail("accepted outcome requires an independent deterministic or blind review")
        if grade["final_result"] != "pass" or not any(row["passed"] for row in cleaned_receipts):
            fail("accepted outcome requires final_result pass and at least one passing receipt")
    return grade


def validate_comparison(value: Any) -> Any:
    if value is None:
        return None
    item = copy.deepcopy(need_object(value, "comparison"))
    item["pair_id"] = need_id(item.get("pair_id"), "comparison.pair_id")
    for key, expected in (("low_risk", True), ("time_critical", False), ("private_external_action", False), ("external_action", False)):
        if item.get(key) is not expected:
            fail(f"comparison.{key} must be {str(expected).lower()} for the initial pilot")
    return item


def validate_handoff(value: Any) -> Any:
    if value is None:
        return None
    item = copy.deepcopy(need_object(value, "handoff"))
    item["alternative_attempt_id"] = need_id(item.get("alternative_attempt_id"), "handoff.alternative_attempt_id")
    if isinstance(item.get("alternatives"), list):
        fail("handoff admits one alternative, not an alternatives array")
    if item.get("side_effects") not in {"none", "reconciled"}:
        fail("handoff.side_effects must be none or reconciled")
    if item.get("quality_preserved") is not True or item.get("privacy_preserved") is not True:
        fail("handoff requires quality_preserved and privacy_preserved true")
    item["reconciliation_receipt"] = need_text(item.get("reconciliation_receipt"), "handoff.reconciliation_receipt")
    return item


def load_prices(path_value: Any) -> tuple[dict[str, Any], str]:
    catalog, catalog_digest = load_json_file(path_value, "--prices")
    catalog = need_object(catalog, "--prices")
    if catalog.get("schema") != PRICE_SCHEMA:
        fail(f"--prices schema must be {PRICE_SCHEMA}")
    parse_time(catalog.get("observed_at"), "prices.observed_at")
    entries = catalog.get("entries")
    if not isinstance(entries, list):
        fail("prices.entries must be an array")
    for index, entry_value in enumerate(entries):
        entry = need_object(entry_value, f"prices.entries[{index}]")
        for key in ("provider", "model", "context_tier", "service_tier", "source_url", "effective_from"):
            need_text(entry.get(key), f"prices.entries[{index}].{key}")
        if not re.match(r"^https://", entry["source_url"]):
            fail(f"prices.entries[{index}].source_url must be https")
        parse_time(entry["effective_from"], f"prices.entries[{index}].effective_from")
        if entry.get("effective_to") is not None:
            parse_time(entry["effective_to"], f"prices.entries[{index}].effective_to")
        if entry.get("currency") != "USD" or entry.get("reasoning") != "included_in_output":
            fail(f"prices.entries[{index}] must use USD and reasoning included_in_output")
        rates = need_object(entry.get("per_million_tokens"), f"prices.entries[{index}].per_million_tokens")
        for key in ("input", "output", "cache_read", "cache_write"):
            nullable_number(rates.get(key), f"prices.entries[{index}].per_million_tokens.{key}")
    return catalog, catalog_digest


def apply_prices(native: dict[str, Any], route: dict[str, Any], finished_at: str, path_value: Any) -> dict[str, Any]:
    if path_value is None:
        return {"api_equivalent_usd": None, "price_catalog_sha256": None, "price_sources": [], "unpriced_models": sorted({row.get("model") or "unknown" for row in native["models"]})}
    catalog, catalog_digest = load_prices(path_value)
    at = parse_time(finished_at, "finished_at")
    total = 0.0
    sources = []
    missing = []
    for row in native["models"]:
        model = row.get("model")
        provider = row.get("provider") or native.get("provider")
        service = row.get("service_tier") or route.get("service_tier")
        context = route.get("context_tier")
        candidates = []
        for entry in catalog["entries"]:
            if (entry.get("provider"), entry.get("model"), entry.get("service_tier"), entry.get("context_tier")) != (provider, model, service, context):
                continue
            start = parse_time(entry["effective_from"], "price.effective_from")
            end = parse_time(entry["effective_to"], "price.effective_to") if entry.get("effective_to") else None
            if start <= at and (end is None or at < end):
                candidates.append(entry)
        if len(candidates) != 1:
            missing.append(model or "unknown")
            continue
        tokens = row["tokens"]
        rates = candidates[0]["per_million_tokens"]
        fields = (("input", "input"), ("output", "output"), ("cache_read", "cache_read"), ("cache_write", "cache_write"))
        if any(tokens.get(token_key) is None or rates.get(rate_key) is None for token_key, rate_key in fields):
            missing.append(model or "unknown")
            continue
        total += sum(tokens[token_key] * rates[rate_key] / 1_000_000 for token_key, rate_key in fields)
        sources.append({"provider": provider, "model": model, "context_tier": context, "service_tier": service, "source_url": candidates[0]["source_url"], "observed_at": catalog["observed_at"]})
    return {"api_equivalent_usd": round(total, 12) if not missing else None, "price_catalog_sha256": catalog_digest, "price_sources": sources, "unpriced_models": sorted(set(missing))}


def fold_rows(rows: list[dict[str, Any]], path: Path, schema: str, key_fields: tuple[str, ...]) -> dict[tuple[Any, ...], dict[str, Any]]:
    latest: dict[tuple[Any, ...], dict[str, Any]] = {}
    for row in rows:
        if row.get("schema") != schema or not isinstance(row.get("record"), dict):
            fail(f"{path} contains an unsupported record")
        key = tuple(row.get(field) for field in key_fields)
        revision = row.get("revision")
        if not all(isinstance(value, str) and value for value in key) or not isinstance(revision, int):
            fail(f"{path} contains a malformed record identity")
        current = latest.get(key)
        if current is None or revision > current["revision"]:
            latest[key] = row
    return latest


def open_store_lock(path: Path) -> Any:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = path.with_name(path.name + ".lock")
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        return os.fdopen(os.open(lock_path, flags, 0o600), "r+")
    except OSError as exc:
        fail(f"cannot lock {path}: {exc}")


def read_store_locked(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    raw, _ = read_private(str(path), str(path))
    return json_lines(raw, str(path))


def fold_events(path: Path, schema: str, key_fields: tuple[str, ...]) -> dict[tuple[Any, ...], dict[str, Any]]:
    if not path.exists():
        return {}
    with open_store_lock(path) as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        return fold_rows(read_store_locked(path), path, schema, key_fields)


def upsert_event(path: Path, schema: str, key_fields: tuple[str, ...], record: dict[str, Any],
                 extra_validate: Any = None) -> dict[str, Any]:
    key = tuple(record[field] for field in key_fields)
    record_digest = digest(record)
    with open_store_lock(path) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        latest = fold_rows(read_store_locked(path), path, schema, key_fields)
        current = latest.get(key)
        if current and current.get("record_sha256") == record_digest:
            return {"action": "noop", "revision": current["revision"], "record_sha256": record_digest}
        if extra_validate is not None:
            extra_validate(latest)
        revision = current["revision"] + 1 if current else 1
        event = {"schema": schema, "event_id": digest({"record": record, "revision": revision}),
                 "recorded_at": now_iso(), **{field: record[field] for field in key_fields},
                 "revision": revision, "record_sha256": record_digest, "record": record}
        if path.exists():
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                fail(f"{path} must be a regular non-symlink file")
        flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(path, flags, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as handle:
                handle.write(canonical(event) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            fail(f"cannot append {path}: {exc}")
        return {"action": "updated" if current else "created", "revision": revision, "record_sha256": record_digest}


def build_record(manifest: dict[str, Any], prices_path: Any) -> dict[str, Any]:
    if manifest.get("schema") != ATTEMPT_SCHEMA:
        fail(f"manifest schema must be {ATTEMPT_SCHEMA}")
    task_id = need_id(manifest.get("task_id"), "task_id")
    attempt_id = need_id(manifest.get("attempt_id"), "attempt_id")
    phase = manifest.get("phase")
    if phase not in PHASES:
        fail("phase must be measurement, shadow, or bounded")
    category = need_text(manifest.get("category"), "category")
    task_shape = need_text(manifest.get("task_shape"), "task_shape")
    route = validate_route(manifest.get("route"))
    native = parse_native(manifest.get("native_receipt"))
    if native.get("task_id_receipt") not in (None, task_id):
        fail("native Pi task id does not match manifest task_id")
    if native.get("requested_model_receipt") not in (None, route["requested_model"]):
        fail("native requested model does not match route.requested_model")
    if native.get("selected_effort_receipt") not in (None, route["requested_effort"]):
        fail("native selected effort does not match route.requested_effort")
    requirements = manifest.get("requirements")
    if requirements is not None:
        requirements = need_object(requirements, "requirements")
        if requirements.get("effective_model") is not None and native.get("effective_model") != requirements.get("effective_model"):
            fail(f"effective model requirement not proven: expected {requirements.get('effective_model')}, got {native.get('effective_model') or 'unknown'}")
        if requirements.get("effective_effort") is not None and native.get("effective_effort") != requirements.get("effective_effort"):
            fail(f"effective effort requirement not proven: expected {requirements.get('effective_effort')}, got {native.get('effective_effort') or 'unknown'}")
    started, finished, time_values = validate_time(manifest)
    billing = need_object(manifest.get("billing"), "billing")
    billing_record = {
        "actual_incremental_usd": nullable_number(billing.get("actual_incremental_usd"), "billing.actual_incremental_usd"),
        "fixed_subscription_usd": nullable_number(billing.get("fixed_subscription_usd"), "billing.fixed_subscription_usd"),
    }
    billing_record.update(apply_prices(native, route, finished, prices_path))
    outcome = manifest.get("outcome")
    if outcome not in OUTCOMES:
        fail("outcome must be accepted, unresolved, failed, or abandoned")
    record = {
        "schema": ATTEMPT_SCHEMA, "task_id": task_id, "attempt_id": attempt_id,
        "phase": phase, "category": category, "task_shape": task_shape,
        "route": route, "native": native, "requirements": copy.deepcopy(requirements),
        "started_at": started, "finished_at": finished, "time_ms": time_values,
        "billing": billing_record, "quota": quota_record(manifest.get("quota")),
        "grading": validate_grading(manifest.get("grading"), outcome),
        "comparison": validate_comparison(manifest.get("comparison")),
        "handoff": validate_handoff(manifest.get("handoff")),
        "outcome": outcome,
    }
    return record


def import_attempt(args: argparse.Namespace) -> dict[str, Any]:
    manifest, _ = load_json_file(args.manifest, "--manifest")
    manifest = need_object(manifest, "--manifest")
    record = build_record(manifest, args.prices)
    store = Path(args.store).expanduser()
    def comparison_cap(latest: dict[tuple[Any, ...], dict[str, Any]]) -> None:
        if not record.get("comparison"):
            return
        pair_ids = {event["record"]["comparison"]["pair_id"] for key, event in latest.items()
                    if key != (record["task_id"], record["attempt_id"])
                    and event["record"].get("category") == record["category"] and event["record"].get("comparison")}
        pair_ids.add(record["comparison"]["pair_id"])
        if len(pair_ids) > 2:
            fail(f"initial pilot already has two comparison pairs for category {record['category']}")
    result = upsert_event(store, EVENT_SCHEMA, ("task_id", "attempt_id"), record, comparison_cap)
    return {"ok": True, "task_id": record["task_id"], "attempt_id": record["attempt_id"], **result}


def validate_candidate(value: Any, index: int) -> dict[str, Any]:
    item = copy.deepcopy(need_object(value, f"candidates[{index}]"))
    item["route"] = validate_route(item.get("route"))
    for key in ("eligibility", "capability_class_fit", "runway_feasibility"):
        if item.get(key) not in {"pass", "fail", "unknown"}:
            fail(f"candidates[{index}].{key} must be pass, fail, or unknown")
    priority = item.get("spend_priority")
    if priority is not None and (not isinstance(priority, (int, float)) or isinstance(priority, bool) or not math.isfinite(float(priority))):
        fail(f"candidates[{index}].spend_priority must be a number or null")
    item["uncertainty"] = need_text(item.get("uncertainty"), f"candidates[{index}].uncertainty")
    item["explanation"] = need_text(item.get("explanation"), f"candidates[{index}].explanation")
    return item


def import_shadow(args: argparse.Namespace) -> dict[str, Any]:
    manifest, _ = load_json_file(args.manifest, "--manifest")
    manifest = need_object(manifest, "--manifest")
    if manifest.get("schema") != SHADOW_SCHEMA:
        fail(f"manifest schema must be {SHADOW_SCHEMA}")
    task_id = need_id(manifest.get("task_id"), "task_id")
    decision_id = need_id(manifest.get("decision_id"), "decision_id")
    candidates = manifest.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        fail("candidates must be a non-empty array")
    record = {
        "schema": SHADOW_SCHEMA, "task_id": task_id, "decision_id": decision_id,
        "at": need_text(manifest.get("at"), "at"),
        "category": need_text(manifest.get("category"), "category"),
        "task_shape": need_text(manifest.get("task_shape"), "task_shape"),
        "candidates": [validate_candidate(item, index) for index, item in enumerate(candidates)],
        "recommended_route": validate_route(manifest.get("recommended_route")),
        "explanation": need_text(manifest.get("explanation"), "explanation"),
        "evidence_sufficient_for_bounded_routing": manifest.get("evidence_sufficient_for_bounded_routing"),
    }
    parse_time(record["at"], "at")
    if record["evidence_sufficient_for_bounded_routing"] not in (True, False):
        fail("evidence_sufficient_for_bounded_routing must be boolean")
    recommended = canonical(record["recommended_route"])
    if recommended not in {canonical(item["route"]) for item in record["candidates"]}:
        fail("recommended_route must exactly match one accounted candidate")
    store = Path(args.shadow_store).expanduser()
    result = upsert_event(store, SHADOW_EVENT_SCHEMA, ("task_id", "decision_id"), record)
    return {"ok": True, "task_id": task_id, "decision_id": decision_id, **result}


def metric(values: Iterable[Any]) -> dict[str, Any]:
    items = list(values)
    known = [float(value) for value in items if isinstance(value, (int, float)) and not isinstance(value, bool)]
    total = round(sum(known), 12) if known else (0 if not items else None)
    return {"known_total": total, "known_count": len(known), "unknown_count": len(items) - len(known)}


def route_name(record: dict[str, Any]) -> str:
    route = record["route"]
    effective_model = record["native"].get("effective_model") or route["requested_model"]
    effective_effort = record["native"].get("effective_effort") or f"requested:{route['requested_effort']}"
    return f"{route['harness']}/{route['provider']}/{effective_model}/{effective_effort}"


def legacy_history(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"path": str(path), "rows": 0, "groups": []}
    raw, source_digest = read_private(str(path), str(path))
    reader = csv.DictReader(raw.splitlines(), delimiter="\t")
    required = {"task", "harness", "model", "effort", "shape", "outcome"}
    if reader.fieldnames is None or not required.issubset(reader.fieldnames):
        fail(f"{path} is not a compatible dispatch-log TSV")
    groups: dict[tuple[str, str, str], int] = {}
    rows = 0
    for row in reader:
        if not any(row.values()):
            continue
        rows += 1
        key = (row.get("shape") or "unknown", "/".join((row.get("harness") or "unknown", row.get("model") or "unknown", row.get("effort") or "unknown")), row.get("outcome") or "unknown")
        groups[key] = groups.get(key, 0) + 1
    return {"path": str(path), "source_sha256": source_digest, "rows": rows,
            "groups": [{"task_shape": key[0], "route": key[1], "outcome": key[2], "samples": count}
                       for key, count in sorted(groups.items())],
            "completeness": "historical outcome only; token, cost, quota, native effort, and end-to-end attribution unknown"}


def build_scorecard(store: Path, shadow_store: Path, legacy_log: Path) -> dict[str, Any]:
    records = [event["record"] for event in fold_events(store, EVENT_SCHEMA, ("task_id", "attempt_id")).values()]
    shadows = [event["record"] for event in fold_events(shadow_store, SHADOW_EVENT_SCHEMA, ("task_id", "decision_id")).values()]
    groups: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for record in records:
        groups.setdefault((record["category"], record["task_shape"], route_name(record)), []).append(record)
    route_groups = []
    for (category, shape, route), items in sorted(groups.items()):
        route_groups.append({
            "category": category, "task_shape": shape, "route": route,
            "attempts": len(items), "accepted_attempts": sum(item["outcome"] == "accepted" for item in items),
            "outcomes": {name: sum(item["outcome"] == name for item in items) for name in sorted(OUTCOMES)},
            "tokens": {key: metric(item["native"]["tokens"].get(key) for item in items) for key in TOKEN_KEYS},
            "time_ms": {key: metric(item["time_ms"].get(key) for item in items) for key in (*TIME_KEYS, "end_to_end")},
            "actual_incremental_usd": metric(item["billing"].get("actual_incremental_usd") for item in items),
            "fixed_subscription_usd": metric(item["billing"].get("fixed_subscription_usd") for item in items),
            "api_equivalent_usd": metric(item["billing"].get("api_equivalent_usd") for item in items),
            "grader_overhead": {
                "duration_ms": metric(item["grading"]["overhead"].get("duration_ms") for item in items),
                "actual_incremental_usd": metric(item["grading"]["overhead"].get("actual_incremental_usd") for item in items),
                "tokens": {key: metric((item["grading"]["overhead"].get("tokens") or {}).get(key) for item in items) for key in TOKEN_KEYS},
            },
            "uncertainty": sorted({reason for item in items for reason in (
                (["effective effort unknown"] if item["native"].get("effective_effort") is None else [])
                + (["API-equivalent price unknown"] if item["billing"].get("api_equivalent_usd") is None else [])
                + (["quota attribution unknown"] if not item.get("quota") or item["quota"].get("attribution") != "exclusive" else [])
            )}),
        })
    task_rows = []
    by_task: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        by_task.setdefault(record["task_id"], []).append(record)
    for task_id, items in sorted(by_task.items()):
        accepted_items = [item for item in items if item["outcome"] == "accepted"]
        accepted = bool(accepted_items)
        accepted_span = None
        if accepted:
            task_start = min(parse_time(item["started_at"], "started_at") for item in items)
            accepted_finish = min(parse_time(item["finished_at"], "finished_at") for item in accepted_items)
            accepted_span = max(0, round((accepted_finish - task_start).total_seconds() * 1000))
        task_rows.append({"task_id": task_id, "category": one_or_unknown(item["category"] for item in items),
                          "task_shape": one_or_unknown(item["task_shape"] for item in items),
                          "attempts": len(items), "accepted": accepted,
                          "accepted_task_actual_incremental_usd": metric(item["billing"].get("actual_incremental_usd") for item in items) if accepted else None,
                          "accepted_task_api_equivalent_usd": metric(item["billing"].get("api_equivalent_usd") for item in items) if accepted else None,
                          "accepted_task_fixed_subscription_usd": metric(item["billing"].get("fixed_subscription_usd") for item in items) if accepted else None,
                          "accepted_task_end_to_end_ms": metric([accepted_span]) if accepted else None,
                          "grader_actual_incremental_usd": metric(item["grading"]["overhead"].get("actual_incremental_usd") for item in items),
                          "grader_duration_ms": metric(item["grading"]["overhead"].get("duration_ms") for item in items),
                          "unresolved_or_failure_actual_usd": metric(item["billing"].get("actual_incremental_usd") for item in items if item["outcome"] != "accepted")})
    return {"schema": "fm-routing-scorecard.v1", "generated_at": now_iso(), "attempt_count": len(records),
            "task_count": len(by_task), "routes": route_groups, "tasks": task_rows,
            "shadow_recommendations": [{"task_id": row["task_id"], "decision_id": row["decision_id"], "category": row["category"],
                                         "task_shape": row["task_shape"], "recommended_route": route_name({"route": row["recommended_route"], "native": {"effective_model": None, "effective_effort": None}}),
                                         "evidence_sufficient_for_bounded_routing": row["evidence_sufficient_for_bounded_routing"], "explanation": row["explanation"],
                                         "candidate_evidence": [{"route": route_name({"route": item["route"], "native": {"effective_model": None, "effective_effort": None}}),
                                                                 "uncertainty": item["uncertainty"], "explanation": item["explanation"]}
                                                                for item in row["candidates"]]}
                                        for row in sorted(shadows, key=lambda item: (item["task_id"], item["decision_id"]))],
            "legacy_history": legacy_history(legacy_log),
            "interpretation": "Descriptive evidence only. Heterogeneous tasks and small samples do not establish a winner; unknown fields stay outside known totals."}


def format_metric(value: dict[str, Any], suffix: str = "") -> str:
    total = value.get("known_total")
    shown = "unknown" if total is None else f"{total:g}{suffix}"
    if value.get("unknown_count"):
        shown += f" (+{value['unknown_count']} unknown)"
    return shown


def render_markdown(scorecard: dict[str, Any]) -> str:
    lines = ["# Model-routing scorecard", "", f"Attempts: {scorecard['attempt_count']} across {scorecard['task_count']} tasks.", "",
             "## Exact routes", "", "| Category | Task shape | Exact route / effort | n | Accepted | Input tokens | Output tokens | Actual incremental | Fixed subscription | API-equivalent | End-to-end | Grader time | Uncertainty |",
             "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
    for row in scorecard["routes"]:
        lines.append("| " + " | ".join([
            row["category"], row["task_shape"], row["route"], str(row["attempts"]), str(row["accepted_attempts"]),
            format_metric(row["tokens"]["input"]), format_metric(row["tokens"]["output"]),
            format_metric(row["actual_incremental_usd"], " USD"), format_metric(row["fixed_subscription_usd"], " USD"),
            format_metric(row["api_equivalent_usd"], " USD"), format_metric(row["time_ms"]["end_to_end"], " ms"),
            format_metric(row["grader_overhead"]["duration_ms"], " ms"), "; ".join(row["uncertainty"]) or "none",
        ]) + " |")
    if not scorecard["routes"]:
        lines.append("| - | - | - | 0 | 0 | unknown | unknown | unknown | unknown | unknown | unknown | unknown | no samples |")
    lines.extend(["", "## Accepted-task and failure cost", "",
                  "| Task | Category | Shape | Attempts | Accepted | Accepted actual | Grader actual | Fixed subscription | API-equivalent | Accepted time | Unresolved/failure actual |",
                  "|---|---|---|---:|---|---:|---:|---:|---:|---:|---:|"])
    for row in scorecard["tasks"]:
        lines.append("| " + " | ".join([
            row["task_id"], row["category"] or "mixed", row["task_shape"] or "mixed", str(row["attempts"]), "yes" if row["accepted"] else "no",
            format_metric(row["accepted_task_actual_incremental_usd"], " USD") if row["accepted_task_actual_incremental_usd"] else "n/a",
            format_metric(row["grader_actual_incremental_usd"], " USD"),
            format_metric(row["accepted_task_fixed_subscription_usd"], " USD") if row["accepted_task_fixed_subscription_usd"] else "n/a",
            format_metric(row["accepted_task_api_equivalent_usd"], " USD") if row["accepted_task_api_equivalent_usd"] else "n/a",
            format_metric(row["accepted_task_end_to_end_ms"], " ms") if row["accepted_task_end_to_end_ms"] else "n/a",
            format_metric(row["unresolved_or_failure_actual_usd"], " USD"),
        ]) + " |")
    if not scorecard["tasks"]:
        lines.append("| - | - | - | 0 | no | n/a | unknown | n/a | n/a | n/a | unknown |")
    lines.extend(["", "## Shadow recommendations", ""])
    if scorecard["shadow_recommendations"]:
        for row in scorecard["shadow_recommendations"]:
            readiness = "bounded-ready" if row["evidence_sufficient_for_bounded_routing"] else "shadow-only"
            lines.append(f"- {row['task_id']} ({row['category']}, {row['task_shape']}): {row['recommended_route']} - {readiness}. {row['explanation']}")
            for candidate in row["candidate_evidence"]:
                lines.append(f"  - {candidate['route']}: {candidate['explanation']} Uncertainty: {candidate['uncertainty']}.")
    else:
        lines.append("- No shadow recommendations recorded.")
    lines.extend(["", "## Legacy dispatch history", ""])
    legacy = scorecard["legacy_history"]
    if legacy["rows"]:
        lines.append(f"{legacy['rows']} pre-measurement outcome rows remain visible but are not mixed into receipt-backed totals.")
        for row in legacy["groups"][:12]:
            lines.append(f"- {row['task_shape']} / {row['route']} / {row['outcome']}: n={row['samples']}.")
        if len(legacy["groups"]) > 12:
            lines.append(f"- {len(legacy['groups']) - 12} more legacy groups are available in JSON output.")
        lines.append(f"Completeness: {legacy['completeness']}.")
    else:
        lines.append("- No compatible legacy dispatch history found.")
    lines.extend(["", scorecard["interpretation"]])
    return "\n".join(lines) + "\n"


def scorecard_command(args: argparse.Namespace) -> Any:
    scorecard = build_scorecard(Path(args.store).expanduser(), Path(args.shadow_store).expanduser(), Path(args.legacy_log).expanduser())
    return scorecard if args.format == "json" else render_markdown(scorecard)


def inspect_command(args: argparse.Namespace) -> dict[str, Any]:
    task_id = need_id(args.task, "--task")
    records = [event["record"] for key, event in fold_events(Path(args.store).expanduser(), EVENT_SCHEMA, ("task_id", "attempt_id")).items() if key[0] == task_id]
    return {"ok": True, "task_id": task_id, "attempts": sorted(records, key=lambda row: row["attempt_id"])}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Import native usage receipts and report model-routing efficiency without choosing or launching a model.",
        epilog="Run '<command> --help' for inputs. Typical flow: import measured attempts, record shadow decisions, then render scorecard.")
    sub = result.add_subparsers(dest="command", required=True)
    imp = sub.add_parser("import", help="idempotently import one task attempt",
                         description="Import one fm-routing-attempt.v1 manifest. Native receipt kinds: pi-session, claude-result, claude-session, agy-result.",
                         epilog="Example: fm-routing-outcomes.py import --manifest attempt.json --prices prices.json --json")
    imp.add_argument("--manifest", required=True)
    imp.add_argument("--store", default=str(default_store()))
    imp.add_argument("--prices", help="private timestamped exact-price catalog")
    imp.add_argument("--json", action="store_true")
    shadow = sub.add_parser("shadow", help="record a quota-informed recommendation without dispatching it",
                            description="Record one fm-routing-shadow.v1 decision after accounting for every candidate; this never dispatches the recommendation.",
                            epilog="Example: fm-routing-outcomes.py shadow --manifest decision.json --json")
    shadow.add_argument("--manifest", required=True)
    shadow.add_argument("--shadow-store", default=str(default_shadow_store()))
    shadow.add_argument("--json", action="store_true")
    score = sub.add_parser("scorecard", help="render compact descriptive evidence",
                           description="Fold latest attempt and shadow revisions, keep compatible legacy TSV history separate, and render descriptive evidence.",
                           epilog="Example: fm-routing-outcomes.py scorecard --format json")
    score.add_argument("--store", default=str(default_store()))
    score.add_argument("--shadow-store", default=str(default_shadow_store()))
    score.add_argument("--legacy-log", default=str(default_legacy_log()), help="compatible pre-measurement dispatch-log TSV")
    score.add_argument("--format", choices=("markdown", "json"), default="markdown")
    inspect = sub.add_parser("inspect", help="show latest attempts for one task",
                             description="Return the folded latest attempt records for one exact task id.",
                             epilog="Example: fm-routing-outcomes.py inspect --task task-id --json")
    inspect.add_argument("--task", required=True)
    inspect.add_argument("--store", default=str(default_store()))
    inspect.add_argument("--json", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "import":
            result = import_attempt(args)
        elif args.command == "shadow":
            result = import_shadow(args)
        elif args.command == "scorecard":
            result = scorecard_command(args)
        else:
            result = inspect_command(args)
        if isinstance(result, str):
            sys.stdout.write(result)
        elif getattr(args, "json", False) or args.command in {"scorecard", "inspect"}:
            print(json.dumps(result, sort_keys=True, indent=2))
        else:
            identity = result.get("attempt_id") or result.get("decision_id")
            print(f"{result['action']}: {result['task_id']}/{identity} revision {result['revision']}")
        return 0
    except RoutingError as exc:
        json_error = getattr(args, "json", False) or (args.command == "scorecard" and args.format == "json")
        if json_error:
            print(json.dumps({"ok": False, "error": str(exc)}, sort_keys=True))
        else:
            print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
