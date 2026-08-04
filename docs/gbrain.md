# Local GBrain archive

This operator reference owns the Firstmate GBrain installation, archive setup, retrieval configuration, privacy boundary, and recovery procedure.
The local embedding endpoint contract is in [gbrain-endpoints.md](gbrain-endpoints.md), the local reranker evidence is in [verification/gbrain-reranker.md](verification/gbrain-reranker.md), and the empirical installation evidence is in [verification/gbrain-init-retrieval.md](verification/gbrain-init-retrieval.md).

## Operating paths

The pinned GBrain source and executable live under `/home/sungin/.local/gbrain`.
The PGLite database and index live at `/home/sungin/.local/share/gbrain/pglite`.
The GBrain runtime configuration lives at `/home/sungin/.local/share/gbrain/runtime/.gbrain` through `GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime`.
The canonical markdown archive is the remote-less Git repository at `/home/sungin/.local/share/gbrain/archive`, outside both Firstmate project roots and the Firstmate source tree.
Do not add a third-party Git remote to that archive.

## Pinned installation and upgrade

The installed GBrain release is `v0.42.69.0` at commit `3acd511b80bd4d2fe487290a70de75d4cf094730`, which is the first release whose tag contains GBrain's native MiniMax chat-touchpoint change for `MiniMax-M3`.
The installation uses GBrain's documented `git clone` plus `bun install` fallback because the tested standalone Linux release binaries did not initialize PGLite correctly.
The supporting Bun runtime is `1.3.14` at `/home/sungin/.local/gbrain/bin/bun`.

The executable is `/home/sungin/.local/gbrain/bin/gbrain`.
For a clean source installation with the pinned Bun binary already present, run:

```sh
mkdir -p /home/sungin/.local/gbrain/{bin,bun-global,cache}
git clone https://github.com/garrytan/gbrain.git /home/sungin/.local/gbrain/src
git -C /home/sungin/.local/gbrain/src checkout --detach 3acd511b80bd4d2fe487290a70de75d4cf094730
cd /home/sungin/.local/gbrain/src
BUN_INSTALL=/home/sungin/.local/gbrain/bun-global \
  /home/sungin/.local/gbrain/bin/bun install \
  --frozen-lockfile --ignore-scripts --cache-dir /home/sungin/.local/gbrain/cache
BUN_INSTALL=/home/sungin/.local/gbrain/bun-global \
  /home/sungin/.local/gbrain/bin/bun link
install -m 0755 /dev/stdin /home/sungin/.local/gbrain/bin/gbrain <<'GBRAIN_LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

exec /home/sungin/.local/gbrain/bin/bun /home/sungin/.local/gbrain/src/src/cli.ts "$@"
GBRAIN_LAUNCHER
```

The installed `/home/sungin/.local/gbrain/bin/gbrain` launcher executes `/home/sungin/.local/gbrain/src/src/cli.ts` with the pinned Bun binary, so runtime selection does not depend on a user-global `bun` command.
Set `PATH=/home/sungin/.local/gbrain/bin:$PATH` for operations that cause GBrain to spawn `gbrain` as a child process, including migrations.
To upgrade deliberately, select a newer verified GBrain tag, then run:

```sh
git -C /home/sungin/.local/gbrain/src fetch --tags origin
git -C /home/sungin/.local/gbrain/src checkout --detach <verified-tag>
cd /home/sungin/.local/gbrain/src
/home/sungin/.local/gbrain/bin/bun install --frozen-lockfile --ignore-scripts --cache-dir /home/sungin/.local/gbrain/cache
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
PATH=/home/sungin/.local/gbrain/bin:$PATH \
  /home/sungin/.local/gbrain/bin/gbrain apply-migrations \
  --yes --non-interactive --no-autopilot-install
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain doctor
```

Verify PGLite initialization in an isolated approved directory before adopting a new standalone release binary.
`--ignore-scripts` prevents Bun's postinstall hook from running an unguarded migration, and the explicit `--no-autopilot-install` migration skips the Phase F autopilot installation.
The story #6 deployment's migration-created unit has already been removed, so it has no autopilot unit eligible for routine cleanup.
If an autopilot unit exists before a future upgrade, leave it unchanged unless an ownership record proves that this deployment created it and confirms that no other story requires it.
A matching filename or generic GBrain-generated unit shape is not ownership proof.
Do not run `gbrain autopilot --uninstall` on this shared user home because its cleanup targets ignore `GBRAIN_HOME` and sweep user-home launchd, systemd, OpenClaw, crontab, and wrapper artifacts.
Clean up only an exact artifact with separate proof that this deployment created and still owns it.

## Initialize and configure retrieval

Initialize a new local PGLite brain with the verified local embedding model and its probed dimension:

```sh
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain init --pglite \
  --path /home/sungin/.local/share/gbrain/pglite \
  --embedding-model ollama:snowflake-arctic-embed2:568m \
  --embedding-dimensions 1024 \
  --non-interactive
```

Configure the local reranker and hosted synthesis routing with these verified commands:

```sh
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set provider_base_urls.llama-server-reranker http://127.0.0.1:8081/v1
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set search.reranker.model llama-server-reranker:qwen3-reranker-0.6b-q8_0
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set search.reranker.enabled true
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set provider_base_urls.minimax https://api.minimax.io/v1
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set models.think minimax:MiniMax-M3
```

The embedding and reranking providers are local only.
Set `OLLAMA_BASE_URL=http://127.0.0.1:11434/v1` on every command that can embed or query, because GBrain does not persist the command-scoped endpoint and otherwise falls back to `http://localhost:11434/v1`.
The only configured hosted synthesis provider is `models.think=minimax:MiniMax-M3` through `https://api.minimax.io/v1`.
The current reranker service uses a 4096-token context with physical and micro-batch sizes both set to 4096, and archive-representative inputs complete with local reranking as recorded in [verification/gbrain-reranker.md](verification/gbrain-reranker.md).
An input beyond that service and context bound makes llama-server return HTTP 500, after which GBrain records a rerank failure and returns the non-reranked fallback ranking.
Operators must treat that visible failure as a failed rerank rather than successful reranking, even though retrieval still returns fallback results.

## MiniMax credential contract and privacy boundary

The MiniMax credential is read only at runtime from `/home/sungin/.pi/agent/auth.json`, field `minimax.key`.
The file must remain mode `0600`.
Do not place that value in GBrain configuration, a repository, a test, a log, or a service unit.
Use an untraced shell to inject it only into the `think` process:

```sh
task_minimax_key=$(jq -er '.minimax.key | select(type == "string" and length > 0)' /home/sungin/.pi/agent/auth.json)
MINIMAX_API_KEY="$task_minimax_key" \
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain think '<question>' --rounds 1
unset task_minimax_key
```

`search` and local `query --no-expand` keep retrieval on the host.
`think` sends the question and selected memory excerpts to MiniMax for synthesis.
When the MiniMax credential is absent, `think` returns no synthesis and reports that no LLM is available, while local `search` continues to return results.

## Archive, backup, and rebuild

Import and embed the local-only archive with:

```sh
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain import /home/sungin/.local/share/gbrain/archive
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain embed --stale
```

Stop every `gbrain serve` process before copying PGLite because it is a single-writer database.
Back up the archive, PGLite directory, and runtime configuration together to an on-box directory:

```sh
backup_dir=/home/sungin/.local/share/gbrain/backups/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$backup_dir"
cp -a /home/sungin/.local/share/gbrain/archive \
  /home/sungin/.local/share/gbrain/pglite \
  /home/sungin/.local/share/gbrain/runtime/.gbrain \
  "$backup_dir"/
```

To rebuild a damaged index, retain the automatic `.bak` created by `reinit-pglite`, rerun the local initialization, restore the configuration above, then re-import the archive and embed stale chunks:

```sh
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain reinit-pglite \
  --path /home/sungin/.local/share/gbrain/pglite \
  --embedding-model ollama:snowflake-arctic-embed2:568m \
  --embedding-dimensions 1024 \
  --yes --no-sync
```
