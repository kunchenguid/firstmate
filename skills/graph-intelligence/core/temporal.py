"""Parameterized temporal filtering over in-memory graphs.

The engine is generic over the attribute that carries time: pass any
``time_key`` (``"chapter"``, ``"epoch"``, ``"timestamp"``, ``"turn"``, ...)
and every node/edge holding a value under that key becomes temporally
addressable. Supported value shapes under one key:

* a scalar (``3``, ``"2001-01-01"``, ``"epoch-4"``) — a point in time;
* a two-sequence ``[start, end]`` — a closed interval;
* a mapping ``{"start": ..., "end": ...}`` (aliases ``from``/``to``) — a
  possibly open-ended interval (omit ``end`` for "still ongoing");
* split sibling attributes ``<time_key>_start`` / ``<time_key>_end``.

Elements without the key are *untimed*: treated as timeless and included
in every slice (disable with ``include_untimed=False``).

Comparisons use native Python ordering; mixed values that cannot be
ordered (ints vs strings) raise :class:`TemporalError` instead of
failing silently.
"""

from __future__ import annotations

from typing import Any, Callable, Mapping

import networkx as nx

from core.contract import GraphIntelError


class TemporalError(GraphIntelError):
    """Raised for invalid temporal parameters or incomparable time values."""


# ---------------------------------------------------------------------------
# Time-bound introspection
# ---------------------------------------------------------------------------


def _interval_bounds(value: Any):
    """Return (start, end) when the value encodes an interval, else None."""
    if isinstance(value, Mapping):
        if "start" in value or "from" in value:
            return value.get("start", value.get("from")), value.get("end", value.get("to"))
        return None
    if isinstance(value, (list, tuple)) and len(value) == 2:
        return value[0], value[1]
    return None


def _temporal_bound(data: Mapping[str, Any], time_key: str):
    """Classify a record's temporal value: ``(is_interval, start, end)``.

    Scalars become zero-width points (start == end == value). Returns
    ``None`` when the record is untimed under ``time_key``.
    """
    if time_key in data:
        raw = data[time_key]
        bounds = _interval_bounds(raw)
        if bounds is not None:
            return True, bounds[0], bounds[1]
        return False, raw, raw
    start_key, end_key = f"{time_key}_start", f"{time_key}_end"
    if start_key in data or end_key in data:
        return True, data.get(start_key), data.get(end_key)
    return None


def _cmp(a: Any, b: Any) -> int | None:
    """Three-way compare; None signals incomparable types."""
    try:
        if a < b:
            return -1
        if b < a:
            return 1
        return 0
    except TypeError:
        return None


def _covered(bound, at: Any) -> bool:
    """True when a point/interval bound contains ``at`` (closed interval)."""
    is_interval, start, end = bound
    if not is_interval:
        if _cmp(start, at) == 0:
            return True
        return False
    if start is not None:
        order = _cmp(start, at)
        if order is None or order == 1:
            return False
    if end is not None:
        order = _cmp(at, end)
        if order is None or order == 1:
            return False
    return True


def _overlaps_window(bound, start: Any, end: Any) -> bool:
    """True when a bound overlaps the closed window [start, end].

    ``None`` window bounds mean unbounded on that side.
    """
    is_interval, v_start, v_end = bound
    if not is_interval:
        point = v_start
        if start is not None:
            low = _cmp(point, start)
            if low == -1 or low is None:
                return False
        if end is not None:
            high = _cmp(point, end)
            if high == 1 or high is None:
                return False
        return True
    if v_end is not None and start is not None and _cmp(v_end, start) == -1:
        return False
    if v_start is not None and end is not None and _cmp(v_start, end) == 1:
        return False
    # Incomparable bounds fail closed for the overlap check.
    if start is not None and v_end is not None and _cmp(v_end, start) is None:
        return False
    if end is not None and v_start is not None and _cmp(v_start, end) is None:
        return False
    return True


def _revealed_by(bound, at: Any) -> bool:
    """True when a point was established at/before ``at`` or an interval
    is still active at ``at``."""
    is_interval, start, end = bound
    if not is_interval:
        return _cmp(start, at) in (0, -1)
    if start is not None and _cmp(start, at) == 1:
        return False
    if end is not None and _cmp(at, end) == 1:
        return False
    # Closed world: incomparable bounds mean "cannot confirm exposure".
    if start is not None and _cmp(start, at) is None:
        return False
    if end is not None and _cmp(at, end) is None:
        return False
    return True

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

_SLICE_SCOPES = ("all", "nodes", "edges")


def _require_scope(scope: str) -> None:
    if scope not in _SLICE_SCOPES:
        raise TemporalError(f"scope must be one of {_SLICE_SCOPES}")


def _passes(bound, mode: str, *, at=None, start=None, end=None) -> bool:
    """Dispatch a classified temporal bound against the slice mode."""
    if mode == "at":
        return _covered(bound, at)
    if mode == "as_of":
        return _revealed_by(bound, at)
    if mode == "window":
        return _overlaps_window(bound, start, end)
    raise TemporalError(f"unknown slice mode {mode!r}")


def _temporal_view(
    graph: nx.Graph,
    time_key: str,
    mode: str,
    *,
    at: Any = None,
    start: Any = None,
    end: Any = None,
    scope: str = "all",
    include_untimed: bool = True,
) -> nx.Graph:
    """Build the zero-copy temporal subgraph view (single implementation)."""
    if not isinstance(time_key, str) or not time_key:
        raise TemporalError("time_key must be a non-empty attribute name")
    if scope not in ("all", "nodes", "edges"):
        raise TemporalError(f"scope must be one of {_SLICE_SCOPES}")

    def keep(record: Mapping[str, Any]) -> bool:
        bound = _temporal_bound(record, time_key)
        if bound is None:
            return include_untimed
        return _passes(bound, mode, at=at, start=start, end=end)

    view_kwargs: dict[str, Any] = {}
    if scope in ("all", "nodes"):
        view_kwargs["filter_node"] = lambda node_id: keep(graph.nodes[node_id])
    if scope in ("all", "edges"):
        if graph.is_multigraph():
            view_kwargs["filter_edge"] = (
                lambda u, v, k: keep(graph[u][v][k])
            )
        else:
            view_kwargs["filter_edge"] = lambda u, v: keep(graph[u][v])
    return nx.subgraph_view(graph, **view_kwargs)


def slice_at(
    graph: nx.Graph,
    time_key: str,
    at: Any,
    *,
    scope: str = "all",
    include_untimed: bool = True,
) -> nx.Graph:
    """Elements present at exactly ``at``: scalar values equal to ``at``,
    intervals containing ``at``."""
    _require_scope(scope)
    return _temporal_view(
        graph, time_key, "at", at=at, scope=scope, include_untimed=include_untimed
    )


def as_of(
    graph: nx.Graph,
    time_key: str,
    at: Any,
    *,
    scope: str = "all",
    include_untimed: bool = True,
) -> nx.Graph:
    """Cumulative view as of ``at``: points established at or before it,
    intervals still active at it. Untimed elements count as timeless."""
    return _temporal_view(
        graph, time_key, "as_of", at=at, scope=scope, include_untimed=include_untimed
    )


def window(
    graph: nx.Graph,
    time_key: str,
    start: Any = None,
    end: Any = None,
    *,
    scope: str = "all",
    include_untimed: bool = True,
) -> nx.Graph:
    """Elements temporally overlapping the closed window [start, end].

    ``None`` bounds are unbounded; scalars qualify when inside the window,
    intervals when they intersect it.
    """
    if start is None and end is None:
        raise TemporalError("window() requires at least one of start/end")
    return _temporal_view(
        graph,
        time_key,
        "window",
        start=start,
        end=end,
        scope=scope,
        include_untimed=include_untimed,
    )


def temporal_bound(data: Mapping[str, Any], time_key: str):
    """Public read-only classification helper (diagnostics and tests)."""
    return _temporal_bound(data, time_key)
