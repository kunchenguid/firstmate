"""Connected components, LCC isolation, bridges and articulation points.

All functions are pure Python, operate on NetworkX graphs or GraphSpec
dicts, and integrate with ``core.filter_engine`` and ``core.temporal``
for in-memory predicate and time filtering.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import networkx as nx

# Ensure skill root is importable when run as module
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
        # GraphSpec may have inline extras; merge them into node/edge attrs
        g = graph.to_networkx()
        # Fix: GraphSpec with inline attributes loses them (stored as extras)
        # So patch nodes that ended up with empty attrs but had extras
        for node in graph.nodes:
            nid = node.id
            if nid in g and not g.nodes[nid] and node.__pydantic_extra__:
                g.nodes[nid].update(node.__pydantic_extra__)
            # Also handle attributes dict merging
            if node.attributes:
                g.nodes[nid].update(node.attributes)
        return g
    if isinstance(graph, dict):
        if "nodes" in graph or "edges" in graph or "links" in graph:
            from core.graph_loader import load_json

            return load_json(graph)
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
    """Apply filter_engine and temporal filters in sequence."""
    view = graph
    # Attribute / predicate filtering via filter_engine
    if node_attributes or edge_attributes:
        view = filter_graph(
            view,
            node_attributes=node_attributes,
            edge_attributes=edge_attributes,
        )
    # Temporal filtering
    if time_key is not None:
        if time_mode == "slice_at" or (time_mode is None and time_at is not None):
            view = slice_at(view, time_key, time_at, include_untimed=include_untimed)
        elif time_mode == "as_of":
            view = as_of(view, time_key, time_at, include_untimed=include_untimed)
        elif time_mode == "window":
            view = window(view, time_key, time_start, time_end, include_untimed=include_untimed)
        elif time_mode is not None:
            raise ValueError(f"unknown time_mode: {time_mode!r}")
        # if time_key provided but no mode/at, treat as no-op
    return view


def _graph_to_spec(graph: nx.Graph) -> dict[str, Any]:
    """Serialize a NetworkX graph back to interchange dict."""
    nodes = [{"id": str(n), "attributes": dict(d)} for n, d in graph.nodes(data=True)]
    edges = [
        {"source": str(u), "target": str(v), "attributes": dict(d)}
        for u, v, d in graph.edges(data=True)
    ]
    return {"directed": graph.is_directed(), "nodes": nodes, "edges": edges}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


@dual_mode
def compute_components(
    graph: Any,
    *,
    directed: bool | None = None,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Compute connected components (weak/strong for directed).

    Returns ``{"components": [[node_id, ...], ...], "count": int,
    "sizes": [int, ...], "directed": bool}`` sorted deterministically.
    """
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
    is_directed = directed if directed is not None else g.is_directed()
    if is_directed and g.is_directed():
        comps = list(nx.weakly_connected_components(g))
    elif is_directed and not g.is_directed():
        # Treat undirected as directed-agnostic
        comps = list(nx.connected_components(g))
    else:
        comps = list(nx.connected_components(g)) if not g.is_directed() else list(nx.weakly_connected_components(g))

    # Deterministic sort: by size desc then lexicographically
    sorted_comps = sorted([sorted(str(n) for n in c) for c in comps], key=lambda x: (-len(x), x))
    sizes = sorted([len(c) for c in sorted_comps], reverse=True)
    return {
        "components": sorted_comps,
        "count": len(sorted_comps),
        "sizes": sizes,
        "directed": is_directed,
    }


@dual_mode
def isolate_lcc(
    graph: Any,
    *,
    directed: bool | None = None,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Return the largest connected component as an interchange dict.

    Also returns metadata ``{"graph": {...}, "lcc_nodes": [...], "lcc_size": int,
    "total_components": int}``.
    """
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
    is_directed = directed if directed is not None else g.is_directed()
    if g.number_of_nodes() == 0:
        return {"graph": _graph_to_spec(g), "lcc_nodes": [], "lcc_size": 0, "total_components": 0}

    if is_directed and g.is_directed():
        comps = list(nx.weakly_connected_components(g))
    else:
        comps = list(nx.connected_components(g)) if not g.is_directed() else list(nx.weakly_connected_components(g))

    if not comps:
        return {"graph": _graph_to_spec(g), "lcc_nodes": [], "lcc_size": 0, "total_components": 0}

    lcc = max(comps, key=len)
    lcc_sorted = sorted(str(n) for n in lcc)
    # Build subgraph and materialize
    sub = g.subgraph(lcc).copy()
    return {
        "graph": _graph_to_spec(sub),
        "lcc_nodes": lcc_sorted,
        "lcc_size": len(lcc_sorted),
        "total_components": len(comps),
    }


@dual_mode
def find_bridges_and_articulation_points(
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
    """Find bridges and articulation points (undirected view).

    For directed graphs the underlying undirected version is used.
    Returns ``{"bridges": [[u, v], ...], "articulation_points": [...],
    "bridge_count": int, "articulation_count": int}``.
    """
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
    # Use undirected view for bridge/articulation semantics
    ug = g.to_undirected() if g.is_directed() else g
    # Work on a copy to avoid view issues with algorithms that mutate
    # subgraph_view can cause issues with some nx algorithms; copy nodes
    if hasattr(ug, '_NODE_OK'):
        ug = nx.Graph(ug)

    bridges: list[list[str]] = []
    articulation: list[str] = []

    if ug.number_of_nodes() > 0:
        try:
            bridges = sorted([sorted([str(u), str(v)]) for u, v in nx.bridges(ug)])
        except Exception:
            bridges = []
        try:
            articulation = sorted(str(n) for n in nx.articulation_points(ug))
        except Exception:
            articulation = []

    return {
        "bridges": bridges,
        "articulation_points": articulation,
        "bridge_count": len(bridges),
        "articulation_count": len(articulation),
    }


# ---------------------------------------------------------------------------
# CLI entry points
# ---------------------------------------------------------------------------

main_components = export_dual_mode(compute_components)
main_lcc = export_dual_mode(isolate_lcc)
main_bridges = export_dual_mode(find_bridges_and_articulation_points)

main = export_dual_mode(compute_components)


if __name__ == "__main__":
    raise SystemExit(main())
