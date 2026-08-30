"""Link prediction (Adamic-Adar, Resource Allocation) and Heider balance.

Pure Python using networkx. Integrates with filter_engine and temporal.
"""

from __future__ import annotations

import math
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


def _prepare_undirected_copy(g: nx.Graph) -> nx.Graph:
    if hasattr(g, '_NODE_OK'):
        g = nx.Graph(g) if not g.is_directed() else nx.DiGraph(g)
    ug = g.to_undirected() if g.is_directed() else g
    if hasattr(ug, '_NODE_OK'):
        ug = nx.Graph(ug)
    else:
        ug = nx.Graph(ug)
    return ug


def _candidate_pairs(
    graph: nx.Graph,
    ebunch: list[tuple[str, str]] | None = None,
) -> list[tuple[str, str]]:
    """Determine candidate non-edges for scoring."""
    if ebunch is not None:
        return [(str(u), str(v)) for u, v in ebunch]
    # All non-edges (capped for performance on large graphs)
    nodes = sorted(str(n) for n in graph.nodes())
    if len(nodes) > 200:
        # For large graphs, use 2-hop candidates only
        candidates: set[tuple[str, str]] = set()
        for node in graph.nodes():
            nbrs = set(graph.neighbors(node))
            for nbr in nbrs:
                for twohop in graph.neighbors(nbr):
                    if twohop != node and not graph.has_edge(node, twohop) and not graph.has_edge(twohop, node):
                        a, b = sorted([str(node), str(twohop)])
                        candidates.add((a, b))
        return sorted(candidates)
    # Small graph: all non-edges
    return sorted(
        (a, b) for i, a in enumerate(nodes) for b in nodes[i + 1 :] if not graph.has_edge(a, b) and not graph.has_edge(b, a)
    )


@dual_mode
def predict_links_aa_ra(
    graph: Any,
    *,
    ebunch: list[list[str]] | None = None,
    top_k: int | None = 10,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Adamic-Adar and Resource Allocation link prediction.

    Scores all non-edges (or the provided ``ebunch``) using both
    Adamic-Adar and Resource Allocation indices.

    Args:
        ebunch: explicit candidate pairs to score. If None, all non-edges.
        top_k: return only top-K per metric (None = all).

    Returns ``{"adamic_adar": [[u, v, score], ...],
    "resource_allocation": [[u, v, score], ...], "candidate_count": int}``.
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
    ug = _prepare_undirected_copy(g)

    if ug.number_of_nodes() == 0:
        return {"adamic_adar": [], "resource_allocation": [], "candidate_count": 0}

    # Normalize ebunch
    ebunch_tuples: list[tuple[str, str]] | None = None
    if ebunch is not None:
        ebunch_tuples = [(str(a), str(b)) for a, b in ebunch]

    candidates = _candidate_pairs(ug, ebunch_tuples)

    if not candidates:
        return {"adamic_adar": [], "resource_allocation": [], "candidate_count": 0}

    # Compute scores using networkx generators
    aa_scores: dict[tuple[str, str], float] = {}
    ra_scores: dict[tuple[str, str], float] = {}

    # Adamic-Adar
    try:
        for u, v, score in nx.adamic_adar_index(ug, ebunch=candidates):
            key = (str(u), str(v))
            aa_scores[key] = float(score)
    except Exception:
        # Manual fallback
        for u, v in candidates:
            common = set(ug.neighbors(u)) & set(ug.neighbors(v))
            score = 0.0
            for w in common:
                deg = ug.degree(w)
                if deg > 1:
                    score += 1.0 / math.log(deg)
            aa_scores[(u, v)] = score

    # Resource Allocation
    try:
        for u, v, score in nx.resource_allocation_index(ug, ebunch=candidates):
            key = (str(u), str(v))
            ra_scores[key] = float(score)
    except Exception:
        for u, v in candidates:
            common = set(ug.neighbors(u)) & set(ug.neighbors(v))
            score = 0.0
            for w in common:
                deg = ug.degree(w)
                if deg > 0:
                    score += 1.0 / deg
            ra_scores[(u, v)] = score

    # Ensure all candidates have entries
    for c in candidates:
        aa_scores.setdefault(c, 0.0)
        ra_scores.setdefault(c, 0.0)

    # Sort by score desc, then lexicographically
    aa_sorted = sorted(aa_scores.items(), key=lambda x: (-x[1], x[0]))
    ra_sorted = sorted(ra_scores.items(), key=lambda x: (-x[1], x[0]))

    if top_k is not None:
        aa_sorted = aa_sorted[:top_k]
        ra_sorted = ra_sorted[:top_k]

    return {
        "adamic_adar": [[u, v, s] for (u, v), s in aa_sorted],
        "resource_allocation": [[u, v, s] for (u, v), s in ra_sorted],
        "candidate_count": len(candidates),
    }


@dual_mode
def evaluate_heider_balance(
    graph: Any,
    *,
    sign_key: str = "sign",
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Evaluate Heider (structural) balance for signed graphs.

    Each edge should carry a sign attribute (``sign_key``): positive
    values (>0 or "positive"/"+") are treated as friendly, negative
    as hostile.

    Balance is measured over all triangles: a triangle is balanced
    when the product of its three signs is positive (even number of
    negative edges).

    Returns ``{"balanced_triangles": int, "unbalanced_triangles": int,
    "total_triangles": int, "balance_ratio": float, "triangles": [...]}``.
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
    ug = _prepare_undirected_copy(g)

    if ug.number_of_nodes() < 3:
        return {
            "balanced_triangles": 0,
            "unbalanced_triangles": 0,
            "total_triangles": 0,
            "balance_ratio": 1.0,
            "triangles": [],
        }

    def _edge_sign(u: str, v: str) -> int:
        """Extract sign: +1 or -1."""
        if not ug.has_edge(u, v):
            return 1  # shouldn't happen for triangle edges
        data = ug[u][v]
        raw = data.get(sign_key, data.get("weight", 1))
        if isinstance(raw, str):
            low = raw.lower().strip()
            if low in ("negative", "-", "neg", "hostile", "enemy", "-1"):
                return -1
            if low in ("positive", "+", "pos", "friendly", "ally", "+1", "1"):
                return 1
            try:
                raw = float(raw)
            except ValueError:
                return 1
        try:
            val = float(raw)
            return 1 if val >= 0 else -1
        except (TypeError, ValueError):
            return 1

    # Find all triangles
    triangles: list[dict[str, Any]] = []
    balanced = 0
    unbalanced = 0

    nodes = sorted(str(n) for n in ug.nodes())
    # Use networkx triangles enumeration via adjacency
    # For each node, check pairs of neighbors
    seen: set[tuple[str, str, str]] = set()
    for u in nodes:
        nbrs = sorted(str(n) for n in ug.neighbors(u))
        for i, v in enumerate(nbrs):
            for w in nbrs[i + 1 :]:
                if ug.has_edge(v, w):
                    tri = tuple(sorted([u, v, w]))
                    if tri in seen:
                        continue
                    seen.add(tri)
                    s_uv = _edge_sign(tri[0], tri[1])
                    s_uw = _edge_sign(tri[0], tri[2])
                    s_vw = _edge_sign(tri[1], tri[2])
                    product = s_uv * s_uw * s_vw
                    is_balanced = product > 0
                    if is_balanced:
                        balanced += 1
                    else:
                        unbalanced += 1
                    triangles.append(
                        {
                            "nodes": list(tri),
                            "signs": [s_uv, s_uw, s_vw],
                            "balanced": is_balanced,
                        }
                    )

    total = balanced + unbalanced
    ratio = (balanced / total) if total > 0 else 1.0

    # Deterministic sort
    triangles.sort(key=lambda t: t["nodes"])

    return {
        "balanced_triangles": balanced,
        "unbalanced_triangles": unbalanced,
        "total_triangles": total,
        "balance_ratio": round(ratio, 6),
        "triangles": triangles,
    }


main_aa_ra = export_dual_mode(predict_links_aa_ra)
main_heider = export_dual_mode(evaluate_heider_balance)

main = export_dual_mode(predict_links_aa_ra)


if __name__ == "__main__":
    raise SystemExit(main())
