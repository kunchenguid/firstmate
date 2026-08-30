"""Centrality measures: betweenness, Katz, harmonic with fallback.

All functions are pure Python using networkx. Supports filter_engine
and temporal slicing. Falls back gracefully for disconnected graphs.
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


def _prepare_copy(g: nx.Graph) -> nx.Graph:
    if hasattr(g, '_NODE_OK'):
        return nx.Graph(g) if not g.is_directed() else nx.DiGraph(g)
    return g


def _normalize_scores(scores: dict[Any, float]) -> dict[str, float]:
    return {str(k): float(v) for k, v in sorted(scores.items(), key=lambda x: str(x[0]))}


@dual_mode
def compute_betweenness(
    graph: Any,
    *,
    normalized: bool = True,
    weight: str | None = None,
    k: int | None = None,
    seed: int | None = 0,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Betweenness centrality (Brandes algorithm).

    Args:
        normalized: normalize scores to [0, 1].
        weight: edge weight attribute (None = unweighted).
        k: sample k nodes for approximation (None = exact).
        seed: random seed for sampling.

    Returns ``{"scores": {node: float}, "top": [[node, score], ...],
    "normalized": bool}``.
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
    g = _prepare_copy(g)

    if g.number_of_nodes() == 0:
        return {"scores": {}, "top": [], "normalized": normalized}

    # Resolve weight
    if weight is not None:
        has_weight = any(weight in d for _, _, d in g.edges(data=True))
        if not has_weight:
            weight = None

    try:
        if k is not None and k < g.number_of_nodes():
            scores = nx.betweenness_centrality(g, k=k, normalized=normalized, weight=weight, seed=seed)
        else:
            scores = nx.betweenness_centrality(g, normalized=normalized, weight=weight)
    except Exception as exc:
        raise ValueError(f"betweenness failed: {exc}") from exc

    normalized_scores = _normalize_scores(scores)
    top = sorted(normalized_scores.items(), key=lambda x: (-x[1], x[0]))[:10]
    return {"scores": normalized_scores, "top": [[n, s] for n, s in top], "normalized": normalized}


@dual_mode
def compute_katz(
    graph: Any,
    *,
    alpha: float | None = None,
    beta: float = 1.0,
    max_iter: int = 1000,
    tol: float = 1e-06,
    normalized: bool = True,
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
    """Katz centrality with automatic alpha selection.

    If ``alpha`` is None, it is set to ``1 / (max_eigenvalue + 1)`` or
    ``0.1 / max_degree`` as a safe default.

    Returns ``{"scores": {node: float}, "top": [[node, score], ...],
    "alpha": float, "converged": bool}``.
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
    g = _prepare_copy(g)

    if g.number_of_nodes() == 0:
        return {"scores": {}, "top": [], "alpha": 0.0, "converged": True}

    if weight is not None:
        has_weight = any(weight in d for _, _, d in g.edges(data=True))
        if not has_weight:
            weight = None

    # Auto-select alpha if not provided
    if alpha is None:
        max_deg = max(dict(g.degree()).values()) if g.number_of_nodes() > 0 else 1
        alpha = 1.0 / (max_deg + 1) * 0.9
        if alpha <= 0:
            alpha = 0.1

    converged = True
    try:
        scores = nx.katz_centrality(
            g, alpha=alpha, beta=beta, max_iter=max_iter, tol=tol, normalized=normalized, weight=weight
        )
    except nx.PowerIterationFailedConvergence:
        converged = False
        # Fallback: try with smaller alpha
        try:
            smaller_alpha = alpha * 0.5
            scores = nx.katz_centrality(
                g, alpha=smaller_alpha, beta=beta, max_iter=max_iter, tol=tol, normalized=normalized, weight=weight
            )
            alpha = smaller_alpha
            converged = True
        except Exception:
            # Final fallback: use numpy variant or degree centrality
            try:
                scores = nx.katz_centrality_numpy(g, alpha=alpha * 0.1, beta=beta, normalized=normalized, weight=weight)
                alpha = alpha * 0.1
                converged = True
            except Exception:
                scores = nx.degree_centrality(g)
                converged = False
    except Exception as exc:
        raise ValueError(f"katz centrality failed: {exc}") from exc

    normalized_scores = _normalize_scores(scores)
    top = sorted(normalized_scores.items(), key=lambda x: (-x[1], x[0]))[:10]
    return {"scores": normalized_scores, "top": [[n, s] for n, s in top], "alpha": float(alpha), "converged": converged}


@dual_mode
def compute_harmonic_fallback(
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
    """Harmonic centrality with closeness fallback for edge cases.

    Harmonic centrality naturally handles disconnected graphs (unreachable
    pairs contribute 0). For single-node or empty graphs, returns uniform
    scores.

    Returns ``{"scores": {node: float}, "top": [[node, score], ...],
    "method": str}`` where method is "harmonic" or "closeness_fallback".
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
    g = _prepare_copy(g)

    if g.number_of_nodes() == 0:
        return {"scores": {}, "top": [], "method": "harmonic"}

    if g.number_of_nodes() == 1:
        node = str(list(g.nodes())[0])
        return {"scores": {node: 0.0}, "top": [[node, 0.0]], "method": "harmonic"}

    if weight is not None:
        has_weight = any(weight in d for _, _, d in g.edges(data=True))
        if not has_weight:
            weight = None

    method = "harmonic"
    try:
        scores = nx.harmonic_centrality(g, distance=weight)
    except Exception:
        # Fallback to closeness
        try:
            scores = nx.closeness_centrality(g, distance=weight)
            method = "closeness_fallback"
        except Exception as exc:
            raise ValueError(f"harmonic centrality failed: {exc}") from exc

    normalized_scores = _normalize_scores(scores)
    top = sorted(normalized_scores.items(), key=lambda x: (-x[1], x[0]))[:10]
    return {"scores": normalized_scores, "top": [[n, s] for n, s in top], "method": method}


main_betweenness = export_dual_mode(compute_betweenness)
main_katz = export_dual_mode(compute_katz)
main_harmonic = export_dual_mode(compute_harmonic_fallback)

main = export_dual_mode(compute_betweenness)


if __name__ == "__main__":
    raise SystemExit(main())
