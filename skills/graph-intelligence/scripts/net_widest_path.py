"""Widest path (bottleneck capacity Dijkstra) maximizing minimum edge capacity.

Finds the path between source and target that maximizes the bottleneck
capacity (minimum edge weight along the path). Uses a max-heap Dijkstra
variant. Integrates with ``core.filter_engine`` and ``core.temporal``
and exposes dual-mode CLI via ``core.contract``.
"""

from __future__ import annotations

import heapq
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


def _widest_path_dijkstra(g: nx.Graph, source: str, target: str, weight: str) -> tuple[list[str] | None, float]:
    """Max-heap Dijkstra maximizing bottleneck capacity."""
    # capacity[v] = max bottleneck capacity from source to v
    capacity: dict[str, float] = {str(n): 0.0 for n in g.nodes()}
    # source has infinite capacity
    capacity[source] = float("inf")
    parent: dict[str, str | None] = {str(n): None for n in g.nodes()}
    # max-heap via negative values
    heap: list[tuple[float, str]] = [(-float("inf"), source)]
    visited: set[str] = set()

    while heap:
        neg_cap, u = heapq.heappop(heap)
        cap_u = -neg_cap
        if u in visited:
            continue
        visited.add(u)
        if u == target:
            break
        # Explore neighbors
        for v in g.neighbors(u):
            vs = str(v)
            if vs in visited:
                continue
            # edge capacity
            data = g.get_edge_data(u, v)
            if data is None:
                continue
            if g.is_multigraph():
                # pick max capacity among parallel edges
                try:
                    edge_cap = max(float(d.get(weight, 1.0)) for d in data.values())
                except Exception:
                    edge_cap = 1.0
            else:
                edge_cap = float(data.get(weight, 1.0))
            # bottleneck to v via u is min(cap_u, edge_cap)
            if cap_u == float("inf"):
                new_cap = edge_cap
            else:
                new_cap = min(cap_u, edge_cap)
            if new_cap > capacity[vs]:
                capacity[vs] = new_cap
                parent[vs] = u
                heapq.heappush(heap, (-new_cap, vs))

    if capacity[target] == 0.0:
        return None, 0.0

    # Reconstruct path
    path: list[str] = []
    cur: str | None = target
    while cur is not None:
        path.append(cur)
        cur = parent[cur]
    path.reverse()
    # Validate path starts at source
    if not path or path[0] != source:
        return None, 0.0
    return path, float(capacity[target])


@dual_mode
def find_widest_bottleneck_path(
    graph: Any,
    source: str | None = None,
    target: str | None = None,
    *,
    weight: str = "weight",
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Widest bottleneck path maximizing minimum edge capacity.

    Args:
        graph: NetworkX graph, GraphSpec, or interchange dict.
        source: start node id.
        target: end node id.
        weight: edge attribute for capacity (defaults to "weight").

    Returns ``{"path": [nodes], "bottleneck_capacity": float,
    "found": bool, "hops": int, "source": str, "target": str}``.
    """
    # CLI payload envelope
    if isinstance(graph, dict) and source is None and target is None:
        if "source" in graph and "target" in graph:
            payload = graph
            _inner = payload.get("graph") if isinstance(payload.get("graph"), dict) else None
            has_inner = isinstance(_inner, dict) and ("nodes" in _inner or "edges" in _inner or "links" in _inner)
            if "source" in payload or "target" in payload:
                new_source = payload.get("source", source)
                new_target = payload.get("target", target)
                weight = payload.get("weight", weight)
                # avoid treating weight=None as missing explicitly
                # need to check if key present
                if "weight" not in payload:
                    weight = weight  # keep current
                node_attributes = payload.get("node_attributes", node_attributes)
                edge_attributes = payload.get("edge_attributes", edge_attributes)
                time_key = payload.get("time_key", time_key)
                time_mode = payload.get("time_mode", time_mode)
                time_at = payload.get("time_at", time_at)
                time_start = payload.get("time_start", time_start)
                time_end = payload.get("time_end", time_end)
                include_untimed = payload.get("include_untimed", include_untimed)
                if has_inner:
                    graph = _inner
                elif "nodes" in payload or "edges" in payload:
                    graph = {k: v for k, v in payload.items() if k not in ("source", "target", "weight", "node_attributes", "edge_attributes", "time_key", "time_mode", "time_at", "time_start", "time_end", "include_untimed")}
                source = new_source
                target = new_target

    if source is None or target is None:
        raise ValueError("source and target are required")

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
        return {"path": [], "bottleneck_capacity": 0.0, "found": False, "hops": 0, "source": src, "target": tgt, "reason": "source or target not in graph"}

    if src == tgt:
        return {"path": [src], "bottleneck_capacity": float("inf"), "found": True, "hops": 0, "source": src, "target": tgt}

    # If weight attribute missing on all edges, treat uniform capacity 1.0 so any path is max
    has_weight = any(weight in d for _, _, d in g.edges(data=True)) if weight else False
    if not has_weight:
        # No capacity data: uniform 1.0, widest path is any shortest path; use BFS
        try:
            path = nx.shortest_path(g, src, tgt)
            path = [str(n) for n in path]
            return {"path": path, "bottleneck_capacity": 1.0, "found": True, "hops": len(path) - 1, "source": src, "target": tgt}
        except (nx.NetworkXNoPath, nx.NodeNotFound):
            return {"path": [], "bottleneck_capacity": 0.0, "found": False, "hops": 0, "source": src, "target": tgt}

    path, cap = _widest_path_dijkstra(g, src, tgt, weight)
    if path is None:
        return {"path": [], "bottleneck_capacity": 0.0, "found": False, "hops": 0, "source": src, "target": tgt}
    return {"path": path, "bottleneck_capacity": float(cap), "found": True, "hops": len(path) - 1, "source": src, "target": tgt}


main = export_dual_mode(find_widest_bottleneck_path)


if __name__ == "__main__":
    raise SystemExit(main())
