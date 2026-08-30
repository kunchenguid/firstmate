"""Wave 1 script tests: direct imports + CLI dual-mode for all 5 tools."""

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

from scripts.net_centrality import compute_betweenness, compute_harmonic_fallback, compute_katz
from scripts.net_components import compute_components, find_bridges_and_articulation_points, isolate_lcc
from scripts.net_constrained_paths import find_constrained_path, sample_bounded_random_walks
from scripts.net_kcore_onion import compute_kcore, compute_onion_layers
from scripts.net_link_prediction import evaluate_heider_balance, predict_links_aa_ra

FIXTURE = Path(__file__).parent / "fixtures" / "sample_graph.json"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _sample_graph_dict() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def _simple_graph() -> nx.Graph:
    g = nx.Graph()
    g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a"), ("c", "d")])
    return g


def _path_graph() -> nx.Graph:
    g = nx.Graph()
    g.add_edges_from([("a", "b"), ("b", "c"), ("c", "d")])
    return g


def _signed_triangle() -> nx.Graph:
    g = nx.Graph()
    g.add_edge("a", "b", sign=1)
    g.add_edge("b", "c", sign=1)
    g.add_edge("a", "c", sign=-1)  # unbalanced
    return g


def _cli_run(module: str, payload: dict) -> dict:
    """Run a module's CLI via stdin and return parsed JSON."""
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
# net_components
# ---------------------------------------------------------------------------


class TestNetComponents:
    def test_compute_components_direct(self):
        g = _simple_graph()
        out = compute_components(g)
        assert out["count"] == 1
        assert out["sizes"] == [4]

    def test_compute_components_disconnected(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        out = compute_components(g)
        assert out["count"] == 2
        assert sorted(out["sizes"]) == [2, 2]

    def test_compute_components_with_dict(self):
        d = _sample_graph_dict()
        out = compute_components(d)
        assert out["count"] >= 1
        assert "components" in out

    def test_compute_components_filter(self):
        d = _sample_graph_dict()
        out = compute_components(d, node_attributes={"type": "character"})
        # Only character nodes
        assert out["count"] >= 1

    def test_compute_components_temporal(self):
        d = _sample_graph_dict()
        out = compute_components(d, time_key="chapter", time_mode="slice_at", time_at=1)
        assert "components" in out

    def test_isolate_lcc_direct(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("b", "c")
        g.add_edge("x", "y")
        out = isolate_lcc(g)
        assert out["lcc_size"] == 3
        assert out["total_components"] == 2
        assert "graph" in out

    def test_isolate_lcc_empty(self):
        g = nx.Graph()
        out = isolate_lcc(g)
        assert out["lcc_size"] == 0

    def test_find_bridges_direct(self):
        g = _path_graph()
        out = find_bridges_and_articulation_points(g)
        # path a-b-c-d: all edges are bridges, b and c are articulation
        assert out["bridge_count"] == 3
        assert "b" in out["articulation_points"]
        assert "c" in out["articulation_points"]

    def test_find_bridges_triangle_no_bridges(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a")])
        out = find_bridges_and_articulation_points(g)
        assert out["bridge_count"] == 0
        assert out["articulation_count"] == 0

    def test_components_cli(self):
        d = _sample_graph_dict()
        result = _cli_run("scripts.net_components", d)
        assert result["ok"] is True
        assert "components" in result["data"]

    def test_components_cli_stdin(self):
        g = _simple_graph()
        # Convert to dict for CLI
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_components", d)
        assert result["ok"] is True

    def test_lcc_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_components", d)
        assert result["ok"] is True
        # Also test isolate_lcc via direct with dict
        out = isolate_lcc(d)
        assert out["lcc_size"] == 4

    def test_bridges_cli_payload(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        # Use find_bridges via direct; CLI via net_components covers compute_components
        out = find_bridges_and_articulation_points(d)
        assert out["bridge_count"] == 3


# ---------------------------------------------------------------------------
# net_kcore_onion
# ---------------------------------------------------------------------------


class TestNetKcoreOnion:
    def test_compute_kcore_direct(self):
        g = _simple_graph()
        out = compute_kcore(g)
        assert "core_numbers" in out
        assert "degeneracy" in out
        assert out["degeneracy"] >= 1

    def test_compute_kcore_with_k(self):
        g = _simple_graph()
        out = compute_kcore(g, k=2)
        assert "kcore_nodes" in out
        assert out["k"] == 2

    def test_compute_kcore_k_too_high(self):
        g = _path_graph()
        out = compute_kcore(g, k=10)
        assert out["kcore_size"] == 0

    def test_compute_kcore_empty(self):
        g = nx.Graph()
        out = compute_kcore(g)
        assert out["core_numbers"] == {}
        assert out["degeneracy"] == 0

    def test_compute_kcore_filter(self):
        d = _sample_graph_dict()
        out = compute_kcore(d, node_attributes={"type": "character"})
        assert "core_numbers" in out

    def test_compute_onion_layers_direct(self):
        g = _simple_graph()
        out = compute_onion_layers(g)
        assert "onion_layers" in out
        assert "layers" in out
        assert "max_layer" in out

    def test_compute_onion_empty(self):
        g = nx.Graph()
        out = compute_onion_layers(g)
        assert out["onion_layers"] == {}

    def test_kcore_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_kcore_onion", d)
        assert result["ok"] is True
        assert "core_numbers" in result["data"]

    def test_onion_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_kcore_onion", d)
        assert result["ok"] is True

    def test_kcore_temporal(self):
        d = _sample_graph_dict()
        out = compute_kcore(d, time_key="chapter", time_mode="slice_at", time_at=1)
        assert "core_numbers" in out


# ---------------------------------------------------------------------------
# net_constrained_paths
# ---------------------------------------------------------------------------


class TestNetConstrainedPaths:
    def test_find_constrained_path_direct(self):
        g = _path_graph()
        out = find_constrained_path(g, source="a", target="d")
        assert out["found"] is True
        assert out["path"] == ["a", "b", "c", "d"]
        assert out["length"] == 3

    def test_find_constrained_path_no_path(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        out = find_constrained_path(g, source="a", target="d")
        assert out["found"] is False

    def test_find_constrained_path_max_depth(self):
        g = _path_graph()
        out = find_constrained_path(g, source="a", target="d", max_depth=2)
        assert out["found"] is False

    def test_find_constrained_path_avoid(self):
        g = _path_graph()
        out = find_constrained_path(g, source="a", target="d", avoid_nodes=["c"])
        assert out["found"] is False

    def test_find_constrained_path_weighted(self):
        g = nx.Graph()
        g.add_edge("a", "b", weight=1)
        g.add_edge("b", "c", weight=1)
        g.add_edge("a", "c", weight=10)
        out = find_constrained_path(g, source="a", target="c", weight="weight")
        assert out["found"] is True
        assert out["path"] == ["a", "b", "c"]

    def test_find_constrained_path_payload_dict(self):
        d = _sample_graph_dict()
        out = find_constrained_path(d, source="alice", target="harbor")
        assert "found" in out

    def test_sample_bounded_random_walks(self):
        g = _simple_graph()
        out = sample_bounded_random_walks(g, start="a", num_walks=3, walk_length=4, seed=42)
        assert len(out["walks"]) == 3
        for w in out["walks"]:
            assert w[0] == "a"
            assert len(w) <= 4

    def test_sample_walks_deterministic(self):
        g = _simple_graph()
        out1 = sample_bounded_random_walks(g, start="a", num_walks=5, walk_length=4, seed=0)
        out2 = sample_bounded_random_walks(g, start="a", num_walks=5, walk_length=4, seed=0)
        assert out1["walks"] == out2["walks"]

    def test_sample_walks_invalid_start(self):
        g = _simple_graph()
        with pytest.raises(ValueError):
            sample_bounded_random_walks(g, start="zzz", num_walks=2, walk_length=3)

    def test_constrained_path_cli(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_constrained_paths", {"graph": d, "source": "a", "target": "d"})
        assert result["ok"] is True
        assert result["data"]["found"] is True

    def test_walks_cli(self):
        # Walks tested via direct import; CLI dispatches to constrained_path by default
        g = _simple_graph()
        out = sample_bounded_random_walks(g, start="a", num_walks=2, walk_length=3, seed=0)
        assert len(out["walks"]) == 2
        # Verify CLI still works for constrained path via same module
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_constrained_paths", {"graph": d, "source": "a", "target": "d"})
        assert result["ok"] is True

    def test_constrained_filter_integration(self):
        d = _sample_graph_dict()
        out = find_constrained_path(d, source="alice", target="carol", node_attributes={"type": "character"})
        assert "found" in out


# ---------------------------------------------------------------------------
# net_centrality
# ---------------------------------------------------------------------------


class TestNetCentrality:
    def test_betweenness_direct(self):
        g = _path_graph()
        out = compute_betweenness(g)
        assert "scores" in out
        # Middle nodes have higher betweenness in a path
        assert out["scores"]["b"] > out["scores"]["a"]
        assert out["scores"]["c"] > out["scores"]["d"]

    def test_betweenness_empty(self):
        g = nx.Graph()
        out = compute_betweenness(g)
        assert out["scores"] == {}

    def test_betweenness_normalized(self):
        g = _simple_graph()
        out = compute_betweenness(g, normalized=True)
        assert out["normalized"] is True
        for v in out["scores"].values():
            assert 0 <= v <= 1

    def test_katz_direct(self):
        g = _simple_graph()
        out = compute_katz(g)
        assert "scores" in out
        assert "alpha" in out
        assert len(out["scores"]) == 4

    def test_katz_converged(self):
        g = _simple_graph()
        out = compute_katz(g)
        assert "converged" in out

    def test_harmonic_direct(self):
        g = _path_graph()
        out = compute_harmonic_fallback(g)
        assert "scores" in out
        assert "method" in out

    def test_harmonic_disconnected(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        out = compute_harmonic_fallback(g)
        assert "scores" in out
        assert len(out["scores"]) == 4

    def test_harmonic_single_node(self):
        g = nx.Graph()
        g.add_node("solo")
        out = compute_harmonic_fallback(g)
        assert out["scores"]["solo"] == 0.0

    def test_centrality_filter(self):
        d = _sample_graph_dict()
        out = compute_betweenness(d, node_attributes={"type": "character"})
        assert "scores" in out

    def test_centrality_temporal(self):
        d = _sample_graph_dict()
        out = compute_katz(d, time_key="chapter", time_mode="slice_at", time_at=1)
        assert "scores" in out

    def test_betweenness_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_centrality", d)
        assert result["ok"] is True
        assert "scores" in result["data"]

    def test_katz_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_centrality", d)
        assert result["ok"] is True

    def test_harmonic_cli(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_centrality", {"graph": d, "weight": None})
        assert result["ok"] is True


# ---------------------------------------------------------------------------
# net_link_prediction
# ---------------------------------------------------------------------------


class TestNetLinkPrediction:
    def test_predict_aa_ra_direct(self):
        g = _path_graph()
        out = predict_links_aa_ra(g)
        assert "adamic_adar" in out
        assert "resource_allocation" in out
        assert out["candidate_count"] > 0

    def test_predict_with_ebunch(self):
        g = _simple_graph()
        out = predict_links_aa_ra(g, ebunch=[["a", "d"]])
        assert out["candidate_count"] == 1
        assert len(out["adamic_adar"]) == 1

    def test_predict_top_k(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "d"), ("d", "e"), ("a", "c")])
        out = predict_links_aa_ra(g, top_k=2)
        assert len(out["adamic_adar"]) <= 2
        assert len(out["resource_allocation"]) <= 2

    def test_predict_empty(self):
        g = nx.Graph()
        out = predict_links_aa_ra(g)
        assert out["candidate_count"] == 0

    def test_predict_complete_graph(self):
        g = nx.complete_graph(4)
        # Relabel to strings
        g = nx.relabel_nodes(g, {i: str(i) for i in g.nodes()})
        out = predict_links_aa_ra(g)
        assert out["candidate_count"] == 0

    def test_heider_balanced(self):
        g = nx.Graph()
        g.add_edge("a", "b", sign=1)
        g.add_edge("b", "c", sign=1)
        g.add_edge("a", "c", sign=1)
        out = evaluate_heider_balance(g)
        assert out["total_triangles"] == 1
        assert out["balanced_triangles"] == 1
        assert out["balance_ratio"] == 1.0

    def test_heider_unbalanced(self):
        g = _signed_triangle()
        out = evaluate_heider_balance(g)
        assert out["total_triangles"] == 1
        assert out["unbalanced_triangles"] == 1
        assert out["balance_ratio"] == 0.0

    def test_heider_no_triangles(self):
        g = _path_graph()
        out = evaluate_heider_balance(g)
        assert out["total_triangles"] == 0
        assert out["balance_ratio"] == 1.0

    def test_heider_two_triangles(self):
        g = nx.Graph()
        g.add_edge("a", "b", sign=1)
        g.add_edge("b", "c", sign=1)
        g.add_edge("a", "c", sign=1)  # balanced
        g.add_edge("c", "d", sign=1)
        g.add_edge("a", "d", sign=-1)  # check
        g.add_edge("b", "d", sign=1)
        out = evaluate_heider_balance(g)
        assert out["total_triangles"] >= 1

    def test_link_prediction_cli(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_link_prediction", d)
        assert result["ok"] is True
        assert "adamic_adar" in result["data"]

    def test_heider_cli(self):
        g = _signed_triangle()
        d = {
            "nodes": [{"id": n} for n in g.nodes()],
            "edges": [{"source": u, "target": v, "attributes": dict(d)} for u, v, d in g.edges(data=True)],
        }
        result = _cli_run_stdin("scripts.net_link_prediction", d)
        assert result["ok"] is True

    def test_link_prediction_filter(self):
        d = _sample_graph_dict()
        out = predict_links_aa_ra(d, node_attributes={"type": "character"})
        assert "adamic_adar" in out

    def test_heider_temporal(self):
        d = _sample_graph_dict()
        out = evaluate_heider_balance(d, time_key="chapter", time_mode="slice_at", time_at=2)
        assert "total_triangles" in out

    def test_link_prediction_string_signs(self):
        g = nx.Graph()
        g.add_edge("a", "b", sign="positive")
        g.add_edge("b", "c", sign="negative")
        g.add_edge("a", "c", sign="positive")
        out = evaluate_heider_balance(g, sign_key="sign")
        assert out["total_triangles"] == 1
