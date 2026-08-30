"""Multi-hypothesis traversal: Yen's K shortest loop-free paths.

Implements Yen's algorithm via ``networkx.shortest_simple_paths``
which is its modern loop-free variant. Supports K <= 10, diverse
alternative paths, weighted/unweighted graphs, and integrates with
``core.filter_engine`` and ``core.temporal``.
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


def _resolve_weight(g: nx.Graph, weight: str | None) -> str | None:
    if weight is None:
        return None
    has = any(weight in d for _, _, d in g.edges(data=True))
    return weight if has else None


def _path_cost(graph: nx.Graph, path: list[Any], weight: str | None) -> float:
    if len(path) < 2:
        return 0.0
    if weight is None:
        return float(len(path) - 1)
    total = 0.0
    for u, v in zip(path, path[1:]):
        data = graph.get_edge_data(u, v)
        if data is None:
            return float("inf")
        # multigraph: data is dict of key -> attrs
        if graph.is_multigraph():
            # take min weight among parallel edges
            try:
                w = min(d.get(weight, 1.0) for d in data.values())
            except Exception:
                w = 1.0
        else:
            w = float(data.get(weight, 1.0))
        total += w
    return float(total)


@dual_mode
def find_yen_k_shortest_paths(
    graph: Any,
    source: str | None = None,
    target: str | None = None,
    *,
    k: int = 3,
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
    """Yen's K shortest loop-free paths (K ≤ 10).

    Each path is simple (no repeated nodes). Paths are returned in order
    of non-decreasing cost (hop count when unweighted, weight sum otherwise).
    Diverse alternatives naturally emerge from Yen's deviation mechanism.

    Args:
        graph: NetworkX graph, GraphSpec, or interchange dict.
        source: start node id.
        target: end node id.
        k: number of paths (1..10).
        weight: edge attribute for cost, or None for BFS hop count.

    Returns ``{"paths": [[node, ...], ...], "costs": [float, ...],
    "found": bool, "count": int, "k": int, "source": str, "target": str}``.
    When no path exists, ``paths`` and ``costs`` are empty and ``found``
    is False.
    """
    # CLI payload envelope: {"graph": {...}, "source": "a", "target": "b", "k": 3}
    if isinstance(graph, dict) and source is None and target is None:
        if "source" in graph and "target" in graph:
            payload = graph
            inner = payload.get("graph", None)
            # inner may be interchange dict or absent (then graph itself is the spec plus keys)
            if inner is not None and isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
                graph = inner
            else:
                # payload itself may be the graph spec plus source/target; strip those keys and treat remainder as graph
                # Heuristic: if payload has nodes/edges keys, it's a graph spec with extra keys
                if "nodes" in payload or "edges" in payload or "links" in payload:
                    # keep payload as graph (coerce will ignore extra keys? but our loader uses nodes/edges)
                    graph = {kk: vv for kk, vv in payload.items() if kk not in ("source", "target", "k", "weight", "node_attributes", "edge_attributes", "time_key", "time_mode", "time_at", "time_start", "time_end", "include_untimed")}
                else:
                    graph = payload.get("graph", payload)
            source = payload.get("source", source)
            target = payload.get("target", target)
            k = payload.get("k", k)
            weight = payload.get("weight", weight)
            node_attributes = payload.get("node_attributes", node_attributes)
            edge_attributes = payload.get("edge_attributes", edge_attributes)
            time_key = payload.get("time_key", time_key)
            time_mode = payload.get("time_mode", time_mode)
            time_at = payload.get("time_at", time_at)
            time_start = payload.get("time_start", time_start)
            time_end = payload.get("time_end", time_end)
            include_untimed = payload.get("include_untimed", include_untimed)

    if source is None or target is None:
        raise ValueError("source and target are required")

    if not isinstance(k, int) or k < 1 or k > 10:
        raise ValueError(f"k must be an integer in 1..10, got {k!r}")

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

    src, tgt = str(source), str(target)

    if src not in g or tgt not in g:
        return {"paths": [], "costs": [], "found": False, "count": 0, "k": int(k), "source": src, "target": tgt, "reason": "source or target not in graph"}

    if src == tgt:
        return {"paths": [[src]], "costs": [0.0], "found": True, "count": 1, "k": int(k), "source": src, "target": tgt}

    w = _resolve_weight(g, weight)

    # Use Yen's via shortest_simple_paths
    try:
        gen = nx.shortest_simple_paths(g, src, tgt, weight=w)
    except (nx.NetworkXNoPath, nx.NodeNotFound) as exc:
        return {"paths": [], "costs": [], "found": False, "count": 0, "k": int(k), "source": src, "target": tgt, "reason": str(exc)}
    except Exception as exc:
        raise ValueError(f"yen K-shortest failed: {exc}") from exc

    paths: list[list[str]] = []
    costs: list[float] = []
    try:
        for idx, path in enumerate(gen):
            if idx >= k:
                break
            # ensure loop-free (shortest_simple_paths already guarantees)
            str_path = [str(n) for n in path]
            c = _path_cost(g, path, w)
            paths.append(str_path)
            costs.append(float(c))
            if len(paths) >= k:
                break
    except nx.NetworkXNoPath:
        pass
    except Exception as exc:
        # If generator exhausted or error, just return what we have
        if not paths:
            raise ValueError(f"yen iteration failed: {exc}") from exc

    found = len(paths) > 0
    return {
        "paths": paths,
        "costs": costs,
        "found": bool(found),
        "count": len(paths),
        "k": int(k),
        "source": src,
        "target": tgt,
    }


main_yen = export_dual_mode(find_yen_k_shortest_paths)

main = export_dual_mode(find_yen_k_shortest_paths)


if __name__ == "__main__":
    raise SystemExit(main())
