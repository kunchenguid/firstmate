#!/usr/bin/env python3
"""Bounded subprocess orchestration for independent MagiBook PySpark queries.

Import this helper after the init Cell has returned a proven live application.
Every query uses one pre-existing persistent Python Cell and one stable query key.
The helper records exact task ownership in a protected registry so a retry
reconciles the prior task instead of submitting a duplicate.
"""

from __future__ import annotations

import dataclasses
import fcntl
import hashlib
import json
import os
import selectors
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


_QUERY_STATUS_PREFIX = "MAGIBOOK_QUERY_STATUS "
_PROXY_KEYS = (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
)
_SUCCESS_STATES = {"success", "succeeded", "finished", "completed", "done"}
_FAILURE_STATES = {"fail", "failed", "failure", "error"}
_CANCELLED_STATES = {"cancel", "cancelled", "canceled"}
_RUNNING_STATES = {"running", "executing", "processing"}
_WAITING_STATES = {"created", "pending", "queued", "submitted", "waiting"}


class ParallelQueryError(RuntimeError):
    """Base error for invalid or unsafe orchestration state."""


class InitializationRequiredError(ParallelQueryError):
    """Raised before any CLI call when Spark is not proven live."""


class RegistryError(ParallelQueryError):
    """Raised when persistent task ownership is inconsistent or unsafe."""


class CLICommandError(ParallelQueryError):
    """A bounded, redacted MagiBook CLI failure."""

    def __init__(self, category, summary, *, timed_out=False):
        super().__init__(summary)
        self.category = category
        self.summary = summary
        self.timed_out = timed_out


@dataclasses.dataclass(frozen=True)
class QuerySpec:
    """One independent read or aggregation bound to one persistent Cell."""

    key: str
    cell_id: str
    sql: str
    output_rows: int = 50


def render_query_cell(query):
    """Render bounded Python Cell source using the ensured ``spark`` session."""
    if not isinstance(query, QuerySpec):
        raise TypeError("query must be a QuerySpec")
    if not query.key.strip():
        raise ValueError("query key must be non-empty")
    cell_id = str(query.cell_id).strip()
    if not cell_id.isdigit() or int(cell_id) <= 0:
        raise ValueError("query cell id must be a positive integer")
    if not query.sql.strip():
        raise ValueError("query SQL must be non-empty")
    if '"""' in query.sql:
        raise ValueError('query SQL cannot contain a triple-double-quote sequence')
    if not 1 <= query.output_rows <= 1000:
        raise ValueError("output_rows must be between 1 and 1000")
    sql_literal = query.sql.replace("\\", "\\\\")
    return (
        "import json as _magibook_json\n"
        "_magibook_result = spark.sql(\"\"\"{}\"\"\")\n"
        "_magibook_result.show(n={}, truncate=120)\n"
        "print({!r} + _magibook_json.dumps({{\n"
        "    \"applicationId\": spark.sparkContext.applicationId,\n"
        "    \"queryKey\": {!r},\n"
        "}}, sort_keys=True))\n"
    ).format(sql_literal, query.output_rows, _QUERY_STATUS_PREFIX, query.key)


def _redact(value, sensitive_values):
    text = str(value)
    for sensitive in sensitive_values:
        if sensitive:
            text = text.replace(str(sensitive), "<redacted>")
    return text


def _error_category(message, *, timed_out=False):
    if timed_out:
        return "timeout"
    text = message.lower()
    if any(word in text for word in ("authentication", "credential", "login")):
        return "authentication"
    if any(word in text for word in ("authorization", "forbidden", "permission denied")):
        return "authorization"
    if any(word in text for word in ("already running", "concurrent", "overlap", "serializ")):
        return "concurrency"
    if any(word in text for word in ("scheduler", "yarn", "no resources")):
        return "scheduler"
    if any(word in text for word in ("network", "connection", "dns", "timed out")):
        return "network"
    if any(word in text for word in ("analysisexception", "query")):
        return "query"
    return "cli"


class MagiBookCLI:
    """Small argv-only CLI adapter with bounded per-process capture."""

    def __init__(
        self,
        region,
        *,
        executable="magibook",
        command_timeout=60.0,
        max_output_bytes=65536,
        sensitive_values=(),
        popen_factory=subprocess.Popen,
        env=None,
        monotonic=time.monotonic,
    ):
        if not str(region).strip():
            raise ValueError("region must be explicit")
        if command_timeout <= 0:
            raise ValueError("command_timeout must be positive")
        if max_output_bytes < 1024:
            raise ValueError("max_output_bytes must be at least 1024")
        self.region = str(region)
        self.executable = str(executable)
        self.command_timeout = float(command_timeout)
        self.max_output_bytes = int(max_output_bytes)
        self.sensitive_values = tuple(str(item) for item in sensitive_values)
        self.popen_factory = popen_factory
        self.monotonic = monotonic
        child_env = dict(os.environ if env is None else env)
        for key in _PROXY_KEYS:
            child_env.pop(key, None)
        self.env = child_env
        self.children = []

    def _stop_local_child(self, process):
        if process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    def _collect_bounded(self, process):
        selector = selectors.DefaultSelector()
        streams = {process.stdout: bytearray(), process.stderr: bytearray()}
        totals = {process.stdout: 0, process.stderr: 0}
        for stream in streams:
            selector.register(stream, selectors.EVENT_READ)
        deadline = self.monotonic() + self.command_timeout
        timed_out = False
        try:
            while selector.get_map():
                remaining = deadline - self.monotonic()
                if remaining <= 0:
                    timed_out = True
                    self._stop_local_child(process)
                events = selector.select(timeout=max(0.0, min(0.1, remaining)))
                for key, _ in events:
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    totals[key.fileobj] += len(chunk)
                    retained = streams[key.fileobj]
                    available = self.max_output_bytes - len(retained)
                    if available > 0:
                        retained.extend(chunk[:available])
                if timed_out and process.poll() is not None and not events:
                    for stream in list(selector.get_map().values()):
                        selector.unregister(stream.fileobj)
            remaining = deadline - self.monotonic()
            try:
                returncode = process.wait(timeout=max(0.0, remaining))
            except subprocess.TimeoutExpired:
                timed_out = True
                self._stop_local_child(process)
                returncode = process.wait()
        except KeyboardInterrupt:
            self._stop_local_child(process)
            raise
        finally:
            selector.close()
            for stream in streams:
                stream.close()
        stdout = bytes(streams[process.stdout]).decode("utf-8", errors="replace")
        stderr = bytes(streams[process.stderr]).decode("utf-8", errors="replace")
        return (
            returncode,
            stdout,
            stderr,
            totals[process.stdout],
            totals[process.stderr],
            timed_out,
        )

    def invoke_json(self, purpose, query_key, task_id, *args):
        """Run one exact MagiBook command and return its JSON object plus audit."""
        argv = [self.executable, "--region", self.region, *(str(arg) for arg in args)]
        started = self.monotonic()
        try:
            process = self.popen_factory(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                shell=False,
                env=self.env,
            )
        except OSError as exc:
            summary = _redact(exc, self.sensitive_values)
            raise CLICommandError(_error_category(summary), summary) from exc
        record = {
            "pid": process.pid,
            "purpose": purpose,
            "queryKey": query_key,
            "taskId": task_id,
            "returnCode": None,
            "stdoutBytes": 0,
            "stderrBytes": 0,
            "stdoutTruncated": False,
            "stderrTruncated": False,
            "timedOut": False,
        }
        self.children.append(record)
        try:
            returncode, stdout, stderr, stdout_size, stderr_size, timed_out = (
                self._collect_bounded(process)
            )
        except KeyboardInterrupt:
            record["returnCode"] = process.returncode
            record["interrupted"] = True
            record["durationSeconds"] = round(self.monotonic() - started, 6)
            raise
        record.update(
            {
                "returnCode": returncode,
                "stdoutBytes": stdout_size,
                "stderrBytes": stderr_size,
                "stdoutTruncated": stdout_size > self.max_output_bytes,
                "stderrTruncated": stderr_size > self.max_output_bytes,
                "timedOut": timed_out,
                "durationSeconds": round(self.monotonic() - started, 6),
            }
        )
        safe_stderr = _redact(stderr.strip(), self.sensitive_values)
        if timed_out:
            raise CLICommandError(
                "timeout",
                "local MagiBook CLI child timed out; this did not cancel remote work",
                timed_out=True,
            )
        if returncode != 0:
            summary = safe_stderr or "MagiBook CLI child exited non-zero"
            raise CLICommandError(_error_category(summary), summary)
        if stdout_size > self.max_output_bytes:
            raise CLICommandError(
                "output-limit",
                "MagiBook CLI stdout exceeded the configured capture limit",
            )
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise CLICommandError(
                "protocol",
                "MagiBook CLI returned invalid JSON: {}".format(exc.msg),
            ) from exc
        return payload, record


def _write_protected(path, content):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(content)


def _atomic_write_registry(path, state):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(state, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _load_registry(path, book_uuid, application_id):
    path = Path(path)
    if not path.exists():
        return {
            "version": 1,
            "bookUuid": str(book_uuid),
            "applicationId": str(application_id),
            "queries": {},
        }
    if path.stat().st_mode & 0o077:
        raise RegistryError("query registry must not be group- or world-accessible")
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError("query registry is unreadable: {}".format(exc)) from exc
    if state.get("version") != 1:
        raise RegistryError("unsupported query registry version")
    if str(state.get("bookUuid")) != str(book_uuid):
        raise RegistryError("query registry belongs to a different Book")
    if str(state.get("applicationId")) != str(application_id):
        raise RegistryError("query registry belongs to a different Spark application")
    if not isinstance(state.get("queries"), dict):
        raise RegistryError("query registry has an invalid queries object")
    return state


def _extract_task_id(payload):
    if not isinstance(payload, dict):
        return None
    for key in ("batch_task_id", "batchTaskId", "task_id", "taskId"):
        value = payload.get(key)
        if value is not None and str(value).strip():
            return str(value)
    return None


def _normalized_task_state(payload):
    if not isinstance(payload, dict):
        return "ambiguous", None
    value = None
    for key in ("status", "state", "task_status", "taskStatus"):
        if payload.get(key) is not None:
            value = payload[key]
            break
    if value is None:
        return "ambiguous", None
    raw = str(value).strip().lower()
    if raw in _SUCCESS_STATES:
        return "success", raw
    if raw in _FAILURE_STATES:
        return "failure", raw
    if raw in _CANCELLED_STATES:
        return "cancelled", raw
    if raw in _RUNNING_STATES:
        return "running", raw
    if raw in _WAITING_STATES:
        return "waiting", raw
    return "ambiguous", raw


def _cell_content(payload):
    if isinstance(payload, dict) and isinstance(payload.get("content"), str):
        return payload["content"]
    raise CLICommandError("protocol", "cell view response has no string content")


def _output_identity(payload):
    if not isinstance(payload, dict):
        return None, None
    outputs = payload.get("output")
    if not isinstance(outputs, list):
        return None, None
    for part in outputs:
        if not isinstance(part, dict) or not isinstance(part.get("content"), str):
            continue
        for line in part["content"].splitlines():
            if not line.startswith(_QUERY_STATUS_PREFIX):
                continue
            try:
                marker = json.loads(line[len(_QUERY_STATUS_PREFIX) :])
            except json.JSONDecodeError:
                continue
            if isinstance(marker, dict) and marker.get("applicationId") is not None:
                return str(marker["applicationId"]), str(marker.get("queryKey", ""))
    return None, None


def _output_has_error(payload):
    if not isinstance(payload, dict):
        return True
    outputs = payload.get("output")
    if not isinstance(outputs, list):
        return True
    return any(isinstance(part, dict) and part.get("type") == "error" for part in outputs)


def _result(query, entry, status, **extra):
    value = {
        "key": query.key,
        "cellId": str(query.cell_id),
        "taskId": entry.get("taskId") if entry else None,
        "status": status,
        "remoteStatus": entry.get("remoteStatus") if entry else None,
        "reusedTask": bool(entry and entry.get("reusedTask")),
        "remoteMayStillBeRunning": False,
    }
    value.update(extra)
    return value


def _safe_error(exc):
    if isinstance(exc, CLICommandError):
        return {"category": exc.category, "summary": exc.summary}
    return {
        "category": "orchestration",
        "summary": "protected local orchestration failed with {}".format(
            type(exc).__name__
        ),
    }


def _run_parallel_queries_locked(
    queries,
    *,
    initialization,
    cli,
    book_uuid,
    state_path,
    max_parallel=1,
    query_timeout=3600.0,
    overall_timeout=7200.0,
    poll_interval=2.0,
    capability_probe_seconds=10.0,
    sleep=time.sleep,
    monotonic=time.monotonic,
    wall_clock=time.time,
):
    """Run independent query Cells and return one machine-readable aggregate.

    The function never initializes Spark and never cancels a remote task.
    A retry with the same registry attaches to the exact recorded task.
    """
    query_list = list(queries)
    if initialization.get("state") != "live" or not initialization.get(
        "applicationId"
    ):
        raise InitializationRequiredError(
            "Spark initialization must be terminally live before query submission"
        )
    application_id = str(initialization["applicationId"])
    if not query_list:
        raise ValueError("at least one query is required")
    if not isinstance(cli, MagiBookCLI):
        raise TypeError("cli must be a MagiBookCLI")
    if not str(book_uuid).strip():
        raise ValueError("book_uuid must be explicit")
    if isinstance(max_parallel, bool) or not isinstance(max_parallel, int):
        raise TypeError("max_parallel must be an integer")
    if max_parallel < 1:
        raise ValueError("max_parallel must be at least one")
    if query_timeout <= 0 or overall_timeout <= 0 or poll_interval <= 0:
        raise ValueError("timeouts and poll_interval must be positive")
    if capability_probe_seconds < 0:
        raise ValueError("capability_probe_seconds cannot be negative")

    keys = [query.key for query in query_list]
    cell_ids = [str(query.cell_id) for query in query_list]
    if len(set(keys)) != len(keys):
        raise ValueError("query keys must be distinct")
    if len(set(cell_ids)) != len(cell_ids):
        raise ValueError("query Cell ids must be distinct")
    sources = {query.key: render_query_cell(query) for query in query_list}
    cli.sensitive_values = tuple(
        dict.fromkeys(
            (
                *cli.sensitive_values,
                *(query.sql for query in query_list),
                *sources.values(),
            )
        )
    )
    digests = {
        key: hashlib.sha256(source.encode("utf-8")).hexdigest()
        for key, source in sources.items()
    }
    registry = _load_registry(state_path, book_uuid, application_id)
    results = {}
    active = {}
    pending = []
    stop_reason = None
    interrupted = False
    started = monotonic()
    probe_started = None
    submitted_count = 0
    max_active = 0
    capability_mode = (
        "sequential-configured"
        if max_parallel == 1 or len(query_list) == 1
        else "probing"
    )

    temporary_root = tempfile.mkdtemp(prefix="magibook-parallel-")
    os.chmod(temporary_root, 0o700)
    try:
        for index, query in enumerate(query_list):
            entry = registry["queries"].get(query.key)
            if entry:
                if str(entry.get("cellId")) != str(query.cell_id):
                    results[query.key] = _result(
                        query,
                        entry,
                        "ownership-ambiguous",
                        error={
                            "category": "registry",
                            "summary": "query key is already bound to another Cell",
                        },
                    )
                    stop_reason = "preflight-failure"
                    continue
                if entry.get("contentSha256") != digests[query.key]:
                    results[query.key] = _result(
                        query,
                        entry,
                        "ownership-ambiguous",
                        error={
                            "category": "registry",
                            "summary": "query key is already bound to different content",
                        },
                    )
                    stop_reason = "preflight-failure"
                    continue
                task_id = entry.get("taskId")
                if task_id:
                    entry["reusedTask"] = True
                    active[query.key] = {"query": query, "entry": entry}
                    continue
                if entry.get("phase") in ("submitting", "submission-unknown"):
                    results[query.key] = _result(
                        query,
                        entry,
                        "ownership-ambiguous",
                        remoteMayStillBeRunning=True,
                        error={
                            "category": "registry",
                            "summary": "prior submission has no safely recoverable task id",
                        },
                    )
                    stop_reason = "ambiguous-ownership"
                    continue
            else:
                entry = {
                    "cellId": str(query.cell_id),
                    "contentSha256": digests[query.key],
                    "phase": "preparing",
                    "taskId": None,
                    "remoteStatus": None,
                    "reusedTask": False,
                }
                registry["queries"][query.key] = entry
                _atomic_write_registry(state_path, registry)

            try:
                viewed, _ = cli.invoke_json(
                    "view-cell", query.key, None, "cell", "view", query.cell_id
                )
                existing_source = _cell_content(viewed)
                if existing_source != sources[query.key]:
                    old_path = os.path.join(temporary_root, "{}.old".format(index))
                    new_path = os.path.join(temporary_root, "{}.new".format(index))
                    _write_protected(old_path, existing_source)
                    _write_protected(new_path, sources[query.key])
                    cli.invoke_json(
                        "edit-cell",
                        query.key,
                        None,
                        "cell",
                        "edit",
                        query.cell_id,
                        "--old-file",
                        old_path,
                        "--new-file",
                        new_path,
                    )
                    verified, _ = cli.invoke_json(
                        "verify-cell", query.key, None, "cell", "view", query.cell_id
                    )
                    if _cell_content(verified) != sources[query.key]:
                        raise CLICommandError(
                            "protocol", "Cell content did not match after protected-file edit"
                        )
                entry["phase"] = "prepared"
                _atomic_write_registry(state_path, registry)
                pending.append(query)
            except (CLICommandError, OSError) as exc:
                entry["phase"] = "preflight-failed"
                _atomic_write_registry(state_path, registry)
                results[query.key] = _result(
                    query, entry, "preflight-failed", error=_safe_error(exc)
                )
                stop_reason = "preflight-failure"

        max_active = len(active)
        if len(active) > max_parallel:
            capability_mode = "existing-work-exceeds-bound"
            stop_reason = "existing-work-exceeds-bound"

        if stop_reason:
            for query in pending:
                results[query.key] = _result(
                    query,
                    registry["queries"][query.key],
                    "not-submitted",
                    reason=stop_reason,
                )
            pending.clear()

        def submit_one(query):
            nonlocal submitted_count, stop_reason, capability_mode
            entry = registry["queries"][query.key]
            entry["phase"] = "submitting"
            _atomic_write_registry(state_path, registry)
            try:
                payload, record = cli.invoke_json(
                    "submit-query",
                    query.key,
                    None,
                    "cell",
                    "run",
                    book_uuid,
                    query.cell_id,
                )
            except KeyboardInterrupt:
                entry["phase"] = "submission-unknown"
                _atomic_write_registry(state_path, registry)
                results[query.key] = _result(
                    query,
                    entry,
                    "interrupted",
                    remoteMayStillBeRunning=True,
                    error={
                        "category": "submission-ownership",
                        "summary": "interrupted submission returned no exact task id",
                    },
                )
                raise
            except CLICommandError as exc:
                entry["phase"] = "submission-unknown"
                _atomic_write_registry(state_path, registry)
                results[query.key] = _result(
                    query,
                    entry,
                    "submission-unknown",
                    remoteMayStillBeRunning=True,
                    error=_safe_error(exc),
                )
                stop_reason = "submission-failure"
                if exc.category == "concurrency":
                    capability_mode = "overlap-rejected"
                return
            task_id = _extract_task_id(payload)
            if task_id is None:
                entry["phase"] = "submission-unknown"
                _atomic_write_registry(state_path, registry)
                results[query.key] = _result(
                    query,
                    entry,
                    "submission-unknown",
                    remoteMayStillBeRunning=True,
                    error={
                        "category": "protocol",
                        "summary": "submission response contained no exact task id",
                    },
                )
                stop_reason = "ambiguous-ownership"
                return
            if any(
                other.get("taskId") == task_id
                for key, other in registry["queries"].items()
                if key != query.key
            ):
                entry["phase"] = "submission-unknown"
                _atomic_write_registry(state_path, registry)
                results[query.key] = _result(
                    query,
                    entry,
                    "ownership-ambiguous",
                    remoteMayStillBeRunning=True,
                    error={
                        "category": "protocol",
                        "summary": "MagiBook returned a task id already owned by another query",
                    },
                )
                stop_reason = "ambiguous-ownership"
                return
            record["taskId"] = task_id
            entry.update(
                {
                    "taskId": task_id,
                    "phase": "submitted",
                    "submittedAt": wall_clock(),
                    "remoteStatus": "submitted",
                }
            )
            _atomic_write_registry(state_path, registry)
            active[query.key] = {"query": query, "entry": entry}
            submitted_count += 1

        def finalize_success(query, entry):
            try:
                output, _ = cli.invoke_json(
                    "view-output",
                    query.key,
                    entry["taskId"],
                    "cell",
                    "view",
                    query.cell_id,
                    "--output",
                )
            except CLICommandError as exc:
                return _result(
                    query,
                    entry,
                    "verification-failed",
                    error=_safe_error(exc),
                )
            reported_app, reported_key = _output_identity(output)
            if _output_has_error(output):
                return _result(
                    query,
                    entry,
                    "failure",
                    error={
                        "category": "query",
                        "summary": "terminal Cell output contains an error payload",
                    },
                )
            if reported_app != application_id or reported_key != query.key:
                return _result(
                    query,
                    entry,
                    "verification-failed",
                    reportedApplicationId=reported_app,
                    reportedQueryKey=reported_key,
                    error={
                        "category": "application-identity",
                        "summary": "Cell output did not prove the expected query and Spark application",
                    },
                )
            return _result(
                query,
                entry,
                "success",
                applicationIdVerified=True,
                outputTruncated=bool(output.get("is_truncated")),
            )

        while pending or active:
            if monotonic() - started >= overall_timeout:
                stop_reason = "overall-timeout"
                for key, item in list(active.items()):
                    results[key] = _result(
                        item["query"],
                        item["entry"],
                        "timeout",
                        remoteMayStillBeRunning=True,
                        reason="overall-timeout",
                    )
                    del active[key]
                break

            if not stop_reason:
                if capability_mode == "concurrent-observed":
                    capacity = max_parallel - len(active)
                elif capability_mode == "probing":
                    capacity = min(2, max_parallel) - len(active)
                else:
                    capacity = 1 if not active else 0
                while pending and capacity > 0 and not stop_reason:
                    submit_one(pending.pop(0))
                    capacity -= 1
                    max_active = max(max_active, len(active))

            observations = {}
            terminal_failure = False
            for key, item in list(active.items()):
                query = item["query"]
                entry = item["entry"]
                try:
                    payload, _ = cli.invoke_json(
                        "poll-task",
                        query.key,
                        entry["taskId"],
                        "cell",
                        "task-status",
                        entry["taskId"],
                    )
                except CLICommandError as exc:
                    results[key] = _result(
                        query,
                        entry,
                        "reconciliation-failed",
                        remoteMayStillBeRunning=True,
                        error=_safe_error(exc),
                    )
                    del active[key]
                    stop_reason = "reconciliation-failure"
                    terminal_failure = True
                    continue
                normalized, raw = _normalized_task_state(payload)
                entry["remoteStatus"] = raw
                entry["phase"] = normalized
                _atomic_write_registry(state_path, registry)
                if normalized == "success":
                    results[key] = finalize_success(query, entry)
                    terminal_failure = (
                        terminal_failure or results[key]["status"] != "success"
                    )
                    del active[key]
                elif normalized == "failure":
                    results[key] = _result(
                        query,
                        entry,
                        "failure",
                        error={
                            "category": "query",
                            "summary": "exact MagiBook task reported failure",
                        },
                    )
                    del active[key]
                    terminal_failure = True
                elif normalized == "cancelled":
                    results[key] = _result(
                        query,
                        entry,
                        "cancelled",
                        error={
                            "category": "cancellation",
                            "summary": "exact MagiBook task reported cancellation",
                        },
                    )
                    del active[key]
                    terminal_failure = True
                elif normalized == "ambiguous":
                    results[key] = _result(
                        query,
                        entry,
                        "ownership-ambiguous",
                        remoteMayStillBeRunning=True,
                        error={
                            "category": "task-state",
                            "summary": "exact task returned an unknown or ambiguous state",
                        },
                    )
                    del active[key]
                    stop_reason = "ambiguous-task-state"
                    terminal_failure = True
                    capability_mode = "ambiguous"
                else:
                    observations[key] = normalized
                    submitted_at_value = entry.get("submittedAt")
                    submitted_at = (
                        float(submitted_at_value)
                        if submitted_at_value is not None
                        else wall_clock()
                    )
                    if wall_clock() - submitted_at >= query_timeout:
                        results[key] = _result(
                            query,
                            entry,
                            "timeout",
                            remoteMayStillBeRunning=True,
                            reason="query-timeout",
                        )
                        del active[key]
                        stop_reason = "query-timeout"
                        terminal_failure = True

            if terminal_failure and not stop_reason:
                stop_reason = "peer-failure"

            if capability_mode == "probing":
                running = [key for key, state in observations.items() if state == "running"]
                waiting = [key for key, state in observations.items() if state == "waiting"]
                if len(running) >= 2:
                    capability_mode = "concurrent-observed"
                elif running and waiting:
                    if probe_started is None:
                        probe_started = monotonic()
                    if monotonic() - probe_started >= capability_probe_seconds:
                        capability_mode = "serialized-fallback"
                elif submitted_count >= 2 and len(active) < 2:
                    capability_mode = "sequential-inconclusive"

            if stop_reason and not active:
                break

            if active:
                sleep(poll_interval)

        if stop_reason:
            for query in pending:
                results[query.key] = _result(
                    query,
                    registry["queries"][query.key],
                    "not-submitted",
                    reason=stop_reason,
                )
            pending.clear()
    except KeyboardInterrupt:
        interrupted = True
        stop_reason = "interrupted"
        for key, item in list(active.items()):
            query = item["query"]
            entry = item["entry"]
            try:
                payload, _ = cli.invoke_json(
                    "interrupt-reconcile",
                    query.key,
                    entry["taskId"],
                    "cell",
                    "task-status",
                    entry["taskId"],
                )
                normalized, raw = _normalized_task_state(payload)
                entry["remoteStatus"] = raw
                if normalized == "success":
                    results[key] = finalize_success(query, entry)
                elif normalized in ("failure", "cancelled"):
                    results[key] = _result(query, entry, normalized)
                else:
                    results[key] = _result(
                        query,
                        entry,
                        "interrupted",
                        remoteMayStillBeRunning=True,
                    )
            except (CLICommandError, KeyboardInterrupt):
                results[key] = _result(
                    query,
                    entry,
                    "interrupted",
                    remoteMayStillBeRunning=True,
                    error={
                        "category": "reconciliation",
                        "summary": "interruption reconciliation could not prove a terminal remote state",
                    },
                )
            _atomic_write_registry(state_path, registry)
        for query in query_list:
            if query.key in results:
                continue
            entry = registry["queries"].get(query.key)
            if entry and entry.get("phase") in ("submitting", "submission-unknown"):
                results[query.key] = _result(
                    query,
                    entry,
                    "interrupted",
                    remoteMayStillBeRunning=True,
                    reason="interrupted-during-submission",
                )
            else:
                results[query.key] = _result(
                    query,
                    entry,
                    "not-submitted",
                    reason="interrupted",
                )
    finally:
        shutil.rmtree(temporary_root)

    ordered_results = [results[query.key] for query in query_list]
    remaining = [
        {
            "key": result["key"],
            "cellId": result["cellId"],
            "taskId": result["taskId"],
            "remoteStatus": result["remoteStatus"],
        }
        for result in ordered_results
        if result.get("remoteMayStillBeRunning")
    ]
    if interrupted:
        overall_status = "interrupted"
    elif all(result["status"] == "success" for result in ordered_results):
        overall_status = "success"
    else:
        overall_status = "partial-failure"
    return {
        "version": 1,
        "overallStatus": overall_status,
        "initialization": {
            "state": "live",
            "applicationId": application_id,
        },
        "capability": {
            "requestedConcurrency": int(max_parallel),
            "mode": capability_mode,
            "maxObservedActiveTasks": max_active,
            "simultaneousRunningObserved": capability_mode == "concurrent-observed",
            "speedupClaimed": False,
            "timingEvidence": "no sequential baseline was collected",
        },
        "queries": ordered_results,
        "remoteWorkRemaining": remaining,
        "children": list(cli.children),
        "elapsedSeconds": round(monotonic() - started, 6),
    }


def run_parallel_queries(queries, *, state_path, **kwargs):
    """Serialize registry ownership, then run bounded query orchestration."""
    lock_path = Path(str(state_path) + ".lock")
    lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_handle = lock_path.open("a+", encoding="utf-8")
    os.chmod(lock_path, 0o600)
    try:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RegistryError(
                "another orchestrator currently owns this query registry"
            ) from exc
        return _run_parallel_queries_locked(
            queries,
            state_path=state_path,
            **kwargs,
        )
    finally:
        lock_handle.close()
