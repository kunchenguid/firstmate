"""Global reach: closeness and harmonic centrality with broadcast seeds.

Both measures integrate with ``core.filter_engine`` and ``core.temporal``.
Closeness uses Wasserman-Faust improvement for disconnected graphs so
unreachable pairs contribute proportionally rather than as zero/inf.
Harmonic naturally handles disconnected graphs. Broadcast seed selection
picks one representative per component (highest degree, tie-break lexicographically)
so callers can seed broadcasts efficiently.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import networkx as nx

_SKILL_ROOT = Path(__file__).resolve().parents[1]
if str(_SKILL_ROOT) not in sys.path:
    sys.path.insert(0, str(_SKILL_ROOT))

from core.contract import GraphSpec, dual_mode, export_dual_mode  # noqa: E402
from core.filter_engine import filter_graph  # noqa: E402
from core.temporal import as_of, slice_at, window  # noqa: E402


def _coerce_graph(graph: Any) -> nx.Graph:
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
        if "graph" in graph and isinstance(graph["graph"], dict):
            inner = graph["graph"]
            if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
                from core.graph_loader import load_json

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


def _materialize_copy(g: nx.Graph) -> nx.Graph:
    if hasattr(g, "_NODE_OK"):
        return nx.Graph(g) if not g.is_directed() else nx.DiGraph(g)
    return g


def _normalize_scores(scores: dict[Any, float]) -> dict[str, float]:
    return {str(k): float(v) for k, v in sorted(scores.items(), key=lambda x: str(x[0]))}


def _broadcast_seeds(graph: nx.Graph) -> list[str]:
    """Pick one seed per connected component (undirected view).

    Seed per component = node with highest degree (tie lexicographically
    smallest string id). Returned sorted lexicographically for determinism.
    """
    if graph.number_of_nodes() == 0:
        return []
    ug = graph.to_undirected() if graph.is_directed() else graph
    # ensure materialized for components
    if hasattr(ug, "_NODE_OK"):
        ug = nx.Graph(ug)
    try:
        comps = list(nx.connected_components(ug))
    except Exception:
        # directed fallback already handled
        comps = [set(ug.nodes())]
    seeds: list[str] = []
    for comp in comps:
        # highest degree in original graph (respect direction's total degree)
        best = None
        best_deg = -1
        for n in comp:
            deg = graph.degree(n) if n in graph else 0
            ns = str(n)
            if deg > best_deg or (deg == best_deg and (best is None or ns < best)):
                best_deg = deg
                best = ns
        if best is not None:
            seeds.append(best)
    return sorted(seeds)


@dual_mode
def compute_closeness(
    graph: Any,
    *,
    weight: str | None = None,
    wf_improved: bool = True,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Closeness centrality with disconnected-graph handling.

    Uses ``nx.closeness_centrality`` with Wasserman-Faust scaling
    (``wf_improved``) by default so components are comparable.
    For disconnected graphs, ``seeds`` gives one broadcast seed per
    component (highest-degree node) and ``disconnected`` flags the case.

    Returns ``{"scores": {node: float}, "top": [[node, score], ...],
    "disconnected": bool, "seeds": [...], "components": int}``.
    """
    # CLI envelope
    if isinstance(graph, dict) and "graph" in graph and isinstance(graph["graph"], dict):
        payload = graph
        inner = payload.get("graph")
        if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
            weight = payload.get("weight", weight)
            wf_improved = payload.get("wf_improved", wf_improved)
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
    g = _materialize_copy(g)

    if g.number_of_nodes() == 0:
        return {"scores": {}, "top": [], "disconnected": False, "seeds": [], "components": 0}

    if weight is not None:
        has_weight = any(weight in d for _, _, d in g.edges(data=True))
        if not has_weight:
            weight = None

    # Component info for seed selection (before closeness)
    ug_for_comp = g.to_undirected() if g.is_directed() else g
    if hasattr(ug_for_comp, "_NODE_OK"):
        ug_for_comp = nx.Graph(ug_for_comp)
    try:
        if g.is_directed():
            comps = list(nx.weakly_connected_components(g))
        else:
            comps = list(nx.connected_components(g))
    except Exception:
        comps = [set(g.nodes())]
    disconnected = len(comps) > 1
    seeds = _broadcast_seeds(g)

    # Single node special case: closeness 0
    if g.number_of_nodes() == 1:
        node = str(list(g.nodes())[0])
        return {"scores": {node: 0.0}, "top": [[node, 0.0]], "disconnected": False, "seeds": [node], "components": 1}

    try:
        scores = nx.closeness_centrality(g, distance=weight, wf_improved=wf_improved)
    except Exception as exc:
        raise ValueError(f"closeness centrality failed: {exc}") from exc

    norm = _normalize_scores(scores)
    top = sorted(norm.items(), key=lambda x: (-x[1], x[0]))[:10]
    return {
        "scores": norm,
        "top": [[n, s] for n, s in top],
        "disconnected": bool(disconnected),
        "seeds": seeds,
        "components": len(comps),
    }


@dual_mode
def compute_harmonic(
    graph: Any,
    *,
    weight: str | None = None,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Harmonic centrality (naturally handles disconnected graphs).

    Unreachable pairs contribute 0. Also returns broadcast seeds per
    component and component count for operational use.

    Returns ``{"scores": {node: float}, "top": [[node, score], ...],
    "disconnected": bool, "seeds": [...], "components": int}``.
    """
    if isinstance(graph, dict) and "graph" in graph and isinstance(graph["graph"], dict):
        payload = graph
        inner = payload.get("graph")
        if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
            weight = payload.get("weight", weight)
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
    g = _materialize_copy(g)

    if g.number_of_nodes() == 0:
        return {"scores": {}, "top": [], "disconnected": False, "seeds": [], "components": 0}

    if g.number_of_nodes() == 1:
        node = str(list(g.nodes())[0])
        return {"scores": {node: 0.0}, "top": [[node, 0.0]], "disconnected": False, "seeds": [node], "components": 1}

    if weight is not None:
        has_weight = any(weight in d for _, _, d in g.edges(data=True))
        if not has_weight:
            weight = None

    try:
        if g.is_directed():
            comps = list(nx.weakly_connected_components(g))
        else:
            comps = list(nx.connected_components(_materialize_copy(g.to_undirected() if g.is_directed() else g)))
    except Exception:
        comps = [set(g.nodes())]
    disconnected = len(comps) > 1
    seeds = _broadcast_seeds(g)

    try:
        scores = nx.harmonic_centrality(g, distance=weight)
    except Exception as exc:
        raise ValueError(f"harmonic centrality failed: {exc}") from exc

    norm = _normalize_scores(scores)
    top = sorted(norm.items(), key=lambda x: (-x[1], x[0]))[:10]
    return {
        "scores": norm,
        "top": [[n, s] for n, s in top],
        "disconnected": bool(disconnected),
        "seeds": seeds,
        "components": len(comps),
    }


main_closeness = export_dual_mode(compute_closeness)
main_harmonic = export_dual_mode(compute_harmonic)

main = export_dual_mode(compute_closeness)


if __name__ == "__main__":
    raise SystemExit(main())
