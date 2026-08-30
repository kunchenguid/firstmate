# Input / Output JSON Schemas — graph-intelligence (15 Dual-Mode Tools)

> Every tool is dual-mode: callable as Python (`from scripts.net_*.py import ...`) and as CLI
> (`python -m scripts.net_<tool> '{"graph": {...}, ...}' < graph.json`).
> CLI contract: stdin or file arg → JSON payload → stdout envelope `{"ok": true, "data": ...}` (sorted keys, indent 2).
> Telemetry to stderr only on `--telemetry`. See `core.contract`.

## Shared Envelope & Base Types

### Graph Payload (input `graph` field or bare payload)

```json
{
  "directed": false,
  "nodes": [{"id": "alice", "attributes": {"type": "character", "chapter": 1}}],
  "edges": [{"source": "alice", "target": "bob", "attributes": {"weight": 2}}]
}
```

- `directed` bool default false. `links` alias for `edges`. NetworkX node-link keys (`directed`/`multigraph`/`links`) also accepted.
- OR pass a NetworkX `Graph`/`DiGraph` directly in Python.
- Coercion: node ids coerced to strings; `source`/`target` aliases `from`/`to`/`u`/`v`/`tail`/`head`.

### Shared Optional Filters (all 15 tools accept these)

```json
{
  "node_attributes": {"type": "character"},
  "edge_attributes": {"weight": 2},
  "time_key": "chapter",
  "time_mode": "slice_at | as_of | window",
  "time_at": 3,
  "time_start": 1,
  "time_end": 5,
  "include_untimed": true
}
```

`node_attributes`/`edge_attributes`: exact-match filter (value or `[accepted values]`). Routed to `core.filter_engine`.
`time_key` temporal slicing routed to `core.temporal`: scalar/interval/split `_start`/`_end` keys; see `references/cypher_patterns.md` §4–5.

### CLI Envelope (stdout)

Success: `{"ok": true, "data": <tool-specific>}`  Failure: `{"ok": false, "error": "Type: message"}`

---

## 1. `net_components.compute_components`

**Input:** `{graph, directed?, + shared filters}`  (`directed` overrides graph's own directedness).

**Output:**
```json
{"components": [["a","b","c"],["d"]], "count": 2, "sizes": [3,1], "directed": false}
```

## 2. `net_components.isolate_lcc`

**Input:** `{graph, directed?, + shared filters}`

**Output:**
```json
{"graph": {"directed": false, "nodes": [...], "edges": [...]}, "lcc_nodes": ["a","b"], "lcc_size": 2, "total_components": 2}
```

## 3. `net_components.find_bridges_and_articulation_points`

**Input:** `{graph, + shared filters}` (undirected view for directed graphs)

**Output:**
```json
{"bridges": [["b","c"]], "articulation_points": ["b"], "bridge_count": 1, "articulation_count": 1}
```

## 4. `net_kcore_onion.compute_kcore`

**Input:** `{graph, k?, + shared filters}` (`k` int; when present also returns induced k-core subgraph nodes). **Output:**
```json
{"core_numbers": {"a":2,"b":2,"c":1}, "degeneracy": 2, "kcore_nodes": ["a","b"], "kcore_size": 2}
```
`kcore_nodes`/`kcore_size` only when `k` is given.

## 5. `net_kcore_onion.compute_onion_layers`

**Input:** `{graph, + shared filters}`

**Output:**
```json
{"onion_layers": {"a":1,"b":1,"c":2}, "layers": {"1":["a","b"],"2":["c"]}, "max_layer": 2, "core_numbers": {"a":1,"b":1,"c":1}}
```

## 6. `net_constrained_paths.find_constrained_path`

**Input:**
```json
{"graph": {...}, "source": "a", "target": "b", "weight": "weight", "max_depth": 5, "max_cost": 10.0, "avoid_nodes": ["x"], "avoid_edges": [["u","v"]], "+ shared filters"}
```
`source`/`target` required (from envelope or payload). `weight` null → BFS hop count. `avoid_nodes`/`avoid_edges` pruned before search.

**Output:**
```json
{"path": ["a","c","b"], "cost": 3.0, "length": 2, "found": true}
```
`found: false` → `path: [], cost: inf` (or absent `cost`).

## 7. `net_constrained_paths.sample_bounded_random_walks`

**Input:** `{graph, start?, walk_length?, num_walks?, + shared filters}`

**Output:**
```json
{"walks": [["a","b","c"],["a","c"]], "start": "a", "num_walks": 2, "walk_length": 3}
```

## 8. `net_centrality.compute_betweenness`

**Input:**
```json
{"graph": {...}, "normalized": true, "weight": null, "k": null, "seed": 0, "+ shared filters"}
```
`k`: sample k pivots for approximation (null = exact).

**Output:**
```json
{"scores": {"a":0.5,"b":0.0}, "top": [["a",0.5],["b",0.0]], "normalized": true}
```

## 9. `net_centrality.compute_katz`

**Input:**
```json
{"graph": {...}, "alpha": null, "beta": 1.0, "max_iter": 1000, "tol": 1e-06, "normalized": true, "weight": null, "+ shared filters"}
```
`alpha` auto `0.9/(max_degree+1)` when null.

**Output:**
```json
{"scores": {"a":0.4,"b":0.3}, "top": [["a",0.4]], "alpha": 0.12, "converged": true}
```

## 10. `net_centrality.compute_harmonic_fallback`

**Input:** `{graph, weight?, + shared filters}`

**Output:**
```json
{"scores": {"a":1.5,"b":0.0}, "top": [["a",1.5]], "method": "harmonic"}
```
`method: "closeness_fallback"` on error path; single-node `{"a":0.0}`.

## 11. `net_link_prediction.predict_links_aa_ra`

**Input:**
```json
{"graph": {...}, "ebunch": [["a","b"]], "top_k": 10, "+ shared filters"}
```
`ebunch` null → all non-edges.

**Output:**
```json
{"adamic_adar": [["a","c",1.2],["b","d",0.8]], "resource_allocation": [["a","c",0.6]], "candidate_count": 5, "top_k": 10}
```

## 12. `net_link_prediction.evaluate_heider_balance`

**Input:** `{graph, + shared filters}` (uses `sign` edge attribute: positive/negative).

**Output:**
```json
{"balanced_triangles": 3, "unbalanced_triangles": 1, "total_triangles": 4, "balance_ratio": 0.75}
```

## 13. `net_maximal_cliques`

### `find_maximal_cliques`

**Input:** `{graph, + shared filters}`  Bare `graph` dict is used directly as the graph.

**Output:**
```json
{"cliques": [["a","b","c"],["c","d"]], "count": 2, "max_size": 3}
```

### `count_triangles` / `get_clique_number`

Analogous CLI via same module; Python:

```python
from scripts.net_maximal_cliques import count_triangles, get_clique_number, iter_maximal_cliques
count_triangles(G)        # -> {"triangles": {"a":1}, "total": 1}
get_clique_number(G)      # -> {"clique_number": 3, "max_clique": ["a","b","c"]}
list(iter_maximal_cliques(G))  # stream iterator
```

## 14. `net_closeness_harmonic`

### `compute_closeness`

**Input:** `{graph, weight?, wf_improved?, + shared filters}`  **Output:**
```json
{"scores": {"a":0.6,"b":0.4}, "top": [["a",0.6]], "method": "closeness"}
```

### `compute_harmonic`

**Input:** `{graph, weight?, + shared filters}`  **Output:**
```json
{"scores": {"a":1.2,"b":0.8}, "top": [["a",1.2]], "method": "harmonic"}
```

## 15. `net_yen_k_shortest.find_yen_k_shortest_paths`

**Input:**
```json
{"graph": {...}, "source": "a", "target": "e", "k": 3, "weight": null, "+ shared filters"}
```
`k` 1..10, `weight` null → hop count. `source`/`target` required.

**Output:**
```json
{"paths": [["a","b","e"],["a","c","e"]], "costs": [2.0,2.0], "found": true, "count": 2, "k": 3, "source": "a", "target": "e"}
```

## 16. `net_steiner_tree.compute_steiner_tree`

**Input:**
```json
{"graph": {...}, "terminals": ["a","c","e"], "weight": "weight", "+ shared filters"}
```
`terminals` required, `len ≥ 3`.

**Output:**
```json
{"nodes": ["a","b","c","d","e"], "edges": [["a","b"],["b","c"]], "total_weight": 3.0, "terminal_count": 3, "steiner_nodes": ["b","d"], "approximation_ratio": "2-approx (Mehlhorn)", "connected": true}
```
`connected: false` → `total_weight: inf, reason: str` when terminals disconnected.

## 17. `net_widest_path.find_widest_bottleneck_path`

**Input:**
```json
{"graph": {...}, "source": "a", "target": "d", "weight": "weight", "+ shared filters"}
```
`source`/`target` required; same node → trivial path. `weight` missing falls back to hop-count capacity 1.

**Output:**
```json
{"path": ["a","c","d"], "bottleneck_capacity": 5.0, "hops": 2, "found": true, "source": "a", "target": "d"}
```
`found: false → path: []`.

## 18. `net_triad_census.compute_triad_census_16`

**Input:** `{graph, + shared filters}` (bare graph dict OK). Directed treated as directed; undirected projected to mutual dyads.

**Output:**
```json
{"census": {"003":5,"012":3,"102":1,"021D":0,"021U":0,"021C":0,"111D":0,"111U":0,"030T":0,"030C":0,"201":0,"120D":0,"120U":0,"120C":0,"210":0,"300":0}, "total_triads": 9, "n": 6, "directed": false, "motif_fingerprint": {"003":0.55}}
```
`motif_fingerprint` normalizes `census/total`. Keys sorted; all 16 present. Undirected 2-edge path among 3 nodes → type depends on mutual encoding.

## 19. `net_treewidth.estimate_treewidth`

**Input:**
```json
{"graph": {...}, "heuristic": "min-degree | min-fill | min-fill-in", "+ shared filters"}
```
`min-fill-in` alias for `min-fill`.

**Output:**
```json
{"treewidth_upper": 1, "max_bag_size": 2, "elimination_order": ["a","b","c"], "bags": [["a","b"],["b","c"]], "heuristic": "min-degree", "both_heuristics": {"min-degree": 1, "min-fill": 1}, "n": 3}
```

## 20. `net_bounded_apsp.compute_bounded_apsp`

**Input:**
```json
{"graph": {...}, "cutoff": 2, "sources": ["a","b"], "weight": null, "+ shared filters"}
```
`cutoff` 1..10 required; `sources` null → all nodes; `weight` null → hop count.

**Output:**
```json
{"distances": {"a": {"b":1.0,"c":2.0}}, "paths": {"a": {"b":["a","b"]}}, "cutoff": 2, "n": 5, "reachable_pairs": 8, "total_pairs": 20, "density": 0.4}
```
Self-distances `0.0` always included. Pairs beyond cutoff absent.

## 21. `net_preferential_attach.compute_preferential_attachment`

**Input:**
```json
{"graph": {...}, "ebunch": [["a","d"]], "top_k": 10, "+ shared filters"}
```
`ebunch` null → all non-edges. Scores sorted descending.

**Output:**
```json
{"scores": [["c","d",6],["a","d",4]], "candidate_count": 2, "method": "preferential_attachment", "top_k": 10}
```
`score = deg(u)·deg(v)` per NetworkX.

## 22. `net_katz_lp.compute_katz_link_index`

**Input:**
```json
{"graph": {...}, "beta": 0.1, "ebunch": [["a","b"]], "top_k": 10, "+ shared filters"}
```
`beta` ∈ (0,1) default `0.1` (must satisfy `β < 1/λ_max`). `ebunch`/`top_k` as above.

**Output:**
```json
{"scores": [["a","c",0.02],["b","d",0.01]], "candidate_count": 5, "method": "katz", "beta": 0.1, "top_k": 10}
```
`S = Σ β^k A^k` via Neumann/inverse.

---

## JSON Schema (Pydantic source → JSON Schema)

Base types from `core.contract`:

```python
from core.contract import GraphSpec, NodeSpec, EdgeSpec, Result
print(GraphSpec.model_json_schema())   # for external validation
```

CLI validation: every tool validates `GraphSpec` via `core.graph_loader.load_json` and filter/temporal params; bad input → `{"ok": false, "error": "..."}` at exit 1. See `core.contract.Result`.

## Error Handling (all 15 tools)

- Missing `source`/`target`/`terminals`/`k`/`cutoff`/`beta` → `ValueError` (CLI: `ok: false`).
- Invalid `heuristic`/`time_mode`/`limit` → `ValueError` / `CypherExtractorError`.
- In-memory graph at Cypher boundary → `CypherExtractorError` with demarcation message.
- Disconnected / no-path cases return `found: false` or `connected: false` (not exceptions) where applicable; score-only tools return `candidate_count: 0, scores: []`.
