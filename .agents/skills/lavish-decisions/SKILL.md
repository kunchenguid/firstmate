---
name: lavish-decisions
description: >-
  Agent-only workflow for creating durable captain-facing Lavish decisions.
  Use before creating, repairing, or presenting a multi-option captain choice; route it through the durable file protocol, with the Firstmate board wrapper as the sole supported browser surface.
  Never use an upstream served session, server, or poll for this workflow.
  Do not use it for read-only reports or simple yes/no questions.
user-invocable: false
metadata:
  internal: true
---

# Lavish decisions

Create a self-contained, durable decision that the captain can answer when convenient, even when no firstmate process is running.
Use the firstmate-owned `lavish-axi` file protocol documented in `tools/lavish/README.md`.

## Create

1. Reconcile the proposed decision against live fleet state immediately before writing it.
2. Write complete human context to Markdown.
   Include the decision, recommendation, alternatives, consequences, and what happens after each choice.
3. Define the ordered questions and options in the JSON shape documented by the tool.
   Use nonempty unique lowercase-slug keys.
4. Choose a durable `$FM_HOME`-relative destination below `data/`.
   This is where intake commits the validated answer before writing its receipt.
5. Run `lavish-axi create` with a stable decision id, title, Markdown request, question JSON, and destination, and retain its emitted `Run:` line.
6. From firstmate's environment, run `lavish show <id>` and `lavish inbox` to verify the exact durable request.
7. Choose exactly one captain surface.
   For a terminal answer, surface only the title and the exact `Run:` line emitted by `lavish-axi create`:

   ```text
   Decision waiting: <short title>
   <exact Run: line emitted by lavish-axi create>
   ```

   For a self-contained browser board, run `bin/fm-lavish-board.sh <decision-id> --home <resolved-absolute-home>` as documented in `tools/lavish/README.md`, then tell the captain the named decision board is open.
   Do not surface or invent a session URL.

The surfaced command is for the captain's shell, not firstmate's environment.
It must retain the emitted `--home` argument and resolved absolute home path even when firstmate has `FM_HOME` exported.
Never shorten the command or reconstruct it from a placeholder.
Always carrying the explicit home is slightly noisier than asking the captain to export `FM_HOME`, but it makes every decision independently runnable and avoids a hidden setup dependency.
The browser wrapper must receive that same explicit resolved home so its dedicated profile and recovery check stay bound to the decision's fleet home.

Do not edit `request.md` or `manifest.toon` after surfacing the decision.
Their digest and ordered question set are the immutable contract.

## Consume

Firstmate's ordinary wake drain and session start invoke Lavish intake.
The answer file is authoritative; the wake record is only a pointer.
Visible prompt delivery is redundant; `tools/lavish/README.md` owns its home-bound routing and manifest-destination contract.
If that proof is unavailable, accept the fail-closed refusal and rely on the durable wake path rather than targeting ambient terminal state or asking the captain to submit again.

When a destination appears:

1. Read the full validated answer from the declared destination.
2. Revalidate any execution preconditions that may have changed while the decision waited.
3. Act on the captain's complete batch without weakening or reinterpreting it.
4. Update the owning task or backlog record so the captain-gated thread is durably closed.

## Reliability boundary

Never start a server, create or share a session URL, poll, long-poll, register a filesystem watcher, schedule a timer sweep, or launch a resident server or listener process for Lavish decision capture.
Do not use upstream `serve`, `poll`, browser, layout-audit, or session-lifecycle commands.
The sole browser exception is `bin/fm-lavish-board.sh`, which opens a decision-specific profile and arms one ordinary bounded recovery check around the authoritative file protocol.

Every core Lavish command must finish its bounded local file operation and exit.
If `lavish answer` reports `answer saved; wake not queued`, do not ask the captain to answer again.
The next ordinary intake scan recovers the durable unreceipted answer.
