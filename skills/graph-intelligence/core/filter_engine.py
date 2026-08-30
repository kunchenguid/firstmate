"""In-memory graph filtering via zero-copy ``nx.subgraph_view`` views.

This module is the ONLY sanctioned path for filtering in-memory NetworkX
graphs. It never copies nodes or edges: every filter returns an
``nx.subgraph_view`` whose node/edge data remains shared with the parent
graph, so attribute reads are free and writes propagate.

(External databases are the exclusive territory of
``core.cypher_extractor``; see the demarcation note there.)
"""

from __future__ import annotations

from typing import Any, Callable, Mapping

import networkx as nx

from core.contract import GraphIntelError


class FilterEngineError(GraphIntelError):
    """Raised for invalid filter specifications."""


NodePredicate = Callable[[Any, Mapping[str, Any]], bool]
EdgePredicate = Callable[..., bool]


def compose_predicates(*predicates: NodePredicate) -> NodePredicate:
    """AND-compose node predicates into one predicate."""
    real = [p for p in predicates if p is not None]
    if not real:
        return lambda node_id, data: True
    if len(real) == 1:
        return real[0]
    return lambda node_id, data: all(p(node_id, data) for p in real)


def _attribute_predicate(
    attributes: Mapping[str, Any] | None,
) -> NodePredicate | None:
    if not attributes:
        return None
    expected = dict(attributes)

    def predicate(node_id: Any, data: Mapping[str, Any]) -> bool:
        for key, wanted in expected.items():
            actual = data.get(key)
            if isinstance(wanted, (list, tuple, set)) and not isinstance(
                wanted, (str, bytes)
            ):
                if actual not in wanted:
                    return False
            elif actual != wanted:
                return False
        return True

    return predicate


def filter_nodes(
    graph: nx.Graph,
    predicate: NodePredicate | None = None,
    attributes: Mapping[str, Any] | None = None,
) -> nx.Graph:
    """Zero-copy view over nodes passing a predicate and/or attribute match.

    ``predicate`` is called as ``predicate(node_id, data)``. ``attributes``
    maps attribute keys to an exact value or a collection of acceptable
    values. Both may be combined (AND).
    """
    if graph is None:
        raise FilterEngineError("graph is required")
    conditions = [p for p in (predicate, _attribute_predicate(attributes)) if p]

    def filter_node(node_id: Any) -> bool:
        data = graph.nodes[node_id]
        return all(p(node_id, data) for p in conditions)

    return nx.subgraph_view(graph, filter_node=filter_node)


def filter_edges(
    graph: nx.Graph,
    predicate: Callable[[Any, Any, Mapping[str, Any]], bool] | None = None,
    attributes: Mapping[str, Any] | None = None,
) -> nx.Graph:
    """Zero-copy view over edges matching a predicate and/or attributes.

    ``predicate`` is called as ``predicate(u, v, data)`` (multigraphs add a
    fourth key argument). ``attributes`` follows the same semantics as
    ``filter_nodes``.
    """
    checks = []
    pred = _edge_attribute_predicate(graph, attributes)
    if pred is not None:
        checks.append(pred)
    if predicate is not None:
        checks.append(predicate)
    if not checks:
        return nx.subgraph_view(graph)

    if graph.is_multigraph():

        def filter_edge(u: Any, v: Any, k: Any) -> bool:
            data = graph[u][v][k]
            return all(c(u, v, data) for c in checks)

    else:

        def filter_edge(u: Any, v: Any) -> bool:  # type: ignore[misc]
            data = graph[u][v]
            return all(c(u, v, data) for c in checks)

    return nx.subgraph_view(graph, filter_edge=filter_edge)


def filter_graph(
    graph: nx.Graph,
    node_predicate: NodePredicate | None = None,
    edge_predicate: Callable[[Any, Any, Mapping[str, Any]], bool] | None = None,
    node_attributes: Mapping[str, Any] | None = None,
    edge_attributes: Mapping[str, Any] | None = None,
) -> nx.Graph:
    """Filter nodes and edges in one pass, returning a zero-copy view.

    Nodes failing the node filter are excluded; among the surviving nodes,
    only edges passing the edge filter are visible.
    """
    view = filter_nodes(graph, node_predicate, node_attributes)
    checks = []
    edge_pred = _edge_attribute_predicate(graph, edge_attributes)
    if edge_pred is not None:
        checks.append(edge_pred)
    if edge_predicate is not None:
        checks.append(edge_predicate)
    if not checks:
        return view

    if graph.is_multigraph():

        def filter_edge(u: Any, v: Any, k: Any) -> bool:
            data = graph[u][v][k]
            return all(c(u, v, data) for c in checks)

    else:

        def filter_edge(u: Any, v: Any) -> bool:  # type: ignore[misc]
            data = graph[u][v]
            return all(c(u, v, data) for c in checks)

    return nx.subgraph_view(view, filter_edge=filter_edge)


def _edge_attribute_predicate(graph: nx.Graph, attributes: Mapping[str, Any] | None):
    """Wrap an attribute-match mapping as an (u, v, data) edge predicate."""
    if not attributes:
        return None
    expected = dict(attributes)

    def predicate(u: Any, v: Any, data: Mapping[str, Any]) -> bool:
        return all(
            (data.get(key) in wanted)
            if isinstance(wanted, (list, tuple, set))
            and not isinstance(wanted, (str, bytes))
            else (data.get(key) == wanted)
            for key, wanted in expected.items()
        )

    return predicate