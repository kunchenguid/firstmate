# Cypher Extract Patterns — graph-intelligence

> How to project data OUT of external Cypher-capable databases (Neo4j, LadybugDB, DuckDB+extension)
> into in-memory NetworkX graphs for local analytics. Transport is stdlib-only via `core.cypher_extractor`.
>
> **DEMARCATION:** `core.cypher_extractor` is for EXTERNAL databases only.
> In-memory NetworkX filtering belongs to `core.filter_engine` (zero-copy `nx.subgraph_view`).
> The guard `assert_external_backend(nx.Graph)` refuses in-memory graphs at the Cypher boundary.

## Connection — `CypherHttpExtractor`

```python
from core.cypher_extractor import CypherHttpExtractor

ext = CypherHttpExtractor(
    uri="http://localhost:7474",
    username="neo4j",
    password="secret",
    database="neo4j",   # default
    timeout=30.0,
)
```

HTTP transactional endpoint: `{uri}/db/{database}/tx/commit`. Auth is Basic over `urllib` (stdlib). Inject a `transport(url, body, headers) -> (status, parsed_json)` callable for tests.

## Building Parameterized Queries

```python
from core.cypher_extractor import build_match_query, CypherQuery

# Node-only projection
q = build_match_query("Person", properties={"status": "active"}, limit=1000)
# -> MATCH (n:`Person` {status: $p_status}) RETURN n LIMIT 1000

# Relationship projection (directed)
q = build_match_query("Person", relationship="KNOWS", properties={"chapter": 2})
# -> MATCH (n:`Person` {chapter: $p_chapter})-[r:`KNOWS`]->(m) RETURN n, r, m

# Raw CypherQuery for custom patterns
from core.cypher_extractor import CypherQuery
q = CypherQuery(
    statement="MATCH (a:Person)-[r:KNOWS]->(b:Person) WHERE r.weight > $min_w RETURN a, r, b",
    parameters={"min_w": 0.5},
)
```

Property values become `$param` placeholders — never interpolated — so queries are injection-safe. Labels and property keys are validated alphanumerically (plus `_`/`-`).

## Executing & Materializing

```python
from core.cypher_extractor import graph_from_records

rows: list[dict] = ext.run(q)                          # str or CypherQuery
rows2: list[dict] = ext.run("MATCH (n) RETURN n LIMIT 5")  # raw Cypher string

# Materialize rows into NetworkX (directed by default)
G = graph_from_records(rows, directed=True)

# Row shapes understood by graph_from_records:
# - Neo4j node JSON: {"identity": ..., "labels": [...], "properties": {...}}
# - Neo4j relationship JSON: {"type": "KNOWS", "start": id, "end": id, "properties": {...}}
# - Plain id strings / {"id": str, ...props}
```

Node `identity` / `elementId` / `properties.id` are merged into string ids; `_labels` preserved under `node["_labels"]`. Relationships become directed edges with `_type`.

## Pattern Library (10 reusable extracts)

### 1. Full graph projection

```cypher
MATCH (n) OPTIONAL MATCH (n)-[r]->(m) RETURN n, r, m
```

### 2. Label-filtered subgraph

```cypher
MATCH (n:Character {status: "active"}) RETURN n
```
Python: `build_match_query("Character", properties={"status": "active"})`

### 3. Relationship-type projection

```cypher
MATCH (a)-[r:ALLY_OF|RIVAL_OF]->(b) RETURN a, r, b
```
Python: custom `CypherQuery` with multi-type pattern.

### 4. Time-sliced projection (scalar `chapter`)

```cypher
MATCH (n) WHERE n.chapter = $at OR n.chapter IS NULL RETURN n
UNION
MATCH (a)-[r]->(b) WHERE r.chapter = $at OR r.chapter IS NULL RETURN a, r, b
```
Then apply `core.temporal.slice_at(G, "chapter", at)` if intervals also present. For pure retrieval, `WHERE n.chapter <= $at` (as-of) or `WHERE n.chapter IN range($start, $end)`.

### 5. Interval-window projection

Nodes/edges store `chapter: {start: 3, end: 7}` or split `chapter_start`/`chapter_end`:
```cypher
MATCH (n) WHERE n.chapter.start <= $end AND (n.chapter.end IS NULL OR n.chapter.end >= $start) RETURN n
```
Mirrors `core.temporal.window` window-overlap logic.

### 6. K-hop neighborhood around a seed

```cypher
MATCH (seed:Character {id: $seed_id})
MATCH path = (seed)-[*1..3]-(neighbor)
RETURN neighbor, relationships(path) AS rels, nodes(path) AS hops
```
Or via APOC: `CALL apoc.path.expandConfig(seed, {maxLevel: 3})`.

### 7. Edge-weighted threshold filter (pre-analytic)

```cypher
MATCH (a)-[r {weight: w}]->(b) WHERE r.weight >= $min_weight RETURN a, r, b
```

### 8. Largest Connected Component seed (fetch then run `isolate_lcc` locally)

```cypher
MATCH (n) RETURN n
MATCH ()-[r]->() RETURN r    -- fetch separately or combined
```
Then locally: `from scripts.net_components import isolate_lcc; isolate_lcc(G)`.
Do NOT attempt LCC via Cypher — graph algorithms run locally.

### 9. Link-prediction candidate collection (open triads)

```cypher
MATCH (a:Character)-[:ALLY_OF]-(w)-[:ALLY_OF]-(b:Character)
WHERE a <> b AND NOT (a)-[:ALLY_OF]-(b)
RETURN a.id AS source, b.id AS target, count(w) AS commonNeighbors
```
Score locally via `predict_links_aa_ra(G)` for exact AA/RA.

### 10. Signed-triangle balance pre-filter

```cypher
MATCH (a)-[r1]-(b)-[r2]-(c)-[r3]-(a)
WHERE r1.sign IS NOT NULL AND r2.sign IS NOT NULL AND r3.sign IS NOT NULL
RETURN a, r1, b, r2, c, r3
```
Then locally: `evaluate_heider_balance(G)`.

## External DB Notes

| Database | Endpoint | Notes |
|----------|----------|-------|
| Neo4j 4.x/5.x | `http://host:7474/db/{db}/tx/commit` | Native Cypher; `Neo4j` label quoting supported |
| LadybugDB | Same transactional HTTP shape | Cypher subset; test your dialect via `transport` stub |
| DuckDB + `duckpgq` | In-process, not HTTP | Use `graph_from_records` only after exporting rows externally; or inject a DuckDB transport |

## Anti-patterns (refused at the boundary)

- Passing an `nx.Graph` to `CypherHttpExtractor.run` → `CypherExtractorError` via `assert_external_backend`.
- Cypher for in-memory filtering — use `core.filter_engine` / `core.temporal`.
- Interpolating user input into statement strings — use `parameters` dict.

## Testing without a live DB

```python
from core.cypher_extractor import CypherHttpExtractor, graph_from_records

def fake_transport(url, body, headers):
    return 200, {"results": [{"columns": ["n"], "data": [{"row": [{"identity": 1, "labels": ["X"], "properties": {"id": "a"}}]}]}], "errors": []}

ext = CypherHttpExtractor("http://fake", "u", "p", transport=fake_transport)
rows = ext.run("MATCH (n) RETURN n")
G = graph_from_records(rows)
assert "a" in G
```
