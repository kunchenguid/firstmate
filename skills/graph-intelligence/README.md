# graph-intelligence — Universal Agent Skill

> 15 deterministic graph algorithms for narrative, social, and knowledge graphs. Each tool is dual-mode (direct import + JSON CLI), pure-Python (`networkx` + `pydantic` + `scipy`), with zero-copy filtering and temporal slicing that composes with every algorithm.

## Install

```bash
uv pip install -e "skills/graph-intelligence"
# or plain pip
pip install -e skills/graph-intelligence
```

Requires Python ≥ 3.11, `networkx`, `pydantic`, `scipy` (pure-Python wheels).

## Quick start (Python)

```python
from core.graph_loader import load_json
from scripts.net_components import compute_components
from scripts.net_centrality import compute_betweenness

G = load_json({"nodes": [{"id": "a"}, {"id": "b"}, {"id": "c"}],
               "edges": [{"source": "a", "target": "b"}, {"source": "b", "target": "c"}]})
print(compute_components(G))
print(compute_betweenness(G))
```

## Quick start (CLI)

Every script is a standalone tool with deterministic JSON I/O:

```bash
echo '{"nodes":[{"id":"a"},{"id":"b"}],"edges":[{"source":"a","target":"b"}]}' \
  | python -m scripts.net_components
# -> {"ok": true, "data": {"components": [["a","b"]], "count": 1, ...}}
```

## The 15 tools

| # | Module | What it answers |
|---|--------|-----------------|
| 1 | `net_components` | Connected components, LCC isolation, bridges & articulation points |
| 2 | `net_kcore_onion` | K-core numbers / degeneracy + onion peeling layers |
| 3 | `net_constrained_paths` | Constrained shortest path (depth/cost/avoid) + bounded random walks |
| 4 | `net_centrality` | Betweenness (Brandes), Katz (auto α), harmonic fallback |
| 5 | `net_link_prediction` | Adamic-Adar / Resource Allocation + Heider signed balance |
| 6 | `net_maximal_cliques` | Bron–Kerbosch maximal cliques, triangle count, clique number |
| 7 | `net_closeness_harmonic` | Closeness (Wasserman–Faust) / harmonic with broadcast seeds |
| 8 | `net_yen_k_shortest` | Yen K-shortest loop-free paths (K ≤ 10) |
| 9 | `net_steiner_tree` | Mehlhorn 2-approx Steiner tree over ≥3 terminals (metric closure + MST + pruned expansion) |
| 10 | `net_widest_path` | Widest / bottleneck path maximizing the minimum edge weight |
| 11 | `net_triad_census` | Davis–Leinhardt 16 triad types + motif fingerprint |
| 12 | `net_treewidth` | Elimination-heuristic treewidth upper bound (min-degree / min-fill) |
| 13 | `net_bounded_apsp` | Bounded all-pairs shortest paths with cutoff d≤3 + LRU memoization |
| 14 | `net_preferential_attach` | Preferential attachment O(1) degree-product ranker |
| 15 | `net_katz_lp` | Global Katz index S = Σ β^k A^k via Neumann/inverse |

## Cognitive router

The skill ships a deterministic IF-ELSE router in `SKILL.md` (Q1–Q9, top-to-bottom, first-match-fires) that picks the right tool from the question shape and graph properties without LLM choice paralysis. Cite the Q-number that fired.

## Core plumbing (composes with every tool)

- `core.graph_loader` — JSON / edge-list / adjacency / GraphML, auto-sniffed.
- `core.filter_engine` — zero-copy `nx.subgraph_view` predicate & attribute filtering.
- `core.temporal` — parameterized `time_key` slicing (`slice_at` / `as_of` / `window`) over scalar / interval / split keys.
- `core.contract` — Pydantic schemas (`GraphSpec`/`NodeSpec`/`EdgeSpec`/`Result`), telemetry decorator, and `export_dual_mode` CLI bridge.
- `core.cypher_extractor` — demarcated Cypher projection for **external** DBs only (Neo4j/LadybugDB/DuckDB); `assert_external_backend` refuses in-memory graphs here.

## References

- `references/algorithm_catalog.md` — formulas, complexity table, NetworkX mapping for all 15.
- `references/cypher_patterns.md` — 10 reusable Cypher extracts + demarcation notes.
- `references/schemas.md` — input/output JSON schemas for every dual-mode tool + shared envelope.

## Verification

```bash
uv run pytest skills/graph-intelligence/tests/   # all tests pass in <60 s
```
