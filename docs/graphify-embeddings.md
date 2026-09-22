# Graphify semantic and structural regions

`bin/fm-graphify-embed.py` enriches an existing Graphify JSON export without changing the input file.

The command reads `graphify-out/graph.json` by default, or the path supplied with `--input`.

It writes a visualization-ready JSON graph to the required `--output` path and a deterministic region plan beside it unless `--region-plan-output` is supplied.

## Run it

Configure the selected backend and model explicitly for each run.

Configure an endpoint when using the `openai` backend.

Keep any API credential in the environment instead of passing it as an argument.

```sh
OPENAI_API_KEY="$OPENAI_API_KEY" \
  bin/fm-graphify-embed.py \
  --backend openai \
  --input graphify-out/graph.json \
  --endpoint https://embedding.example.invalid/v1/embeddings \
  --model text-embedding-3-small \
  --threshold 0.82 \
  --top-k 3 \
  --output graphify-out/graph-semantic.json \
  --region-plan-output graphify-out/graph-semantic.regions.json
```

The default `openai` backend calls the configured OpenAI-compatible endpoint.

The `local` backend loads a standard sentence-transformers model in the current process and never calls an HTTP provider.

```sh
bin/fm-graphify-embed.py \
  --backend local \
  --model sentence-transformers/all-MiniLM-L6-v2 \
  --device cuda \
  --input graphify-out/graph.json \
  --threshold 0.82 \
  --top-k 3 \
  --output graphify-out/graph-semantic.json \
  --region-plan-output graphify-out/graph-semantic.regions.json
```

Install `sentence-transformers` and a CUDA-enabled PyTorch build before selecting the local backend with `--device cuda`.

CUDA requests fail when PyTorch cannot report an available CUDA device, and the tool never falls back to CPU.

## Structural splitting without embeddings

The `structural` backend requires no embedding provider, model, credential, or network access.

```sh
bin/fm-graphify-embed.py \
  --backend structural \
  --input graphify-out/graph.json \
  --threshold 0.82 \
  --top-k 3 \
  --output graphify-out/graph-structural.json \
  --region-plan-output graphify-out/graph-structural.regions.json
```

Structural regions are deterministic weakly connected components of valid original graph edges, with edge direction ignored and prior semantic edges excluded.

Structural output nodes receive `structural_region_id`, and the region plan records `strategy: structural_ast`.

The structural path preserves every original edge, including edges whose endpoints are absent from the node set.

`--endpoint` may name an OpenAI-compatible `/embeddings` route or a base URL to which `/embeddings` is appended.

The endpoint must be an absolute HTTP or HTTPS URL.


`--region-plan-output` selects the Luna and Jev handoff artifact path.

When it is omitted, `graph-semantic.json` produces `graph-semantic.regions.json`.

The endpoint and model may instead come from `GRAPHIFY_EMBEDDINGS_ENDPOINT` and `GRAPHIFY_EMBEDDINGS_MODEL` when a local wrapper needs environment configuration.

`--threshold`, `--top-k`, and `--output` are required for every run, while `--model` is required only for embedding backends.

The default credential variable is `OPENAI_API_KEY`, and `--api-key-env NAME` selects another environment variable without exposing its value to the process arguments or diagnostics.

A provider that does not require authentication may omit the credential variable.

The tool sends JSON requests shaped like the OpenAI embeddings API: `{"input": [...], "model": "..."}`.

It accepts the standard response shape `{"data": [{"index": 0, "embedding": [...]}, ...]}` and rejects missing, non-finite, empty, inconsistent, or duplicate vectors.

Provider failures report only an HTTP status or a safe connection or response error, never the response body or authorization header.

## Fingerprints and clustering

Each embedding input is a canonical JSON fingerprint, not a prose summary.

The fingerprint contains the node label, source path, sorted incident relation types, and at most twelve sorted neighbor records containing direction, relation type, and neighbor label.

The reader accepts Graphify node arrays or id-keyed node objects.

It recognizes common node fields including `id`, `label`, `name`, `title`, `source_path`, `sourcePath`, `file_path`, `filePath`, `path`, and `file`.

It recognizes common edge endpoint fields including `source`/`target`, `from`/`to`, and `src`/`dst`.

It recognizes `relation`, `type`, `kind`, `label`, and `edge_type` as relation fields.

Edges with unknown endpoint ids are preserved in the output but omitted from fingerprints, local neighbors, and region summaries.

Other malformed graph structures stop the command safely.

Cosine similarity is computed locally from the returned vectors.

For each node, candidates at or above `--threshold` are sorted by descending similarity and then node id, and only the first `--top-k` candidates become semantic edges.

Threshold-qualified edges form connected components, so no predefined taxonomy or cluster count is required.

Each component receives a stable `semantic-cluster-<sha256-prefix>` identifier derived from its sorted node ids.

Output nodes receive `semantic_cluster_id`.

If an input node already has that field, the tool uses `graphify_semantic_cluster_id` so the input value is preserved.

Output edges retain every original edge and append `type` and `relation` set to `semantically_similar_to`, with a numeric `similarity` score.

The tool never removes authoritative AST edges and never writes the input path in place.

Repeated runs with identical input, provider vectors, threshold, and top-k produce the same semantic identifiers, edge ordering, and region plan.

## Region plan artifact

The region plan is JSON with schema `graphify-region-plan/v1`.

It contains no generated prose and is intended as a bounded navigation index for a host agent.

Each `clusters` entry contains the stable `cluster_id`, complete sorted `node_ids`, `node_count`, unique sorted `source_paths`, and a sorted `relation_summary`.

Each `relation_summary` item records one original Graphify relation and its number of incident original edges in that cluster.

Each cluster contains at most three `representative_nodes`, selected by descending local AST degree and then ascending node id.

Each representative node contains its id, label, source path, incident relation types, and at most twelve bounded local AST neighbors.

`cross_region_links` aggregates original AST edges whose source and target belong to different semantic clusters.

Each cross-region link records the source and target cluster ids, relation, edge count, and at most three sorted endpoint examples.

Semantic edges are not used as cross-region links because threshold-connected nodes already define the regions.

## Luna and Jev handoff

The host agent may give Luna the region plan and visualization graph so Luna can inspect structural or embedding regions and local AST context.

Luna's output is navigation and classification guidance for the host agent, not an authoritative source classification.

The host agent must give Jev the source paths from the region plan and require Jev to read the underlying source directly for final classification.

The region plan is an index and must not replace direct source reading by Jev.

This command does not invoke Jev, call a free-form generation endpoint, or assume that a Jev embeddings endpoint exists.

Any future Jev adapter requires an explicitly verified request and response contract, a configured endpoint, and a configured credential before integration.

An absent contract or credential is an actionable prerequisite, not a reason to invent a fallback endpoint.

The command performs structural region planning or embedding graph enrichment and never performs final Jev classification.

## Persistent navigation viewer

`bin/fm-graphify-viewer.py` serves a local Svelte and Sigma viewer backed by the Graphify graph and optional structural and call artifacts.

Build the bundled frontend once before starting the server.

```sh
(cd web && npm install && npm run build)
bin/fm-graphify-viewer.py \
  --graph graphify-out/graph.json \
  --structural graphify-out/graph-semantic.regions.json \
  --calls graphify-out/calls.json \
  --source-root . \
  --host 127.0.0.1 \
  --port 8765
```

The server exposes `/api/scene` as one bounded multilevel scene containing folder clusters, structural regions, file or module, and function nodes with stable parent and cluster IDs plus aggregated call and containment edges.
The compatibility `/api/subgraph?level=region`, `/api/subgraph?level=file`, and `/api/subgraph?level=function` endpoints remain available for focused API consumers.
Node roles are classified once by the server as test, leaf, function or method, file or module, structural region, or topology cluster, and the viewer keeps those role colors across levels with a neutral selected-state ring.
Folder clusters use source paths when available and fall back to stable node namespaces, rather than selecting a fixed number of labels from the render cap.
The viewer uses a deterministic ForceAtlas2 layout once, then Sigma reducers use the continuous camera ratio to reveal bounded cluster, region, file, and function labels and edges without fetching or rebuilding the graph on zoom.
The viewer supports wheel navigation, search, source inspection, and bounded rendering.
The viewer polls `/api/health` and rebuilds the persistent scene after the graph, structural artifact, or call artifact modification time changes.

A Graphify export hook can regenerate those artifacts in place while the server remains running, and the next health poll refreshes the viewer without restarting it.

`--max-visible` bounds every API response and the rendered graph, while `--frontend` selects a separately built Svelte asset directory when packaging the server.

The server keeps the Graphify input authoritative and never writes any graph or source artifact.
