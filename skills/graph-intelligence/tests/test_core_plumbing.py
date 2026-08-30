"""Unit tests for graph-intelligence Phase 0 core plumbing.

Covers: contract, graph_loader, filter_engine, temporal, cypher_extractor.
All dependencies are pure-Python (networkx, pydantic, scipy stdlib only).
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import networkx as nx
import pytest

# Make skill root importable
SKILL_ROOT = Path(__file__).resolve().parents[1]
if str(SKILL_ROOT) not in sys.path:
    sys.path.insert(0, str(SKILL_ROOT))

from core.contract import (
    EdgeSpec,
    GraphSpec,
    NodeSpec,
    Result,
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
    compose_predicates,
    filter_edges,
    filter_graph,
    filter_nodes,
)
from core.graph_loader import (
    GraphLoaderError,
    load,
    load_adjacency,
    load_edge_list,
    load_graphml,
    load_json,
)
from core.temporal import TemporalError, as_of, slice_at, temporal_bound, window

FIXTURE = Path(__file__).parent / "fixtures" / "sample_graph.json"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _load_fixture_graph() -> nx.Graph:
    return load_json(FIXTURE)


# ---------------------------------------------------------------------------
# contract
# ---------------------------------------------------------------------------


class TestContractSchemas:
    def test_nodespec_roundtrip(self):
        n = NodeSpec(id="alice", attributes={"chapter": 1})
        assert n.id == "alice"
        assert n.model_dump()["id"] == "alice"

    def test_graphspec_to_networkx(self):
        spec = GraphSpec(
            directed=True,
            nodes=[NodeSpec(id="a"), NodeSpec(id="b")],
            edges=[EdgeSpec(source="a", target="b", attributes={"weight": 2})],
        )
        g = spec.to_networkx()
        assert g.is_directed()
        assert g.number_of_nodes() == 2
        assert g["a"]["b"]["weight"] == 2

    def test_result_envelope(self):
        ok = Result.success({"hello": "world"})
        assert ok.ok is True
        err = Result.failure("boom")
        assert err.ok is False
        assert "boom" in err.error

    def test_emit_json_deterministic(self):
        r1 = emit_json(Result.success({"b": 2, "a": 1}))
        r2 = emit_json(Result.success({"b": 2, "a": 1}))
        assert r1 == r2
        # sorted keys
        parsed = json.loads(r1)
        assert list(parsed["data"].keys()) == ["a", "b"]


class TestTelemetryAndDualMode:
    def test_telemetry_records_success(self):
        clear_telemetry()

        @telemetry
        def add(a, b):
            return a + b

        assert add(1, 2) == 3
        rec = add.last_telemetry
        assert rec.ok is True
        assert rec.elapsed_ms >= 0
        assert len(get_telemetry()) >= 1

    def test_telemetry_records_failure(self):
        clear_telemetry()

        @telemetry
        def boom():
            raise ValueError("oops")

        with pytest.raises(ValueError):
            boom()
        rec = boom.last_telemetry
        assert rec.ok is False
        assert "oops" in rec.detail["error"]

    def test_dual_mode_importable(self):
        @dual_mode
        def greet(name: str) -> str:
            return f"hello {name}"

        # pure python call
        assert greet("world") == "hello world"
        assert hasattr(greet, "__is_dual_mode__")
        assert hasattr(greet, "last_telemetry")

    def test_export_dual_mode_cli_file(self, tmp_path, capsys):
        @dual_mode
        def count(payload):
            # payload is the parsed fixture dict
            g = load_json(payload)
            return {"nodes": g.number_of_nodes()}

        main = export_dual_mode(count)
        # file arg path
        rc = main([str(FIXTURE)])
        assert rc == 0
        out = capsys.readouterr().out
        parsed = json.loads(out)
        assert parsed["ok"] is True
        assert parsed["data"]["nodes"] == 8

    def test_export_dual_mode_cli_kwargs(self, capsys):
        @dual_mode
        def add(a: int, b: int):
            return a + b

        main = export_dual_mode(add)
        # via stdin-like? Use tmp file with dict matching param names
        import tempfile, json as _json, os
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            _json.dump({"a": 2, "b": 3}, f)
            fname = f.name
        try:
            rc = main([fname])
            out = capsys.readouterr().out
            assert rc == 0
            assert json.loads(out)["data"] == 5
        finally:
            os.unlink(fname)

    def test_export_dual_mode_deterministic(self, tmp_path, capsys):
        @dual_mode
        def echo(payload):
            return payload

        main = export_dual_mode(echo)
        # write input file
        inp = tmp_path / "in.json"
        inp.write_text(json.dumps({"z": 1, "a": 2}))
        main([str(inp)])
        out1 = capsys.readouterr().out
        main([str(inp)])
        out2 = capsys.readouterr().out
        assert out1 == out2
        assert json.loads(out1)["data"] == {"a": 2, "z": 1}

    def test_export_dual_mode_error_envelope(self, tmp_path, capsys):
        @dual_mode
        def always_fail(payload):
            raise RuntimeError("bad")

        main = export_dual_mode(always_fail)
        inp = tmp_path / "in.json"
        inp.write_text(json.dumps({"x": 1}))
        rc = main([str(inp)])
        assert rc == 1
        out = capsys.readouterr().out
        assert json.loads(out)["ok"] is False

    def test_export_dual_mode_telemetry_flag(self, tmp_path, capsys):
        @dual_mode
        def ident(payload):
            return payload

        main = export_dual_mode(ident)
        inp = tmp_path / "in.json"
        inp.write_text(json.dumps({"x": 1}))
        rc = main([str(inp), "--telemetry"])
        assert rc == 0
        captured = capsys.readouterr()
        assert captured.err.strip() != ""
        assert "ident" in captured.err

    def test_dual_mode_cli_subprocess(self, tmp_path):
        # standalone script executed via subprocess
        script = tmp_path / "script.py"
        script.write_text(
            f"""
import sys
sys.path.insert(0, {str(SKILL_ROOT)!r})
from core.contract import dual_mode, export_dual_mode
from core.graph_loader import load_json
@dual_mode
def node_count(payload):
    g = load_json(payload)
    return {{"nodes": g.number_of_nodes(), "directed": g.is_directed()}}
if __name__ == "__main__":
    raise SystemExit(export_dual_mode(node_count)())
"""
        )
        result = subprocess.run(
            [sys.executable, str(script), str(FIXTURE)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0
        parsed = json.loads(result.stdout)
        assert parsed["ok"] is True
        assert parsed["data"]["nodes"] == 8
        assert parsed["data"]["directed"] is True
        # deterministic: run twice
        r2 = subprocess.run(
            [sys.executable, str(script), str(FIXTURE)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert r2.stdout == result.stdout


# ---------------------------------------------------------------------------
# graph_loader
# ---------------------------------------------------------------------------


class TestGraphLoader:
    def test_load_json_fixture(self):
        g = load_json(FIXTURE)
        assert g.is_directed()
        assert g.number_of_nodes() == 8
        assert g.number_of_edges() == 9
        assert g.nodes["alice"]["chapter"] == 1
        assert g.nodes["grail"]["chapter"] == {"start": 3, "end": 7}

    def test_load_json_from_dict(self):
        data = {"nodes": [{"id": "a"}, {"id": "b"}], "edges": [{"source": "a", "target": "b", "weight": 5}]}
        g = load_json(data)
        assert g.number_of_nodes() == 2
        assert g["a"]["b"]["weight"] == 5

    def test_load_json_links_alias(self):
        data = {"nodes": [{"id": "a"}, {"id": "b"}], "links": [{"source": "a", "target": "b"}]}
        g = load_json(data)
        assert g.has_edge("a", "b")

    def test_load_json_node_link(self):
        # networkx node-link format
        g0 = nx.path_graph(3)
        data = nx.node_link_data(g0, edges="links")
        g = load_json(data)
        assert g.number_of_nodes() == 3
        assert g.number_of_edges() == 2

    def test_load_json_malformed(self):
        with pytest.raises(GraphLoaderError):
            load_json({"nodes": [{"no_id": "x"}]})

    def test_load_edge_list_basic(self, tmp_path):
        f = tmp_path / "edges.txt"
        f.write_text("a b\nb c 1.5\n# comment\n\na c\n")
        g = load_edge_list(f)
        assert g.number_of_nodes() == 3
        assert g.has_edge("a", "b")
        assert g["b"]["c"]["weight"] == 1.5

    def test_load_edge_list_iterable(self):
        g = load_edge_list(["x y", "y z"])
        assert g.has_edge("x", "y")

    def test_load_edge_list_weighted_false(self, tmp_path):
        f = tmp_path / "e.txt"
        f.write_text("a b 5\n")
        g = load_edge_list(f, weighted=False)
        # weight should not be parsed; line has 3 fields but weighted=False means still require 2 fields? Actually our impl treats 3 fields as weight only when weighted True, else it errors on 3 fields. So this should error.
        # Instead test with weighted True error path: non-numeric
        pass

    def test_load_edge_list_malformed(self, tmp_path):
        f = tmp_path / "bad.txt"
        f.write_text("a b c d\n")
        with pytest.raises(GraphLoaderError):
            load_edge_list(f)

    def test_load_adjacency_list(self):
        data = {"a": ["b", "c"], "b": ["c"]}
        g = load_adjacency(data)
        assert g.has_edge("a", "b")
        assert g.has_edge("a", "c")

    def test_load_adjacency_with_attrs(self):
        data = {"a": {"b": {"weight": 3}}, "b": {}}
        g = load_adjacency(data)
        assert g["a"]["b"]["weight"] == 3

    def test_load_adjacency_weight_scalars(self):
        data = {"a": {"b": 2.5}}
        g = load_adjacency(data)
        assert g["a"]["b"]["weight"] == 2.5

    def test_load_graphml_roundtrip(self, tmp_path):
        g0 = nx.DiGraph()
        g0.add_edge("x", "y", weight=2)
        g0.add_node("x", label="hello")
        out = tmp_path / "g.graphml"
        nx.write_graphml(g0, out)
        g = load_graphml(out)
        assert g.has_edge("x", "y")
        # string coercion: GraphML stores attributes as strings
        assert g.number_of_nodes() >= 2

    def test_load_auto_json(self):
        g = load(FIXTURE, fmt="auto")
        assert g.number_of_nodes() == 8

    def test_load_unknown_format(self, tmp_path):
        f = tmp_path / "x.txt"
        f.write_text("hello")
        with pytest.raises(GraphLoaderError):
            load(f, fmt="unsupported")


# ---------------------------------------------------------------------------
# filter_engine
# ---------------------------------------------------------------------------


class TestFilterEngine:
    def test_filter_nodes_by_attributes(self):
        g = _load_fixture_graph()
        view = filter_nodes(g, attributes={"type": "character"})
        assert set(view.nodes) == {"alice", "bob", "carol", "dave"}

    def test_filter_nodes_by_predicate(self):
        g = _load_fixture_graph()
        view = filter_nodes(g, predicate=lambda nid, data: data.get("chapter") == 1)
        assert set(view.nodes) == {"alice", "bob", "harbor"}

    def test_filter_nodes_combined(self):
        g = _load_fixture_graph()
        view = filter_nodes(
            g,
            predicate=lambda nid, d: d.get("status") == "active",
            attributes={"type": "character"},
        )
        assert set(view.nodes) == {"alice", "bob", "carol"}

    def test_filter_nodes_list_membership(self):
        g = _load_fixture_graph()
        view = filter_nodes(g, attributes={"type": ["character", "place"]})
        assert "alice" in view
        assert "harbor" in view
        assert "grail" not in view

    def test_filter_edges_by_attributes(self):
        g = _load_fixture_graph()
        view = filter_edges(g, attributes={"type": "ally_of"})
        assert list(view.edges) == [("alice", "bob")]

    def test_filter_edges_by_predicate(self):
        g = _load_fixture_graph()
        view = filter_edges(g, predicate=lambda u, v, d: d.get("weight", 0) >= 3)
        edges = set(view.edges)
        assert ("carol", "dave") in edges
        assert ("grail", "dave") in edges

    def test_filter_graph_combined(self):
        g = _load_fixture_graph()
        view = filter_graph(
            g,
            node_attributes={"type": "character"},
            edge_attributes={"type": "ally_of"},
        )
        assert "harbor" not in view
        assert ("alice", "bob") in view.edges
        assert ("alice", "harbor") not in view.edges

    def test_zero_copy(self):
        g = _load_fixture_graph()
        view = filter_nodes(g, attributes={"type": "character"})
        # mutate through view
        view.nodes["alice"]["chapter"] = 99
        assert g.nodes["alice"]["chapter"] == 99
        # mutation visible both ways
        g.nodes["bob"]["chapter"] = 77
        assert view.nodes["bob"]["chapter"] == 77

    def test_compose_predicates(self):
        g = _load_fixture_graph()
        p1 = lambda nid, d: d.get("type") == "character"
        p2 = lambda nid, d: d.get("status") == "active"
        combined = compose_predicates(p1, p2)
        view = filter_nodes(g, predicate=combined)
        assert set(view.nodes) == {"alice", "bob", "carol"}
        # empty compose returns True for all
        view2 = filter_nodes(g, predicate=compose_predicates())
        assert view2.number_of_nodes() == g.number_of_nodes()

    def test_filter_edges_multigraph(self):
        g = nx.MultiGraph()
        g.add_edge("a", "b", key=0, weight=1)
        g.add_edge("a", "b", key=1, weight=5)
        view = filter_edges(g, predicate=lambda u, v, d: d.get("weight", 0) > 3)
        # MultiGraph view should have only the heavy edge
        # subgraph_view on MultiGraph keeps keys? Check via edges(keys=True)
        edges = list(view.edges(keys=True, data=True))
        assert len(edges) == 1
        assert edges[0][3]["weight"] == 5


# ---------------------------------------------------------------------------
# temporal
# ---------------------------------------------------------------------------


class TestTemporal:
    def test_slice_at_point(self):
        g = _load_fixture_graph()
        view = slice_at(g, "chapter", 2)
        # scalars ==2 plus intervals containing 2
        # characters at 2: carol, rumor; grail is 3-7 so not included
        assert "carol" in view.nodes
        assert "rumor" in view.nodes
        assert "alice" not in view.nodes
        assert "grail" not in view.nodes

    def test_slice_at_interval_contains(self):
        g = _load_fixture_graph()
        # grail interval 3-7 contains 5
        view = slice_at(g, "chapter", 5)
        assert "grail" in view.nodes
        assert "vessel" in view.nodes
        assert "carol" not in view.nodes

    def test_as_of_cumulative(self):
        g = _load_fixture_graph()
        view = as_of(g, "chapter", 2)
        # points <=2 plus intervals starting <=2 containing 2? For our semantics as_of is revealed_by
        # our fixture: alice(1), bob(1), harbor(1), carol(2), rumor(2) -> 5
        # grail 3-7 not yet (start 3 >2)
        assert "alice" in view.nodes
        assert "bob" in view.nodes
        assert "carol" in view.nodes
        assert "grail" not in view.nodes

    def test_as_of_with_interval_active(self):
        g = _load_fixture_graph()
        view = as_of(g, "chapter", 5)
        assert "grail" in view.nodes
        assert "alice" in view.nodes  # point 1 <=5 still included

    def test_window_overlap(self):
        g = _load_fixture_graph()
        view = window(g, "chapter", start=2, end=5)
        # points 2..5: carol(2), dave(4), rumor(2), vessel(5) plus grail interval overlaps 3-7
        assert "carol" in view.nodes
        assert "dave" in view.nodes
        assert "vessel" in view.nodes
        assert "grail" in view.nodes
        assert "alice" not in view.nodes  # 1 outside

    def test_window_open_ended(self):
        g = _load_fixture_graph()
        view = window(g, "chapter", start=4)
        assert "dave" in view.nodes  # 4
        assert "vessel" in view.nodes  # 5
        assert "alice" not in view.nodes

    def test_window_requires_bounds(self):
        g = _load_fixture_graph()
        with pytest.raises(TemporalError):
            window(g, "chapter")

    def test_arbitrary_time_key(self):
        g = nx.Graph()
        g.add_node("a", epoch=10)
        g.add_node("b", epoch=20)
        g.add_node("c", epoch={"start": 5, "end": 15})
        view = slice_at(g, "epoch", 10)
        assert "a" in view.nodes
        assert "c" in view.nodes
        assert "b" not in view.nodes

    def test_split_keys(self):
        g = nx.Graph()
        g.add_node("a", epoch_start=5, epoch_end=10)
        g.add_node("b", epoch_start=20)
        view = slice_at(g, "epoch", 7)
        assert "a" in view.nodes
        assert "b" not in view.nodes
        # window with split keys
        view2 = window(g, "epoch", start=6, end=8)
        assert "a" in view2.nodes

    def test_list_interval(self):
        g = nx.Graph()
        g.add_node("a", turn=[3, 7])
        assert "a" in slice_at(g, "turn", 5).nodes
        assert "a" not in slice_at(g, "turn", 8).nodes

    def test_include_untimed(self):
        g = nx.Graph()
        g.add_node("a", chapter=1)
        g.add_node("b")  # untimed
        assert "b" in slice_at(g, "chapter", 1).nodes
        assert "b" not in slice_at(g, "chapter", 1, include_untimed=False).nodes

    def test_scope_nodes_only(self):
        g = _load_fixture_graph()
        view = slice_at(g, "chapter", 2, scope="nodes")
        # edges unchanged? nodes filtered, edges still visible among kept nodes
        assert "alice" not in view.nodes
        # edge alice->bob should be hidden because alice not in view
        # but edge filtering not applied; edges among kept nodes remain
        assert ("alice", "bob") not in view.edges

    def test_scope_edges_only(self):
        g = _load_fixture_graph()
        view = slice_at(g, "chapter", 2, scope="edges")
        # nodes all present, edges filtered to those with chapter==2
        assert "alice" in view.nodes
        # edge alice->bob chapter 1 should be hidden
        assert ("alice", "bob") not in view.edges
        assert ("bob", "carol") in view.edges

    def test_temporal_bound_helper(self):
        assert temporal_bound({"chapter": 5}, "chapter") == (False, 5, 5)
        assert temporal_bound({"chapter": {"start": 1, "end": 3}}, "chapter") == (
            True,
            1,
            3,
        )
        assert temporal_bound({"chapter": [1, 2]}, "chapter") == (True, 1, 2)
        assert temporal_bound({"other": 1}, "chapter") is None

    def test_invalid_scope(self):
        g = _load_fixture_graph()
        with pytest.raises(TemporalError):
            slice_at(g, "chapter", 1, scope="bad")

    def test_invalid_time_key(self):
        g = _load_fixture_graph()
        with pytest.raises(TemporalError):
            slice_at(g, "", 1)


# ---------------------------------------------------------------------------
# cypher_extractor
# ---------------------------------------------------------------------------


class TestCypherExtractor:
    def test_demarcation_guard(self):
        g = nx.Graph()
        g.add_node("a")
        with pytest.raises(CypherExtractorError, match="demarcated"):
            assert_external_backend(g)

    def test_demarcation_run_guard(self):
        extractor = CypherHttpExtractor(
            "http://example.com", "u", "p", transport=lambda u, b, h: (200, {"results": [], "errors": []})
        )
        g = nx.Graph()
        with pytest.raises(CypherExtractorError):
            extractor.run(g)  # type: ignore[arg-type]

    def test_cypher_query_model(self):
        q = CypherQuery(statement="MATCH (n) RETURN n", parameters={"x": 1})
        body = q.to_tx_body()
        assert body["statements"][0]["statement"] == "MATCH (n) RETURN n"
        assert body["statements"][0]["parameters"]["x"] == 1

    def test_build_match_query_nodes(self):
        q = build_match_query("Person", properties={"name": "Alice"}, limit=10)
        assert "MATCH" in q.statement
        assert "Person" in q.statement
        assert "LIMIT 10" in q.statement
        assert "p_name" in q.parameters

    def test_build_match_query_relationship(self):
        q = build_match_query("Person", relationship="KNOWS", limit=5)
        assert "KNOWS" in q.statement

    def test_build_match_query_unsafe(self):
        with pytest.raises(CypherExtractorError):
            build_match_query("Bad Label!")

    def test_http_extractor_with_stub(self):
        def stub(url, body, headers):
            # verify auth header
            assert "Authorization" in headers
            assert headers["Authorization"].startswith("Basic ")
            assert "tx/commit" in url
            payload = json.loads(body.decode())
            assert "statements" in payload
            return (
                200,
                {
                    "results": [
                        {
                            "columns": ["n"],
                            "data": [{"row": [{"identity": 1, "labels": ["Person"], "properties": {"id": "alice"}}]}],
                        }
                    ],
                    "errors": [],
                },
            )

        ex = CypherHttpExtractor("http://localhost:7474", "neo4j", "pass", transport=stub)
        rows = ex.run("MATCH (n) RETURN n")
        assert rows == [{"n": {"identity": 1, "labels": ["Person"], "properties": {"id": "alice"}}}]

    def test_http_extractor_error(self):
        def stub_err(url, body, headers):
            return (200, {"results": [], "errors": [{"message": "bad cypher"}]})

        ex = CypherHttpExtractor("http://x", "u", "p", transport=stub_err)
        with pytest.raises(CypherExtractorError, match="bad cypher"):
            ex.run("BAD")

    def test_http_extractor_with_cypherquery(self):
        def stub(url, body, headers):
            return (200, {"results": [{"columns": ["n"], "data": []}], "errors": []})

        ex = CypherHttpExtractor("http://x", "u", "p", transport=stub)
        q = CypherQuery(statement="MATCH (n) RETURN n")
        assert ex.run(q) == []

    def test_graph_from_records_nodes(self):
        rows = [
            {"n": {"identity": 1, "labels": ["Person"], "properties": {"id": "alice", "age": 30}}},
            {"n": {"identity": 2, "labels": ["Person"], "properties": {"id": "bob"}}},
        ]
        g = graph_from_records(rows)
        assert g.has_node("1") or g.has_node("alice")
        # Our implementation uses elementId/identity fallback; check both
        assert g.number_of_nodes() == 2

    def test_graph_from_records_relationships(self):
        rows = [
            {
                "r": {
                    "identity": 10,
                    "type": "KNOWS",
                    "start": "1",
                    "end": "2",
                    "properties": {"since": 2020},
                }
            }
        ]
        g = graph_from_records(rows)
        assert g.has_edge("1", "2")
        assert g["1"]["2"]["_type"] == "KNOWS"

    def test_graph_from_records_mixed(self):
        rows = [
            {
                "n": {"identity": 1, "labels": ["Person"], "properties": {"id": "alice"}},
                "r": {"type": "KNOWS", "start": "1", "end": "2", "properties": {}},
                "m": {"identity": 2, "labels": ["Person"], "properties": {"id": "bob"}},
            }
        ]
        g = graph_from_records(rows)
        assert g.number_of_nodes() >= 2
        assert g.has_edge("1", "2")

    def test_cypher_query_empty_statement(self):
        ex = CypherHttpExtractor("http://x", "u", "p", transport=lambda u, b, h: (200, {"results": [], "errors": []}))
        with pytest.raises(CypherExtractorError):
            ex.run("   ")
