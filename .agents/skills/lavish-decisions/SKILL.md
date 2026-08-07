---
name: lavish-decisions
description: >-
  Agent-only workflow for creating durable captain-facing Lavish decisions and annotation boards.
  Use before creating, repairing, or presenting a multi-option captain choice, or before asking the captain to comment on material without choosing anything; route it through the durable file protocol, with the Firstmate board wrapper as the sole supported browser surface, never a hand-authored page or built-in question tool.
  Never use an upstream served session, server, or poll for this workflow.
  Do not use it for read-only reports or simple yes/no questions.
user-invocable: false
metadata:
  internal: true
---

# Lavish decisions

Create a self-contained, durable decision that the captain can answer when convenient, even when no firstmate process is running.
Use the firstmate-owned `lavish-axi` file protocol documented in `tools/lavish/README.md`.

## Pick the mode first

Ask what the captain is being asked to do, and pick before writing anything.

- The captain is choosing between options: that is a **decision**, defined with `--questions`.
- The captain is reading material and reacting to it: that is an **annotation**, defined with `--items`.
  Each item gets its own comment box, plus one overall note.

"Turn this into something I can comment on", "I want to react to each of these", and any ask that names no choice are all annotations.
**Never invent questions to fit material the captain only wants to comment on.**
Two-option questions manufactured around an artifact are worse than useless: they put words in the captain's mouth and hide the free text under a choice nobody asked for.
If a decision seems to need zero questions, it is an annotation; `lavish-axi create` will refuse an empty question array and say so.

An annotation item is a captain-facing item like any other, so it goes through `bin/fm-captain-item-check.sh` too, in `note` mode.
That mode mandates no sections, no headings, and no length: write the item the way you would say it, and the check refuses it only for internal vocabulary.
Do not pad an item to satisfy a wrapper it does not have.

## Create

1. Reconcile the proposed decision against live fleet state immediately before writing it.
2. Write each captain-facing risk or decision as the plain-language wrapper required by `AGENTS.md` section 9.
   When relaying exact source text, keep it unaltered in the optional verbatim block rather than rewriting or removing its technical detail.
3. Define the ordered questions and options, or the ordered annotation items, in the JSON shape documented by the tool.
   Use nonempty unique lowercase-slug keys.
   Item keys are how the captain's comments come back to you, so name them after the thing being commented on.
4. Choose a durable `$FM_HOME`-relative destination below `data/`.
   This is where intake commits the validated answer before writing its receipt.
5. Assemble the exact Markdown request from one or more items using the item boundaries and multi-item concatenation contract in the header of `bin/fm-captain-item-check.sh`.
   Put no captain-facing prose outside those boundaries.
6. Run `lavish-axi create` with a stable decision id, title, that exact Markdown request, the question or item JSON, and destination, and retain its emitted `Run:` line.
   Creation snapshots the request bytes once, runs request mode against that snapshot, and stores those same bytes; a separate earlier check grants no approval, and any failure refuses creation.
   Annotation item bodies clear the same gate in note mode, reported by declared item number.
7. From firstmate's environment, run `lavish show <id>` and `lavish inbox` to verify the exact durable request.
8. Choose exactly one captain surface.
   For a terminal answer, surface only the title and the exact `Run:` line emitted by `lavish-axi create`:

   ```text
   Decision waiting: <short title>
   <exact Run: line emitted by lavish-axi create>
   ```

   For a self-contained browser board, run `bin/fm-lavish-board.sh <decision-id> --home <resolved-absolute-home>` as documented in `tools/lavish/README.md`.
   Only a successful exit authorizes reporting the board open because the helper checks its answering machinery before it arms pickup or opens Chrome.
   Then tell the captain the named decision board is open.
   Do not surface or invent a session URL.

The surfaced command is for the captain's shell, not firstmate's environment.
It must retain the emitted `--home` argument and resolved absolute home path even when firstmate has `FM_HOME` exported.
Never shorten the command or reconstruct it from a placeholder.
Always carrying the explicit home is slightly noisier than asking the captain to export `FM_HOME`, but it makes every decision independently runnable and avoids a hidden setup dependency.
The browser wrapper must receive that same explicit resolved home so its dedicated profile and recovery check stay bound to the decision's fleet home.

Do not edit `request.md` or `manifest.toon` after surfacing the decision.
Their digest and ordered question or item set are the immutable contract.

## Consume

Firstmate's ordinary wake drain and session start invoke Lavish intake.
The answer file is authoritative; the wake record is only a pointer.
Visible prompt delivery is redundant; `tools/lavish/README.md` owns its home-bound routing and manifest-destination contract.
If that proof is unavailable, accept the fail-closed refusal and rely on the durable wake path rather than targeting ambient terminal state or asking the captain to submit again.

When a destination appears:

1. Read the full validated answer from the declared destination.
   An annotation answer carries one `annotations` entry per item key; an empty note means the captain read that item and said nothing, which is not the same as an item that was never surfaced.
2. Revalidate any execution preconditions that may have changed while the decision waited.
3. Act on the captain's complete batch without weakening or reinterpreting it.
4. Update the owning task or backlog record so the captain-gated thread is durably closed.

## Reliability boundary

Never start a server, create or share a session URL, poll, long-poll, register a filesystem watcher, schedule a timer sweep, or launch a resident server or listener process for Lavish decision capture.
Do not use upstream `serve`, `poll`, browser, layout-audit, or session-lifecycle commands.
The sole browser exception is `bin/fm-lavish-board.sh`, which opens a decision-specific profile and arms one ordinary bounded recovery check around the authoritative file protocol.
Only that helper arms the pickup path; a hand-authored page is not a fallback because its answers cannot reach firstmate.

Every core Lavish command must finish its bounded local file operation and exit.
If `lavish answer` reports `answer saved; wake not queued`, do not ask the captain to answer again.
The next ordinary intake scan recovers the durable unreceipted answer.
