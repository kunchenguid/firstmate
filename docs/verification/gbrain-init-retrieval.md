# GBrain local retrieval and MiniMax verification

This record captures the active GBrain installation, local retrieval evidence, and the explicit hosted synthesis boundary.
The evidence was refreshed on 2026-08-04.

## Version and installation evidence

GBrain `v0.42.69.0` is installed from the pinned source checkout at `/home/sungin/.local/gbrain/src`.
GBrain's native MiniMax recipe change is commit `fecd331f0247c7ff224a3723268233a62799425b` from 2026-07-23.
`git tag --contains` identified `v0.42.69.0` as the first release tag containing that change.
The installed CLI reported `gbrain 0.42.69.0`.
The source installation used Bun `1.3.14`, GBrain's documented `git clone` plus `bun install && bun link` fallback, and a repository-local Bun cache.
GBrain migrations spawn `gbrain` by name, so the local bin directory must be prepended to `PATH` for `apply-migrations`.
The migration runner installed `gbrain-autopilot.service` as a side effect.
`gbrain autopilot --uninstall` removed that unit, and `systemctl --user` then reported it `not-found` and `inactive`.

The v0.42.71.0 and v0.42.72.1 standalone Linux binaries both failed the end-user PGLite initialization path before a brain was configured.
Each printed `Extension bundle not found: file:///$bunfs/vector.tar.gz` and `Extension bundle not found: file:///$bunfs/pg_trgm.tar.gz`.
The v0.42.69.0 release has no standalone binary asset.
The pinned source installation is therefore the verified functional installation path.

## Local retrieval configuration and health

PGLite initialized at `/home/sungin/.local/share/gbrain/pglite` with `snowflake-arctic-embed2:568m` and `1024` dimensions.
The successful initialization reported `120 migration(s) applied` and `embedding_check` with `ok: true` and `live_ok: true`.
The runtime configuration lives under `GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime`.

`gbrain models doctor --skip=anthropic --json` reported all four local checks as `ok`.
Those checks were the 1024-dimensional embedding configuration, reranker configuration, embedding reachability, and reranker reachability.
The reranker used `llama-server-reranker:qwen3-reranker-0.6b-q8_0` at `http://127.0.0.1:8081/v1`.
The MiniMax routing used `models.think=minimax:MiniMax-M3` and `provider_base_urls.minimax=https://api.minimax.io/v1`.

## Archive and local-network evidence

The archive at `/home/sungin/.local/share/gbrain/archive` is a remote-less Git repository with 27 representative Firstmate markdown documents.
GBrain imported 27 pages and created 190 chunks.
The local embedding pass embedded 181 chunks, then the incremental import added nine already embedded chunks.

`gbrain search 'snowflake arctic embed2' --limit 5` returned `firstmate-docs/gbrain-endpoints` first.
The local hybrid retrieval command below returned the embedding endpoint and both endpoint-verification documents in its first four results:

```sh
env -i PATH=/usr/bin:/bin HOME=/home/sungin \
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  strace -f -e trace=connect \
  -o /home/sungin/.local/share/gbrain/runtime/local-query-connect.log \
  /home/sungin/.local/gbrain/bin/gbrain query \
  'Which local endpoints provide embeddings and reranking for GBrain?' \
  --no-expand --limit 5
```

The trace contained exactly the expected inference connections: `127.0.0.1:11434` for Ollama and `127.0.0.1:8081` for llama-server reranking.
No cloud embedding or reranking connection appeared in the trace.

## Hosted MiniMax synthesis boundary

With `MINIMAX_API_KEY` injected only from the mode-600 Pi authentication file, one `gbrain think --rounds 1` call completed with `Model: minimax:MiniMax-M3`, five gathered pages, and four citations.
The answer cited `firstmate-docs/gbrain-endpoints`, `firstmate-docs/gbrain-embedding-verification`, and `firstmate-docs/gbrain-reranker-verification`.

With `MINIMAX_API_KEY` removed through `env -i`, the same `think` path returned no synthesis and printed `(no LLM available — set anthropic_api_key via gbrain config or ANTHROPIC_API_KEY env)` while retaining `Model: minimax:MiniMax-M3` in its summary.
That is a clear no-answer state, but the current GBrain message incorrectly recommends the Anthropic credential rather than the missing MiniMax credential.
In the same credential-free environment, `gbrain search 'snowflake arctic embed2' --limit 5` continued to return five local results.
