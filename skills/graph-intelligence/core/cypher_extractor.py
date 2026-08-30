"""Demarcated Cypher projection interface for EXTERNAL graph databases.

DEMARCATION CONTRACT
    This module is the only place the Cypher dialect may appear in the
    graph-intelligence skill. It exists to project data OUT of external
    Cypher-capable databases (Neo4j and friends) into plain NetworkX
    graphs for in-memory work.

    * Do NOT use this module on in-memory NetworkX graphs. Guards will
      refuse and raise :class:`CypherExtractorError`.
    * In-memory filtering belongs to ``core.filter_engine`` (zero-copy
      ``nx.subgraph_view`` predicates), never to Cypher.

Transport is dependency-free: the default HTTP transport uses only the
standard library (``urllib`` + base64) against a database's transactional
HTTP endpoint. No database driver is installed by this skill.
"""

from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from typing import Any, Callable, Mapping

import networkx as nx
from pydantic import BaseModel, Field

from core.contract import GraphIntelError


class CypherExtractorError(GraphIntelError):
    """Raised for misuse of the Cypher boundary or transport failures."""


def assert_external_backend(candidate: object) -> None:
    """Refuse in-memory NetworkX graphs at the Cypher boundary."""
    if isinstance(candidate, nx.Graph):
        raise CypherExtractorError(
            "cypher_extractor is demarcated for external databases only; "
            "in-memory NetworkX graphs must use core.filter_engine or "
            "core.temporal (zero-copy subgraph views)"
        )


class CypherQuery(BaseModel):
    """A parameterized Cypher statement ready for a transaction endpoint."""

    statement: str
    parameters: dict[str, object] = Field(default_factory=dict)
    database: str = "neo4j"

    def to_tx_body(self) -> dict:
        """HTTP transactional payload for this single statement."""
        return {
            "statements": [
                {
                    "statement": self.statement,
                    "parameters": dict(self.parameters),
                }
            ]
        }


def build_match_query(
    label: str,
    *,
    relationship: str | None = None,
    properties: Mapping[str, object] | None = None,
    limit: int | None = None,
) -> CypherQuery:
    """Build a parameterized node-or-relationship match query.

    Property filters become ``$param`` placeholders, never interpolated
    literals, keeping queries injection-safe.
    """
    if not label or not label.replace("_", "").replace("-", "").isalnum():
        raise CypherExtractorError(f"unsafe label {label!r}")
    props = dict(properties or {})
    params: dict[str, object] = {}
    clauses: list[str] = []
    for key, value in props.items():
        # sanitize key
        if not key.replace("_", "").isalnum():
            raise CypherExtractorError(f"unsafe property key {key!r}")
        placeholder = f"p_{key}"
        params[placeholder] = value
        clauses.append(f"{key}: ${placeholder}")

    where = ""
    if clauses:
        where = " {" + ", ".join(clauses) + "}"

    if relationship is None:
        statement = f"MATCH (n:`{label}`{where}) RETURN n"
    else:
        if not relationship.replace("_", "").isalnum():
            raise CypherExtractorError(f"unsafe relationship {relationship!r}")
        # directed pattern n -[r:REL]-> m
        target_where = ""
        statement = (
            f"MATCH (n:`{label}`{where})-[r:`{relationship}`]->(m) "
            f"RETURN n, r, m"
        )

    if limit is not None:
        if limit <= 0:
            raise CypherExtractorError("limit must be positive")
        statement += f" LIMIT {int(limit)}"

    return CypherQuery(statement=statement, parameters=params)


class CypherHttpExtractor:
    """Minimal HTTP extractor for a Neo4j transactional endpoint.

    Uses only stdlib ``urllib`` so the skill remains pure-Python.  Provide
    a custom ``transport`` callable to inject a stub in tests:
    ``transport(url, body_bytes, headers) -> (status_code, parsed_json)``.
    """

    def __init__(
        self,
        uri: str,
        username: str,
        password: str,
        *,
        database: str = "neo4j",
        timeout: float = 30.0,
        transport: Callable[[str, bytes, dict[str, str]], tuple[int, dict]] | None = None,
    ) -> None:
        if not uri:
            raise CypherExtractorError("uri is required")
        self.uri = uri.rstrip("/")
        self.username = username
        self.password = password
        self.database = database
        self.timeout = timeout
        self._transport = transport or self._default_transport

    def _default_transport(
        self, url: str, body: bytes, headers: dict[str, str]
    ) -> tuple[int, dict]:
        request = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
                parsed = json.loads(raw.decode("utf-8"))
                return response.status, parsed
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                parsed = json.loads(raw.decode("utf-8"))
            except Exception:
                parsed = {"errors": [{"message": raw.decode("utf-8", errors='replace')}]}
            return exc.code, parsed
        except OSError as exc:
            raise CypherExtractorError(f"transport error: {exc}") from exc

    def run(
        self,
        query: str | CypherQuery,
        parameters: Mapping[str, object] | None = None,
    ) -> list[dict[str, Any]]:
        """Execute a Cypher query and return rows as ``{column: value}`` dicts.

        Raises :class:`CypherExtractorError` on bad input, HTTP errors,
        or server-reported Cypher errors.
        """
        if isinstance(query, nx.Graph):
            assert_external_backend(query)
        if isinstance(query, CypherQuery):
            cypher = query
            if parameters is not None:
                raise CypherExtractorError(
                    "parameters must be supplied on the CypherQuery itself"
                )
        elif isinstance(query, str):
            cypher = CypherQuery(statement=query, parameters=dict(parameters or {}))
        else:
            raise CypherExtractorError(f"query must be str or CypherQuery, got {type(query).__name__}")

        if not cypher.statement.strip():
            raise CypherExtractorError("Cypher statement may not be empty")

        url = f"{self.uri}/db/{self.database}/tx/commit"
        body = json.dumps(cypher.to_tx_body()).encode("utf-8")
        token = base64.b64encode(f"{self.username}:{self.password}".encode()).decode()
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Basic {token}",
        }

        status, parsed = self._transport(url, body, headers)

        errors = parsed.get("errors") or []
        if errors:
            raise CypherExtractorError(f"cypher error: {errors[0].get('message', errors[0])}")

        if status < 200 or status >= 300:
            raise CypherExtractorError(f"HTTP {status}: {parsed}")

        results = parsed.get("results") or []
        if not results:
            return []
        columns: list[str] = results[0].get("columns", [])
        data = results[0].get("data", [])
        rows: list[dict[str, Any]] = []
        for entry in data:
            values = entry.get("row", [])
            rows.append({col: val for col, val in zip(columns, values)})
        return rows


def graph_from_records(
    rows: list[Mapping[str, Any]],
    *,
    directed: bool = True,
) -> nx.Graph:
    """Build a NetworkX graph from Neo4j HTTP row payloads.

    Each row is the ``{column: value}`` mapping returned by
    :meth:`CypherHttpExtractor.run`. Values may be Neo4j node/relationship
    JSON objects ``{"identity": ..., "labels"/"type": ..., "properties": ...}``
    or plain dicts/strings that already look like node ids.

    Nodes with the same ``identity`` (or ``elementId``/``id``) are merged.
    Relationships become directed edges ``start -> end`` with their properties.
    """
    graph: nx.Graph = nx.DiGraph() if directed else nx.Graph()

    def _add_node_payload(payload: Any) -> str | None:
        if payload is None:
            return None
        if isinstance(payload, str):
            if payload not in graph:
                graph.add_node(payload)
            return payload
        if isinstance(payload, Mapping):
            # Neo4j node shape: identity/elementId + labels + properties
            if "properties" in payload or "labels" in payload or "identity" in payload:
                nid = str(
                    payload.get("elementId")
                    or payload.get("identity")
                    or payload.get("id")
                    or payload.get("properties", {}).get("id")
                    or payload
                )
                props = dict(payload.get("properties", {}))
                # preserve labels for diagnostics
                if "labels" in payload:
                    props["_labels"] = list(payload["labels"])
                if nid not in graph:
                    graph.add_node(nid, **props)
                else:
                    # merge labels
                    for k, v in props.items():
                        if k not in graph.nodes[nid]:
                            graph.nodes[nid][k] = v
                return nid
            # Relationship shape: start/end/type/properties
            if "type" in payload and ("start" in payload or "end" in payload):
                # handle as edge below via caller
                return None
            # plain id dict
            if "id" in payload:
                nid = str(payload["id"])
                props = {k: v for k, v in payload.items() if k != "id"}
                if nid not in graph:
                    graph.add_node(nid, **props)
                return nid
            # fallback: treat entire dict as id? skip
            return None
        return None

    def _add_rel_payload(payload: Any) -> None:
        if not isinstance(payload, Mapping):
            return
        if "type" not in payload:
            return
        start = payload.get("start") or payload.get("startNode") or payload.get("source")
        end = payload.get("end") or payload.get("endNode") or payload.get("target")
        if start is None or end is None:
            return
        src = str(start)
        dst = str(end)
        props = dict(payload.get("properties", {}))
        props["_type"] = payload.get("type")
        # ensure endpoints exist
        if src not in graph:
            graph.add_node(src)
        if dst not in graph:
            graph.add_node(dst)
        graph.add_edge(src, dst, **props)

    for row in rows:
        if not isinstance(row, Mapping):
            continue
        for value in row.values():
            if isinstance(value, Mapping) and "type" in value and ("start" in value or "end" in value):
                _add_rel_payload(value)
            else:
                nid = _add_node_payload(value)
                # If value was actually a relationship mistaken for node, handle
                if nid is None and isinstance(value, Mapping) and "type" in value:
                    _add_rel_payload(value)
            # Also scan nested dicts for relationship objects inside row values that are lists
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, Mapping) and "type" in item:
                        _add_rel_payload(item)
                    elif isinstance(item, Mapping):
                        _add_node_payload(item)

        # Second pass: relationships may be separate columns; handle explicitly
        for value in row.values():
            if isinstance(value, Mapping) and "type" in value:
                _add_rel_payload(value)

    return graph
