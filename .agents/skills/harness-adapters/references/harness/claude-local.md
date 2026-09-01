# Claude-local

The verified `claude` CLI pinned to a locally served OpenAI/Anthropic-compatible endpoint, LM Studio by default.
Verified 2026-09-01 against LM Studio serving `qwen3-coder-next-mlx` on an Apple M1 Max (64 GB).

**Not a second harness implementation.**
It is the same binary, so its trust dialog, lifecycle hooks, control family, and semantic busy source are claude's, reached through the `claude*` prefix rule that `../../../../../bin/fm-control-lib.sh` owns.
Its composer busy signature is explicitly mapped to claude's shared signature in `../../../../../bin/fm-composer-lib.sh`.
Never give it a private copy of a shape the shared classifier owns.

## Standing boundary

**Opt-in, short-context, crewmate/scout only, and NOT trustworthy for unattended work.**
No supervised turn was ever observed completing on this runtime.
Offer it for short, attended, local work the captain has asked to keep on his own machine; never route ordinary shipping here.

`../../../../../bin/fm-spawn.sh` enforces the boundary rather than documenting it, and each refusal names its own reason:

| Gate | Refuses |
|---|---|
| Opt-in | Selection from `config/crew-harness` or `config/secondmate-harness`; only an explicit per-spawn harness or a dispatch profile reaches it. |
| Kind | `--secondmate`, in the spawn and in the control plane that decides a relaunch before stopping the running agent. |
| Mode | `--mode no-mistakes`. |
| Model | An omitted `--model`; the id is the endpoint's own catalog id and is never guessed. |
| Endpoint | An endpoint that is not answering, or a model that is not loaded. |
| Context | A brief beyond the usable headroom. |

## Operating facts

| Fact | Value |
|---|---|
| Busy | **Established.** claude's own hooks fire unchanged: `claude-hook` `user-prompt-submit` was observed opening a turn on this runtime. |
| Trust | **Established.** A trust dialog appears on each fresh worktree, and its default selection is **`No, exit`** - bare Enter exits the agent. Accept with Down, then Enter. |
| Interrupt | **Established.** Delivered through the control plane, reporting `cancel=unconfirmed`, matching claude's documented no-hook interrupt. A pending request-retry timer did not clear. |
| Tool use | **Established.** Survives the Anthropic-compatible endpoint end to end: a forced file read returned the correct sentinel. |
| Turn end | **UNESTABLISHED.** No supervised turn ever completed, so neither the `Stop` hook nor the turn-ended marker was ever observed firing here. |
| Exit | **UNESTABLISHED.** `fm-control exit` did not return within two minutes. |
| Resume | **UNESTABLISHED.** Not exercised. |
| Skill | **UNESTABLISHED.** Not exercised. |
| Model | `ANTHROPIC_MODEL`, not `--model`: the endpoint's catalog id selects the served model. Discover with `bin/fm-local-model.sh list`, which prints each served id and its load state; `probe` only confirms the endpoint answers. |
| Effort | None. The record-and-omit contract in `../common/model-and-effort.md` applies: effort is recorded in task metadata and no flag is emitted. |

## The endpoint

`../../../../../bin/fm-local-model.sh` is the one owner of every endpoint fact; its header owns the exact commands and exit codes.
Three findings drive its design, and none of them is safe to re-derive by intuition:

- **The catalog is the only model-identity source.** A request naming a model that is not loaded returned HTTP 200 and was answered by whatever *was* loaded, with the response naming the loaded model. The request path can therefore never report an eviction; `GET /api/v0/models` and its per-model `state` can.
- **`POST /v1/messages/count_tokens` is not implemented** ("Unexpected endpoint or method"), so no exact token count is available without spending a full prefill.
- **The harness prompt is the dominant context consumer.** Captured from the server's own request log, a single `claude -p` turn carrying a one-sentence prompt sent ~250 KB - roughly 60k tokens of system prompt and tool schema - before any task content. Against the 65,536-token window the reference model had loaded, that is ~96% of the window, leaving 5,536 tokens of headroom.

The short-context boundary is enforced against that **headroom**, not the window, because the window number alone would be theatre.
A window the harness prompt alone fills is refused outright, naming the one action that fixes it: raise the model's loaded context length.

## When the model goes away

LM Studio unloads an idle model on its own TTL and auto-evict settings, so the model can vanish under a running worker, and the server can simply be off.
Both are silent to the worker - Claude Code retries rather than exiting, and was observed sitting in a multi-minute retry backoff with no request reaching the server at all.
`bin/fm-spawn.sh` automatically arms `bin/fm-local-model.sh check <model>` as the task's registered custom watcher check and teardown retires it through `bin/fm-check-unregister.sh`.
It prints one actionable line for a stopped server and a different one for an evicted model, and nothing while the runtime is healthy.

## Latency

Measured on the reference machine: a trivial single turn 153s, a two-turn tool-using exchange 309s.
A later, identical trivial turn did not complete in 20 minutes.
Treat per-turn latency as minutes and as **not stable**; two concurrent clients against one local model starve each other.
