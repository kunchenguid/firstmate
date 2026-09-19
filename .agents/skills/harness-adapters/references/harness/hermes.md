# Hermes

Verified as a primary harness. Integration uses a Hermes plugin for session-start injection and turn-end guard, plus a backend adapter for worker management.

## Operating facts

| Fact | Value |
|---|---|
| Busy | No lifecycle hooks. Inferred from `state/<id>.progress` file + process presence for workers. |
| Exit | `/exit` or Ctrl+D. |
| Interrupt | Ctrl+C. |
| Skill | `/<skill>` (Hermes slash-command compatibility). |
| Model | `--model <model>` or `/model` interactive picker. |
| Effort | `--reasoning <none\|minimal\|low\|medium\|high\|xhigh\|max>` or `/reasoning`. |
| Permissions | Hermes approval mode (`smart`/`manual`/`off`). `/yolo` toggles bypass. |

## Workspace trust

Hermes has NO workspace-trust dialog. No pre-registration needed. No trust boundary. No external-imports gate.

## Composer ghost

Hermes has no composer-ghost issue (no predictive text in empty input).

## Feedback drafts

N/A — Hermes has no `/bug` or `/feedback` model-drafted feedback flow.

## Task control channel

Hermes task workers receive their brief via the launch command (`hermes chat -q "<brief>"`). Firstmate steering-inbox messages arrive via `bin/fm-send.sh` (filesystem-based inbox). The inbox is backend-agnostic and works identically for Hermes workers.

## Primary integration

Primary integration is provided by the `firstmate` Hermes plugin at `~/.hermes/plugins/firstmate/`. The plugin registers:

- `on_session_start` — runs `bin/fm-session-start.sh`, caches digest
- `on_session_reset` — re-caches digest on `/new` and `/reset`
- `pre_llm_call` — injects cached digest as context on first call after session start
- `pre_verify` — bounded continuation guard (forces one extra turn if fleet work is active)

The plugin must be installed in the Hermes home for firstmate supervision to function. Without it, firstmate runs in "unknown harness" mode (no digest injection, no turn-end guard).

Watcher supervision uses `terminal(background=True, notify=['wake:'])` to run `bin/fm-watch-arm.sh` as a long-running background process. The watcher wakes the model on actionable events.

### Session-start delivery

The plugin caches the digest to `state/.firstmate-session-start-cache` on `on_session_start` and `on_session_reset`. The `pre_llm_call` hook injects this as `{"context": ...}` on the first LLM call. Injection is tracked per-session via `state/.firstmate-digest-injected-<session_id>`.

### Turn-end guard

The `pre_verify` hook checks `state/.wake-queue` for pending wakes. If non-empty, it returns `{"action": "continue", "message": "Firstmate: fleet wake pending."}` to force one continuation turn. Bounded by `agent.max_verify_nudges`.

This is NOT a hard block — a captain message always terminates the guard. For v1, this is an accepted tradeoff.

### Compaction

Hermes compaction (`/compact`) does NOT re-fire `on_session_start`. The digest is NOT refreshed on compact in v1. This is a known limitation. After compact, the model may not have the latest firstmate operational context until the next `/new`.

## Known gaps

- No `agent_start`/`agent_stop` lifecycle events (busy-state is file-based)
- No hard turn-end block (only bounded continuation via `pre_verify`)
- No instruction refresh on `/compact`
- Background watcher is process-local (does not survive gateway restart)
- No native push events (backend adapter is polling-based)

## Worker launch

Hermes workers are launched as:

```bash
hermes chat -q "<brief content>" --cwd /path/to/worktree
```

Each worker runs in its own treehouse worktree. Worker state is detected via `ps` for `hermes chat` processes.
