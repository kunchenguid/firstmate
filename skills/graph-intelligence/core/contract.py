"""Dual-mode execution contract for graph-intelligence scripts.

Every script in this skill is written as a pure Python function that takes
plain Python data and returns plain Python data.  The same function can be:

1. Imported and called directly::

       from core.temporal import as_of
       view = as_of(graph, "chapter", 3)

2. Executed as a standalone CLI tool with deterministic JSON I/O::

       python -m core.temporal '{"time_key": "chapter", "at": 3}' < graph.json

The ``dual_mode`` decorator marks a function as CLI-exposed and adds
telemetry capture.  ``export_dual_mode`` builds the ``main()`` bridge.

Determinism rules for CLI output on **stdout**:

- JSON with sorted keys, ASCII-escaped, fixed indent -- same input always
  produces byte-identical output.
- No wall-clock values, host names, or ordering-dependent fields on stdout.
- Telemetry goes to **stderr** only, and only on request (--telemetry).
"""

from __future__ import annotations

import functools
import inspect
import json
import sys
import threading
import time
from typing import Any, Callable

from pydantic import BaseModel, ConfigDict, Field


class GraphIntelError(Exception):
    """Base error for the graph-intelligence skill."""


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------


class NodeSpec(BaseModel):
    """One node in an interchange graph payload."""

    model_config = ConfigDict(extra="allow")

    id: str
    attributes: dict[str, Any] = Field(default_factory=dict)


class EdgeSpec(BaseModel):
    """One edge in an interchange graph payload."""

    model_config = ConfigDict(extra="allow")

    source: str
    target: str
    attributes: dict[str, Any] = Field(default_factory=dict)


class GraphSpec(BaseModel):
    """Full interchange schema for a graph payload."""

    directed: bool = False
    nodes: list[NodeSpec] = Field(default_factory=list)
    edges: list[EdgeSpec] = Field(default_factory=list)

    def to_networkx(self):
        """Materialize the spec as a networkx graph (DiGraph when directed)."""
        import networkx as nx

        graph = nx.DiGraph() if self.directed else nx.Graph()
        for node in self.nodes:
            graph.add_node(node.id, **dict(node.attributes))
        for edge in self.edges:
            graph.add_edge(edge.source, edge.target, **dict(edge.attributes))
        return graph


class TelemetryRecord(BaseModel):
    """One structured telemetry record. Never serialized to CLI stdout."""

    tool: str
    ok: bool
    elapsed_ms: float
    detail: dict[str, Any] = Field(default_factory=dict)


class Result(BaseModel):
    """Standard envelope for CLI output and programmatic checks."""

    ok: bool
    data: Any = None
    error: str | None = None

    @classmethod
    def success(cls, data: Any) -> "Result":
        return cls(ok=True, data=data)

    @classmethod
    def failure(cls, error: str) -> "Result":
        return cls(ok=False, error=error)


# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

_TELEMETRY_LOCK = threading.Lock()
_TELEMETRY: list[TelemetryRecord] = []


def clear_telemetry() -> None:
    """Drop all recorded telemetry (useful in tests)."""
    with _TELEMETRY_LOCK:
        _TELEMETRY.clear()


def get_telemetry() -> list[TelemetryRecord]:
    """Snapshot of all telemetry records collected so far."""
    with _TELEMETRY_LOCK:
        return list(_TELEMETRY)


def telemetry(func: Callable) -> Callable:
    """Record a telemetry entry for an instrumented function.

    The wrapped function's return value is untouched, so this decorator is
    invisible to plain-Python callers. Telemetry is retrievable via
    ``get_telemetry()`` or ``wrapper.last_telemetry``.
    """

    @functools.wraps(func)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        started = time.perf_counter()
        ok = True
        error: str | None = None
        try:
            return func(*args, **kwargs)
        except Exception as exc:  # noqa: BLE001 - telemetry must see all
            ok = False
            error = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            record = TelemetryRecord(
                tool=getattr(func, "__name__", "unknown"),
                ok=ok,
                elapsed_ms=round(elapsed_ms, 3),
                detail={"error": error} if error else {},
            )
            with _TELEMETRY_LOCK:
                _TELEMETRY.append(record)
            wrapper.last_telemetry = record

    wrapper.last_telemetry: TelemetryRecord | None = None  # type: ignore[attr-defined]
    wrapper.__is_telemetry__ = True  # type: ignore[attr-defined]
    return wrapper


# ---------------------------------------------------------------------------
# Dual-mode CLI bridge
# ---------------------------------------------------------------------------


def dual_mode(func: Callable) -> Callable:
    """Mark a pure Python function as also executable as a CLI tool.

    The decorator itself changes nothing about in-process behavior; it adds
    telemetry and a marker that ``export_dual_mode`` looks for.
    """

    wrapper = telemetry(func)
    wrapper.__is_dual_mode__ = True  # type: ignore[attr-defined]
    return wrapper


def emit_json(result: Result) -> str:
    """Serialize the result envelope deterministically (sorted keys, ASCII)."""
    payload = (
        {"ok": True, "data": result.data}
        if result.ok
        else {"ok": False, "error": result.error}
    )
    return json.dumps(payload, sort_keys=True, indent=2, ensure_ascii=True)


def export_dual_mode(func: Callable) -> Callable[[], int]:
    """Build a ``main()`` entry point for a dual-mode function.

    CLI contract
        argv[0]      path to a JSON input file with '-' meaning stdin
                     (optional; stdin is used when omitted)
        --telemetry  print the function's telemetry record to stderr

    Input handling
        * If the parsed JSON is a dict whose keys are all parameter names of
          the function, it is splatted as keyword arguments.
        * Otherwise it is passed as the single positional argument.

    Output
        stdout: deterministic JSON envelope ``{"ok": true, "data": ...}``
        exit:   0 on success, 1 on failure (error envelope on stdout)
    """

    def main(argv: list[str] | None = None) -> int:
        argv = list(sys.argv[1:] if argv is None else argv)
        want_telemetry = "--telemetry" in argv
        argv = [arg for arg in argv if arg != "--telemetry"]

        try:
            if argv:
                source, extra_args = argv[0], argv[1:]
                if source == "-":
                    payload = json.load(sys.stdin)
                else:
                    with open(source, "r", encoding="utf-8") as handle:
                        payload = json.load(handle)
            else:
                payload = json.load(sys.stdin)
                extra_args = []
        except Exception as exc:  # noqa: BLE001
            print(emit_json(Result.failure(f"input error: {exc}")))
            return 1

        if extra_args:
            print(
                emit_json(
                    Result.failure(f"unexpected extra arguments: {extra_args!r}")
                )
            )
            return 1

        clear_telemetry()
        try:
            if isinstance(payload, dict) and _looks_like_kwargs(payload, func):
                data = func(**payload)
            else:
                data = func(payload)
        except Exception as exc:  # noqa: BLE001 - CLI boundary
            print(emit_json(Result.failure(f"{type(exc).__name__}: {exc}")))
            return 1

        if want_telemetry:
            record = getattr(func, "last_telemetry", None)
            if record is not None:
                print(record.model_dump_json(), file=sys.stderr)
        print(emit_json(Result.success(data)))
        return 0

    main.__cli_function__ = func  # type: ignore[attr-defined]
    return main


def _looks_like_kwargs(payload: dict, func: Callable) -> bool:
    """True when a JSON dict should be splatted into the function.

    Single owner of the kwargs-splat decision: the payload is a dict, the
    function declares at least one named parameter, and every payload key is
    a named parameter of the function.
    """
    if not isinstance(payload, dict):
        return False
    try:
        signature = inspect_signature(func)
    except (TypeError, ValueError):
        return False
    params = list(signature.parameters.values())
    named = [
        p.name
        for p in params
        if p.kind
        in (
            inspect.Parameter.POSITIONAL_OR_KEYWORD,
            inspect.Parameter.KEYWORD_ONLY,
        )
    ]
    positional_only = [
        p
        for p in params
        if p.kind
        in (inspect.Parameter.POSITIONAL_ONLY, inspect.Parameter.VAR_POSITIONAL)
    ]
    if not named or len(positional_only) == len(params):
        return False
    return all(key in named for key in payload)


def inspect_signature(func: Callable):
    """Small indirection so tests can monkeypatch signature introspection."""
    return inspect.signature(func)