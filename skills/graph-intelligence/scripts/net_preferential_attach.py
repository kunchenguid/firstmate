"""Preferential attachment: O(1) degree-prior baseline ranker.

Scores candidate pairs by deg(u)*deg(v) — the classic Barabasi-Albert
prior. O(1) per pair after O(n) degree precomputation. Integrates with
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
    # For undirected, enumerate unordered pairs; for directed, ordered pairs
    if g.is_directed():
        candidates: list[tuple[str, str]] = []
        for i, u in enumerate(nodes):
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


@dual_mode
def compute_preferential_attachment(
    graph: Any,
    *,
    ebunch: list[list[str]] | None = None,
    top_k: int | None = None,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """O(1) degree-prior baseline ranker (preferential attachment).

    Score(u,v) = deg(u) * deg(v). Precomputes degrees in O(n), scores
    each pair in O(1). Useful as a fast, interpretable baseline for
    link prediction comparison (cf. Katz, AA/RA).

    Args:
        graph: NetworkX graph, GraphSpec, or interchange dict.
        ebunch: explicit candidate pairs to score; when None, all non-edges.
        top_k: keep only top-k ranked pairs.

    Returns ``{"scores": [[u, v, score], ...], "candidate_count": int,
    "top_k": int|None, "method": "preferential_attachment"}``.
    Scores are sorted descending, ties lexicographically.
    """
    # CLI payload envelope
    if isinstance(graph, dict) and "graph" in graph and isinstance(graph["graph"], dict):
        payload = graph
        inner = payload.get("graph")
        if isinstance(inner, dict) and ("nodes" in inner or "edges" in inner or "links" in inner):
            ebunch = payload.get("ebunch", ebunch)
            top_k = payload.get("top_k", top_k)
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

    # Degree map - O(n)
    deg: dict[str, int] = {str(n): int(d) for n, d in g.degree()}

    if ebunch is not None:
        candidates = [(str(a), str(b)) for a, b in ebunch]
        # Filter to valid nodes and non-existing edges? Score even if edge exists (for testing)
        candidates = [(u, v) for u, v in candidates if u in deg and v in deg and u != v]
        # For undirected, deduplicate
        if not g.is_directed():
            seen: set[tuple[str, str]] = set()
            uniq: list[tuple[str, str]] = []
            for u, v in candidates:
                key = (u, v) if u <= v else (v, u)
                if key not in seen:
                    seen.add(key)
                    uniq.append((key[0], key[1]))
            candidates = uniq
    else:
        candidates = _all_nonedges(g)

    # O(1) per pair scoring
    scored: list[tuple[str, str, int]] = []
    for u, v in candidates:
        s = deg.get(u, 0) * deg.get(v, 0)
        scored.append((u, v, int(s)))

    # Sort descending by score, then lexicographically for determinism
    scored.sort(key=lambda x: (-x[2], x[0], x[1]))

    total = len(scored)
    if top_k is not None:
        top_k = int(top_k)
        scored = scored[:top_k]

    scores_out = [[u, v, int(s)] for u, v, s in scored]

    return {
        "scores": scores_out,
        "candidate_count": int(total),
        "returned_count": len(scores_out),
        "top_k": top_k,
        "method": "preferential_attachment",
        "n": int(g.number_of_nodes()),
        "m": int(g.number_of_edges()),
    }


main = export_dual_mode(compute_preferential_attachment)


if __name__ == "__main__":
    raise SystemExit(main())
