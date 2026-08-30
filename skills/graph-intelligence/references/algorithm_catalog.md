# Algorithm Catalog — graph-intelligence (15 Tools)

> Full mathematical formulas, complexity, and NetworkX mapping for every algorithm.
> All 15 tools are pure-Python, deterministic, and dual-mode (import + CLI via `core.contract`).

## Complexity Table (all 15)

| # | Tool | Script | Function(s) | Time | Space | Directed? | Weighted? |
|---|------|--------|-------------|------|-------|-----------|-----------|
| 1 | Connected Components | `net_components` | `compute_components` | O(n+m) | O(n) | weak/strong | no |
| 2 | Largest Connected Component | `net_components` | `isolate_lcc` | O(n+m) | O(n) | weak/strong | no |
| 3 | Bridges & Articulation Points | `net_components` | `find_bridges_and_articulation_points` | O(n+m) | O(n) | undirected view | no |
| 4 | K-Core Decomposition | `net_kcore_onion` | `compute_kcore` | O(n+m) | O(n) | undirected view | no |
| 5 | Onion Layers | `net_kcore_onion` | `compute_onion_layers` | O(n+m) | O(n) | undirected view | no |
| 6 | Constrained Shortest Path | `net_constrained_paths` | `find_constrained_path` | O(m log n) | O(n) | yes | yes |
| 7 | Bounded Random Walks | `net_constrained_paths` | `sample_bounded_random_walks` | O(walks·steps) | O(walks·steps) | yes | yes |
| 8 | Betweenness Centrality | `net_centrality` | `compute_betweenness` | O(nm) exact; O(km) sampled | O(n+m) | yes | yes |
| 9 | Katz Centrality | `net_centrality` | `compute_katz` | O(iter·(n+m)) | O(n+m) | yes | yes |
| 10 | Harmonic Centrality (fallback) | `net_centrality` | `compute_harmonic_fallback` | O(n(m+n log n)) | O(n) | yes | yes |
| 11 | Adamic-Adar / Resource Allocation | `net_link_prediction` | `predict_links_aa_ra` | O(Σ deg²) over candidates | O(n) | undirected view | no |
| 12 | Heider Balance (signed triangles) | `net_link_prediction` | `evaluate_heider_balance` | O(n·d²) triangles | O(n) | undirected view | signed |
| 13 | Maximal Cliques | `net_maximal_cliques` | `find_maximal_cliques`, `iter_maximal_cliques`, `count_triangles`, `get_clique_number` | O(3^{n/3}) worst; linear on sparse | O(n+m) | undirected view | no |
| 14 | Closeness / Harmonic (broadcast) | `net_closeness_harmonic` | `compute_closeness`, `compute_harmonic` | O(n(m+n log n)) | O(n) | yes | yes |
| 15 | Yen K-Shortest Paths | `net_yen_k_shortest` | `find_yen_k_shortest_paths` | O(K·n(m+n log n)) | O(Kn) | yes | yes |
| 16 | Steiner Tree (Mehlhorn 2-approx) | `net_steiner_tree` | `compute_steiner_tree` | O(t(m+n log n)) t=terminals | O(n+m) | undirected view | yes |
| 17 | Widest / Bottleneck Path | `net_widest_path` | `find_widest_bottleneck_path` | O(m log n) | O(n) | yes | yes |
| 18 | Triad Census (16 types) | `net_triad_census` | `compute_triad_census_16` | O(n³) enumeration | O(n) | directed | no |
| 19 | Treewidth (elimination heuristics) | `net_treewidth` | `estimate_treewidth` | O(n(n+m)) | O(n+m) | undirected view | no |
| 20 | Bounded APSP (cutoff ≤3) | `net_bounded_apsp` | `compute_bounded_apsp` | O(s(m+n log n)) s=sources | O(s·n) | yes | yes |
| 21 | Preferential Attachment | `net_preferential_attach` | `compute_preferential_attachment` | O(n²) candidates; O(1) per pair | O(n) | undirected view | no |
| 22 | Katz Link Prediction | `net_katz_lp` | `compute_katz_link_index` | O(n³) inverse / O(iter·n²) | O(n²) | undirected view | no |

> The skill exposes 15 script modules. Several scripts export >1 `dual_mode` function, yielding 22 callable entry points. The router in `SKILL.md` maps intents to the 15 modules.

---

## 1. Connected Components — `net_components.compute_components`

**Formula:** Partition V into maximal connected subgraphs.
- Undirected: DFS/BFS equivalence classes.
- Directed weak: underlying undirected connectivity.
- Directed strong: Kosaraju / Tarjan SCC.

**Complexity:** O(n+m).

**NetworkX:** `nx.connected_components` / `nx.weakly_connected_components` / `nx.strongly_connected_components`.

---

## 2. Largest Connected Component — `net_components.isolate_lcc`

**Formula:** `LCC = argmax_{C ∈ components} |C|`. Returns interchange dict of the induced subgraph plus `lcc_size`, `total_components`.

**Complexity:** O(n+m).

**NetworkX:** `max(nx.connected_components(G), key=len)` then `G.subgraph(LCC)`.

---

## 3. Bridges & Articulation Points — `net_components.find_bridges_and_articulation_points`

**Formula (Tarjan DFS):**
- `low[v] = min(disc[v], disc[w] for back-edge (v,w), low[child])`.
- Bridge `(u,v)` iff `low[v] > disc[u]` where v is DFS child of u.
- Articulation `u` iff `low[child] ≥ disc[u]` for any child (root needs ≥2 children).

**Complexity:** O(n+m).

**NetworkX:** `nx.bridges` (undirected), `nx.articulation_points`.

---

## 4. K-Core Decomposition — `net_kcore_onion.compute_kcore`

**Formula:** Iterative peel: repeatedly delete nodes with degree < k. Remaining is the k-core.
`core_number(v) = max k such that v ∈ k-core`. `degeneracy = max_v core_number(v)`.

**Complexity:** O(n+m) (Batagelj-Zaversnik bucket queue).

**NetworkX:** `nx.core_number`, `nx.k_core(G, k)`.

---

## 5. Onion Layers — `net_kcore_onion.compute_onion_layers`

**Formula:** Layer = peeling round in which v is removed during k-core decomposition. `layer(v) ≥ core_number(v)` with ties broken by queue order. Produces `layers: {layer → [nodes]}`.

**Complexity:** O(n+m).

**NetworkX:** `nx.onion_layers`.

---

## 6. Constrained Shortest Path — `net_constrained_paths.find_constrained_path`

**Formula:** Dijkstra with pruning: `dist[v] = min_{u→v} dist[u] + w(u,v)` subject to `depth ≤ max_depth`, `cost ≤ max_cost`, and forbidden `avoid_nodes / avoid_edges` removed before search.

**Complexity:** O(m log n).

**NetworkX:** `nx.dijkstra_path` / `nx.shortest_path` with pre-filtered graph.

---

## 7. Bounded Random Walks — `net_constrained_paths.sample_bounded_random_walks`

**Formula:** From `start`, repeat `num_walks` walks of length ≤ `walk_length` (or `max_depth`), uniform neighbor sampling at each step, optionally weighted.

**Complexity:** O(walks · steps).

**NetworkX:** Pure Python loop over `G.neighbors`.

---

## 8. Betweenness Centrality — `net_centrality.compute_betweenness`

**Formula (Brandes):**
`C_B(v) = Σ_{s≠v≠t} σ_{st}(v) / σ_{st}` normalized by `2/((n-1)(n-2))` when `normalized=True`.
`k`-sampling: approximate over k pivot sources with seed.

**Complexity:** O(nm) exact; O(km) with k-sampling.

**NetworkX:** `nx.betweenness_centrality`.

---

## 9. Katz Centrality — `net_centrality.compute_katz`

**Formula:** `x = (αA^T + β·1)` solved iteratively; `x_i = α Σ_j A_{ji} x_j + β`. Auto α = `0.9/(max_degree+1)`. Falls back to `α/2` on non-convergence, then `katz_centrality_numpy`, then degree.

**Complexity:** O(iter·(n+m)).

**NetworkX:** `nx.katz_centrality`, `nx.katz_centrality_numpy`.

---

## 10. Harmonic Centrality — `net_centrality.compute_harmonic_fallback`

**Formula:** `C_H(v) = Σ_{u≠v} 1/dist(v,u)` (unreachable = 0). Handles disconnected graphs naturally. Single-node → 0. Falls back to closeness on error.

**Complexity:** O(n(m+n log n)).

**NetworkX:** `nx.harmonic_centrality`.

---

## 11. Adamic-Adar & Resource Allocation — `net_link_prediction.predict_links_aa_ra`

**Formulas:**
- AA: `AA(u,v) = Σ_{w ∈ Γ(u)∩Γ(v)} 1/log|Γ(w)|`
- RA: `RA(u,v) = Σ_{w ∈ Γ(u)∩Γ(v)} 1/|Γ(w)|`

Scored over all non-edges (or `ebunch`), `top_k` per metric.

**Complexity:** O(Σ deg²) over candidate neighborhoods.

**NetworkX:** `nx.adamic_adar_index`, `nx.resource_allocation_index`.

---

## 12. Heider Balance — `net_link_prediction.evaluate_heider_balance`

**Formula (signed triangles):** Triangle `(a,b,c)` balanced iff `sign(a,b)·sign(b,c)·sign(a,c) > 0` (even number of negative edges). Reports `balanced_triangles / unbalanced_triangles`.

**Complexity:** O(n·d²).

**NetworkX:** Custom enumeration over `nx.triangles` + sign attribute.

---

## 13. Maximal Cliques — `net_maximal_cliques`

**Formulas:**
- Bron–Kerbosch with pivot: enumerate all maximal cliques without duplication.
- `count_triangles`: per-node and total triangle count.
- `clique_number`: size of the largest maximal clique (= ω(G)).

**Complexity:** O(3^{n/3}) worst-case; near-linear on sparse graphs.

**NetworkX:** `nx.find_cliques` (Bron–Kerbosch), `nx.triangles`, `nx.graph_clique_number`.

---

## 14. Closeness & Harmonic (broadcast seeds) — `net_closeness_harmonic`

**Formulas:**
- Wasserman–Faust closeness (disconnected-safe): `C(v) = (reachable/(n-1)) · (reachable / Σ_{u reachable} dist(v,u))`
- Harmonic (same as §10 but with per-component broadcast seed selection for independent validation).

**Complexity:** O(n(m+n log n)).

**NetworkX:** `nx.closeness_centrality` with `wf_improved=True`, `nx.harmonic_centrality`.

---

## 15. Yen K-Shortest Paths — `net_yen_k_shortest.find_yen_k_shortest_paths`

**Formula (Yen):** Iteratively deviate from each prefix of the current best path, run Dijkstra from spur node with root-path nodes/edges excluded, collect candidates in a min-heap. K ≤ 10.

**Complexity:** O(K·n(m+n log n)).

**NetworkX:** `nx.shortest_simple_paths` (Yen variant).

---

## 16. Steiner Tree (Mehlhorn 2-approx) — `net_steiner_tree.compute_steiner_tree`

**Formula (Mehlhorn):**
1. Metric closure: `d(t_i,t_j) = dist_G(t_i,t_j)` via Dijkstra from each terminal (t = |T|).
2. MST over complete graph `K_T` weighted by d.
3. Expand each MST edge to its shortest path in G; union edges.
4. Prune non-terminal leaves iteratively. Ratio ≤ 2.

**Complexity:** O(t(m+n log n)).

**NetworkX:** `nx.single_source_dijkstra` + `nx.minimum_spanning_tree`.

---

## 17. Widest / Bottleneck Path — `net_widest_path.find_widest_bottleneck_path`

**Formula (modified Dijkstra):** `capacity[v] = max_{path s→v} min_{e∈path} w(e)`. Relax via maximin: `if min(cap[u], w(u,v)) > cap[v]` then update. Same source = trivial path.

**Complexity:** O(m log n) (max-heap).

**NetworkX:** Custom max-heap Dijkstra (no direct NetworkX equivalent; `nx.dijkstra_path` with negated/minimax).

---

## 18. Triad Census (16 types) — `net_triad_census.compute_triad_census_16`

**Formula (Davis–Leinhardt):** Enumerate each 3-node subset; classify by `{m,a,s}` = mutual/asymmetric/null dyads into 16 types: `003,012,102,021D,021U,021C,111D,111U,030T,030C,201,120D,120U,120C,210,300`. Also returns `motif_fingerprint = census/total`.

**Complexity:** O(n³).

**NetworkX:** `nx.triad_census` / `nx.triads.triad_type`.

---

## 19. Treewidth (elimination heuristics) — `net_treewidth.estimate_treewidth`

**Formula:** Elimination ordering heuristic; `treewidth_upper = max_bag_size - 1` where each eliminated node creates a bag `{v} ∪ neighbors` and fills missing edges. Two heuristics computed; best returned: min-degree vs min-fill-in.

**Complexity:** O(n(n+m)).

**NetworkX:** No single function; uses `nx.Graph` fill-in loops (related: `nx.approximation.treewidth_min_degree` in newer versions).

---

## 20. Bounded APSP (cutoff d≤3) — `net_bounded_apsp.compute_bounded_apsp`

**Formula:** Repeated Dijkstra from each `source` (or all nodes), truncate at `cutoff ≤10` (default 2–3). Also returns `paths`, `reachable_pairs`, `density`, `total_pairs`. Results LRU-cached per graph signature.

**Complexity:** O(s(m+n log n)) where s = |sources|.

**NetworkX:** `nx.single_source_dijkstra` with cutoff.

---

## 21. Preferential Attachment — `net_preferential_attach.compute_preferential_attachment`

**Formula:** `PA(u,v) = |Γ(u)| · |Γ(v)|` (degree product). O(1) per candidate pair. Baseline ranker for link prediction.

**Complexity:** O(n²) candidates.

**NetworkX:** `nx.preferential_attachment`.

---

## 22. Katz Link Prediction — `net_katz_lp.compute_katz_link_index`

**Formula (global Katz):** `S = Σ_{k≥1} β^k A^k = (I - βA)^{-1} - I` with Neumann/inverse; `β < 1/λ_max`. Scores every non-edge by `S[u,v]`.

**Complexity:** O(n³) inverse; O(iter·n²) iterative.

**NetworkX:** `nx.katz_centrality_numpy` family (link variant via adjacency powers).

---

## References

- Brandes 2001 — Betweenness via BFS/Dijkstra.
- Batagelj & Zaversnik 2003 — O(m) k-core.
- Bron–Kerbosch 1973 — Maximal cliques.
- Yen 1971 — K-shortest loopless paths.
- Mehlhorn 1988 — 2-approximation Steiner tree.
- Davis & Leinhardt 1972 — Triad census.
- Wasserman & Faust 1994 — Closeness normalization.
