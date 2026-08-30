"""graph-intelligence core — Phase 0 plumbing."""

from core.contract import (
    EdgeSpec,
    GraphIntelError,
    GraphSpec,
    NodeSpec,
    Result,
    TelemetryRecord,
    clear_telemetry,
    dual_mode,
    emit_json,
    export_dual_mode,
    get_telemetry,
    telemetry,
)
from core.cypher_extractor import (
    CypherExtractorError,
    CypherHttpExtractor,
    CypherQuery,
    assert_external_backend,
    build_match_query,
    graph_from_records,
)
from core.filter_engine import (
    FilterEngineError,
    compose_predicates,
    filter_edges,
    filter_graph,
    filter_nodes,
)
from core.graph_loader import (
    GraphLoaderError,
    SUPPORTED_FORMATS,
    load,
    load_adjacency,
    load_edge_list,
    load_graphml,
    load_json,
)
from core.temporal import (
    TemporalError,
    as_of,
    slice_at,
    temporal_bound,
    window,
)

__all__ = [
    # contract
    "GraphIntelError",
    "NodeSpec",
    "EdgeSpec",
    "GraphSpec",
    "TelemetryRecord",
    "Result",
    "telemetry",
    "clear_telemetry",
    "get_telemetry",
    "dual_mode",
    "export_dual_mode",
    "emit_json",
    # loader
    "GraphLoaderError",
    "SUPPORTED_FORMATS",
    "load",
    "load_json",
    "load_edge_list",
    "load_adjacency",
    "load_graphml",
    # filter
    "FilterEngineError",
    "compose_predicates",
    "filter_nodes",
    "filter_edges",
    "filter_graph",
    # temporal
    "TemporalError",
    "slice_at",
    "as_of",
    "window",
    "temporal_bound",
    # cypher
    "CypherExtractorError",
    "CypherQuery",
    "CypherHttpExtractor",
    "assert_external_backend",
    "build_match_query",
    "graph_from_records",
]

__version__ = "0.1.0"
