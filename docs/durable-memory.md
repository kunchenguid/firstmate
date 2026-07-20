# Durable Session Memory

Firstmate preserves bounded recovery evidence outside model context so a runtime-generated compaction summary is never the sole copy of decisions, constraints, work state, or the next safe action.
`bin/fm-memory.js` is the one owner of formats, paths, bounds, validation, atomic writes, and command behavior.
The `durable-memory-recovery` skill owns the conditional semantic procedure.

## Architecture

Canonical private records live under the active home's `data/memory/` directory.
`FM_DATA_OVERRIDE` retains its normal test precedence, and no command implicitly searches another `FM_HOME`.

- `events/<writer>/*.json` contains immutable `fm.memory.event.v1` records.
- `checkpoints/*.md` contains immutable `fm.memory.checkpoint.v1` Markdown with canonical JSON and a sibling SHA-256 file.
- Runtime transcript content remains in the runtime's own store; Firstmate records an opaque lineage reference and an optional file hash, size, and path only when deliberately supplied.

One immutable file per event avoids a shared JSONL append race while retaining append-only semantics, deterministic event IDs, sortable sequences, retry idempotency, and previous-high-water linkage.
Every mutation requires ancestry ownership of the active home's session lock and is serialized through one private home-local write lock, so capacity checks and publication form one bounded operation.
Atomic create uses a same-directory temporary file, file `fsync`, hard-link publication without overwrite, and best-effort directory `fsync`.
Checkpoint publication uses the same primitive, then reads back and validates the hash, schema, and referenced event high-water.

Events record only objectives, decisions and approvals, blockers, task transitions, artifact, PR, and test outcomes, checkpoints, recovery outcomes, and session lineage.
The owner rejects secret-like text, explicit chain-of-thought material, unsafe names, symlink inputs, oversized inputs, unsupported event types, and missing high-water references.
Event capacity exhaustion refuses rather than deleting canonical evidence.
Checkpoint publication keeps the newest 1000 validated checkpoint/hash pairs and removes older pairs only after the replacement checkpoint and its event have been published and read back successfully.

## Authority

Memory references existing owners and never overrides them.

- `data/captain.md` remains home-local captain preference authority.
- `data/captain-shared.md` remains primary-owned shared preference authority.
- `data/learnings.md` remains curated fleet-local knowledge authority.
- Backlog and decision records remain work and approval authority.
- Scout reports remain investigation evidence.
- Project `AGENTS.md` remains project-intrinsic contributor knowledge authority.
- Git, PRs, tests, and live process state remain current operational evidence.

Recovery validates the newest intact checkpoint, replays only bounded later events, and performs cheap reconciliation of recorded task-presence and local Git evidence.
It labels conflicts `stale`, `disputed`, or `unverifiable` and points the agent at the session-start digest for the remaining authoritative reconciliation.
The capsule is capped at 12000 bytes and is printed once by `fm-session-start.sh` without replacing or causing a second read of the existing context and fleet digest.
A lock-refused session may read recovery evidence but may not append an event or checkpoint.

## Lifecycle

Every supported primary runtime reaches a logical turn boundary that invokes `fm-memory.sh boundary` before its supervision predicate.
OpenCode records that boundary before its watcher coordinator can return from normal `session.idle` handling, while the other adapters reach it through `bin/fm-turnend-guard.sh`.
The memory owner verifies that the hook process descends from the active home's lock holder, records only opaque runtime lineage from the bounded hook payload, and writes a validated checkpoint.
Hook memory failure remains non-blocking so a storage problem cannot wedge a model session; session start surfaces recovery failure explicitly.

Codex `PostCompact` output has no model-context field in 0.144.4, and its common `systemMessage` field is only a UI or event-stream warning.
The tracked `PostCompact` hook therefore stages the bounded capsule privately and returns no output, leaving automatic compaction enabled.
At the end of that compacted turn, the tracked blocking `Stop` hook reads the staged capsule and uses its continuation prompt, which Codex records as model input for one bounded follow-up.
The follow-up Stop callback acknowledges the staged record; if the process ends first, the next `UserPromptSubmit` claims it through `hookSpecificOutput.additionalContext`.

`fm-session-start.sh` prints the latest bounded recovery capsule after its wake queue and before the existing supervision, context, and fleet sections.
When the session owns the lock, it then records a session-start boundary.
When lock acquisition is refused, it performs no memory mutation.

Before intentional compaction or reset, load `durable-memory-recovery` and `/stow`, then supply a semantic checkpoint through the safe JSON file or stdin contract.
After detected context loss, load the same skill and reconcile before consequential work.

## Runtime Support Matrix

The portable guarantee is continuous external evidence plus logical turn and session-start checkpoints.
Codex additionally uses its verified first-class compaction callbacks, and no other runtime is claimed to provide a pre-compaction callback without direct evidence.

| Runtime | Session lineage and boundary surface | Pre-compaction support | Firstmate behavior |
| --- | --- | --- | --- |
| Claude | Tracked `SessionStart` and blocking `Stop` hooks. | Claude supports a `compact` session-start reason, but the tracked matcher deliberately covers `startup|resume|clear`; no pre-discard callback was verified. | Turn-boundary checkpoint plus next-session recovery. |
| Codex | Tracked `SessionStart`, blocking `Stop`, `PreCompact`, `PostCompact`, and `UserPromptSubmit` hooks; compaction payloads provide opaque session and turn identifiers plus `manual|auto` trigger. | Verified in Codex CLI 0.144.4. | `PreCompact` writes a validated checkpoint without stopping automatic compaction, `PostCompact` privately stages recovery, `Stop` injects it through one model continuation, and the next prompt is the unclaimed-record fallback. |
| OpenCode | `session.created` and passive `session.idle` project plugin events. | No verified pre-compaction callback. | Passive logical-turn checkpoint and session-start recovery; headless follow-up limitations remain unchanged. |
| Pi | `session_start` and `agent_settled` tracked extension events. | No verified pre-compaction callback. | Logical-run checkpoint and session-start recovery. |
| Grok | Project `SessionStart` and passive `Stop` hooks with an opaque session ID. | No verified pre-compaction callback. | Passive turn-boundary checkpoint and session-start recovery; project trust remains required. |

Verification was reviewed on 2026-07-20.
Installed commands and exact outputs were:

```text
$ codex --version
codex-cli 0.144.4
$ claude --version
2.1.209 (Claude Code)
$ opencode --version
1.18.3
$ grok --version
Error: grok not found in PATH
$ command -v shellcheck
(no output)
$ shellcheck --version
zsh: command not found: shellcheck
$ command -v tmux
(no output)
$ tmux -V
zsh: command not found: tmux
$ codex --strict-config -c model_auto_compact_token_limit=123456 --version
codex-cli 0.144.4
$ CODEX_JS=$(realpath "$(command -v codex)")
$ CODEX_BIN=$(find -L "$(dirname "$CODEX_JS")/../node_modules/@openai/codex-darwin-arm64/vendor" -type f -name codex -perm -111)
$ strings "$CODEX_BIN" | rg -x 'PreCompact|PostCompact|model_auto_compact_token_limit' | sort -u
PostCompact
PreCompact
model_auto_compact_token_limit
```

Pi and Grok were absent from this task environment.
The latest repository-recorded turn-end evidence remains Pi 0.80.5 and Grok 0.2.93 in `docs/turnend-guard.md`; the newer session-start-only evidence in `docs/sessionstart-nudge.md` is not represented as turn-end re-verification.
The Codex hook inventory was checked against the installed binary, the tracked `.codex/hooks.json`, and strict parsing of `model_auto_compact_token_limit`.
No persistent compaction setting was added or changed, so Codex retains its model-selected automatic compaction threshold.
ShellCheck 0.11.0 and tmux were absent before validation, and the focused local round did not install or substitute either tool.

The credentialed automatic-compaction experiment is opt-in because it spends live Codex model turns and uses ambient authentication.
It preserves automatic compaction, sets `model_auto_compact_token_limit=8000` only for the isolated commands, records Codex's resolved token limit and automatic trigger in turn-level trace evidence, requires a `pre-compact` checkpoint and lineage event, requires the PostCompact staged record to be acknowledged, and requires the private objective marker to appear in a subsequent model response.
Its full JSONL and stderr evidence remains under the testing evidence directory named by the script.

```text
$ FM_CODEX_LIVE_COMPACTION=1 bash tests/fm-memory-codex-live.test.sh
ok - durable memory: Codex 0.144.4 auto compaction fires both hooks and reaches the model
```

## Transcript Evidence

Runtime session stores are opaque evidence archives, not a shared transcript schema and not automatic prompt content.
`transcript-ref` records the runtime, opaque session identifier, and optionally the SHA-256, size, and absolute path of one deliberately supplied regular file no larger than 100 MiB.
It rejects project-clone paths, symlinks, and paths outside the active home or the selected runtime's known private store.
It never crawls provider caches, copies raw messages, or indexes transcript text.

This preserves recoverability without assuming stable vendor-private JSON formats or ingesting secrets blindly.
Targeted transcript reading remains a privacy-sensitive forensic action.

## Search

`fm-memory.sh search` performs bounded local substring search over events, validated checkpoints, and the existing curated Markdown owners.
It supports project, task, type, status, time, kind, and result-limit filters and returns provenance with every result.
Schema-backed events and checkpoints marked `restricted` are excluded unless `--include-sensitive` is explicit; curated Markdown retains its existing file-level access model.
The implementation uses only the universally required Node runtime and canonical files.
No SQLite projection, embeddings, graph database, cloud service, or new daemon is required.

## Curated Markdown Portability

Existing curated files do not require a rewrite.
When richer provenance is useful, a normal Markdown section or entry may use YAML frontmatter fields such as `id`, `scope`, `status`, `confidence`, `provenance`, `reviewed`, `sensitivity`, and `supersedes`.
Stable IDs and normal relative Markdown links are preferred where they improve Open Knowledge Format v0.1 portability.
Obsidian may open the same private Markdown as a human interface, but wikilinks, plugins, Sync, and conflict behavior are not machine contracts.

## Hermes Inspiration And License

The design was informed by Nous Research's Hermes Agent at commit `31c08a9aad6e83ded5d0e55dc7d41b94a99f08a1`.
Reviewed sources were `agent/context_compressor.py`, `agent/conversation_compression.py`, `hermes_state.py`, `tools/session_search_tool.py`, `tools/memory_tool.py`, and `LICENSE`.
Hermes is MIT licensed, copyright 2025 Nous Research.

Firstmate adapts the ideas of durable session lineage, bounded source-first retrieval, immutable evidence before lossy compression, atomic memory writes, and reconciliation after session rotation.
It does not copy substantial Hermes source, does not use Hermes' SQLite transcript schema, does not normalize runtime transcripts, and does not claim byte-for-byte or API compatibility.
Because no substantial source was copied, a separate bundled license copy is not required; this reference records the inspiration and upstream license accurately.

## Threat Model And Limitations

The design protects against automatic compaction loss, abrupt process exit after an earlier boundary, concurrent writers at capacity, duplicate hook retries, truncated or malformed records, accidental checkpoint modification, symlinked storage parents, path traversal, and stale operational claims.
Hashes detect accidental changes; they are not signatures and do not defend against a malicious process with write access to the same home.
Secret-pattern checks reduce accidental credential capture but cannot prove arbitrary prose contains no sensitive information.
The checkpoint is only as complete as the meaningful events and semantic checkpoint input supplied before loss.
A crash before the first durable event cannot be reconstructed.
Runtime providers may delete their own transcript archives independently.
Current authority can change after checkpoint creation, which is why recovery must reconcile rather than trust memory silently.
