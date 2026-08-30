"""K-core decomposition and onion layers.

Pure Python using networkx. Integrates with filter_engine and temporal.
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


def _ensure_undirected_copy(g: nx.Graph) -> nx.Graph:
    """Return an undirected copy suitable for core algorithms."""
    ug = g.to_undirected() if g.is_directed() else g
    if hasattr(ug, '_NODE_OK'):
        ug = nx.Graph(ug)
    else:
        # Copy to avoid mutating original
        ug = nx.Graph(ug)
    return ug


@dual_mode
def compute_kcore(
    graph: Any,
    *,
    k: int | None = None,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """K-core decomposition.

    If ``k`` is provided, returns the k-core subgraph info.
    Otherwise returns core numbers for all nodes and degeneracy.

    Returns ``{"core_numbers": {node: int}, "degeneracy": int,
    "kcore_nodes": [...], "kcore_size": int}`` (kcore_* present when k given).
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
    ug = _ensure_undirected_copy(g)

    if ug.number_of_nodes() == 0:
        result: dict[str, Any] = {"core_numbers": {}, "degeneracy": 0}
        if k is not None:
            result.update({"kcore_nodes": [], "kcore_size": 0, "k": k})
        return result

    core_numbers = nx.core_number(ug)
    # Convert keys to strings for JSON determinism
    core_str = {str(node): int(val) for node, val in core_numbers.items()}
    degeneracy = max(core_numbers.values()) if core_numbers else 0

    result = {"core_numbers": dict(sorted(core_str.items())), "degeneracy": int(degeneracy)}

    if k is not None:
        if not isinstance(k, int) or k < 0:
            raise ValueError(f"k must be a non-negative integer, got {k!r}")
        try:
            kcore_graph = nx.k_core(ug, k=k)
            kcore_nodes = sorted(str(n) for n in kcore_graph.nodes())
        except Exception:
            # Fallback: filter by core number
            kcore_nodes = sorted(n for n, c in core_str.items() if c >= k)
        result.update({"kcore_nodes": kcore_nodes, "kcore_size": len(kcore_nodes), "k": k})

    return result


@dual_mode
def compute_onion_layers(
    graph: Any,
    *,
    node_attributes: dict[str, Any] | None = None,
    edge_attributes: dict[str, Any] | None = None,
    time_key: str | None = None,
    time_mode: str | None = None,
    time_at: Any = None,
    time_start: Any = None,
    time_end: Any = None,
    include_untimed: bool = True,
) -> dict[str, Any]:
    """Onion decomposition (k-core layers).

    Returns ``{"onion_layers": {node: layer}, "layers": {layer: [nodes]},
    "max_layer": int, "core_numbers": {node: int}}``.
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
    ug = _ensure_undirected_copy(g)

    if ug.number_of_nodes() == 0:
        return {"onion_layers": {}, "layers": {}, "max_layer": 0, "core_numbers": {}}

    try:
        onion = nx.onion_layers(ug)
        onion_str = {str(node): int(layer) for node, layer in onion.items()}
    except Exception:
        # Fallback: use core numbers as proxy layers
        core_numbers = nx.core_number(ug)
        onion_str = {str(n): int(c) for n, c in core_numbers.items()}

    # Also compute core numbers for reference
    try:
        core_numbers = nx.core_number(ug)
        core_str = {str(n): int(c) for n, c in core_numbers.items()}
    except Exception:
        core_str = dict(onion_str)

    # Group by layer
    layers: dict[int, list[str]] = {}
    for node, layer in onion_str.items():
        layers.setdefault(layer, []).append(node)
    # Sort nodes within each layer
    layers_sorted: dict[str, list[str]] = {
        str(layer): sorted(nodes) for layer, nodes in sorted(layers.items())
    }

    max_layer = max(onion_str.values()) if onion_str else 0

    return {
        "onion_layers": dict(sorted(onion_str.items())),
        "layers": layers_sorted,
        "max_layer": int(max_layer),
        "core_numbers": dict(sorted(core_str.items())),
    }


main_kcore = export_dual_mode(compute_kcore)
main_onion = export_dual_mode(compute_onion_layers)

main = export_dual_mode(compute_kcore)


if __name__ == "__main__":
    raise SystemExit(main())
