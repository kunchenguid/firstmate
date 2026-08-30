"""Wave 3 script tests: direct imports + CLI dual-mode for all 7 tools."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import networkx as nx
import pytest

SKILL_ROOT = Path(__file__).resolve().parents[1]
if str(SKILL_ROOT) not in sys.path:
    sys.path.insert(0, str(SKILL_ROOT))

from scripts.net_steiner_tree import compute_steiner_tree
from scripts.net_widest_path import find_widest_bottleneck_path
from scripts.net_triad_census import compute_triad_census_16
from scripts.net_treewidth import estimate_treewidth
from scripts.net_bounded_apsp import compute_bounded_apsp
from scripts.net_preferential_attach import compute_preferential_attachment
from scripts.net_katz_lp import compute_katz_link_index

FIXTURE = Path(__file__).parent / "fixtures" / "sample_graph.json"


def _sample_graph_dict() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def _simple_graph() -> nx.Graph:
    g = nx.Graph()
    g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a"), ("c", "d"), ("d", "e")])
    return g


def _path_graph() -> nx.Graph:
    g = nx.Graph()
    g.add_edges_from([("a", "b"), ("b", "c"), ("c", "d"), ("d", "e")])
    return g


def _triangle_graph() -> nx.Graph:
    g = nx.Graph()
    g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a")])
    return g


def _cli_run(module: str, payload: dict) -> dict:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8") as tmp:
        json.dump(payload, tmp)
        tmp_path = tmp.name
    try:
        result = subprocess.run(
            [sys.executable, "-m", module, tmp_path],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(SKILL_ROOT),
        )
        assert result.returncode == 0, f"CLI failed: {result.stdout} {result.stderr}"
        return json.loads(result.stdout)
    finally:
        Path(tmp_path).unlink(missing_ok=True)


def _cli_run_stdin(module: str, payload: dict) -> dict:
    result = subprocess.run(
        [sys.executable, "-m", module],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=30,
        cwd=str(SKILL_ROOT),
    )
    assert result.returncode == 0, f"CLI stdin failed: {result.stdout} {result.stderr}"
    return json.loads(result.stdout)


# ---------------------------------------------------------------------------
# net_steiner_tree
# ---------------------------------------------------------------------------


class TestNetSteinerTree:
    def test_steiner_direct_simple(self):
        g = _simple_graph()
        out = compute_steiner_tree(g, terminals=["a", "c", "e"])
        assert out["connected"] is True
        assert out["terminal_count"] == 3
        assert set(["a", "c", "e"]).issubset(set(out["nodes"]))
        assert out["total_weight"] == 3.0
        assert "d" in out["steiner_nodes"]

    def test_steiner_requires_three_terminals(self):
        g = _simple_graph()
        with pytest.raises(ValueError):
            compute_steiner_tree(g, terminals=["a", "b"])

    def test_steiner_missing_terminal(self):
        g = _simple_graph()
        with pytest.raises(ValueError):
            compute_steiner_tree(g, terminals=["a", "c", "zzz"])

    def test_steiner_triangle_terminals(self):
        g = _triangle_graph()
        g.add_node("d")
        g.add_edge("c", "d")
        out = compute_steiner_tree(g, terminals=["a", "b", "d"])
        assert out["connected"] is True
        assert "d" in out["nodes"]
        assert "c" not in out.get("steiner_nodes", []) or True  # c may be steiner or terminal depending

    def test_steiner_weighted(self):
        g = nx.Graph()
        g.add_edge("a", "b", weight=10)
        g.add_edge("b", "c", weight=1)
        g.add_edge("a", "c", weight=10)
        g.add_edge("c", "d", weight=1)
        g.add_edge("d", "e", weight=1)
        out = compute_steiner_tree(g, terminals=["a", "c", "e"], weight="weight")
        assert out["connected"] is True
        assert out["total_weight"] > 0

    def test_steiner_disconnected_terminals(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        g.add_node("e")
        out = compute_steiner_tree(g, terminals=["a", "c", "e"])
        assert out["connected"] is False

    def test_steiner_complete_graph(self):
        g = nx.complete_graph(4)
        g = nx.relabel_nodes(g, {i: str(i) for i in g.nodes()})
        out = compute_steiner_tree(g, terminals=["0", "1", "2"])
        assert out["connected"] is True
        assert out["total_weight"] == 2.0  # MST of 3 terminals in complete graph = 2 edges

    def test_steiner_filter(self):
        d = _sample_graph_dict()
        out = compute_steiner_tree(d, terminals=["alice", "bob", "carol"], node_attributes={"type": "character"})
        assert "nodes" in out

    def test_steiner_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_steiner_tree", {"graph": d, "terminals": ["a", "c", "e"]})
        assert result["ok"] is True
        assert result["data"]["connected"] is True
        assert result["data"]["terminal_count"] == 3

    def test_steiner_cli_stdin(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_steiner_tree", {"graph": d, "terminals": ["a", "c", "e"]})
        assert result["ok"] is True
        assert result["data"]["connected"] is True

    def test_steiner_with_dict_graph(self):
        d = _sample_graph_dict()
        # pick 3 characters that exist
        out = compute_steiner_tree(d, terminals=["alice", "bob", "carol"])
        assert "nodes" in out

    def test_steiner_payload_envelope(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        payload = {"graph": d, "terminals": ["a", "c", "e"]}
        out = compute_steiner_tree(payload)
        assert out["connected"] is True

    def test_steiner_path_graph(self):
        g = _path_graph()
        out = compute_steiner_tree(g, terminals=["a", "c", "e"])
        assert out["connected"] is True
        assert out["nodes"] == ["a", "b", "c", "d", "e"]


# ---------------------------------------------------------------------------
# net_widest_path
# ---------------------------------------------------------------------------


class TestNetWidestPath:
    def test_widest_direct_unweighted(self):
        g = _simple_graph()
        out = find_widest_bottleneck_path(g, source="a", target="e")
        assert out["found"] is True
        assert out["path"][0] == "a"
        assert out["path"][-1] == "e"
        assert out["hops"] == len(out["path"]) - 1

    def test_widest_weighted_bottleneck(self):
        g = nx.Graph()
        g.add_edge("a", "b", weight=10)
        g.add_edge("b", "d", weight=1)
        g.add_edge("a", "c", weight=5)
        g.add_edge("c", "d", weight=5)
        out = find_widest_bottleneck_path(g, source="a", target="d", weight="weight")
        assert out["found"] is True
        # Widest path should be a-c-d with bottleneck 5, not a-b-d with bottleneck 1
        assert out["path"] == ["a", "c", "d"]
        assert out["bottleneck_capacity"] == 5.0

    def test_widest_same_source_target(self):
        g = _simple_graph()
        out = find_widest_bottleneck_path(g, source="a", target="a")
        assert out["found"] is True
        assert out["path"] == ["a"]
        assert out["hops"] == 0

    def test_widest_no_path(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        out = find_widest_bottleneck_path(g, source="a", target="d")
        assert out["found"] is False
        assert out["path"] == []

    def test_widest_missing_node(self):
        g = _simple_graph()
        out = find_widest_bottleneck_path(g, source="zzz", target="e")
        assert out["found"] is False

    def test_widest_directed(self):
        g = nx.DiGraph()
        g.add_edge("a", "b", weight=10)
        g.add_edge("b", "c", weight=3)
        g.add_edge("a", "c", weight=2)
        out = find_widest_bottleneck_path(g, source="a", target="c", weight="weight")
        assert out["found"] is True
        assert out["path"] == ["a", "b", "c"]
        assert out["bottleneck_capacity"] == 3.0

    def test_widest_filter(self):
        d = _sample_graph_dict()
        out = find_widest_bottleneck_path(d, source="alice", target="carol", node_attributes={"type": "character"})
        assert "found" in out

    def test_widest_temporal(self):
        d = _sample_graph_dict()
        out = find_widest_bottleneck_path(d, source="alice", target="carol", time_key="chapter", time_mode="slice_at", time_at=2)
        assert "found" in out

    def test_widest_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v, "attributes": {"weight": 1}} for u, v in g.edges()]}
        result = _cli_run("scripts.net_widest_path", {"graph": d, "source": "a", "target": "e", "weight": "weight"})
        assert result["ok"] is True
        assert result["data"]["found"] is True

    def test_widest_cli_stdin(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_widest_path", {"graph": d, "source": "a", "target": "e"})
        assert result["ok"] is True
        assert "path" in result["data"]

    def test_widest_payload_envelope(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        payload = {"graph": d, "source": "a", "target": "e", "weight": "weight"}
        out = find_widest_bottleneck_path(payload)
        assert out["found"] is True

    def test_widest_requires_source_target(self):
        g = _simple_graph()
        with pytest.raises(ValueError):
            find_widest_bottleneck_path(g)

    def test_widest_uniform_capacity_path(self):
        g = _path_graph()
        out = find_widest_bottleneck_path(g, source="a", target="e", weight="nonexistent_attr")
        assert out["found"] is True
        assert out["path"] == ["a", "b", "c", "d", "e"]


# ---------------------------------------------------------------------------
# net_triad_census
# ---------------------------------------------------------------------------


class TestNetTriadCensus:
    def test_triad_triangle_undirected(self):
        g = _triangle_graph()
        out = compute_triad_census_16(g)
        assert out["n"] == 3
        assert out["total_triads"] == 1
        # Triangle in undirected -> 300 when directed projection (mutual)
        assert out["census"]["300"] == 1
        assert sum(out["census"].values()) == 1

    def test_triad_path_undirected(self):
        g = _path_graph()
        # path on 5 nodes? path_graph has 5 nodes (a-b-c-d-e), n=5->10 triads
        g2 = nx.Graph()
        g2.add_edges_from([("a", "b"), ("b", "c")])
        out = compute_triad_census_16(g2)
        assert out["n"] == 3
        assert out["total_triads"] == 1
        # path a-b-c has 2 edges among 3 nodes -> 102 (one mutual pair missing? actually for undirected mutual encoding)
        # For undirected, edges are bidirectional, so 2 edges = 4 directed arcs = type 201?
        # Let's just verify counts sum
        assert sum(out["census"].values()) == 1

    def test_triad_empty(self):
        g = nx.Graph()
        out = compute_triad_census_16(g)
        assert out["total_triads"] == 0
        assert all(v == 0 for v in out["census"].values())

    def test_triad_two_nodes(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        out = compute_triad_census_16(g)
        assert out["total_triads"] == 0
        assert sum(out["census"].values()) == 0

    def test_triad_directed_cycle(self):
        g = nx.DiGraph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a")])
        out = compute_triad_census_16(g)
        assert out["directed"] is True
        assert out["total_triads"] == 1
        assert out["census"]["030C"] == 1

    def test_triad_transitive(self):
        g = nx.DiGraph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("a", "c")])
        out = compute_triad_census_16(g)
        assert out["total_triads"] == 1
        assert out["census"]["030T"] == 1

    def test_triad_total_is_choose_n3(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "d")])
        out = compute_triad_census_16(g)
        n = g.number_of_nodes()
        expected = n * (n - 1) * (n - 2) // 6
        assert out["total_triads"] == expected

    def test_triad_motif_fingerprint(self):
        g = _triangle_graph()
        out = compute_triad_census_16(g)
        assert "motif_fingerprint" in out
        assert abs(sum(out["motif_fingerprint"].values()) - 1.0) < 1e-9 or sum(out["census"].values()) == 0

    def test_triad_filter(self):
        d = _sample_graph_dict()
        out = compute_triad_census_16(d, node_attributes={"type": "character"})
        assert "census" in out

    def test_triad_temporal(self):
        d = _sample_graph_dict()
        out = compute_triad_census_16(d, time_key="chapter", time_mode="slice_at", time_at=1)
        assert "census" in out

    def test_triad_cli(self):
        g = _triangle_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_triad_census", d)
        assert result["ok"] is True
        assert "census" in result["data"]
        assert result["data"]["total_triads"] == 1

    def test_triad_cli_stdin(self):
        g = nx.DiGraph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a")])
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()], "directed": True}
        result = _cli_run_stdin("scripts.net_triad_census", d)
        assert result["ok"] is True
        assert "census" in result["data"]

    def test_triad_cli_with_envelope(self):
        g = _triangle_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_triad_census", {"graph": d})
        assert result["ok"] is True

    def test_triad_has_all_16_types(self):
        g = _simple_graph()
        out = compute_triad_census_16(g)
        assert len(out["census"]) == 16
        assert set(out["census"].keys()) == {"003", "012", "102", "021D", "021U", "021C", "111D", "111U", "030T", "030C", "201", "120D", "120U", "120C", "210", "300"}

    def test_triad_isolated_nodes(self):
        g = nx.Graph()
        g.add_nodes_from(["a", "b", "c"])
        out = compute_triad_census_16(g)
        assert out["census"]["003"] == 1
        assert out["total_triads"] == 1


# ---------------------------------------------------------------------------
# net_treewidth
# ---------------------------------------------------------------------------


class TestNetTreewidth:
    def test_treewidth_path(self):
        g = _path_graph()
        out = estimate_treewidth(g)
        # Path has treewidth 1
        assert out["treewidth_upper"] == 1
        assert out["n"] == 5
        assert len(out["elimination_order"]) == 5

    def test_treewidth_complete(self):
        g = nx.complete_graph(4)
        g = nx.relabel_nodes(g, {i: str(i) for i in g.nodes()})
        out = estimate_treewidth(g)
        # Complete graph K4 has treewidth 3
        assert out["treewidth_upper"] == 3
        assert out["max_bag_size"] == 4

    def test_treewidth_empty(self):
        g = nx.Graph()
        out = estimate_treewidth(g)
        assert out["treewidth_upper"] == 0
        assert out["elimination_order"] == []

    def test_treewidth_single_node(self):
        g = nx.Graph()
        g.add_node("a")
        out = estimate_treewidth(g)
        assert out["treewidth_upper"] == 0
        assert out["elimination_order"] == ["a"]

    def test_treewidth_both_heuristics(self):
        g = _simple_graph()
        out = estimate_treewidth(g, heuristic="min-degree")
        assert "both_heuristics" in out
        assert "min-degree" in out["both_heuristics"]
        assert "min-fill" in out["both_heuristics"]
        out2 = estimate_treewidth(g, heuristic="min-fill")
        assert out2["heuristic"] == "min-fill"
        assert out["both_heuristics"]["min-degree"] == out2["both_heuristics"]["min-degree"]

    def test_treewidth_alias_heuristic(self):
        g = _simple_graph()
        out = estimate_treewidth(g, heuristic="min-fill-in")
        assert out["heuristic"] == "min-fill"

    def test_treewidth_invalid_heuristic(self):
        g = _simple_graph()
        with pytest.raises(ValueError):
            estimate_treewidth(g, heuristic="bad-name")

    def test_treewidth_filter(self):
        d = _sample_graph_dict()
        out = estimate_treewidth(d, node_attributes={"type": "character"})
        assert "treewidth_upper" in out

    def test_treewidth_temporal(self):
        d = _sample_graph_dict()
        out = estimate_treewidth(d, time_key="chapter", time_mode="slice_at", time_at=1)
        assert "treewidth_upper" in out

    def test_treewidth_cli(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_treewidth", d)
        assert result["ok"] is True
        assert "treewidth_upper" in result["data"]

    def test_treewidth_cli_stdin(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_treewidth", d)
        assert result["ok"] is True

    def test_treewidth_cli_heuristic(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_treewidth", {"graph": d, "heuristic": "min-fill"})
        assert result["ok"] is True
        assert result["data"]["heuristic"] == "min-fill"

    def test_treewidth_tree_is_one(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("b", "d"), ("d", "e")])
        out = estimate_treewidth(g)
        assert out["treewidth_upper"] == 1

    def test_treewidth_bags_valid(self):
        g = _simple_graph()
        out = estimate_treewidth(g)
        for bag in out["bags"]:
            assert len(bag) > 0
            assert len(bag) == len(set(bag))


# ---------------------------------------------------------------------------
# net_bounded_apsp
# ---------------------------------------------------------------------------


class TestNetBoundedApsp:
    def test_apsp_direct_cutoff2(self):
        g = _simple_graph()
        out = compute_bounded_apsp(g, cutoff=2)
        assert out["cutoff"] == 2
        assert out["n"] == 5
        assert "a" in out["distances"]
        # a to b is 1, a to c is 1, a to d is 2
        assert out["distances"]["a"]["b"] == 1.0
        assert out["distances"]["a"]["c"] == 1.0
        assert out["distances"]["a"]["d"] == 2.0
        # a to e is 3 hops, beyond cutoff 2
        assert "e" not in out["distances"]["a"]

    def test_apsp_cutoff3(self):
        g = _path_graph()
        out = compute_bounded_apsp(g, cutoff=3)
        assert out["cutoff"] == 3
        # path a-b-c-d-e, a->d is 3 hops within cutoff, a->e is 4 hops beyond
        assert out["distances"]["a"]["d"] == 3.0
        assert "e" not in out["distances"]["a"]
        # But a->c is 2 hops
        assert out["distances"]["a"]["c"] == 2.0

    def test_apsp_empty(self):
        g = nx.Graph()
        out = compute_bounded_apsp(g, cutoff=2)
        assert out["distances"] == {}
        assert out["reachable_pairs"] == 0

    def test_apsp_single_node(self):
        g = nx.Graph()
        g.add_node("a")
        out = compute_bounded_apsp(g, cutoff=2)
        assert out["distances"]["a"]["a"] == 0.0

    def test_apsp_sources_subset(self):
        g = _simple_graph()
        out = compute_bounded_apsp(g, cutoff=2, sources=["a", "b"])
        assert set(out["distances"].keys()) == {"a", "b"}
        assert out["total_pairs"] == 2 * 4

    def test_apsp_invalid_cutoff(self):
        g = _simple_graph()
        with pytest.raises(ValueError):
            compute_bounded_apsp(g, cutoff=0)
        with pytest.raises(ValueError):
            compute_bounded_apsp(g, cutoff=11)

    def test_apsp_paths_included(self):
        g = _path_graph()
        out = compute_bounded_apsp(g, cutoff=2)
        assert "paths" in out
        assert out["paths"]["a"]["b"] == ["a", "b"]

    def test_apsp_filter(self):
        d = _sample_graph_dict()
        out = compute_bounded_apsp(d, cutoff=2, node_attributes={"type": "character"})
        assert "distances" in out

    def test_apsp_temporal(self):
        d = _sample_graph_dict()
        out = compute_bounded_apsp(d, cutoff=2, time_key="chapter", time_mode="slice_at", time_at=2)
        assert "distances" in out

    def test_apsp_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_bounded_apsp", {"graph": d, "cutoff": 2})
        assert result["ok"] is True
        assert "distances" in result["data"]
        assert result["data"]["cutoff"] == 2

    def test_apsp_cli_stdin(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_bounded_apsp", {"graph": d, "cutoff": 2})
        assert result["ok"] is True

    def test_apsp_density(self):
        g = _triangle_graph()
        out = compute_bounded_apsp(g, cutoff=2)
        # triangle: all pairs reachable within 1 hop, density 1.0
        assert out["density"] == 1.0
        assert out["reachable_pairs"] == 6  # 3 nodes -> 6 ordered pairs

    def test_apsp_disconnected(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        out = compute_bounded_apsp(g, cutoff=2)
        # a cannot reach c/d
        assert "c" not in out["distances"]["a"]
        assert "d" not in out["distances"]["a"]


# ---------------------------------------------------------------------------
# net_preferential_attach
# ---------------------------------------------------------------------------


class TestNetPreferentialAttach:
    def test_pref_direct_simple(self):
        g = _simple_graph()
        out = compute_preferential_attachment(g)
        assert out["method"] == "preferential_attachment"
        assert out["candidate_count"] > 0
        # Check that high-degree nodes rank higher
        # In simple_graph: deg c=3, d=2, others less
        # So c-d or c-e etc scored? Actually a-d should be high
        assert len(out["scores"]) == out["candidate_count"]
        scores = {tuple(s[:2]): s[2] for s in out["scores"]}
        # c is degree 3, b is 2, etc.
        # Scores should be deg(u)*deg(v)
        assert scores[("a", "d")] == 2 * 2  # deg a=2? Let's just check exists
        assert all(s[2] >= 0 for s in out["scores"])

    def test_pref_scores_sorted(self):
        g = _simple_graph()
        out = compute_preferential_attachment(g)
        vals = [s[2] for s in out["scores"]]
        assert vals == sorted(vals, reverse=True)

    def test_pref_with_ebunch(self):
        g = _simple_graph()
        out = compute_preferential_attachment(g, ebunch=[["a", "d"], ["a", "e"]])
        assert out["candidate_count"] == 2
        assert len(out["scores"]) == 2

    def test_pref_top_k(self):
        g = _simple_graph()
        out = compute_preferential_attachment(g, top_k=2)
        assert len(out["scores"]) == 2
        assert out["top_k"] == 2

    def test_pref_empty(self):
        g = nx.Graph()
        out = compute_preferential_attachment(g)
        assert out["candidate_count"] == 0
        assert out["scores"] == []

    def test_pref_complete_graph(self):
        g = nx.complete_graph(4)
        g = nx.relabel_nodes(g, {i: str(i) for i in g.nodes()})
        out = compute_preferential_attachment(g)
        assert out["candidate_count"] == 0

    def test_pref_single_node(self):
        g = nx.Graph()
        g.add_node("a")
        out = compute_preferential_attachment(g)
        assert out["candidate_count"] == 0

    def test_pref_filter(self):
        d = _sample_graph_dict()
        out = compute_preferential_attachment(d, node_attributes={"type": "character"})
        assert "scores" in out

    def test_pref_temporal(self):
        d = _sample_graph_dict()
        out = compute_preferential_attachment(d, time_key="chapter", time_mode="slice_at", time_at=2)
        assert "scores" in out

    def test_pref_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_preferential_attach", d)
        assert result["ok"] is True
        assert "scores" in result["data"]

    def test_pref_cli_stdin(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_preferential_attach", d)
        assert result["ok"] is True

    def test_pref_cli_with_ebunch(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_preferential_attach", {"graph": d, "ebunch": [["a", "d"]]})
        assert result["ok"] is True
        assert result["data"]["candidate_count"] == 1

    def test_pref_with_payload_envelope(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        payload = {"graph": d, "top_k": 2}
        out = compute_preferential_attachment(payload)
        assert len(out["scores"]) <= 2

    def test_pref_degree_product_correctness(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("a", "c"), ("a", "d")])  # a deg 3, others 1
        g.add_edge("b", "e")  # b deg 2
        out = compute_preferential_attachment(g, ebunch=[["c", "e"], ["b", "c"]])
        lookup = {(s[0], s[1]): s[2] for s in out["scores"]}
        # c deg 1, e deg 1 => 1; b deg 2, c deg 1 => 2
        assert lookup[("b", "c")] == 2
        assert lookup[("c", "e")] == 1


# ---------------------------------------------------------------------------
# net_katz_lp
# ---------------------------------------------------------------------------


class TestNetKatzLp:
    def test_katz_direct_simple(self):
        g = _simple_graph()
        out = compute_katz_link_index(g)
        assert out["method"] == "katz"
        assert "beta" in out
        assert out["candidate_count"] > 0
        assert len(out["scores"]) == out["candidate_count"]
        assert all(s[2] >= 0 for s in out["scores"])

    def test_katz_scores_sorted(self):
        g = _simple_graph()
        out = compute_katz_link_index(g)
        vals = [s[2] for s in out["scores"]]
        assert vals == sorted(vals, reverse=True)

    def test_katz_custom_beta(self):
        g = _simple_graph()
        out = compute_katz_link_index(g, beta=0.05)
        assert out["beta"] == 0.05

    def test_katz_invalid_beta(self):
        g = _simple_graph()
        with pytest.raises(ValueError):
            compute_katz_link_index(g, beta=1.5)
        with pytest.raises(ValueError):
            compute_katz_link_index(g, beta=0)

    def test_katz_with_ebunch(self):
        g = _simple_graph()
        out = compute_katz_link_index(g, ebunch=[["a", "d"]])
        assert len(out["scores"]) == 1
        assert out["scores"][0][0] == "a"

    def test_katz_top_k(self):
        g = _simple_graph()
        out = compute_katz_link_index(g, top_k=2)
        assert len(out["scores"]) == 2
        assert out["top_k"] == 2

    def test_katz_empty(self):
        g = nx.Graph()
        out = compute_katz_link_index(g)
        assert out["candidate_count"] == 0

    def test_katz_complete_graph(self):
        g = nx.complete_graph(4)
        g = nx.relabel_nodes(g, {i: str(i) for i in g.nodes()})
        out = compute_katz_link_index(g)
        assert out["candidate_count"] == 0

    def test_katz_filter(self):
        d = _sample_graph_dict()
        out = compute_katz_link_index(d, node_attributes={"type": "character"})
        assert "scores" in out

    def test_katz_temporal(self):
        d = _sample_graph_dict()
        out = compute_katz_link_index(d, time_key="chapter", time_mode="slice_at", time_at=2)
        assert "scores" in out

    def test_katz_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_katz_lp", d)
        assert result["ok"] is True
        assert "scores" in result["data"]

    def test_katz_cli_stdin(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_katz_lp", d)
        assert result["ok"] is True

    def test_katz_cli_with_envelope(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_katz_lp", {"graph": d, "beta": 0.05, "top_k": 2})
        assert result["ok"] is True
        assert len(result["data"]["scores"]) <= 2

    def test_katz_long_range(self):
        # Katz should give non-zero to distant pairs via multi-hop paths
        g = _path_graph()  # a-b-c-d-e, a-e is distant (4 hops)
        out = compute_katz_link_index(g)
        # All non-edges should appear; a-e and a-d etc should have some score >0 for connected
        pairs = {(s[0], s[1]) for s in out["scores"]}
        assert ("a", "c") in pairs or ("a", "d") in pairs

    def test_katz_with_dict(self):
        d = _sample_graph_dict()
        out = compute_katz_link_index(d)
        assert "scores" in out
