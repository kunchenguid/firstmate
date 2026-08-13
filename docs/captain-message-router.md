# Captain-message continuity router

This is **not** watcher continuity.
It routes an incoming captain chat message relative to primary-session open asks so a late or unrelated reply does not silently steer the wrong turn.

## Ownership

- Bash owner: `bin/fm-captain-message-router.sh` owns truth (anchors, briefs, classification, ephemeral router spawn, verdict log, pending handoffs).
- Pi hook: `.pi/extensions/fm-primary-captain-message-router.ts` is a thin trigger only.
- The Firstmate primary agent never runs continuity.

Primary homes only (main home or a marked secondmate home).
Child crew/scout worktrees and no-mistakes gate agents are inert.

## Router model runner

The built-in profile uses upstream Firstmate's verified Cursor Agent CLI resolver with the account-listed `cursor-grok-4.6-low` model.
It runs non-interactively in Cursor's read-only `ask` mode and never passes `--yolo` or `--force`.
The router adds no fork-specific Cursor compatibility layer and no Pi provider extension.

## Fail-open

Errors allow the message into the current primary and record a failure.
The captain is never locked out by a broken router.
Only invalid CLI usage exits non-zero.

## State

Local-only under `state/captain-router/` (gitignored with `state/`):

| Path | Purpose |
| --- | --- |
| `anchors.current` | Current session open-ask anchors |
| `current.session` | Session id last settled on this home |
| `sessions/<id>.brief` | Per-session topic head + anchors |
| `pending/<ts>-<digest>.route` | Staged reroute/new handoff for later delivery |
| `pending/LATEST` | Basename of the newest pending route |
| `verdicts.log` | Append-only verdict rows |
| `explanations.log` | Append-only model rationale rows (audit only) |
| `failures.log` | Append-only fail-open failure rows |
| `last-handoff.txt` | Hook-side pointer after reroute/new |
| `hook.log` | Hook bookkeeping notes |

### Session id assumption

Prefer `--session-id` from the hook, else `FM_CAPTAIN_ROUTER_SESSION_ID`, else the prior `current.session` pointer, else the stable home-scoped fallback `primary`.
Hooks should pass the harness session id when the event exposes one.

### Brief format

```
session_id=<id>
updated=<iso8601>
topic=<single-line head summary>
---
<normalized anchor>
...
```

Session discovery enumerates `state/captain-router/sessions/*.brief` only.
It does not scan unrelated fleet metadata.

## Modes

### `--on-settle`

Reads the last assistant turn on stdin.
Extracts question anchors, refreshes `anchors.current`, writes/refreshes the current session brief, and records `current.session`.
Multi-ask mismatch (many `?` but too few distinct anchors) warns on stderr and never blocks.

### `--on-submit`

Reads the captain message on stdin and prints one machine-readable line:

```text
verdict=<same|reroute|new> target=<session-id|-> confidence=<det|model>
```

Conceptual form `reroute:<session-id>` is the `verdict=reroute target=<session-id>` wire line.

**The model decides every submit.**
There is no deterministic classification shortcut: each `--on-submit` spawns the configured router agent and honors its verdict, recorded as `confidence=model`.
The deterministic layer survives only as the fail-open fallback described below, which is what `confidence=det` now means.

`reroute` and `new` also stage `pending/*.route` for later delivery.
The current implementation classifies and stages only: it does **not** auto-spawn a new primary session or compact/inject across sessions.

## Ephemeral router agent

### What the model sees

The prompt carries four framed parts:

1. Its role and the verdict semantics, including the instruction to prefer `same` for ordinary in-conversation replies that share no literal words with the last assistant turn.
2. A bounded, redacted excerpt of the recent chat history for the current session, supplied by the harness hook through `--chat-history-file`.
3. Every session brief under `sessions/*.brief`, so the model can reason about what each session is about.
4. The captain message to classify.

The hook caps the excerpt at the newest 12 user/assistant turns and 6000 characters, and the owner re-bounds it (`FM_CAPTAIN_ROUTER_HISTORY_CHARS`, default 6000) and redacts before the model sees anything.
Redaction drops any line carrying a Firstmate operational injection and masks secret-shaped tokens and `token`/`secret`/`password`/`api_key` values.
With no history file the model still gets the briefs and the message.

### What the model returns

```text
verdict=<same|reroute|new>
target=<session-id|->
explanation=<up to 3 sentences: why this verdict / what context this belongs to>
```

`verdict` and `target` drive routing.
Targets are normalized and validated by the owner, never trusted raw: `new` forces `target=-`, `same` resolves to the current session id, and `reroute` must name a session that has a brief on disk.

`explanation` is **audit-only**.
It is appended to `explanations.log` keyed by the same message digest as `verdicts.log`, and written as an `explanation=` header field in the staged `pending/*.route`.
It is never printed on the wire line, never placed in the routed message body, and never forwarded into the routed or new session's prompt or drop-in.
It exists so the captain can audit why a verdict was chosen and dial the prompt instructions over time.

### Fail-open fallback

A spawn error, a timeout (`FM_CAPTAIN_ROUTER_TIMEOUT_SECS`, default 90s when a `timeout`/`gtimeout` binary exists), an unparseable reply, or a `reroute` naming a session with no brief all fall back to `same` against the current session with `confidence=det` and a `failures.log` row.
The captain is never locked out by a broken or slow router.

### Configuration

The owner always uses upstream Firstmate's Cursor Agent CLI resolver and defaults to `cursor-grok-4.6-low`.
Set `FM_CAPTAIN_ROUTER_MODEL` to another model id exposed by the current Cursor account.
The Cursor model id carries the reasoning level because Cursor exposes no separate effort flag.
Launch is non-interactive Cursor `--print --mode ask`, pinned to the Firstmate home as its workspace.
Unit tests mock the agent through `FM_CAPTAIN_ROUTER_AGENT_CMD` (prompt on stdin, verdict block on stdout), or put a recording fake Cursor CLI on `PATH` to assert the real spawn argv.
No real model calls in unit tests; `tests/fm-captain-router-live-e2e.test.sh` is the opt-in live proof.

## Hook behavior

- Settle: fire-and-forget.
- Submit: synchronous so bash can stage pending routes before the primary turn proceeds.
- The hook captures a bounded transcript excerpt on `agent_end` and hands it to the owner on the next submit through `--chat-history-file`, dropping Firstmate's own operational injections first.
- `same`: allow.
- `reroute` / `new`: record hook-side `last-handoff.txt`; do not inject continuity into primary context.
- Always fail-open.

## Current limits

- Multi-ask mismatch warns and never blocks.
- `new` stages under `pending/`; it does not auto-spawn a new primary session.
- Cross-session compact and inject is not implemented.
- The primary hook is available for Pi only.

## Verification

```sh
bin/fm-test-run.sh tests/fm-captain-message-router.test.sh
bin/fm-lint.sh bin/fm-captain-message-router.sh

# Opt-in live proof that submit really reaches a model (pin a model you are authenticated for).
FM_CAPTAIN_ROUTER_LIVE_E2E=1 FM_CAPTAIN_ROUTER_MODEL=<cursor-model-id> bash tests/fm-captain-router-live-e2e.test.sh
```

The script header owns exact flags, environment overrides, and state mechanics.
