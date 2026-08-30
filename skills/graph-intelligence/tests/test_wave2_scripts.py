"""Wave 2 script tests: direct imports + CLI dual-mode for all 3 tools."""

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

from scripts.net_closeness_harmonic import compute_closeness, compute_harmonic
from scripts.net_maximal_cliques import count_triangles, find_maximal_cliques, get_clique_number, iter_maximal_cliques
from scripts.net_yen_k_shortest import find_yen_k_shortest_paths

FIXTURE = Path(__file__).parent / "fixtures" / "sample_graph.json"


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


def _triangle_graph() -> nx.Graph:
    g = nx.Graph()
    g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a")])
    return g


def _disconnected_graph() -> nx.Graph:
    g = nx.Graph()
    g.add_edge("a", "b")
    g.add_edge("c", "d")
    g.add_edge("e", "f")
    g.add_edge("a", "c")  # component1: a,b,c,d
    # component2: e,f isolated pair
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
# net_maximal_cliques
# ---------------------------------------------------------------------------


class TestNetMaximalCliques:
    def test_find_maximal_cliques_direct(self):
        g = _triangle_graph()
        out = find_maximal_cliques(g)
        assert out["count"] == 1
        assert out["cliques"] == [["a", "b", "c"]]
        assert out["clique_number"] == 3

    def test_find_maximal_cliques_two_triangles(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a"), ("c", "d"), ("d", "e"), ("e", "c")])
        out = find_maximal_cliques(g)
        # Two triangles sharing node c -> two maximal cliques
        assert out["count"] == 2
        assert out["max_size"] == 3

    def test_find_maximal_cliques_path(self):
        g = _path_graph()
        out = find_maximal_cliques(g)
        # path a-b-c-d: 3 edges, each edge is a maximal clique of size 2
        assert out["count"] == 3
        assert out["max_size"] == 2

    def test_find_maximal_cliques_filter(self):
        d = _sample_graph_dict()
        out = find_maximal_cliques(d, node_attributes={"type": "character"})
        assert "cliques" in out
        assert "count" in out

    def test_find_maximal_cliques_temporal(self):
        d = _sample_graph_dict()
        out = find_maximal_cliques(d, time_key="chapter", time_mode="slice_at", time_at=1)
        assert "cliques" in out

    def test_find_maximal_cliques_limit(self):
        g = _path_graph()
        out = find_maximal_cliques(g, limit=2)
        assert out["count"] == 2
        assert len(out["cliques"]) == 2

    def test_find_maximal_cliques_min_max_size(self):
        g = _triangle_graph()
        out = find_maximal_cliques(g, min_size=3)
        assert out["count"] == 1
        out2 = find_maximal_cliques(g, max_size=2)
        assert out2["count"] == 0

    def test_find_maximal_cliques_empty(self):
        g = nx.Graph()
        out = find_maximal_cliques(g)
        assert out["count"] == 0
        assert out["cliques"] == []

    def test_find_maximal_cliques_isolated(self):
        g = nx.Graph()
        g.add_node("solo")
        out = find_maximal_cliques(g)
        assert out["count"] == 1
        assert out["cliques"] == [["solo"]]

    def test_iter_maximal_cliques_stream(self):
        g = _triangle_graph()
        cliques = list(iter_maximal_cliques(g))
        assert len(cliques) == 1
        assert sorted(cliques[0]) == ["a", "b", "c"]
        # Compare with eager version
        eager = find_maximal_cliques(g)
        assert sorted([sorted(c) for c in cliques]) == sorted([sorted(c) for c in eager["cliques"]])

    def test_iter_maximal_cliques_empty(self):
        g = nx.Graph()
        assert list(iter_maximal_cliques(g)) == []

    def test_count_triangles_direct(self):
        g = _triangle_graph()
        out = count_triangles(g)
        assert out["total"] == 1
        for v in ("a", "b", "c"):
            assert out["triangles"][v] == 1

    def test_count_triangles_two_triangles(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a"), ("c", "d"), ("d", "e"), ("e", "c")])
        out = count_triangles(g)
        assert out["total"] == 2

    def test_count_triangles_no_triangles(self):
        g = _path_graph()
        out = count_triangles(g)
        assert out["total"] == 0
        for v in out["triangles"].values():
            assert v == 0

    def test_count_triangles_filter(self):
        d = _sample_graph_dict()
        out = count_triangles(d, node_attributes={"type": "character"})
        assert "triangles" in out
        assert "total" in out

    def test_get_clique_number_direct(self):
        g = _triangle_graph()
        out = get_clique_number(g)
        assert out["clique_number"] == 3
        assert sorted(out["max_clique"]) == ["a", "b", "c"]

    def test_get_clique_number_path(self):
        g = _path_graph()
        out = get_clique_number(g)
        assert out["clique_number"] == 2

    def test_get_clique_number_complete(self):
        g = nx.complete_graph(4)
        g = nx.relabel_nodes(g, {i: str(i) for i in g.nodes()})
        out = get_clique_number(g)
        assert out["clique_number"] == 4

    def test_get_clique_number_empty(self):
        g = nx.Graph()
        out = get_clique_number(g)
        assert out["clique_number"] == 0

    def test_maximal_cliques_cli(self):
        g = _triangle_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_maximal_cliques", d)
        assert result["ok"] is True
        assert "cliques" in result["data"]
        assert result["data"]["count"] == 1

    def test_maximal_cliques_cli_stdin(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_maximal_cliques", d)
        assert result["ok"] is True
        assert result["data"]["count"] == 3

    def test_maximal_cliques_cli_with_envelope(self):
        g = _triangle_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_maximal_cliques", {"graph": d, "min_size": 2})
        assert result["ok"] is True

    def test_count_triangles_cli(self):
        g = _triangle_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        out = count_triangles(d)
        assert out["total"] == 1
        # CLI main dispatched to find_maximal_cliques, but direct still works
        result = _cli_run("scripts.net_maximal_cliques", d)
        assert result["ok"] is True

    def test_directed_cliques(self):
        g = nx.DiGraph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a")])
        out = find_maximal_cliques(g)
        assert out["count"] == 1
        assert out["clique_number"] == 3

    def test_clique_with_graph_dict(self):
        d = _sample_graph_dict()
        out = find_maximal_cliques(d)
        assert "count" in out
        out2 = count_triangles(d)
        assert "total" in out2
        out3 = get_clique_number(d)
        assert "clique_number" in out3


# ---------------------------------------------------------------------------
# net_closeness_harmonic
# ---------------------------------------------------------------------------


class TestNetClosenessHarmonic:
    def test_compute_closeness_direct(self):
        g = _path_graph()
        out = compute_closeness(g)
        assert "scores" in out
        assert "seeds" in out
        assert "disconnected" in out
        # middle nodes higher closeness
        assert out["scores"]["b"] > out["scores"]["a"]
        assert out["scores"]["c"] > out["scores"]["d"]

    def test_compute_closeness_single_node(self):
        g = nx.Graph()
        g.add_node("solo")
        out = compute_closeness(g)
        assert out["scores"]["solo"] == 0.0
        assert out["seeds"] == ["solo"]

    def test_compute_closeness_empty(self):
        g = nx.Graph()
        out = compute_closeness(g)
        assert out["scores"] == {}
        assert out["seeds"] == []

    def test_compute_closeness_disconnected(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        out = compute_closeness(g)
        assert out["disconnected"] is True
        assert out["components"] == 2
        assert len(out["seeds"]) == 2

    def test_compute_closeness_connected_seeds(self):
        g = _triangle_graph()
        out = compute_closeness(g)
        assert out["disconnected"] is False
        assert out["components"] == 1
        assert len(out["seeds"]) == 1

    def test_compute_closeness_filter(self):
        d = _sample_graph_dict()
        out = compute_closeness(d, node_attributes={"type": "character"})
        assert "scores" in out

    def test_compute_closeness_temporal(self):
        d = _sample_graph_dict()
        out = compute_closeness(d, time_key="chapter", time_mode="slice_at", time_at=1)
        assert "scores" in out

    def test_compute_closeness_weighted(self):
        g = nx.Graph()
        g.add_edge("a", "b", weight=1)
        g.add_edge("b", "c", weight=1)
        g.add_edge("a", "c", weight=10)
        out = compute_closeness(g, weight="weight")
        assert "scores" in out

    def test_compute_harmonic_direct(self):
        g = _path_graph()
        out = compute_harmonic(g)
        assert "scores" in out
        assert "seeds" in out
        assert out["scores"]["b"] > out["scores"]["a"]

    def test_compute_harmonic_disconnected(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        out = compute_harmonic(g)
        assert out["disconnected"] is True
        assert len(out["scores"]) == 4
        assert len(out["seeds"]) == 2

    def test_compute_harmonic_single_node(self):
        g = nx.Graph()
        g.add_node("solo")
        out = compute_harmonic(g)
        assert out["scores"]["solo"] == 0.0

    def test_compute_harmonic_empty(self):
        g = nx.Graph()
        out = compute_harmonic(g)
        assert out["scores"] == {}

    def test_compute_harmonic_filter(self):
        d = _sample_graph_dict()
        out = compute_harmonic(d, node_attributes={"type": "character"})
        assert "scores" in out

    def test_compute_harmonic_temporal(self):
        d = _sample_graph_dict()
        out = compute_harmonic(d, time_key="chapter", time_mode="window", time_start=1, time_end=3)
        assert "scores" in out

    def test_closeness_cli(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_closeness_harmonic", d)
        assert result["ok"] is True
        assert "scores" in result["data"]

    def test_closeness_cli_stdin(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_closeness_harmonic", d)
        assert result["ok"] is True
        assert "scores" in result["data"]

    def test_harmonic_direct_via_dict(self):
        d = _sample_graph_dict()
        out = compute_harmonic(d)
        assert "scores" in out
        assert "disconnected" in out

    def test_broadcast_seed_selection(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("b", "c")])  # component 1
        g.add_edge("x", "y")  # component 2
        g.add_node("z")  # component 3 isolated
        out = compute_closeness(g)
        assert out["components"] == 3
        assert len(out["seeds"]) == 3
        # seeds should be sorted
        assert out["seeds"] == sorted(out["seeds"])

    def test_closeness_directed(self):
        g = nx.DiGraph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "a")])
        out = compute_closeness(g)
        assert "scores" in out
        out2 = compute_harmonic(g)
        assert "scores" in out2


# ---------------------------------------------------------------------------
# net_yen_k_shortest
# ---------------------------------------------------------------------------


class TestNetYenKShortest:
    def test_yen_direct_single_path(self):
        g = _path_graph()
        out = find_yen_k_shortest_paths(g, source="a", target="d", k=3)
        assert out["found"] is True
        assert out["count"] >= 1
        assert out["paths"][0] == ["a", "b", "c", "d"]
        assert out["costs"][0] == 3.0

    def test_yen_multiple_paths(self):
        g = _simple_graph()
        # a-b-c, a-c direct, c-d ; multiple paths from a to d: a-b-c-d and a-c-d
        out = find_yen_k_shortest_paths(g, source="a", target="d", k=3)
        assert out["found"] is True
        assert out["count"] == 2
        # costs should be sorted non-decreasing
        assert out["costs"] == sorted(out["costs"])
        # All paths are loop-free
        for p in out["paths"]:
            assert len(p) == len(set(p))

    def test_yen_k_one(self):
        g = _path_graph()
        out = find_yen_k_shortest_paths(g, source="a", target="d", k=1)
        assert out["count"] == 1
        assert out["k"] == 1

    def test_yen_k_limit(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("a", "c"), ("b", "d"), ("c", "d"), ("d", "e")])
        out = find_yen_k_shortest_paths(g, source="a", target="e", k=10)
        assert out["count"] <= 10
        # K capped at 10, more than available
        out2 = find_yen_k_shortest_paths(g, source="a", target="e", k=2)
        assert out2["count"] <= 2

    def test_yen_no_path(self):
        g = nx.Graph()
        g.add_edge("a", "b")
        g.add_edge("c", "d")
        out = find_yen_k_shortest_paths(g, source="a", target="d", k=3)
        assert out["found"] is False
        assert out["paths"] == []

    def test_yen_same_source_target(self):
        g = _simple_graph()
        out = find_yen_k_shortest_paths(g, source="a", target="a", k=3)
        assert out["found"] is True
        assert out["paths"] == [["a"]]
        assert out["costs"] == [0.0]

    def test_yen_invalid_k(self):
        g = _path_graph()
        with pytest.raises(ValueError):
            find_yen_k_shortest_paths(g, source="a", target="d", k=0)
        with pytest.raises(ValueError):
            find_yen_k_shortest_paths(g, source="a", target="d", k=11)
        with pytest.raises(ValueError):
            find_yen_k_shortest_paths(g, source="a", target="d", k=15)

    def test_yen_missing_source(self):
        g = _path_graph()
        out = find_yen_k_shortest_paths(g, source="zzz", target="d", k=3)
        assert out["found"] is False

    def test_yen_weighted(self):
        g = nx.Graph()
        g.add_edge("a", "b", weight=1)
        g.add_edge("b", "d", weight=1)
        g.add_edge("a", "c", weight=1)
        g.add_edge("c", "d", weight=10)
        out = find_yen_k_shortest_paths(g, source="a", target="d", k=2, weight="weight")
        assert out["found"] is True
        assert out["paths"][0] == ["a", "b", "d"]
        assert out["costs"][0] == 2.0

    def test_yen_weighted_fallback(self):
        g = _path_graph()
        out = find_yen_k_shortest_paths(g, source="a", target="d", k=2, weight="nonexistent")
        assert out["found"] is True
        # Falls back to unweighted
        assert out["paths"][0] == ["a", "b", "c", "d"]

    def test_yen_filter(self):
        d = _sample_graph_dict()
        out = find_yen_k_shortest_paths(d, source="alice", target="harbor", k=2, node_attributes={"type": "character"})
        assert "found" in out

    def test_yen_temporal(self):
        d = _sample_graph_dict()
        out = find_yen_k_shortest_paths(d, source="alice", target="carol", k=2, time_key="chapter", time_mode="slice_at", time_at=2)
        assert "found" in out

    def test_yen_cli(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run("scripts.net_yen_k_shortest", {"graph": d, "source": "a", "target": "d", "k": 2})
        assert result["ok"] is True
        assert result["data"]["found"] is True
        assert result["data"]["count"] >= 1

    def test_yen_cli_stdin(self):
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        result = _cli_run_stdin("scripts.net_yen_k_shortest", {"graph": d, "source": "a", "target": "d", "k": 2})
        assert result["ok"] is True
        assert "paths" in result["data"]

    def test_yen_cli_with_dict_graph(self):
        d = _sample_graph_dict()
        result = _cli_run("scripts.net_yen_k_shortest", {"graph": d, "source": "alice", "target": "bob", "k": 2})
        assert result["ok"] is True

    def test_yen_directed(self):
        g = nx.DiGraph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("a", "c")])
        out = find_yen_k_shortest_paths(g, source="a", target="c", k=2)
        assert out["found"] is True
        assert out["count"] == 2

    def test_yen_loop_free(self):
        g = nx.Graph()
        g.add_edges_from([("a", "b"), ("b", "c"), ("c", "d"), ("d", "a"), ("a", "c")])
        out = find_yen_k_shortest_paths(g, source="a", target="c", k=5)
        assert out["found"] is True
        for p in out["paths"]:
            assert len(p) == len(set(p)), f"path not loop-free: {p}"

    def test_yen_with_payload_envelope(self):
        g = _simple_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        out = find_yen_k_shortest_paths({"graph": d, "source": "a", "target": "d", "k": 2})
        assert out["found"] is True

    def test_yen_via_dict_source_target(self):
        # Test that dict containing source/target plus nodes is handled
        g = _path_graph()
        d = {"nodes": [{"id": n} for n in g.nodes()], "edges": [{"source": u, "target": v} for u, v in g.edges()]}
        # CLI payload as combined
        result = _cli_run("scripts.net_yen_k_shortest", {"graph": d, "source": "a", "target": "d", "k": 1, "weight": None})
        assert result["ok"] is True
        assert result["data"]["paths"][0] == ["a", "b", "c", "d"]
