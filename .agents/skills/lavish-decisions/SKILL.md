---
name: lavish-decisions
description: >-
  Agent-only workflow for creating durable captain-facing Lavish decisions.
  Use before creating or revising a multi-option decision, approval batch, triage request, or other structured captain input that must remain answerable asynchronously.
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
   When a question needs visual evidence, reference copied filenames through the documented question `visuals` field and pass the source directory to `lavish-axi create --visuals`.
4. Choose a durable `$FM_HOME`-relative destination below `data/`.
   This is where intake commits the validated answer before writing its receipt.
5. Run `lavish-axi create` with a stable decision id, title, Markdown request, question JSON, and destination.
6. Run `lavish show <id>` and `lavish inbox` to verify the exact durable request.
7. Run `bin/fm-lavish-board.sh <decision-id>` from the active firstmate checkout.
   Tell the captain that the board is open in a separate Chrome window:

   ```text
   Decision waiting: <short title>
   Board open in the separate Lavish Chrome window.
   ```

   If the browser helper cannot run, give `lavish answer <decision-id> --home <absolute-home>` as the terminal fallback.

Do not edit `request.md` or `manifest.toon` after surfacing the decision.
Their digest and ordered question set are the immutable contract.

## Consume

Firstmate's ordinary wake drain and session start invoke Lavish intake.
The answer file is authoritative; the wake record is only a pointer.

When a browser check wakes with `lavish-submit: <decision-id> <payload-path>`, read that payload and run `lavish-axi collect <decision-id> --payload <payload-path> --home <absolute-home>`.
Confirm to the captain only after `collect` reports that the durable answer was saved.

When a destination appears:

1. Read the full validated answer from the declared destination.
2. Revalidate any execution preconditions that may have changed while the decision waited.
3. Act on the captain's complete batch without weakening or reinterpreting it.
4. Update the owning task or backlog record so the captain-gated thread is durably closed.

## Reliability boundary

The Lavish fork runs no server, listener, poller, watcher, or resident process.
Its `board` command writes one self-contained HTML file and exits, just as its other commands finish one bounded local file operation and exit.
Do not use upstream `serve`, `poll`, layout-audit, or session-lifecycle commands.

Firstmate may show that file through `bin/fm-lavish-board.sh`, which owns the separate named Chrome session and the task-neutral check integrated with Firstmate's existing watcher.
That browser glue must never attach to the captain's main Chrome profile or expose a shared board server or session URL.
If `lavish answer` reports `answer saved; wake not queued`, do not ask the captain to answer again.
The next ordinary intake scan recovers the durable unreceipted answer.
