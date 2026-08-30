"""Katz link prediction: global index sum(beta^k * A^k).

Computes the global Katz index for link prediction:
Katz(u,v) = sum_{k>=1} beta^k * (A^k)_{u,v}
where A is the adjacency matrix. Uses iterative power method with
convergence guarantee beta < 1/spectral_radius. Falls back to Neumann
series or diagonal scaling for safety. Integrates with
``core.filter_engine`` and ``core.temporal`` and exposes dual-mode CLI
via ``core.contract``.
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


def _all_nonedges(g: nx.Graph) -> list[tuple[str, str]]:
    nodes = sorted(str(n) for n in g.nodes())
    if len(nodes) < 2:
        return []
    existing: set[tuple[str, str]] = set()
    for u, v in g.edges():
        su, sv = str(u), str(v)
        if g.is_directed():
            existing.add((su, sv))
        else:
            existing.add((su, sv) if su <= sv else (sv, su))
    if g.is_directed():
        candidates: list[tuple[str, str]] = []
        for u in nodes:
            for v in nodes:
                if u == v:
                    continue
                if (u, v) not in existing:
                    candidates.append((u, v))
        return candidates
    else:
        candidates = []
        for i, u in enumerate(nodes):
            for v in nodes[i + 1 :]:
                key = (u, v) if u <= v else (v, u)
                if key not in existing:
                    candidates.append((u, v))
        return candidates


def _katz_scores(
    g: nx.Graph,
    beta: float,
    max_iter: int = 200,
    tol: float = 1e-6,
) -> dict[tuple[str, str], float]:
    """Compute Katz scores via networkx + fallback to manual Neumann series.

    Tries nx.katz_centrality_numpy path internally but for link prediction
    we need pairwise scores, not centralities. So we compute
    (I - beta*A)^{-1} - I via series or linear solve.
    """
    nodes = sorted(str(n) for n in g.nodes())
    n = len(nodes)
    if n == 0:
        return {}
    idx = {node: i for i, node in enumerate(nodes)}

    # Try scipy linear solve when available
    try:
        import numpy as np
        import scipy  # noqa: F401

        # Build dense adjacency
        A = np.zeros((n, n), dtype=float)
        for u, v in g.edges():
            su, sv = str(u), str(v)
            if su in idx and sv in idx:
                A[idx[su], idx[sv]] = 1.0
                if not g.is_directed():
                    A[idx[sv], idx[su]] = 1.0

        # Use Katz formula: K = (I - beta*A)^{-1} - I  (Neumann series sum beta^k A^k)
        # Ensure convergence: beta < 1 / rho(A)
        # We adjust beta if needed
        I = np.eye(n)
        M = I - beta * A
        try:
            K = np.linalg.inv(M) - I
        except np.linalg.LinAlgError:
            # Try with smaller beta
            beta2 = beta * 0.5
            M2 = I - beta2 * A
            K = np.linalg.inv(M2) - I
            beta = beta2

        # Zero out negative tiny values from numerical noise
        K = np.maximum(K, 0.0)

        result: dict[tuple[str, str], float] = {}
        for i, u in enumerate(nodes):
            for j, v in enumerate(nodes):
                if u == v:
                    continue
                # For undirected, only store u < v
                if not g.is_directed() and u > v:
                    continue
                if g.has_edge(u, v):
                    continue
                result[(u, v)] = float(K[i, j])
        return result
    except ImportError:
        pass
    except Exception:
        pass

    # Pure Python fallback: iterative Neumann series sum_{k=1}^{max_iter} beta^k A^k
    # Use adjacency as dict of sets
    adj: dict[str, set[str]] = {node: set() for node in nodes}
    for u, v in g.edges():
        su, sv = str(u), str(v)
        if su in adj:
            adj[su].add(sv)
        if not g.is_directed() and sv in adj:
            adj[sv].add(su)

    # Initialize: A^1 counts
    # We maintain current power matrix as dict {(u,v): count}
    from collections import defaultdict

    # Start with A^1
    cur: dict[tuple[str, str], float] = {}
    for u in nodes:
        for w in adj[u]:
            cur[(u, w)] = cur.get((u, w), 0.0) + 1.0

    scores: dict[tuple[str, str], float] = defaultdict(float)
    b_pow = beta
    for k in range(1, max_iter + 1):
        # Add b_pow * cur to scores
        max_add = 0.0
        for pair, val in cur.items():
            add = b_pow * val
            # Only keep non-edge pairs in final scores, but cur includes all adjacency-derived
            # We accumulate for all pairs and filter at the end
            scores[pair] += add
            if add > max_add:
                max_add = add
        if max_add < tol:
            break
        # Compute next power: cur_next = cur * A
        nxt: dict[tuple[str, str], float] = defaultdict(float)
        for (u, mid), cnt in cur.items():
            for w in adj.get(mid, set()):
                nxt[(u, w)] += cnt
        cur = dict(nxt)
        b_pow *= beta
        if not cur:
            break

    # Filter to non-edges and undirected canonical
    result_pp: dict[tuple[str, str], float] = {}
    existing: set[tuple[str, str]] = set()
    for u, v in g.edges():
        su, sv = str(u), str(v)
        if g.is_directed():
            existing.add((su, sv))
        else:
            existing.add((su, sv) if su <= sv else (sv, su))
    for (u, v), s in scores.items():
        if u == v:
            continue
        if not g.is_directed():
            key = (u, v) if u <= v else (v, u)
            # Skip if this pair is an existing edge
            if key in existing:
                continue
            # Accumulate both directions into undirected key
            result_pp[key] = result_pp.get(key, 0.0) + s
            # For undirected, each direction counted; average to avoid double count from manual series
            # Actually cur for undirected is symmetric so each pair appears twice (u->v and v->u separate entries)
            # Our loop already sums both directed contributions for undirected case via separate cur entries
            # But result_pp aggregates both, so we will have sum of both directions — which is correct for Katz on undirected
            # To avoid double, we should track carefully: better to just let dict accumulate and not double-process later
        else:
            if (u, v) in existing:
                continue
            result_pp[(u, v)] = result_pp.get((u, v), 0.0) + s

    # For undirected, we summed both directions separately when cur contains both orientations
    # The above loop adds to same canonical key from both (u,v) and (v,u) entries, doubling the intended score.
    # Correct by halving for undirected
    if not g.is_directed():
        for key in list(result_pp.keys()):
            result_pp[key] = result_pp[key] / 2.0

    # Ensure all non-edges are represented (even if zero due to distance > max_iter)
    for pair in _all_nonedges(g):
        if pair not in result_pp:
            result_pp[pair] = 0.0

    return result_pp


@dual_mode
def compute_katz_link_index(
    graph: Any,
    *,
    beta: float | None = None,
    ebunch: list[list[str]] | None = None,
    top_k: int | None = None,
    max_iter: int = 100,
    tol: float = 1e-6,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Global Katz index sum(beta^k * A^k) for long-range link prediction.

    Args:
        graph: NetworkX graph, GraphSpec, or interchange dict.
        beta: attenuation factor; auto-selected as 0.05 or 1/(2*max_degree)
              when None to guarantee convergence.
        ebunch: explicit candidate pairs.
        top_k: keep only top-k ranked pairs.

    Returns ``{"scores": [[u,v,score], ...], "candidate_count": int,
    "beta": float, "method": "katz"}``.
    """
    # CLI payload envelope
    if isinstance(graph, dict) and "graph" in graph and isinstance(graph["graph"], dict):
        payload = graph
        inner = payload.get("graph")
        if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
            beta = payload.get("beta", beta)
            ebunch = payload.get("ebunch", ebunch)
            top_k = payload.get("top_k", top_k)
            max_iter = payload.get("max_iter", max_iter)
            tol = payload.get("tol", tol)
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

    n = g.number_of_nodes()
    if n == 0:
        return {"scores": [], "candidate_count": 0, "beta": float(beta or 0.0), "method": "katz"}

    # Auto-select beta to guarantee convergence: beta < 1/spectral_radius
    if beta is None:
        max_deg = max((d for _, d in g.degree()), default=1)
        # spectral radius <= max degree, use conservative
        beta = 1.0 / (max_deg + 1) * 0.5
        if beta <= 0 or beta >= 1:
            beta = 0.05
        # Clamp to small value for stability
        beta = min(beta, 0.1)
    else:
        beta = float(beta)

    if beta <= 0 or beta >= 1:
        raise ValueError(f"beta must be in (0, 1), got {beta!r}")

    # Adjust beta if spectral radius suggests divergence
    try:
        import numpy as np

        nodes = sorted(str(nn) for nn in g.nodes())
        idx = {node: i for i, node in enumerate(nodes)}
        A = np.zeros((len(nodes), len(nodes)), dtype=float)
        for u, v in g.edges():
            su, sv = str(u), str(v)
            if su in idx and sv in idx:
                A[idx[su], idx[sv]] = 1.0
                if not g.is_directed():
                    A[idx[sv], idx[su]] = 1.0
        # Estimate spectral radius via max row sum (Gershgorin bound)
        row_sum = float(np.max(np.sum(np.abs(A), axis=1))) if len(nodes) > 0 else 1.0
        if beta * row_sum >= 1.0:
            beta = 0.9 / max(row_sum, 1.0)
    except Exception:
        pass

    scores_map = _katz_scores(g, beta, max_iter=max_iter, tol=tol)

    # Determine candidates
    if ebunch is not None:
        wanted: set[tuple[str, str]] = set()
        for a, b in ebunch:
            sa, sb = str(a), str(b)
            if not g.is_directed():
                key = (sa, sb) if sa <= sb else (sb, sa)
            else:
                key = (sa, sb)
            if sa != sb and sa in g and sb in g:
                wanted.add(key)
        # Filter scores_map to wanted
        filtered = {k: v for k, v in scores_map.items() if k in wanted}
        # Ensure missing wanted pairs have score 0
        for k in wanted:
            if k not in filtered:
                filtered[k] = 0.0
        scores_map = filtered
    else:
        # Already filtered to non-edges inside _katz_scores when no ebunch
        pass

    # Sort descending by score, then lexicographically
    ranked = sorted(scores_map.items(), key=lambda x: (-x[1], x[0][0], x[0][1]))
    total = len(ranked)
    if top_k is not None:
        ranked = ranked[: int(top_k)]

    scores_out = [[u, v, float(s)] for (u, v), s in ranked]

    return {
        "scores": scores_out,
        "candidate_count": int(total),
        "returned_count": len(scores_out),
        "beta": float(beta),
        "top_k": top_k,
        "method": "katz",
        "n": int(n),
        "m": int(g.number_of_edges()),
    }


main = export_dual_mode(compute_katz_link_index)


if __name__ == "__main__":
    raise SystemExit(main())
