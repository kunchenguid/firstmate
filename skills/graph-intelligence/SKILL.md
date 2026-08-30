# graph-intelligence — Agent Skill

> Deterministic cognitive router over 15 graph algorithms. No LLM choice paralysis: the agent answers a short IF-ELSE chain over graph properties and question shape.

## When to use this skill

Any task involving: component structure, dense cores, shortest / widest / diverse paths, centrality ranking, link prediction, balance, cliques, triads, treewidth, distances, Steiner connectivity, or temporal slicing of a graph.

---

## Deterministic Router (no LLM choice)

Evaluate top-to-bottom; first matching arm fires. Each arm names the exact `scripts.*` module and function to call. Do NOT pick by vibes — follow the chain.

```
Q1  Is the graph external (Neo4j / LadybugDB / DuckDB) and not yet in-memory?
    → YES: core.cypher_extractor.{CypherHttpExtractor, build_match_query, graph_from_records}
           See references/cypher_patterns.md. Materialize to nx.Graph, then continue below.
    → NO : continue (in-memory nx.Graph or interchange {nodes, edges} dict).

Q2  Does the question filter by attribute or time BEFORE computing anything?
    → attribute predicate? → pre-apply core.filter_engine.filter_graph
                            (node_attributes / edge_attributes on every tool also do this zero-copy)
    → time slice (chapter / epoch / timestamp scalar/interval/split)?
                            → pre-apply core.temporal.{slice_at, as_of, window}
                            or use every tool's time_key / time_mode / time_at / time_start / time_end

Q3  Is the question about COMPONENT STRUCTURE?
    IF needs bridge / articulation cut-sets
        → scripts.net_components.find_bridges_and_articulation_points
    ELIF needs whole-graph LCC extraction
        → scripts.net_components.isolate_lcc
    ELIF needs partition/count/sizes of components (weak vs strong for directed)
        → scripts.net_components.compute_components
    (Q3 is the only component arm; do not route component questions to centrality or k-core.)

Q4  Is the question about COHESION / DENSE SUBSTRUCTURE?
    IF triad motif fingerprint over ALL 3-node subsets (16 types, Davis-Leinhardt)
        → scripts.net_triad_census.compute_triad_census_16
    ELIF treewidth / elimination width / chordal bag size
        → scripts.net_treewidth.estimate_treewidth  (try both min-degree and min-fill; take min)
    ELIF enumerating maximal cliques / clique number / triangle census
        → scripts.net_maximal_cliques.{find_maximal_cliques, get_clique_number, count_triangles}
    ELIF k-core numbers / degeneracy / onion peeling order
        → scripts.net_kcore_onion.{compute_kcore, compute_onion_layers}

Q5  Is the question about PATHS (single / diverse / constrained / bottleneck / Steiner)?
    IF connect ≥3 terminals with minimum Steiner tree (2-approx Mehlhorn)
        → scripts.net_steiner_tree.compute_steiner_tree
    ELIF maximize bottleneck capacity (maximin edge weight)
        → scripts.net_widest_path.find_widest_bottleneck_path
    ELIF K diverse loop-free alternatives between s and t (Yen, K≤10)
        → scripts.net_yen_k_shortest.find_yen_k_shortest_paths
    ELIF constraints max_depth / max_cost / avoid_nodes / avoid_edges, or sampled walks
        → scripts.net_constrained_paths.{find_constrained_path, sample_bounded_random_walks}
    ELIF bounded all-pairs distances with cutoff d≤3 (ego-net / locality radius)
        → scripts.net_bounded_apsp.compute_bounded_apsp
    ELIF anything else s-t shortest path
        → scripts.net_constrained_paths.find_constrained_path  (weight-aware, constraint-capable superset)

Q6  Is the question about DISTANCE / REACHABILITY SUMMARIES?
    IF all-pairs up to strict cutoff d≤3, with density + path reconstruction
        → scripts.net_bounded_apsp.compute_bounded_apsp
    ELIF widest capacity between a pair
        → scripts.net_widest_path.find_widest_bottleneck_path
    ELIF multiple diverse s-t options
        → scripts.net_yen_k_shortest.find_yen_k_shortest_paths

Q7  Is the question about CENTRALITY / RANKING?
    IF explicitly asks closeness or harmonic and needs disconnected-safe broadcast seed handling
        → scripts.net_closeness_harmonic.{compute_closeness, compute_harmonic}
    ELIF needs betweenness (exact or k-sampled Brandes)
        → scripts.net_centrality.compute_betweenness
    ELIF needs Katz with auto α tuning
        → scripts.net_centrality.compute_katz
    ELIF needs harmonic that gracefully falls back to closeness
        → scripts.net_centrality.compute_harmonic_fallback
    (Tie-breaker for generic "most important node": compute_betweenness when paths matter,
     compute_katz when walk-count matters, compute_harmonic when distances matter.)

Q8  Is the question about LINK PREDICTION / FUTURE EDGES?
    IF global multi-hop Katz score S = Σ β^k A^k (β < 1/λ_max)
        → scripts.net_katz_lp.compute_katz_link_index
    ELIF degree product baseline O(1) per pair
        → scripts.net_preferential_attach.compute_preferential_attachment
    ELIF common-neighbor weighting Adamic-Adar or Resource Allocation
        → scripts.net_link_prediction.predict_links_aa_ra
    ELIF comparing local predictors or ranking candidates across methods
        → run all three (AA/RA + preferential + Katz) and compare top_k overlap

Q9  Is the question about SIGNED BALANCE / HEIDER?
    → scripts.net_link_prediction.evaluate_heider_balance
      (requires sign edge attribute; reports balanced vs unbalanced triangle ratio)

Fallback: if no Q3–Q9 arm matches, default to scripts.net_components.compute_components + scripts.net_centrality.compute_betweenness as a cheap diagnostic pair, and ask the user which arm they meant.
```

### Router guardrails

- Never choose by LLM intuition; cite the Q-number that fired.
- The router is total: every question hits exactly one arm, or the fallback.
- Temporal and attribute filtering composes with every arm — do not skip Q2.
- Cross-cutting: `core.graph_loader.load` auto-detects JSON / edge-list / adjacency / GraphML.

---

## Usage — Python (import)

```python
from core.graph_loader import load_json
from scripts.net_components import compute_components, isolate_lcc
from scripts.net_centrality import compute_betweenness
from scripts.net_constrained_paths import find_constrained_path

G = load_json({"nodes": [{"id": "a"}, {"id": "b"}], "edges": [{"source": "a", "target": "b"}]})
compute_components(G)                                   # no filter
compute_betweenness(G, normalized=True)                  # centrality
find_constrained_path(G, source="a", target="b", weight=None)  # s-t
# With zero-copy filtering + temporal slicing composed:
compute_betweenness(G, node_attributes={"type": "character"}, time_key="chapter", time_mode="slice_at", time_at=2)
```

## Usage — CLI (dual-mode, deterministic JSON)

Every script is both importable and runnable as `python -m scripts.<tool>`:

```bash
python -m scripts.net_components '{"graph": {"nodes":[{"id":"a"}],"edges":[]}}' < graph.json
python -m scripts.net_centrality --telemetry < payload.json   # telemetry to stderr
echo '{"graph": {"nodes":[...],"edges":[...]}, "source":"a","target":"b"}' | python -m scripts.net_constrained_paths
```

Stdout is always `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}` with sorted keys and fixed indent. See `references/schemas.md` for per-tool JSON schemas.

---

## Catalog index (15 script modules)

| Module | Import path | CLI |
|--------|-------------|-----|
| `net_components` | `scripts.net_components` | `python -m scripts.net_components` |
| `net_kcore_onion` | `scripts.net_kcore_onion` | `python -m scripts.net_kcore_onion` |
| `net_constrained_paths` | `scripts.net_constrained_paths` | `python -m scripts.net_constrained_paths` |
| `net_centrality` | `scripts.net_centrality` | `python -m scripts.net_centrality` |
| `net_link_prediction` | `scripts.net_link_prediction` | `python -m scripts.net_link_prediction` |
| `net_maximal_cliques` | `scripts.net_maximal_cliques` | `python -m scripts.net_maximal_cliques` |
| `net_closeness_harmonic` | `scripts.net_closeness_harmonic` | `python -m scripts.net_closeness_harmonic` |
| `net_yen_k_shortest` | `scripts.net_yen_k_shortest` | `python -m scripts.net_yen_k_shortest` |
| `net_steiner_tree` | `scripts.net_steiner_tree` | `python -m scripts.net_steiner_tree` |
| `net_widest_path` | `scripts.net_widest_path` | `python -m scripts.net_widest_path` |
| `net_triad_census` | `scripts.net_triad_census` | `python -m scripts.net_triad_census` |
| `net_treewidth` | `scripts.net_treewidth` | `python -m scripts.net_treewidth` |
| `net_bounded_apsp` | `scripts.net_bounded_apsp` | `python -m scripts.net_bounded_apsp` |
| `net_preferential_attach` | `scripts.net_preferential_attach` | `python -m scripts.net_preferential_attach` |
| `net_katz_lp` | `scripts.net_katz_lp` | `python -m scripts.net_katz_lp` |

Core: `core.contract` (dual-mode + envelope), `core.graph_loader` (4 formats, auto sniff), `core.filter_engine` (zero-copy `nx.subgraph_view`), `core.temporal` (parameterized `time_key`), `core.cypher_extractor` (external-only Cypher projection).

---

## References

- `references/algorithm_catalog.md` — math formulas, complexity table, NetworkX function mapping for all 15.
- `references/cypher_patterns.md` — Cypher extract queries for Neo4j / LadybugDB / DuckDB (+ 10 reusable patterns).
- `references/schemas.md` — input / output JSON schemas for all 15 dual-mode tools plus shared envelope.

## Verification

```bash
uv run pytest skills/graph-intelligence/tests/   # 60 s timeout, all tests green
```
