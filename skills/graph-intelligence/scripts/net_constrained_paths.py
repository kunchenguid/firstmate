"""Constrained shortest paths and bounded random walks.

Integrates with filter_engine (node/edge predicates) and temporal slicing.
Uses pure Python + networkx.
"""

from __future__ import annotations

import random
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


def _resolve_weight(graph: nx.Graph, weight: str | None) -> str | None:
    if weight is None:
        return None
    # If no edge has that attribute, treat as unweighted
    has_weight = any(weight in d for _, _, d in graph.edges(data=True))
    return weight if has_weight else None


@dual_mode
def find_constrained_path(
    graph: Any,
    source: str | None = None,
    target: str | None = None,
    *,
    weight: str | None = "weight",
    max_depth: int | None = None,
    max_cost: float | None = None,
    avoid_nodes: list[str] | None = None,
    avoid_edges: list[list[str]] | None = None,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Find a constrained shortest path between source and target.

    Handles ``graph`` as NetworkX graph or interchange dict.
    When ``graph`` is a dict payload containing ``source``/``target`` keys
    (CLI splat mode), they are extracted from the payload.

    Constraints:
      - ``max_depth``: maximum number of edges in the path
      - ``max_cost``: maximum total weight
      - ``avoid_nodes``/``avoid_edges``: nodes/edges to exclude
      - ``weight``: edge attribute for cost (None = unweighted BFS)

    Returns ``{"path": [nodes], "cost": float, "length": int, "found": bool}``.
    """
    # CLI splat: graph may be the whole payload dict
    if isinstance(graph, dict) and source is None and target is None:
        # Check if dict looks like a constrained-path request envelope
        if "source" in graph and "target" in graph and ("nodes" in graph or "edges" in graph or "graph" in graph):
            payload = graph
            inner = payload.get("graph", payload)
            # Extract source/target from payload level
            source = payload.get("source")
            target = payload.get("target")
            weight = payload.get("weight", weight)
            max_depth = payload.get("max_depth", max_depth)
            max_cost = payload.get("max_cost", max_cost)
            avoid_nodes = payload.get("avoid_nodes", avoid_nodes)
            avoid_edges = payload.get("avoid_edges", avoid_edges)
            node_attributes = payload.get("node_attributes", node_attributes)
            edge_attributes = payload.get("edge_attributes", edge_attributes)
            time_key = payload.get("time_key", time_key)
            graph = inner
        elif "source" in graph and "target" in graph and "graph" not in graph:
            # Could be just source/target without wrapper - check if graph has nodes/edges
            pass

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

    # Apply avoid filters by creating a copy without those elements
    if avoid_nodes:
        avoid_set = set(str(n) for n in avoid_nodes)
        if source in avoid_set or target in avoid_set:
            return {"path": [], "cost": float("inf"), "length": 0, "found": False, "reason": "source or target in avoid_nodes"}
        g = g.copy()
        g.remove_nodes_from(n for n in avoid_set if n in g)

    if avoid_edges:
        g = g.copy() if not isinstance(g, nx.Graph) or not avoid_nodes else g
        # Need to ensure we have a mutable copy
        if not hasattr(g, '_NODE_OK'):
            pass
        else:
            g = nx.Graph(g) if not g.is_directed() else nx.DiGraph(g)
        for edge in avoid_edges:
            if len(edge) >= 2:
                u, v = str(edge[0]), str(edge[1])
                if g.has_edge(u, v):
                    g.remove_edge(u, v)

    # Handle subgraph views - copy for algorithms that need it
    if hasattr(g, '_NODE_OK'):
        g = nx.Graph(g) if not g.is_directed() else nx.DiGraph(g)

    if source not in g or target not in g:
        return {"path": [], "cost": float("inf"), "length": 0, "found": False, "reason": "source or target not in graph"}

    if source == target:
        return {"path": [str(source)], "cost": 0.0, "length": 0, "found": True}

    w = _resolve_weight(g, weight)

    # Use appropriate algorithm
    try:
        if w is not None:
            path = nx.shortest_path(g, source=source, target=target, weight=w)
            cost = float(nx.shortest_path_length(g, source=source, target=target, weight=w))
        else:
            path = nx.shortest_path(g, source=source, target=target)
            cost = float(len(path) - 1)
    except nx.NetworkXNoPath:
        return {"path": [], "cost": float("inf"), "length": 0, "found": False, "reason": "no path"}
    except nx.NodeNotFound as exc:
        return {"path": [], "cost": float("inf"), "length": 0, "found": False, "reason": str(exc)}

    length = len(path) - 1

    # Apply max_depth constraint
    if max_depth is not None and length > max_depth:
        return {"path": [], "cost": float("inf"), "length": 0, "found": False, "reason": f"path length {length} exceeds max_depth {max_depth}"}

    if max_cost is not None and cost > max_cost:
        return {"path": [], "cost": float("inf"), "length": 0, "found": False, "reason": f"path cost {cost} exceeds max_cost {max_cost}"}

    return {"path": [str(n) for n in path], "cost": cost, "length": length, "found": True}


@dual_mode
def sample_bounded_random_walks(
    graph: Any,
    start: str | None = None,
    num_walks: int = 10,
    walk_length: int = 5,
    *,
    seed: int | None = 0,
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
    """Sample bounded random walks from a start node.

    Deterministic when ``seed`` is set (default 0). Each walk is a list of
    node ids with bounded length. Dead-ends terminate the walk early.

    Returns ``{"walks": [[nodes], ...], "start": str, "num_walks": int,
    "walk_length": int}``.
    """
    # Handle CLI payload envelope
    if isinstance(graph, dict) and start is None:
        if "start" in graph and ("nodes" in graph or "edges" in graph or "graph" in graph):
            payload = graph
            inner = payload.get("graph", payload)
            start = payload.get("start", start)
            num_walks = payload.get("num_walks", num_walks)
            walk_length = payload.get("walk_length", walk_length)
            seed = payload.get("seed", seed)
            weight = payload.get("weight", weight)
            node_attributes = payload.get("node_attributes", node_attributes)
            edge_attributes = payload.get("edge_attributes", edge_attributes)
            time_key = payload.get("time_key", time_key)
            graph = inner

    if start is None:
        raise ValueError("start is required")

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

    # Handle subgraph views
    if hasattr(g, '_NODE_OK'):
        g = nx.Graph(g) if not g.is_directed() else nx.DiGraph(g)

    if start not in g:
        raise ValueError(f"start node {start!r} not in graph")

    if num_walks <= 0 or walk_length <= 0:
        return {"walks": [], "start": str(start), "num_walks": num_walks, "walk_length": walk_length}

    rng = random.Random(seed)

    # Pre-sort neighbors for determinism
    walks: list[list[str]] = []
    for _ in range(num_walks):
        walk = [str(start)]
        current = start
        for _ in range(walk_length - 1):
            neighbors = sorted(g.neighbors(current), key=str)
            if not neighbors:
                break
            if weight is not None and any(weight in g[current][n] for n in neighbors):
                # Weighted sampling
                weights = [float(g[current][n].get(weight, 1.0)) for n in neighbors]
                total = sum(weights)
                if total <= 0:
                    nxt = rng.choice(neighbors)
                else:
                    r = rng.random() * total
                    cum = 0.0
                    nxt = neighbors[-1]
                    for n, w in zip(neighbors, weights):
                        cum += w
                        if r <= cum:
                            nxt = n
                            break
            else:
                nxt = rng.choice(neighbors)
            walk.append(str(nxt))
            current = nxt
        walks.append(walk)

    return {"walks": walks, "start": str(start), "num_walks": num_walks, "walk_length": walk_length}


main_constrained = export_dual_mode(find_constrained_path)
main_walks = export_dual_mode(sample_bounded_random_walks)

main = export_dual_mode(find_constrained_path)


if __name__ == "__main__":
    raise SystemExit(main())
