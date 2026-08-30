"""Graph loading for the graph-intelligence skill.

Loads several common interchange formats into pure NetworkX graphs using
only the Python standard library plus networkx itself (the GraphML reader
in networkx is stdlib-XML based and needs no compiled extensions).

Supported input formats
    json       {"directed": bool, "nodes": [{"id", ...attrs}],
                "edges"|"links": [{"source", "target", ...attrs}]}
               plus networkx node-link JSON (directed/multigraph/links keys).
    edge-list  text lines "u v" or "u v weight"; '#' comments; blank lines
               skipped; explicit delimiter or whitespace splitting.
    adjacency  mapping {"u": ["v", ...]} or
               {"u": {"v": {"weight": 2}}} for neighbor attributes.
    graphml    standard GraphML files.

All loaders accept a path (str or pathlib.Path), a file-like object, or a
native Python value (dict / iterable of lines), and coerce node ids to
strings so attribute lookups stay consistent across sources.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable, Mapping, Union

import networkx as nx

from core.contract import GraphIntelError


class GraphLoaderError(GraphIntelError):
    """Raised when a source cannot be parsed as a graph."""


SUPPORTED_FORMATS = ("json", "edge-list", "adjacency", "graphml")


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _read_text(source: Any) -> str:
    """Read a path or file-like object into text."""
    if isinstance(source, (str, Path)):
        return Path(source).read_text(encoding="utf-8")
    if hasattr(source, "read"):
        return source.read()
    raise GraphLoaderError(f"cannot read text from {type(source).__name__}")


def _coerce_id(value: Any) -> str:
    """Coerce a node id to string; reject non-scalar ids."""
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise GraphLoaderError(f"node id must be scalar, got {value!r}")
    return str(value)


def _first_key(raw: Mapping[str, Any], keys: Iterable[str]) -> str | None:
    for key in keys:
        if key in raw:
            return key
    return None


def _node_attrs(raw: Mapping[str, Any]) -> tuple[str, dict[str, Any]]:
    """Split a node record into (id, attributes).

    Attributes may arrive under an explicit "attributes" key or inline as
    every field other than the id. Explicit "attributes" wins when present.
    """
    id_key = _first_key(raw, ("id", "node", "name"))
    if id_key is None:
        raise GraphLoaderError(f"node record missing an id: {raw!r}")
    node_id = _coerce_id(raw[id_key])
    if isinstance(raw.get("attributes"), Mapping):
        return node_id, dict(raw["attributes"])
    return node_id, {k: v for k, v in raw.items() if k != id_key}


def _edge_endpoints(raw: Mapping[str, Any]) -> tuple[str, str]:
    source_key = _first_key(raw, ("source", "from", "u", "tail"))
    target_key = _first_key(raw, ("target", "to", "v", "head"))
    if source_key is None or target_key is None:
        raise GraphLoaderError(f"edge record missing source/target: {raw!r}")
    return _coerce_id(raw[source_key]), _coerce_id(raw[target_key])


def _edge_attrs(raw: Mapping[str, Any]) -> dict[str, Any]:
    id_like = {"source", "from", "u", "tail", "target", "to", "v", "head", "id"}
    if isinstance(raw.get("attributes"), Mapping):
        return dict(raw["attributes"])
    return {k: v for k, v in raw.items() if k not in id_like}


def _materialize(spec: Mapping[str, Any]) -> nx.Graph:
    """Build a graph from a generic nodes/edges spec dict."""
    directed = bool(spec.get("directed", False))
    graph: nx.Graph = nx.DiGraph() if directed else nx.Graph()
    for raw in spec.get("nodes", []):
        if not isinstance(raw, Mapping):
            raise GraphLoaderError(f"node record must be an object: {raw!r}")
        node_id, attrs = _node_attrs(raw)
        graph.add_node(node_id, **attrs)
    edge_key = "edges" if "edges" in spec else "links"
    for raw in spec.get(edge_key, []):
        if not isinstance(raw, Mapping):
            raise GraphLoaderError(f"edge record must be an object: {raw!r}")
        source, target = _edge_endpoints(raw)
        graph.add_edge(source, target, **_edge_attrs(raw))
    return graph


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------


def load_json(source: Union[str, Path, Mapping[str, Any], Any]) -> nx.Graph:
    """Load a graph from a JSON file or already-parsed mapping.

    Accepts both the skill's own ``{nodes, edges}`` interchange format and
    networkx node-link JSON (detected via the ``links``/``directed``/
    ``multigraph`` marker keys).
    """
    if isinstance(source, Mapping):
        data = dict(source)
    else:
        try:
            data = json.loads(_read_text(source))
        except json.JSONDecodeError as exc:
            raise GraphLoaderError(f"invalid JSON: {exc}") from exc
    if not isinstance(data, Mapping):
        raise GraphLoaderError("JSON graph must be an object")
    # networkx node-link JSON is identified by its "links" edge key plus the
    # "directed"/"multigraph" bookkeeping fields.
    if "links" in data and ("directed" in data or "multigraph" in data):
        return nx.node_link_graph(data, edges="links")
    return _materialize(data)


def load_edge_list(
    source: Union[str, Path, Iterable[str]],
    *,
    directed: bool = False,
    delimiter: str | None = None,
    weighted: bool = True,
) -> nx.Graph:
    """Load a graph from an edge-list text or iterable of line strings.

    Each non-empty, non-comment line is ``u v`` or ``u v weight``. Weight
    parsing only applies when ``weighted`` and the line has exactly three
    fields that parse as a float.
    """
    if isinstance(source, (str, Path)):
        lines = _read_text(source).splitlines()
    elif isinstance(source, str):
        lines = source.splitlines()
    else:
        lines = list(source)
    graph: nx.Graph = nx.DiGraph() if directed else nx.Graph()
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split(delimiter) if delimiter else stripped.split()
        if len(fields) not in (2, 3):
            raise GraphLoaderError(f"malformed edge line: {line!r}")
        source_id, target_id = _coerce_id(fields[0]), _coerce_id(fields[1])
        attrs: dict[str, Any] = {}
        if weighted and len(fields) == 3:
            try:
                attrs["weight"] = float(fields[2])
            except ValueError as exc:
                raise GraphLoaderError(
                    f"non-numeric weight in line: {line!r}"
                ) from exc
        graph.add_edge(source_id, target_id, **attrs)
    return graph


def load_adjacency(source: Union[str, Path, Mapping[str, Any]]) -> nx.Graph:
    """Load a graph from an adjacency mapping.

    Values may be neighbor id lists, neighbor id -> weight scalars, or
    neighbor id -> attribute mappings. Directedness defaults to False;
    pass the parsed mapping through ``_materialize`` for explicit control,
    or use ``load(..., fmt=...)`` with a directed json document instead.
    """
    if isinstance(source, Mapping):
        data = dict(source)
    else:
        try:
            data = json.loads(_read_text(source))
        except json.JSONDecodeError as exc:
            raise GraphLoaderError(f"invalid adjacency JSON: {exc}") from exc
    if not isinstance(data, Mapping):
        raise GraphLoaderError("adjacency input must be a mapping")
    graph: nx.Graph = nx.Graph()
    for raw_node, neighbors in data.items():
        node = _coerce_id(raw_node)
        graph.add_node(node)
        if isinstance(neighbors, Mapping):
            for raw_neighbor, payload in neighbors.items():
                neighbor = _coerce_id(raw_neighbor)
                if isinstance(payload, Mapping):
                    graph.add_edge(node, neighbor, **dict(payload))
                elif payload is None:
                    graph.add_edge(node, neighbor)
                else:
                    graph.add_edge(node, neighbor, weight=payload)
        elif isinstance(neighbors, (list, tuple, set)):
            for raw_neighbor in neighbors:
                graph.add_edge(node, _coerce_id(raw_neighbor))
        else:
            raise GraphLoaderError(
                f"adjacency value for {node!r} must be a list or mapping"
            )
    return graph


def load_graphml(source: Union[str, Path, Any]) -> nx.Graph:
    """Load a graph from an uncompressed GraphML file or file-like object."""
    if isinstance(source, (str, Path)):
        try:
            return nx.read_graphml(source)
        except (nx.NetworkXError, ValueError, OSError, KeyError) as exc:
            raise GraphLoaderError(f"invalid GraphML: {exc}") from exc
    try:
        return nx.parse_graphml(_read_text(source))
    except (nx.NetworkXError, ValueError, KeyError) as exc:
        raise GraphLoaderError(f"invalid GraphML: {exc}") from exc


def _sniff_format(source: Any) -> str:
    """Best-effort format detection for ``load``."""
    if isinstance(source, Mapping):
        return "json" if ("nodes" in source or "links" in source) else "adjacency"
    text = _read_text(source)
    head = text.lstrip()[:1]
    if head == "<":
        return "graphml"
    if head in "{[":
        import json as _json

        try:
            parsed = _json.loads(text)
        except json.JSONDecodeError:
            return "edge-list"
        if isinstance(parsed, Mapping) and ("nodes" in parsed or "links" in parsed):
            return "json"
        if isinstance(parsed, Mapping):
            return "adjacency"
        return "edge-list"
    return "edge-list"


def load(source: Any, fmt: str | None = "auto", **kwargs: Any) -> nx.Graph:
    """Load a graph, dispatching on an explicit or detected format.

    ``fmt`` is one of "auto", "json", "edge-list", "adjacency", "graphml".
    Keyword arguments are forwarded to the chosen loader.
    """
    fmt = _sniff_format(source) if (fmt is None or fmt == "auto") else fmt
    if fmt not in SUPPORTED_FORMATS:
        raise GraphLoaderError(
            f"unsupported format {fmt!r}; expected one of {SUPPORTED_FORMATS}"
        )
    loaders = {
        "json": load_json,
        "edge-list": load_edge_list,
        "adjacency": load_adjacency,
        "graphml": load_graphml,
    }
    return loaders[fmt](source, **kwargs)