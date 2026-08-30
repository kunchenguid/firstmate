"""Treewidth estimation via min-degree and min-fill-in heuristics.

Produces an upper bound on treewidth via elimination-ordering heuristics.
Both ``min-degree`` (pick smallest degree) and ``min-fill`` (pick fewest
fill edges) are implemented purely in Python without C extensions.
Integrates with ``core.filter_engine`` and ``core.temporal`` and exposes
dual-mode CLI via ``core.contract``.
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


def _run_heuristic(
    ug: nx.Graph, heuristic: str
) -> dict[str, Any]:
    nodes = sorted(str(n) for n in ug.nodes())
    if not nodes:
        return {"treewidth_upper": 0, "elimination_order": [], "bags": [], "max_bag_size": 0, "heuristic": heuristic}
    # Build adjacency as undirected sets
    adj: dict[str, set[str]] = {n: set() for n in nodes}
    for u, v in ug.edges():
        su, sv = str(u), str(v)
        if su in adj and sv in adj:
            adj[su].add(sv)
            adj[sv].add(su)

    # Run elimination
    cur: dict[str, set[str]] = {n: set(nbrs) for n, nbrs in adj.items()}
    remaining = set(cur.keys())
    order: list[str] = []
    bags: list[list[str]] = []
    max_bag = 0

    while remaining:
        if heuristic == "min-degree":
            chosen = min(sorted(remaining), key=lambda v: (len(cur[v] & remaining), v))
        elif heuristic == "min-fill":
            def fill_count(v: str) -> int:
                nbrs = sorted(cur[v] & remaining)
                cnt = 0
                for i in range(len(nbrs)):
                    for j in range(i + 1, len(nbrs)):
                        if nbrs[j] not in cur.get(nbrs[i], set()):
                            cnt += 1
                return cnt

            chosen = min(sorted(remaining), key=lambda v: (fill_count(v), v))
        else:
            raise ValueError(f"unknown heuristic {heuristic!r}")

        nbrs = cur[chosen] & remaining
        bag = sorted({chosen} | nbrs)
        bags.append(bag)
        if len(bag) > max_bag:
            max_bag = len(bag)
        nbr_list = sorted(nbrs)
        for i in range(len(nbr_list)):
            for j in range(i + 1, len(nbr_list)):
                a, b = nbr_list[i], nbr_list[j]
                cur[a].add(b)
                cur[b].add(a)
        for nb in list(cur[chosen]):
            cur[nb].discard(chosen)
        order.append(chosen)
        remaining.remove(chosen)

    width = max(0, max_bag - 1)
    return {
        "treewidth_upper": int(width),
        "elimination_order": order,
        "bags": bags,
        "max_bag_size": int(max_bag),
        "heuristic": heuristic,
    }


@dual_mode
def estimate_treewidth(
    graph: Any,
    *,
    heuristic: str = "min-degree",
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Treewidth upper bound via elimination-ordering heuristics.

    Args:
        graph: NetworkX graph, GraphSpec, or interchange dict.
        heuristic: "min-degree" or "min-fill" (also "min-fill-in" alias).

    Returns ``{"treewidth_upper": int, "elimination_order": [nodes],
    "bags": [[nodes], ...], "max_bag_size": int, "heuristic": str,
    "both_heuristics": {name: upper}}`` (both heuristics always computed).
    """
    # Normalize heuristic alias
    if heuristic in ("min-fill-in", "min_fill", "minfill"):
        heuristic = "min-fill"

    # CLI payload envelope
    if isinstance(graph, dict) and "graph" in graph and isinstance(graph["graph"], dict):
        payload = graph
        inner = payload.get("graph")
        if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
            heuristic = payload.get("heuristic", heuristic)
            if heuristic in ("min-fill-in", "min_fill", "minfill"):
                heuristic = "min-fill"
            node_attributes = payload.get("node_attributes", node_attributes)
            edge_attributes = payload.get("edge_attributes", edge_attributes)
            time_key = payload.get("time_key", time_key)
            time_mode = payload.get("time_mode", time_mode)
            time_at = payload.get("time_at", time_at)
            time_start = payload.get("time_start", time_start)
            time_end = payload.get("time_end", time_end)
            include_untimed = payload.get("include_untimed", include_untimed)
            graph = inner
    # Also direct heuristic in payload without graph key
    if isinstance(graph, dict) and "heuristic" in graph and "graph" not in graph:
        # may be flat payload with nodes/edges + heuristic
        if "nodes" in graph or "edges" in graph:
            heuristic = graph.get("heuristic", heuristic)
            if heuristic in ("min-fill-in", "min_fill", "minfill"):
                heuristic = "min-fill"

    if heuristic not in ("min-degree", "min-fill"):
        raise ValueError(f"heuristic must be 'min-degree' or 'min-fill', got {heuristic!r}")

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

    ug = g.to_undirected() if g.is_directed() else g
    if hasattr(ug, "_NODE_OK"):
        ug = nx.Graph(ug)
    else:
        ug = nx.Graph(ug)

    # Run both heuristics; primary is the requested one, but expose both
    res_primary = _run_heuristic(ug, heuristic)
    other = "min-fill" if heuristic == "min-degree" else "min-degree"
    res_other = _run_heuristic(ug, other)

    # treewidth upper is min of both (tighter bound)
    best_upper = min(res_primary["treewidth_upper"], res_other["treewidth_upper"])

    return {
        "treewidth_upper": int(res_primary["treewidth_upper"]),
        "best_upper": int(best_upper),
        "elimination_order": res_primary["elimination_order"],
        "bags": res_primary["bags"],
        "max_bag_size": int(res_primary["max_bag_size"]),
        "heuristic": heuristic,
        "both_heuristics": {
            "min-degree": int(res_other["treewidth_upper"] if other == "min-degree" else res_primary["treewidth_upper"]),
            "min-fill": int(res_other["treewidth_upper"] if other == "min-fill" else res_primary["treewidth_upper"]),
        },
        "n": int(ug.number_of_nodes()),
        "m": int(ug.number_of_edges()),
    }


main = export_dual_mode(estimate_treewidth)


if __name__ == "__main__":
    raise SystemExit(main())
