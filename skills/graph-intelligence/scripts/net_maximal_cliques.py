"""Cohesive groups: maximal cliques, triangles, clique number.

Implements Bron–Kerbosch with pivot and a streaming iterator, plus
triangle counting and clique-number estimation. Handles undirected and
directed inputs (directed → undirected projection), integrates with
``core.filter_engine`` and ``core.temporal``, and exposes dual-mode
CLI via ``core.contract``.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Generator

import networkx as nx

_SKILL_ROOT = Path(__file__).resolve().parents[1]
if str(_SKILL_ROOT) not in sys.path:
    sys.path.insert(0, str(_SKILL_ROOT))

from core.contract import GraphSpec, dual_mode, export_dual_mode  # noqa: E402
from core.filter_engine import filter_graph  # noqa: E402
from core.temporal import as_of, slice_at, window  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _coerce_graph(graph: Any) -> nx.Graph:
    """Accept NetworkX graph, GraphSpec, or interchange dict."""
    if isinstance(graph, nx.Graph):
        return graph
    if isinstance(graph, GraphSpec):
        g = graph.to_networkx()
        for node in graph.nodes:
            nid = node.id
            if nid in g and not g.nodes[nid] and node.__pydantic_extra__:
                g.nodes[nid].update(node.__pydantic_extra__)
            if node.attributes:
                g.nodes[nid].update(node.attributes)
        return g
    if isinstance(graph, dict):
        if "nodes" in graph or "edges" in graph or "links" in graph:
            from core.graph_loader import load_json

            return load_json(graph)
        # payload envelope with graph key
        if "graph" in graph and isinstance(graph["graph"], dict):
            from core.graph_loader import load_json

            inner = graph["graph"]
            if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
                return load_json(inner)
        raise ValueError(f"unrecognised graph dict: {list(graph.keys())[:5]}")
    raise TypeError(f"unsupported graph type: {type(graph).__name__}")


def _apply_filters(
    graph: nx.Graph,
    *,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> nx.Graph:
    view = graph
    if node_attributes or edge_attributes:
        view = filter_graph(view, node_attributes=node_attributes, edge_attributes=edge_attributes)
    if time_key is not None:
        if time_mode == "slice_at" or (time_mode is None and time_at is not None):
            view = slice_at(view, time_key, time_at, include_untimed=include_untimed)
        elif time_mode == "as_of":
            view = as_of(view, time_key, time_at, include_untimed=include_untimed)
        elif time_mode == "window":
            view = window(view, time_key, time_start, time_end, include_untimed=include_untimed)
        elif time_mode is not None:
            raise ValueError(f"unknown time_mode: {time_mode!r}")
    return view


def _to_undirected_copy(g: nx.Graph) -> nx.Graph:
    """Undirected copy suitable for clique algorithms."""
    ug = g.to_undirected() if g.is_directed() else g
    # subgraph_view needs copy for algorithms that mutate
    if hasattr(ug, "_NODE_OK"):
        return nx.Graph(ug)
    # also copy to avoid mutating original
    return nx.Graph(ug)


def _bron_kerbosch_pivot(
    graph: nx.Graph,
) -> Generator[list[str], None, None]:
    """Bron–Kerbosch with pivot — stream iterator of maximal cliques.

    Pure Python, yields sorted clique lists deterministically.
    Pivot selection: node in P ∪ X with max neighbours in P.
    """
    # Use string keys for determinism
    adj: dict[str, set[str]] = {}
    for n in graph.nodes():
        ns = str(n)
        adj[ns] = set(str(nb) for nb in graph.neighbors(n))
    nodes = sorted(adj.keys())

    # Recursive helper
    def _bk(r: set[str], p: set[str], x: set[str]) -> Generator[list[str], None, None]:
        if not p and not x:
            yield sorted(r)
            return
        # pivot choice
        union = p | x
        pivot = None
        max_deg = -1
        for u in union:
            cnt = len(adj[u] & p) if u in adj else 0
            if cnt > max_deg:
                max_deg = cnt
                pivot = u
        # candidates = P \ N(pivot)
        pivot_nbrs = adj.get(pivot, set()) if pivot is not None else set()
        candidates = sorted(p - pivot_nbrs)
        for v in candidates:
            nbrs = adj.get(v, set())
            yield from _bk(r | {v}, p & nbrs, x & nbrs)
            p = p - {v}
            x = x | {v}

    yield from _bk(set(), set(nodes), set())


def _sorted_cliques(cliques: list[list[str]]) -> list[list[str]]:
    """Deterministic sort: size desc then lexicographic."""
    return sorted([sorted(c) for c in cliques], key=lambda x: (-len(x), x))


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


@dual_mode
def find_maximal_cliques(
    graph: Any,
    *,
    max_size: int | None = None,
    min_size: int | None = None,
    limit: int | None = None,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Find all maximal cliques via Bron–Kerbosch with pivot.

    Args:
        max_size: keep only cliques with size <= max_size.
        min_size: keep only cliques with size >= min_size.
        limit: cap number of cliques returned (deterministic order).

    Returns ``{"cliques": [[node_id, ...], ...], "count": int,
    "max_size": int, "clique_number": int}``.

    Cliques are sorted by size descending then lexicographically; inner
    cliques are sorted lexicographically for deterministic JSON.
    """
    # CLI envelope handling
    if isinstance(graph, dict) and "graph" in graph and isinstance(graph["graph"], dict):
        payload = graph
        inner = payload.get("graph")
        if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
            # extract known kwargs
            max_size = payload.get("max_size", max_size)
            min_size = payload.get("min_size", min_size)
            limit = payload.get("limit", limit)
            node_attributes = payload.get("node_attributes", node_attributes)
            edge_attributes = payload.get("edge_attributes", edge_attributes)
            time_key = payload.get("time_key", time_key)
            time_mode = payload.get("time_mode", time_mode)
            time_at = payload.get("time_at", time_at)
            time_start = payload.get("time_start", time_start)
            time_end = payload.get("time_end", time_end)
            include_untimed = payload.get("include_untimed", include_untimed)
            graph = inner

    g = _coerce_graph(graph)
    g = _apply_filters(
        g,
        node_attributes=node_attributes,
        edge_attributes=edge_attributes,
        time_key=time_key,
        time_mode=time_mode,
        time_at=time_at,
        time_start=time_start,
        time_end=time_end,
        include_untimed=include_untimed,
    )
    ug = _to_undirected_copy(g)

    if ug.number_of_nodes() == 0:
        return {"cliques": [], "count": 0, "max_size": 0, "clique_number": 0}

    # Stream via Bron–Kerbosch with pivot
    raw = list(_bron_kerbosch_pivot(ug))
    # Fallback validation: if empty but nodes exist, each isolated node is a clique
    if not raw and ug.number_of_nodes() > 0:
        raw = [[str(n)] for n in ug.nodes()]

    # Apply size filters
    if min_size is not None:
        raw = [c for c in raw if len(c) >= min_size]
    if max_size is not None:
        raw = [c for c in raw if len(c) <= max_size]

    cliques = _sorted_cliques(raw)
    if limit is not None:
        cliques = cliques[: int(limit)]

    max_s = max((len(c) for c in cliques), default=0)
    return {"cliques": cliques, "count": len(cliques), "max_size": max_s, "clique_number": max_s}


def iter_maximal_cliques(
    graph: Any,
    *,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> Generator[list[str], None, None]:
    """Stream iterator over maximal cliques (Bron–Kerbosch with pivot)."""
    g = _coerce_graph(graph)
    g = _apply_filters(
        g,
        node_attributes=node_attributes,
        edge_attributes=edge_attributes,
        time_key=time_key,
        time_mode=time_mode,
        time_at=time_at,
        time_start=time_start,
        time_end=time_end,
        include_untimed=include_untimed,
    )
    ug = _to_undirected_copy(g)
    if ug.number_of_nodes() == 0:
        return
        yield  # make it a generator
    yield from _bron_kerbosch_pivot(ug)


@dual_mode
def count_triangles(
    graph: Any,
    *,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Count triangles per node and total.

    Returns ``{"triangles": {node: int}, "total": int,
    "per_node_avg": float}`` where total is number of distinct
    triangles (each triangle counted once, i.e. sum // 3).

    Uses ``nx.triangles`` on an undirected copy.
    """
    if isinstance(graph, dict) and "graph" in graph and isinstance(graph["graph"], dict):
        payload = graph
        inner = payload.get("graph")
        if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
            node_attributes = payload.get("node_attributes", node_attributes)
            edge_attributes = payload.get("edge_attributes", edge_attributes)
            time_key = payload.get("time_key", time_key)
            time_mode = payload.get("time_mode", time_mode)
            time_at = payload.get("time_at", time_at)
            time_start = payload.get("time_start", time_start)
            time_end = payload.get("time_end", time_end)
            include_untimed = payload.get("include_untimed", include_untimed)
            graph = inner

    g = _coerce_graph(graph)
    g = _apply_filters(
        g,
        node_attributes=node_attributes,
        edge_attributes=edge_attributes,
        time_key=time_key,
        time_mode=time_mode,
        time_at=time_at,
        time_start=time_start,
        time_end=time_end,
        include_untimed=include_untimed,
    )
    ug = _to_undirected_copy(g)
    if ug.number_of_nodes() == 0:
        return {"triangles": {}, "total": 0, "per_node_avg": 0.0}

    try:
        tri = nx.triangles(ug)
    except Exception as exc:
        raise ValueError(f"triangle counting failed: {exc}") from exc

    # Normalize keys to strings, sorted
    tri_str: dict[str, int] = {str(k): int(v) for k, v in tri.items()}
    tri_str = dict(sorted(tri_str.items()))
    total = sum(tri_str.values()) // 3
    avg = sum(tri_str.values()) / len(tri_str) if tri_str else 0.0
    return {"triangles": tri_str, "total": int(total), "per_node_avg": float(avg)}


@dual_mode
def get_clique_number(
    graph: Any,
    *,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Compute the graph clique number (size of maximum clique).

    Returns ``{"clique_number": int, "max_clique": [nodes]}`` where
    ``max_clique`` is one representative maximum clique (sorted).

    Tries ``nx.graph_clique_number`` when available, else derives from
    Bron–Kerbosch maximal cliques.
    """
    if isinstance(graph, dict) and "graph" in graph and isinstance(graph["graph"], dict):
        payload = graph
        inner = payload.get("graph")
        if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
            node_attributes = payload.get("node_attributes", node_attributes)
            edge_attributes = payload.get("edge_attributes", edge_attributes)
            time_key = payload.get("time_key", time_key)
            time_mode = payload.get("time_mode", time_mode)
            time_at = payload.get("time_at", time_at)
            time_start = payload.get("time_start", time_start)
            time_end = payload.get("time_end", time_end)
            include_untimed = payload.get("include_untimed", include_untimed)
            graph = inner

    g = _coerce_graph(graph)
    g = _apply_filters(
        g,
        node_attributes=node_attributes,
        edge_attributes=edge_attributes,
        time_key=time_key,
        time_mode=time_mode,
        time_at=time_at,
        time_start=time_start,
        time_end=time_end,
        include_untimed=include_untimed,
    )
    ug = _to_undirected_copy(g)
    if ug.number_of_nodes() == 0:
        return {"clique_number": 0, "max_clique": []}

    # Try built-in
    try:
        if hasattr(nx, "graph_clique_number"):
            cn = int(nx.graph_clique_number(ug))
            # Find representative max clique via enumeration
            max_clique: list[str] = []
            for c in _bron_kerbosch_pivot(ug):
                if len(c) == cn:
                    max_clique = sorted(c)
                    break
            if not max_clique and cn > 0:
                max_clique = []
            return {"clique_number": cn, "max_clique": max_clique}
    except Exception:
        pass

    try:
        if hasattr(nx, "approximation") and hasattr(nx.approximation, "graph_clique_number"):
            cn = int(nx.approximation.graph_clique_number(ug))
            return {"clique_number": cn, "max_clique": []}
    except Exception:
        pass

    # Fallback: enumerate via Bron–Kerbosch
    max_size = 0
    max_clique: list[str] = []
    for clique in _bron_kerbosch_pivot(ug):
        if len(clique) > max_size:
            max_size = len(clique)
            max_clique = sorted(clique)
    # Isolated nodes: clique number at least 1 if nodes exist
    if max_size == 0 and ug.number_of_nodes() > 0:
        max_size = 1
        max_clique = sorted([str(n) for n in ug.nodes()])[:1]
    return {"clique_number": int(max_size), "max_clique": max_clique}


# ---------------------------------------------------------------------------
# CLI entry points
# ---------------------------------------------------------------------------

main_cliques = export_dual_mode(find_maximal_cliques)
main_triangles = export_dual_mode(count_triangles)
main_clique_number = export_dual_mode(get_clique_number)

main = export_dual_mode(find_maximal_cliques)


if __name__ == "__main__":
    raise SystemExit(main())
