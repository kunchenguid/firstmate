#!/usr/bin/env python3
"""Shared fail-closed bounds for subprocesses and structured artifacts.

The module is importable by Python helpers and also exposes a small CLI for
empirical checks. One absolute deadline covers process execution, output
draining, final wait, and anchored ownership cleanup.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
import errno
import json
import math
import os
from pathlib import Path
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import time
from typing import Any, NoReturn, Sequence


DEFAULT_CLEANUP_GRACE_SECONDS = 0.25
DEFAULT_JSON_MAX_DEPTH = 64
DEFAULT_JSON_MAX_ITEMS = 4096
DEFAULT_PROCESS_CENSUS_MAX_ARGUMENT_BYTES = 4 * 1024 * 1024
DEFAULT_PROCESS_CENSUS_MAX_ITEMS = 16_384
INTERNAL_SUPERVISOR_MODE = "--bounded-io-supervisor"
OWNERSHIP_ENVIRONMENT_KEY = "FM_BOUNDED_IO_OWNERSHIP"
SUPERVISOR_STATUS_LIMIT = 4096


class BoundedIOError(RuntimeError):
    """An operation exceeded or could not prove its declared bounds."""


class BoundedTimeout(BoundedIOError):
    """A subprocess exhausted its one absolute deadline."""


class BoundedOutputExceeded(BoundedIOError):
    """A subprocess exceeded its aggregate stdout and stderr byte ceiling."""


def fail(message: str) -> NoReturn:
    raise BoundedIOError(message)


def positive_number(value: float | int, label: str) -> float:
    try:
        numeric = float(value)
    except (TypeError, ValueError, OverflowError):
        fail(f"{label} must be a positive finite number")
    if not math.isfinite(numeric) or numeric <= 0:
        fail(f"{label} must be a positive finite number")
    return numeric


def positive_integer(value: int, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


@dataclass(frozen=True)
class CommandResult:
    arguments: tuple[str, ...]
    returncode: int
    stdout: bytes
    stderr: bytes


class DeadlineBudget:
    """One wall-clock budget shared by a bounded batch and its commands."""

    def __init__(self, maximum_seconds: float, maximum_items: int) -> None:
        self.maximum_seconds = positive_number(maximum_seconds, "maximum seconds")
        self.maximum_items = positive_integer(maximum_items, "maximum items")
        self.deadline = time.monotonic() + self.maximum_seconds
        self.items = 0

    def consume_item(self, label: str) -> None:
        self.items += 1
        if self.items > self.maximum_items:
            fail(f"{label} exceeds the {self.maximum_items}-item limit")
        self.require_time(label)

    def consume_items(self, values: Sequence[Any], label: str) -> None:
        if len(values) > self.maximum_items - self.items:
            fail(f"{label} exceeds the {self.maximum_items}-item limit")
        self.items += len(values)
        self.require_time(label)

    def require_time(self, label: str) -> None:
        if time.monotonic() >= self.deadline:
            fail(f"{label} exceeded the {self.maximum_seconds:g}-second deadline")

    def bounded_deadline(self, requested_seconds: float, label: str) -> float:
        requested = positive_number(requested_seconds, f"{label} timeout")
        now = time.monotonic()
        if now >= self.deadline:
            fail(f"{label} exceeded the {self.maximum_seconds:g}-second deadline")
        return min(self.deadline, now + requested)


class _ProcessCensusBudget:
    def __init__(
        self,
        deadline: float,
        maximum_items: int = DEFAULT_PROCESS_CENSUS_MAX_ITEMS,
        maximum_argument_bytes: int = DEFAULT_PROCESS_CENSUS_MAX_ARGUMENT_BYTES,
    ) -> None:
        self.deadline = deadline
        self.maximum_items = maximum_items
        self.maximum_argument_bytes = maximum_argument_bytes
        self.items = 0
        self.argument_bytes = 0

    def checkpoint(self) -> None:
        if time.monotonic() >= self.deadline:
            raise OSError(errno.ETIMEDOUT, "bounded process inventory timed out")

    def consume_item(self) -> None:
        self.checkpoint()
        self.items += 1
        if self.items > self.maximum_items:
            raise OSError(errno.EOVERFLOW, "bounded process inventory is oversized")

    def ensure_item_count(self, count: int) -> None:
        self.checkpoint()
        if count > self.maximum_items:
            raise OSError(errno.EOVERFLOW, "bounded process inventory is oversized")

    def consume_argument_bytes(self, count: int) -> None:
        self.checkpoint()
        self.argument_bytes += count
        if self.argument_bytes > self.maximum_argument_bytes:
            raise OSError(
                errno.EOVERFLOW, "bounded process arguments inventory is oversized"
            )


def _write_supervisor_status(descriptor: int, code: str, detail: str = "") -> None:
    safe_detail = detail.replace("\n", " ")[:1024]
    payload = f"{code}:{safe_detail}\n".encode("utf-8", "backslashreplace")
    offset = 0
    while offset < len(payload):
        try:
            offset += os.write(descriptor, payload[offset:])
        except InterruptedError:
            continue
        except OSError:
            return


def _linux_enable_subreaper() -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = libc.prctl
    prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    prctl.restype = ctypes.c_int
    if prctl(36, 1, 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def _linux_process_identity(
    process_id: int, budget: _ProcessCensusBudget | None = None
) -> tuple[int, int] | None:
    if budget is not None:
        budget.checkpoint()
    try:
        raw = Path(f"/proc/{process_id}/stat").read_text(encoding="ascii")
    except (OSError, UnicodeError):
        return None
    if budget is not None:
        budget.checkpoint()
    closing = raw.rfind(")")
    if closing < 0:
        return None
    fields = raw[closing + 2 :].split()
    if len(fields) < 20:
        return None
    try:
        return process_id, int(fields[19])
    except ValueError:
        return None


def _linux_children(process_id: int, budget: _ProcessCensusBudget) -> list[int]:
    budget.checkpoint()
    try:
        descriptor = os.open(
            f"/proc/{process_id}/task/{process_id}/children",
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError:
        return []
    children: list[int] = []
    value = 0
    has_value = False
    try:
        while True:
            budget.checkpoint()
            try:
                chunk = os.read(descriptor, 4096)
            except InterruptedError:
                continue
            except OSError:
                return []
            budget.checkpoint()
            if not chunk:
                break
            for character in chunk:
                if 48 <= character <= 57:
                    value = value * 10 + character - 48
                    if value > 2_147_483_647:
                        return []
                    has_value = True
                    continue
                if character not in b" \t\n\r\v\f":
                    return []
                if has_value:
                    budget.ensure_item_count(len(children) + 1)
                    children.append(value)
                    value = 0
                    has_value = False
        if has_value:
            budget.ensure_item_count(len(children) + 1)
            children.append(value)
    finally:
        os.close(descriptor)
    return children


def _linux_owned_processes(
    budget: _ProcessCensusBudget,
) -> dict[int, tuple[int, int]]:
    owned: dict[int, tuple[int, int]] = {}
    pending = _linux_children(os.getpid(), budget)
    queued = set(pending)
    while pending:
        budget.checkpoint()
        process_id = pending.pop()
        if process_id in owned:
            continue
        budget.consume_item()
        identity = _linux_process_identity(process_id, budget)
        if identity is None:
            continue
        owned[process_id] = identity
        for child_id in _linux_children(process_id, budget):
            if child_id not in queued:
                queued.add(child_id)
                budget.ensure_item_count(len(queued))
                pending.append(child_id)
    return owned


class _DarwinBsdInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("xstatus", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32),
        ("uid", ctypes.c_uint32),
        ("gid", ctypes.c_uint32),
        ("ruid", ctypes.c_uint32),
        ("rgid", ctypes.c_uint32),
        ("svuid", ctypes.c_uint32),
        ("svgid", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("command", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32),
        ("pgid", ctypes.c_uint32),
        ("job_control", ctypes.c_uint32),
        ("terminal_device", ctypes.c_uint32),
        ("terminal_pgid", ctypes.c_uint32),
        ("nice", ctypes.c_int32),
        ("started_seconds", ctypes.c_uint64),
        ("started_microseconds", ctypes.c_uint64),
    ]


class _DarwinUniqueIdentifierInfo(ctypes.Structure):
    _fields_ = [
        ("uuid", ctypes.c_uint8 * 16),
        ("unique_id", ctypes.c_uint64),
        ("parent_unique_id", ctypes.c_uint64),
        ("id_version", ctypes.c_int32),
        ("original_parent_id_version", ctypes.c_int32),
        ("reserved2", ctypes.c_uint64),
        ("reserved3", ctypes.c_uint64),
    ]


class _DarwinAuditToken(ctypes.Structure):
    _fields_ = [("values", ctypes.c_uint32 * 8)]


def _darwin_process_table(
    budget: _ProcessCensusBudget,
) -> dict[int, tuple[int, int, int, tuple[int, int]]]:
    budget.checkpoint()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    list_all = libproc.proc_listallpids
    list_all.argtypes = [ctypes.c_void_p, ctypes.c_int]
    list_all.restype = ctypes.c_int
    pid_info = libproc.proc_pidinfo
    pid_info.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    pid_info.restype = ctypes.c_int
    capacity = list_all(None, 0)
    budget.checkpoint()
    if capacity < 0 or capacity > budget.maximum_items:
        raise OSError(ctypes.get_errno(), "bounded process inventory is unavailable")
    processes = (ctypes.c_int * (capacity + 256))()
    count = list_all(processes, ctypes.sizeof(processes))
    budget.checkpoint()
    if count < 0 or count > len(processes) or count > budget.maximum_items:
        raise OSError(ctypes.get_errno(), "bounded process inventory changed")
    table: dict[int, tuple[int, int, int, tuple[int, int]]] = {}
    for process_id in processes[:count]:
        budget.consume_item()
        if process_id <= 0:
            continue
        info = _DarwinBsdInfo()
        copied = pid_info(process_id, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        budget.checkpoint()
        if copied != ctypes.sizeof(info) or info.pid != process_id:
            continue
        table[process_id] = (
            int(info.ppid),
            int(info.pgid),
            int(info.uid),
            (int(info.started_seconds), int(info.started_microseconds)),
        )
    return table


def _darwin_process_identity(
    process_id: int, budget: _ProcessCensusBudget | None = None
) -> tuple[int, int] | None:
    if budget is not None:
        budget.checkpoint()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    pid_info = libproc.proc_pidinfo
    pid_info.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    pid_info.restype = ctypes.c_int
    info = _DarwinBsdInfo()
    copied = pid_info(process_id, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if budget is not None:
        budget.checkpoint()
    if copied != ctypes.sizeof(info) or info.pid != process_id:
        return None
    return int(info.started_seconds), int(info.started_microseconds)


def _darwin_process_audit_token(process_id: int) -> _DarwinAuditToken | None:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    pid_info = libproc.proc_pidinfo
    pid_info.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    pid_info.restype = ctypes.c_int
    info = _DarwinUniqueIdentifierInfo()
    copied = pid_info(process_id, 17, 0, ctypes.byref(info), ctypes.sizeof(info))
    if copied != ctypes.sizeof(info):
        return None
    token = _DarwinAuditToken()
    token.values[5] = process_id
    token.values[7] = info.id_version
    return token


def _darwin_process_arguments(
    process_id: int, budget: _ProcessCensusBudget
) -> bytes | None:
    budget.checkpoint()
    libc = ctypes.CDLL(None, use_errno=True)
    sysctl = libc.sysctl
    sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_uint,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    sysctl.restype = ctypes.c_int
    query = (ctypes.c_int * 3)(1, 49, process_id)
    size = ctypes.c_size_t()
    if sysctl(query, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    budget.checkpoint()
    if size.value <= 0 or size.value > 1_048_576:
        raise OSError(errno.EOVERFLOW, "bounded process arguments are oversized")
    budget.consume_argument_bytes(size.value)
    buffer = ctypes.create_string_buffer(size.value)
    if sysctl(query, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return None
    budget.checkpoint()
    return buffer.raw[: size.value]


def _darwin_descendants(
    table: dict[int, tuple[int, int, int, tuple[int, int]]],
    roots: dict[int, tuple[int, int]],
    budget: _ProcessCensusBudget,
) -> dict[int, tuple[int, int]]:
    budget.ensure_item_count(len(roots))
    children: dict[int, list[tuple[int, tuple[int, int]]]] = {}
    for process_id, (parent_id, _group_id, _uid, identity) in table.items():
        budget.checkpoint()
        children.setdefault(parent_id, []).append((process_id, identity))
    owned = dict(roots)
    pending = list(roots)
    while pending:
        budget.checkpoint()
        parent_id = pending.pop()
        for process_id, identity in children.get(parent_id, ()):
            budget.checkpoint()
            if process_id in owned:
                continue
            owned[process_id] = identity
            pending.append(process_id)
    return owned


def _darwin_owned_processes(
    command_id: int,
    token: str,
    known: dict[int, tuple[int, int]],
    budget: _ProcessCensusBudget,
) -> dict[int, tuple[int, int]]:
    budget.ensure_item_count(len(known))
    table = _darwin_process_table(budget)
    roots: dict[int, tuple[int, int]] = {}
    for process_id, identity in known.items():
        budget.checkpoint()
        current = table.get(process_id)
        if current is not None and current[3] == identity:
            roots[process_id] = identity
    owned = _darwin_descendants(table, roots, budget)
    marker = f"{OWNERSHIP_ENVIRONMENT_KEY}={token}\0".encode("ascii")
    earliest_owned_start = min(known.values(), default=(0, 0))
    for process_id, (_parent_id, group_id, uid, identity) in table.items():
        budget.checkpoint()
        if process_id == os.getpid() or process_id in owned:
            continue
        if group_id == os.getpgrp():
            owned[process_id] = identity
            continue
        if uid != os.getuid() or identity < earliest_owned_start:
            continue
        arguments = _darwin_process_arguments(process_id, budget)
        if arguments is not None and marker in arguments:
            owned[process_id] = identity
    return owned


def _darwin_record_descendants(
    command_id: int,
    known: dict[int, tuple[int, int]],
    budget: _ProcessCensusBudget,
) -> dict[int, tuple[int, int]]:
    budget.ensure_item_count(len(known))
    table = _darwin_process_table(budget)
    roots: dict[int, tuple[int, int]] = {}
    command = table.get(command_id)
    if command is not None:
        roots[command_id] = command[3]
    for process_id, identity in known.items():
        budget.checkpoint()
        current = table.get(process_id)
        if current is not None and current[3] == identity:
            roots[process_id] = identity
    return _darwin_descendants(table, roots, budget)


def _darwin_refresh_descendants(
    command_id: int,
    known: dict[int, tuple[int, int]],
    budget: _ProcessCensusBudget,
) -> None:
    refreshed = _darwin_record_descendants(command_id, known, budget)
    budget.ensure_item_count(len(refreshed))
    known.clear()
    known.update(refreshed)


def _linux_signal_owned_process(
    process_id: int, identity: tuple[int, int], signal_number: int
) -> None:
    pidfd_open = getattr(os, "pidfd_open", None)
    pidfd_send_signal = getattr(signal, "pidfd_send_signal", None)
    if pidfd_open is None or pidfd_send_signal is None:
        fail("identity-bound process signaling is unavailable")
    try:
        descriptor = pidfd_open(process_id)
    except ProcessLookupError:
        return
    except OSError as exc:
        raise BoundedIOError(
            f"owned process {process_id} could not be identity-bound"
        ) from exc
    try:
        if _linux_process_identity(process_id) != identity:
            return
        try:
            pidfd_send_signal(descriptor, signal_number)
        except ProcessLookupError:
            return
        except OSError as exc:
            raise BoundedIOError(
                f"owned process {process_id} could not be signaled"
            ) from exc
    finally:
        os.close(descriptor)


def _darwin_signal_audit_token(
    token: _DarwinAuditToken, signal_number: int
) -> int:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    signal_process = libproc.proc_signal_with_audittoken
    signal_process.argtypes = [ctypes.POINTER(_DarwinAuditToken), ctypes.c_int]
    signal_process.restype = ctypes.c_int
    return int(signal_process(ctypes.byref(token), signal_number))


def _darwin_signal_owned_process(
    process_id: int, identity: tuple[int, int], signal_number: int
) -> None:
    token = _darwin_process_audit_token(process_id)
    current_identity = _darwin_process_identity(process_id)
    if token is None:
        if current_identity == identity:
            fail(f"owned process {process_id} could not be identity-bound")
        return
    if current_identity != identity:
        return
    result = _darwin_signal_audit_token(token, signal_number)
    if result == 0 or result == errno.ESRCH:
        return
    raise BoundedIOError(f"owned process {process_id} could not be signaled")


def _signal_owned_processes(
    owned: dict[int, tuple[int, int]], signal_number: int, deadline: float
) -> None:
    for process_id, identity in owned.items():
        if time.monotonic() >= deadline:
            fail("owned-process signaling exceeded the absolute deadline")
        if sys.platform.startswith("linux"):
            _linux_signal_owned_process(process_id, identity, signal_number)
        elif sys.platform == "darwin":
            _darwin_signal_owned_process(process_id, identity, signal_number)
        else:
            fail("identity-bound process signaling is unavailable")


def _reap_supervisor_children(
    command_id: int, command_status: int | None
) -> int | None:
    while True:
        try:
            waited, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return command_status
        except InterruptedError:
            continue
        if waited == 0:
            return command_status
        if waited == command_id:
            command_status = os.waitstatus_to_exitcode(status)


def _supervisor_owned_processes(
    command_id: int,
    token: str,
    known: dict[int, tuple[int, int]],
    deadline: float,
) -> dict[int, tuple[int, int]]:
    budget = _ProcessCensusBudget(deadline)
    if sys.platform.startswith("linux"):
        return _linux_owned_processes(budget)
    return _darwin_owned_processes(command_id, token, known, budget)


def _supervisor_cleanup(
    command_id: int,
    token: str,
    deadline: float,
    grace: float,
    command_status: int | None,
    initial_known: dict[int, tuple[int, int]],
) -> tuple[int | None, bool, str]:
    initial_budget = _ProcessCensusBudget(deadline)
    try:
        initial_budget.ensure_item_count(len(initial_known))
    except OSError as exc:
        return command_status, False, f"owned-process inventory failed: {exc}"
    known = dict(initial_known)
    term_deadline = min(deadline, time.monotonic() + grace)
    signal_number = signal.SIGTERM
    while True:
        command_status = _reap_supervisor_children(command_id, command_status)
        try:
            owned = _supervisor_owned_processes(command_id, token, known, deadline)
        except OSError as exc:
            return command_status, False, f"owned-process inventory failed: {exc}"
        known = dict(owned)
        if not owned and command_status is not None:
            return command_status, True, ""
        now = time.monotonic()
        if now >= deadline:
            remaining = ",".join(str(value) for value in sorted(owned)) or "unknown"
            return command_status, False, f"owned processes remain: {remaining}"
        if now >= term_deadline:
            signal_number = signal.SIGKILL
        try:
            _signal_owned_processes(owned, signal_number, deadline)
        except BoundedIOError as exc:
            return command_status, False, str(exc)


def _run_supervisor(arguments: Sequence[str]) -> int:
    if len(arguments) < 5 or arguments[3] != "--":
        return 126
    try:
        status_descriptor = int(arguments[0])
        deadline = float(arguments[1])
        grace = float(arguments[2])
    except ValueError:
        return 126
    command_arguments = list(arguments[4:])
    abort_requested = False

    def request_abort(_signal_number: int, _frame: Any) -> None:
        nonlocal abort_requested
        abort_requested = True

    for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signal_number, request_abort)
    if sys.platform.startswith("linux"):
        try:
            _linux_enable_subreaper()
        except OSError as exc:
            _write_supervisor_status(status_descriptor, "E", f"subreaper setup: {exc}")
            _write_supervisor_status(status_descriptor, "C")
            return 126
    elif sys.platform != "darwin":
        _write_supervisor_status(
            status_descriptor, "E", "process ownership is unsupported on this platform"
        )
        _write_supervisor_status(status_descriptor, "C")
        return 126
    _write_supervisor_status(status_descriptor, "R")
    token = secrets.token_hex(24)
    command_environment = dict(os.environ)
    command_environment[OWNERSHIP_ENVIRONMENT_KEY] = token
    try:
        command = subprocess.Popen(command_arguments, env=command_environment)
    except FileNotFoundError:
        _write_supervisor_status(
            status_descriptor, "E", f"bounded command is unavailable: {command_arguments[0]}"
        )
        _write_supervisor_status(status_descriptor, "C")
        return 126
    except OSError as exc:
        _write_supervisor_status(
            status_descriptor, "E", f"bounded command could not start: {exc}"
        )
        _write_supervisor_status(status_descriptor, "C")
        return 126
    if sys.platform.startswith("linux"):
        command_identity = _linux_process_identity(command.pid)
    else:
        command_identity = _darwin_process_identity(command.pid)
    initial_known = (
        {command.pid: command_identity} if command_identity is not None else {}
    )
    command_status: int | None = None
    next_inventory = time.monotonic()
    while not abort_requested and command_status is None:
        if sys.platform == "darwin" and time.monotonic() >= next_inventory:
            try:
                _darwin_refresh_descendants(
                    command.pid,
                    initial_known,
                    _ProcessCensusBudget(deadline),
                )
            except OSError as exc:
                _write_supervisor_status(
                    status_descriptor, "U", f"owned-process inventory failed: {exc}"
                )
                abort_requested = True
                break
            next_inventory = time.monotonic() + 0.02
        command_status = _reap_supervisor_children(command.pid, command_status)
        if command_status is None:
            time.sleep(min(0.005, max(0, deadline - time.monotonic())))
        if time.monotonic() >= deadline:
            abort_requested = True
    command_status, verified, detail = _supervisor_cleanup(
        command.pid,
        token,
        deadline,
        grace,
        command_status,
        initial_known,
    )
    if command_status is not None:
        _write_supervisor_status(status_descriptor, "X", str(command_status))
    if verified:
        _write_supervisor_status(status_descriptor, "C")
        return 0
    _write_supervisor_status(status_descriptor, "U", detail)
    return 126


def _consume_supervisor_status(
    buffer: bytearray,
    state: dict[str, Any],
) -> None:
    while b"\n" in buffer:
        raw, remainder = buffer.split(b"\n", 1)
        buffer[:] = remainder
        code, separator, detail = raw.partition(b":")
        decoded = detail.decode("utf-8", "replace") if separator else ""
        if code == b"X":
            try:
                state["returncode"] = int(decoded)
            except ValueError:
                state["error"] = "supervisor returned a malformed command status"
        elif code == b"C":
            state["cleanup_verified"] = True
        elif code == b"R":
            state["ready"] = True
        elif code == b"E":
            state["error"] = decoded or "bounded command supervisor failed"
        elif code == b"U":
            state["cleanup_error"] = decoded or "owned-process cleanup was unverified"
        else:
            state["error"] = "bounded command supervisor returned an unknown status"


def _anchor_group_is_owned(process: subprocess.Popen[bytes]) -> bool:
    try:
        return os.getpgid(process.pid) == process.pid
    except ProcessLookupError:
        return False


def _request_anchor_abort(process: subprocess.Popen[bytes]) -> None:
    if not _anchor_group_is_owned(process):
        return
    try:
        os.kill(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return


def _reap_anchor(process: subprocess.Popen[bytes], deadline: float) -> bool:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return False
    try:
        process.wait(timeout=remaining)
        return True
    except subprocess.TimeoutExpired:
        return False


def run_bounded(
    arguments: Sequence[str],
    *,
    timeout_seconds: float,
    maximum_output_bytes: int,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_bytes: bytes | None = None,
    cleanup_grace_seconds: float = DEFAULT_CLEANUP_GRACE_SECONDS,
    absolute_deadline: float | None = None,
) -> CommandResult:
    """Run one command with aggregate output, time, and process-tree bounds."""

    if not arguments or any(not isinstance(item, str) or not item for item in arguments):
        fail("bounded command arguments must be nonempty strings")
    if input_bytes is not None and not isinstance(input_bytes, bytes):
        fail("bounded command input must be bytes")
    timeout = positive_number(timeout_seconds, "timeout seconds")
    output_limit = positive_integer(maximum_output_bytes, "maximum output bytes")
    started = time.monotonic()
    deadline = started + timeout
    if absolute_deadline is not None:
        deadline = min(
            deadline,
            positive_number(absolute_deadline, "absolute deadline"),
        )
    available = deadline - started
    if available <= 0:
        raise BoundedTimeout("bounded command deadline expired before start")
    cleanup_grace = min(
        positive_number(cleanup_grace_seconds, "cleanup grace seconds"),
        available * 0.8,
    )
    command_deadline = deadline - cleanup_grace
    output = {"stdout": bytearray(), "stderr": bytearray()}
    status_buffer = bytearray()
    state: dict[str, Any] = {
        "returncode": None,
        "ready": False,
        "cleanup_verified": False,
        "cleanup_error": None,
        "error": None,
    }
    captured = 0
    input_offset = 0
    input_view = memoryview(input_bytes) if input_bytes else None
    input_length = len(input_view) if input_view is not None else 0
    primary_error: BaseException | None = None
    result: CommandResult | None = None
    process: subprocess.Popen[bytes] | None = None
    selector: selectors.BaseSelector | None = None
    status_read = -1
    status_write = -1
    try:
        selector = selectors.DefaultSelector()
        status_read, status_write = os.pipe()
        os.set_blocking(status_read, False)
        supervisor_arguments = [
            sys.executable,
            str(Path(__file__).resolve()),
            INTERNAL_SUPERVISOR_MODE,
            str(status_write),
            repr(deadline),
            repr(cleanup_grace),
            "--",
            *arguments,
        ]
        try:
            process = subprocess.Popen(
                supervisor_arguments,
                cwd=cwd,
                env=env,
                stdin=(
                    subprocess.PIPE
                    if input_bytes is not None
                    else subprocess.DEVNULL
                ),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
                pass_fds=(status_write,),
            )
        except FileNotFoundError:
            fail(f"bounded supervisor is unavailable: {sys.executable}")
        except OSError as exc:
            fail(f"bounded supervisor could not start: {exc}")
        os.close(status_write)
        status_write = -1
        streams = {"stdout": process.stdout, "stderr": process.stderr}
        for label, stream in streams.items():
            if stream is None:
                fail(f"bounded command {label} pipe is unavailable")
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, label)
        selector.register(status_read, selectors.EVENT_READ, "status")
        if process.stdin is not None:
            if input_length:
                os.set_blocking(process.stdin.fileno(), False)
                selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
            else:
                process.stdin.close()

        while selector.get_map():
            active_deadline = (
                deadline
                if state["returncode"] is not None
                or state["cleanup_verified"]
                or state["cleanup_error"]
                or state["error"]
                else command_deadline
            )
            remaining = active_deadline - time.monotonic()
            if remaining <= 0:
                if state["returncode"] is not None:
                    fail("owned-process cleanup exceeded the absolute deadline")
                raise BoundedTimeout(
                    f"bounded command timed out after {timeout:g} seconds"
                )
            for key, _ in selector.select(timeout=min(0.1, remaining)):
                stream = key.fileobj
                if key.data == "stdin":
                    try:
                        written = os.write(stream.fileno(), input_view[input_offset:])
                    except BlockingIOError:
                        continue
                    except BrokenPipeError:
                        written = 0
                    input_offset += written
                    if written == 0 or input_offset == input_length:
                        selector.unregister(stream)
                        stream.close()
                    continue
                if key.data == "status":
                    try:
                        chunk = os.read(status_read, SUPERVISOR_STATUS_LIMIT + 1)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(status_read)
                        os.close(status_read)
                        status_read = -1
                    else:
                        status_buffer.extend(chunk)
                        if len(status_buffer) > SUPERVISOR_STATUS_LIMIT:
                            fail("bounded command supervisor status is oversized")
                        _consume_supervisor_status(status_buffer, state)
                    continue
                try:
                    chunk = os.read(stream.fileno(), min(65_536, output_limit + 1))
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                    continue
                captured += len(chunk)
                if captured > output_limit:
                    raise BoundedOutputExceeded(
                        "bounded command exceeded the "
                        f"{output_limit}-byte aggregate output limit"
                    )
                output[key.data].extend(chunk)
            if state["cleanup_error"]:
                fail(f"owned-process cleanup could not be verified: {state['cleanup_error']}")
            if state["error"]:
                fail(str(state["error"]))
            if (
                state["cleanup_verified"]
                and state["returncode"] is not None
                and all(label not in ("stdout", "stderr") for label in (
                    key.data for key in selector.get_map().values()
                ))
            ):
                break
        if state["returncode"] is None:
            fail("bounded command supervisor exited without a command status")
        if not state["cleanup_verified"]:
            fail("owned-process cleanup could not be verified")
        result = CommandResult(
            tuple(arguments),
            int(state["returncode"]),
            bytes(output["stdout"]),
            bytes(output["stderr"]),
        )
    except BaseException as exc:
        primary_error = exc
    finally:
        cleanup_failure: str | None = None
        anchor_reaped = process is None
        if process is not None and not state["cleanup_verified"]:
            abort_requested = False
            if state["ready"]:
                _request_anchor_abort(process)
                abort_requested = True
            while time.monotonic() < deadline and not state["cleanup_verified"]:
                if status_read < 0:
                    break
                try:
                    chunk = os.read(status_read, SUPERVISOR_STATUS_LIMIT + 1)
                except BlockingIOError:
                    time.sleep(min(0.01, max(0, deadline - time.monotonic())))
                    continue
                if not chunk:
                    break
                status_buffer.extend(chunk)
                if len(status_buffer) > SUPERVISOR_STATUS_LIMIT:
                    break
                _consume_supervisor_status(status_buffer, state)
                if state["ready"] and not abort_requested:
                    _request_anchor_abort(process)
                    abort_requested = True
        if process is not None:
            anchor_reaped = _reap_anchor(process, deadline)
        if selector is not None:
            selector.close()
        if status_read >= 0:
            os.close(status_read)
        if status_write >= 0:
            os.close(status_write)
        if process is not None:
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None and not stream.closed:
                    stream.close()
        if input_view is not None:
            input_view.release()
        if process is not None:
            cleanup_failure = state["cleanup_error"]
            if not anchor_reaped or not state["cleanup_verified"]:
                cleanup_failure = cleanup_failure or (
                    f"cleanup could not be verified for anchored process {process.pid}"
                )
        if cleanup_failure:
            cleanup_error = BoundedIOError(str(cleanup_failure))
            if primary_error is not None:
                raise cleanup_error from primary_error
            raise cleanup_error
    if primary_error is not None:
        raise primary_error
    if result is None:
        fail("bounded command did not produce a result")
    return result


def _json_budget(
    value: Any,
    *,
    maximum_depth: int,
    maximum_items: int,
    maximum_string_bytes: int,
) -> None:
    maximum_depth = positive_integer(maximum_depth, "maximum JSON depth")
    maximum_items = positive_integer(maximum_items, "maximum JSON items")
    maximum_string_bytes = positive_integer(
        maximum_string_bytes, "maximum JSON string bytes"
    )
    stack: list[tuple[Any, int]] = [(value, 1)]
    items = 0
    string_bytes = 0
    while stack:
        current, depth = stack.pop()
        if depth > maximum_depth:
            fail(f"JSON exceeds the {maximum_depth}-level depth limit")
        items += 1
        if items > maximum_items:
            fail(f"JSON exceeds the {maximum_items}-item limit")
        if isinstance(current, str):
            string_bytes += len(current.encode("utf-8"))
            if string_bytes > maximum_string_bytes:
                fail(
                    "JSON exceeds the "
                    f"{maximum_string_bytes}-byte decoded string limit"
                )
        elif isinstance(current, dict):
            for key, child in current.items():
                if not isinstance(key, str):
                    fail("JSON object contains a non-string key")
                string_bytes += len(key.encode("utf-8"))
                if string_bytes > maximum_string_bytes:
                    fail(
                        "JSON exceeds the "
                        f"{maximum_string_bytes}-byte decoded string limit"
                    )
                stack.append((child, depth + 1))
        elif isinstance(current, list):
            stack.extend((child, depth + 1) for child in current)
        elif isinstance(current, float) and not math.isfinite(current):
            fail("JSON contains a non-finite number")


def _reject_json_constant(value: str) -> NoReturn:
    fail(f"JSON contains a non-finite number: {value}")


def read_bounded_json(
    path: Path,
    *,
    maximum_bytes: int,
    maximum_depth: int = DEFAULT_JSON_MAX_DEPTH,
    maximum_items: int = DEFAULT_JSON_MAX_ITEMS,
    maximum_string_bytes: int | None = None,
) -> Any:
    """Read one stable regular JSON file without following a symlink."""

    byte_limit = positive_integer(maximum_bytes, "maximum artifact bytes")
    string_limit = byte_limit if maximum_string_bytes is None else maximum_string_bytes
    try:
        before = path.stat(follow_symlinks=False)
    except OSError as exc:
        fail(f"bounded JSON artifact is unavailable at {path}: {exc}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"bounded JSON artifact is not a regular file: {path}")
    if before.st_size <= 0:
        fail(f"bounded JSON artifact is empty: {path}")
    if before.st_size > byte_limit:
        fail(f"bounded JSON artifact exceeds {byte_limit} bytes: {path}")
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"bounded JSON artifact could not be opened at {path}: {exc}")
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            fail(f"bounded JSON artifact descriptor is not a regular file: {path}")
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            fail(f"bounded JSON artifact identity changed while opening: {path}")
        chunks: list[bytes] = []
        remaining = byte_limit + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    raw = b"".join(chunks)
    if len(raw) > byte_limit:
        fail(f"bounded JSON artifact exceeds {byte_limit} bytes: {path}")
    if (
        opened.st_size != after.st_size
        or opened.st_mtime_ns != after.st_mtime_ns
        or opened.st_ctime_ns != after.st_ctime_ns
    ):
        fail(f"bounded JSON artifact changed while reading: {path}")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            parse_constant=_reject_json_constant,
        )
        _json_budget(
            value,
            maximum_depth=maximum_depth,
            maximum_items=maximum_items,
            maximum_string_bytes=string_limit,
        )
    except BoundedIOError:
        raise
    except (
        UnicodeDecodeError,
        UnicodeEncodeError,
        json.JSONDecodeError,
        RecursionError,
        ValueError,
    ) as exc:
        fail(f"bounded JSON artifact is malformed at {path}: {exc}")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run")
    run.add_argument("--timeout", type=float, required=True)
    run.add_argument("--max-output-bytes", type=int, required=True)
    run.add_argument("arguments", nargs=argparse.REMAINDER)
    artifact = subparsers.add_parser("json")
    artifact.add_argument("--max-bytes", type=int, required=True)
    artifact.add_argument("--max-depth", type=int, default=DEFAULT_JSON_MAX_DEPTH)
    artifact.add_argument("--max-items", type=int, default=DEFAULT_JSON_MAX_ITEMS)
    artifact.add_argument("--max-string-bytes", type=int)
    artifact.add_argument("path", type=Path)
    return parser


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == INTERNAL_SUPERVISOR_MODE:
        return _run_supervisor(sys.argv[2:])
    args = build_parser().parse_args()
    try:
        if args.command == "run":
            arguments = args.arguments
            if arguments and arguments[0] == "--":
                arguments = arguments[1:]
            result = run_bounded(
                arguments,
                timeout_seconds=args.timeout,
                maximum_output_bytes=args.max_output_bytes,
            )
            sys.stdout.buffer.write(result.stdout)
            sys.stderr.buffer.write(result.stderr)
            return result.returncode
        value = read_bounded_json(
            args.path,
            maximum_bytes=args.max_bytes,
            maximum_depth=args.max_depth,
            maximum_items=args.max_items,
            maximum_string_bytes=args.max_string_bytes,
        )
        print(json.dumps(value, sort_keys=True, separators=(",", ":")))
        return 0
    except BoundedTimeout as exc:
        print(f"UNREVIEWED: {exc}", file=sys.stderr)
        return 124
    except BoundedIOError as exc:
        print(f"UNREVIEWED: {exc}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
