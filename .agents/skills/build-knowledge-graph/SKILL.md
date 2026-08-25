---
name: build-knowledge-graph
description: Construct a verified, embedded Knowledge Graph (LadybugDB/Kuzu) from long-form text or book chapters using parallel dual-agent chunking (extractor + quote-verifier), alias disambiguation, PageRank/Leiden enrichment, and a fast Cypher CLI. Trigger when creating a knowledge graph from documents, books, lore bibles, or canon corpora.
metadata:
  internal: true
---

# Build Knowledge Graph

Construct a verified, zero-hallucination, embedded Knowledge Graph from any book, document corpus, or narrative text.

Canonical source: this skill is the authoritative home of the pipeline scripts.
When a repo copy and this skill's scripts diverge, the skill is the reference; sync the repo from it, never the reverse.

## 5 Core Quality Pillars

1. **Letter-Exact Quote Match with Boundary**: Every relationship must carry a non-empty quote whose lowercased letters-only form (digits kept, punctuation and whitespace dropped) appears contiguously in the source chapter text, with the quote's first and last words matching the source sentence boundaries. Mismatched, paraphrased, or mid-word-truncated quotes are rejected. Rejects go to `staging/quarantine.jsonl` with a reason for a follow-up fix pass, never silently dropped.
2. **Zero Entity Collisions (Canonical Disambiguation)**: All name variations ("Harry", "HJPEV", "Potter") resolve to a single canonical node ID.
3. **Zero Orphan Nodes**: Every node must have degree >= 1 connected to at least one valid relationship.
4. **Strict Schema Typing**: All nodes and edges conform to the closed type ontology (see `references/SCHEMA_GUIDE.md`).
5. **Epistemic & Temporal Grounding**: Tracking when facts/beliefs become active or change across chapters.

---

## 5-Phase Sequential Workflow

### Phase 1: Initialize Workspace & Schema
1. Create project repo / directory layout: `data/`, `staging/`, `scripts/`, `gold/`.
2. Initialize LadybugDB / Kuzu schema using `scripts/incremental_db.py`.
3. Set up chapter text cache in `.cache/chapters/`.

- **Completion Criterion**: DB initialized, test schema passes `exit code 0`.

### Phase 2: Parallel Dual-Agent Chunk Extraction
1. Split corpus into $k$ independent chapter chunks.
2. For each chunk, assign an isolated **Dual-Agent Pair** (1 Extractor + 1 Verifier):
   - **Extractor Agent**: Reads chapter text, outputs JSON with `{entities, relations, quotes}` into `staging/chunk_<id>.json`.
   - **Verifier Agent**: Runs `scripts/verify_chunk.py --input staging/chunk_<id>.json --chapters <N-M>`. Checks letter-exact quote match with boundary (see pillar 1) and schema integrity. Writes `staging/chunk_<id>_verifier_report.json` and creates git commit on branch `fm/chunk-<id>-verifier`.
3. **Invariant**: Extractor never verifies its own output; Verifier must audit and commit independently.

- **Completion Criterion**: 100% chunks have signed verifier report JSON with 0 quote failures and git commit.

### Phase 3: Alias Resolution & Master Ingestion
1. Collect all verified chunk JSON files from `staging/`.
2. Run `scripts/resolve_aliases.py` to map name variations to canonical entity IDs.
3. Run `scripts/incremental_db.py` to ingest all chunks into master `data/kg.lbug` with ACID transactions.

- **Completion Criterion**: `data/kg.lbug` contains all entities, rels, quotes; 0 orphan nodes; 0 dangling edges.

### Phase 4: Graph Analytics Enrichment
1. Run `scripts/export_graph.py` on master `data/kg.lbug`.
2. Computes NetworkX PageRank ($lpha=0.85$) and Leiden Community Detection (`seed=42`).
3. Writes `pagerank_score` and `community` properties directly back into entity nodes.

- **Completion Criterion**: 100% entity nodes have `pagerank_score > 0` and integer `community >= 0`.

### Phase 5: Gold Benchmark & CLI Delivery
1. Author 20 QA benchmark queries in `gold/questions.yaml` (Fact lookups, Multi-hop relations, Epistemic/Analytics).
2. Run `scripts/run_eval.py` to compute pass-rate and generate forensic gap report.
3. Deliver `kg.py` CLI (`read_only=True` for query mode, ACID transactions for update mode) and `CHEATSHEET.md` with 15 canonical Cypher patterns (see `references/CYPHERS_15.md`).
4. Update `README.md` with exact corpus statistics and tag release `v1.0.0`.

- **Completion Criterion**: Benchmark pass-rate verified; `kg.py query` executes in < 10ms; release committed.

---

## Anti-Overengineering Self-Check

Before and during execution, ask these 4 diagnostic questions whenever progress stalls:
1. What is the simplest way a human would type this command directly in the terminal?
2. Is there an existing CLI or tool that runs this in 1 step without writing a wrapper script?
3. If a task is hanging or taking too long, am I adding unnecessary complexity?
4. Is there an intermediate step or file that can be removed while keeping the output correct?

---

## Key Gotchas & Rules

- **LadybugDB Concurrency**: Always pass `read_only=True` when opening `ladybug.Database` for read queries. Omitting this acquires an exclusive write-lock, causing `Resource temporarily unavailable` when multiple processes query concurrently.
- **Kuzu/LadybugDB Cypher Dialect**: Use `label(r)` instead of Neo4j's `type(r)`; use 2-arg `round(score, 4)`; use curly braces for relationship properties in CREATE (`CREATE (a)-[:TYPE {props}]->(b)`).
- **Non-Lazy Prompting**: Prompts sent to worker panes must include absolute paths, input/output JSON schemas, checklists, and explicit exit sentinels.
