# Verification: Pi custom OpenAI-compatible providers

Active empirical evidence that Pi's existing adapter is already an implementation lane for a local OpenAI-compatible custom provider, including Antigravity-backed models.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established.
A native `agy` CLI adapter is not required for that lane.

## Subject

| Field | Value |
|---|---|
| Verified | 2026-08-25 |
| Pi | 0.84.3 |
| Custom provider | `antigravity` in `<home>/.pi/agent/models.json`, `api: openai-completions`, `baseUrl: http://127.0.0.1:8328/v1` |
| Proxy | local OpenAI-compatible listener on that base URL, credential record `type: antigravity` |
| Model | `gemini-3.7-flash-high` (absent from `pi --list-models`, present on `GET /v1/models`) |

The proxy, credential files, and `models.json` are operator-local.
Firstmate does not ship, start, or authenticate that proxy.
`127.0.0.1:8328` is this home's observed listener, not a product requirement.

## Catalog versus explicit id

`pi --list-models` is still the auto-dispatch catalog.
It did not list `gemini-3.7-flash-high` under the custom provider, and a fuzzy search for that id printed `No models matching "gemini-3.7-flash-high"`.
An explicit `--provider` plus unlisted `--model` still sent the id:

```sh
pi --provider antigravity --model gemini-3.7-flash-high -p --no-session \
  --no-extensions --no-skills --no-tools --offline "Reply with PONG"
```

```text
Warning: Model "gemini-3.7-flash-high" not found for provider "antigravity". Using custom model id.
PONG
```

`--model antigravity/gemini-3.7-flash-high` (the shape `fm-spawn` already emits) also printed `PONG` and did not emit that warning.
The `--offline` flag did not block the provider HTTP call; Pi documents it as disabling startup network operations.

Auto-dispatch that treats a missing `pi --list-models` entry as unsupported remains correct.
An explicit captain `--model provider/id` on a configured custom provider is the launch this evidence supports.
This change does not add fleet routing.

## Isolated write-tool turn (spawn-shaped flags)

In a throwaway git workspace, with Pi's built-in tools enabled, using only the flags `fm-spawn` already passes for `--harness pi --model antigravity/gemini-3.7-flash-high`:

```sh
pi --model antigravity/gemini-3.7-flash-high --thinking low \
  -p --mode json --no-session --no-extensions --no-skills --approve \
  "Create the file AGY_PI_SPAWN_SHAPE.txt in the current git workspace with exactly this contents and nothing else: HELLO_SPAWN_SHAPE"
```

Observed:

- no custom-model-id warning on stderr; elapsed 5.41s; exit 0
- NDJSON `message` fields: `api=openai-completions`, `provider=antigravity`, `model=gemini-3.7-flash-high`, `responseModel=gemini-3.7-flash`, `rawStopReason=tool_calls`
- assistant `toolCall` `name=write` with `path=AGY_PI_SPAWN_SHAPE.txt` and `content=HELLO_SPAWN_SHAPE`
- `tool_execution_end` `toolName=write` `isError=false`, result text `Successfully wrote 17 bytes to AGY_PI_SPAWN_SHAPE.txt`
- workspace file existed with exactly `HELLO_SPAWN_SHAPE`
- lifecycle events `agent_start`, `turn_start`/`turn_end`, `agent_end`, `agent_settled` (the existing Pi busy-state contract)

A separate `--provider antigravity --model gemini-3.7-flash-high` write produced the same provider/model metadata and a local `write` of `AGY_PI_EDIT_PROOF.txt` containing `HELLO_PI_AGY_PROXY`, plus the catalog warning above.
The proxy process's `/proc/<pid>/io` counters increased during that turn.
The stored Antigravity credential file's mtime did not change (its access token was still unexpired).
Pi's local cost table reported `$0` because the custom `models.json` entry has zero unit costs; that is not a billing proof.

## What this is not

This is not a native Antigravity CLI (`agy`) adapter.
Pi executed its own `write` tool locally; the proxy only served the model.
Native `agy` tools, stream-json session lifetime, and `--add-dir` worktree binding were not used and are not required for this lane.
Fleet `config/crew-dispatch.json` / `config/crew-harness` were not changed.
