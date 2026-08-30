"""Steiner tree: Mehlhorn 2-approximation connecting >=3 terminals.

Implements Mehlhorn's heuristic: build complete distance graph over
terminals (shortest-path metric closure), compute MST, expand each MST
edge back to its original shortest path, and prune leaves to a minimal
Steiner tree. Integrates with ``core.filter_engine`` and
``core.temporal`` and exposes dual-mode CLI via ``core.contract``.
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


def _all_pairs_via_dijkstra(g: nx.Graph, sources: list[str], weight: str | None):
    """Compute shortest paths from each source: {src: {tgt: (dist, path)}}."""
    result: dict[str, dict[str, tuple[float, list[str]]]] = {}
    for src in sources:
        result[src] = {}
        try:
            lengths, paths = nx.single_source_dijkstra(g, src, weight=weight)
        except Exception:
            lengths, paths = {}, {}
        for tgt in sources:
            if tgt == src:
                result[src][tgt] = (0.0, [src])
            elif tgt in lengths:
                result[src][tgt] = (float(lengths[tgt]), [str(n) for n in paths[tgt]])
    return result


@dual_mode
def compute_steiner_tree(
    graph: Any,
    terminals: list[str] | None = None,
    *,
    weight: str | None = "weight",
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Mehlhorn 2-approximation Steiner tree connecting >=3 terminals.

    Args:
        graph: NetworkX graph, GraphSpec, or interchange dict.
        terminals: list of terminal node ids (must have >=3, or all nodes if None).
        weight: edge weight attribute (None = hop count).

    Returns ``{"nodes": [str], "edges": [[u,v], ...], "total_weight": float,
    "terminal_count": int, "steiner_nodes": [str], "approximation_ratio": str}``.
    """
    # CLI payload envelope
    if isinstance(graph, dict) and terminals is None:
        if "terminals" in graph or "graph" in graph:
            payload = graph
            _inner = payload.get("graph") if isinstance(payload.get("graph"), dict) else None
            has_inner = isinstance(_inner, dict) and ("nodes" in _inner or "edges" in _inner or "links" in _inner)
            if "terminals" in payload and (has_inner or "nodes" in payload or "edges" in payload):
                terminals = payload.get("terminals", terminals)
                weight = payload.get("weight", weight)
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
                    graph = {k: v for k, v in payload.items() if k not in ("terminals", "weight", "node_attributes", "edge_attributes", "time_key", "time_mode", "time_at", "time_start", "time_end", "include_untimed")}

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

    # Resolve terminals
    if terminals is None:
        terminals = sorted(str(n) for n in g.nodes())
    else:
        terminals = [str(t) for t in terminals]

    if len(terminals) < 3:
        raise ValueError(f"Steiner tree requires >=3 terminals, got {len(terminals)}")

    for t in terminals:
        if t not in g:
            raise ValueError(f"terminal {t!r} not in graph")

    if g.number_of_nodes() == 0:
        return {"nodes": [], "edges": [], "total_weight": 0.0, "terminal_count": len(terminals), "steiner_nodes": [], "approximation_ratio": "2-approx (Mehlhorn)", "connected": False}

    # For treewidth etc we need undirected view; Steiner tree is on undirected
    ug = g.to_undirected() if g.is_directed() else g
    if hasattr(ug, "_NODE_OK"):
        ug = nx.Graph(ug)

    w = _resolve_weight(ug, weight)

    # Step 1: metric closure via Dijkstra from each terminal
    dist_and_path = _all_pairs_via_dijkstra(ug, terminals, w)

    # Check connectivity among terminals
    for i, a in enumerate(terminals):
        for b in terminals[i + 1 :]:
            if b not in dist_and_path.get(a, {}) or dist_and_path[a].get(b) is None:
                # Try reverse
                if a not in dist_and_path.get(b, {}):
                    return {
                        "nodes": [],
                        "edges": [],
                        "total_weight": float("inf"),
                        "terminal_count": len(terminals),
                        "steiner_nodes": [],
                        "approximation_ratio": "2-approx (Mehlhorn)",
                        "connected": False,
                        "reason": f"terminals {a!r} and {b!r} disconnected",
                    }

    # Step 2: complete graph over terminals with metric distances
    complete = nx.Graph()
    for t in terminals:
        complete.add_node(t)
    for i, a in enumerate(terminals):
        for b in terminals[i + 1 :]:
            d = dist_and_path[a][b][0] if b in dist_and_path[a] else dist_and_path[b][a][0]
            complete.add_edge(a, b, weight=float(d))

    # Step 3: MST of complete graph
    mst = nx.minimum_spanning_tree(complete, weight="weight")

    # Step 4: expand each MST edge back to original shortest path, union edges
    steiner_edges: set[tuple[str, str]] = set()
    steiner_nodes: set[str] = set(terminals)
    total_weight = 0.0

    for u, v in mst.edges():
        # Retrieve shortest path between u and v
        if v in dist_and_path.get(u, {}):
            path = dist_and_path[u][v][1]
        elif u in dist_and_path.get(v, {}):
            path = dist_and_path[v][u][1]
        else:
            # Fallback: compute on demand
            try:
                path = nx.shortest_path(ug, u, v, weight=w)
                path = [str(n) for n in path]
            except nx.NetworkXNoPath:
                continue
        for a, b in zip(path, path[1:]):
            # canonical undirected edge
            e = (a, b) if a <= b else (b, a)
            steiner_edges.add(e)
            steiner_nodes.add(a)
            steiner_nodes.add(b)

    # Compute total_weight as sum of original edge weights in steiner tree
    for a, b in steiner_edges:
        data = ug.get_edge_data(a, b)
        if data is None:
            total_weight += 1.0
        else:
            if w is not None and w in data:
                total_weight += float(data[w])
            else:
                total_weight += 1.0

    # Step 5: prune non-terminal leaves iteratively (minimal subnetwork)
    # Build graph of steiner edges and peel leaves that are not terminals
    terminal_set = set(terminals)
    while True:
        sg = nx.Graph()
        sg.add_nodes_from(steiner_nodes)
        sg.add_edges_from(steiner_edges)
        leaves = [n for n, d in sg.degree() if d == 1 and n not in terminal_set]
        if not leaves:
            break
        for leaf in leaves:
            # remove its single edge
            nbr = next(iter(sg.neighbors(leaf)))
            e = (leaf, nbr) if leaf <= nbr else (nbr, leaf)
            steiner_edges.discard(e)
            steiner_nodes.discard(leaf)
            # adjust weight
            data = ug.get_edge_data(leaf, nbr)
            if data is not None:
                if w is not None and w in data:
                    total_weight -= float(data[w])
                else:
                    total_weight -= 1.0

    # Also remove isolated non-terminals that may have become disconnected after pruning
    sg = nx.Graph()
    sg.add_nodes_from(steiner_nodes)
    sg.add_edges_from(steiner_edges)
    # Keep only nodes reachable from first terminal (should be all connected anyway)
    if sg.number_of_nodes() > 0 and terminals[0] in sg:
        reachable = set(nx.node_connected_component(sg, terminals[0])) if nx.is_connected(sg) or sg.number_of_nodes() > 0 else set()
        # If not all connected, BFS from first terminal
        try:
            reachable = set(nx.node_connected_component(sg, terminals[0]))
        except Exception:
            reachable = set(sg.nodes())
        steiner_nodes = reachable
        steiner_edges = {(a, b) for a, b in steiner_edges if a in reachable and b in reachable}

    sorted_nodes = sorted(steiner_nodes)
    sorted_edges = sorted([sorted(list(e)) for e in steiner_edges])

    return {
        "nodes": sorted_nodes,
        "edges": sorted_edges,
        "total_weight": float(total_weight),
        "terminal_count": len(terminals),
        "steiner_nodes": sorted(n for n in steiner_nodes if n not in terminal_set),
        "approximation_ratio": "2-approx (Mehlhorn)",
        "connected": True,
    }


main = export_dual_mode(compute_steiner_tree)


if __name__ == "__main__":
    raise SystemExit(main())
