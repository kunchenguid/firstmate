---
name: ticket-board
description: >-
  Agent-only reference for the captain-facing ticket board.
  Load before running `bin/fm-ticket-board.sh` for the first time in a home or when explicitly asked to open, rebuild, or change a ticket's status on the board, and on a procevent lavish wake whose source id matches the canonical id of the stable ticket-board path - route that wake to this skill's board-wake handling.
user-invocable: false
metadata:
  internal: true
---

# ticket-board

The captain-facing ticket board is a Lavish page at the stable path `bin/fm-ticket-board.sh path`, backed by the durable `fm-ticket-board.v1` JSON store at `bin/fm-ticket-board.sh store`.
The captain creates a ticket by typing plain text into the board's own Lavish conversation panel and sending it - there is no form on the page.
`bin/fm-ticket-board.sh`'s header owns the exact `init`/`build`/`set-status`/`path`/`store` commands and the store schema; `bin/fm-ticket-board-consume.sh`'s header owns the receiving side that turns a captured board result into a new ticket.
Follow the same architecture as the `bearings` skill's Lavish board mode: serve-then-bind-then-arm ordering, an idempotent rebuild-in-place at a stable path, and fail-closed validation that never clobbers an existing board on a bad build.

## Building or opening the board

Run `bin/fm-ticket-board.sh build` to create or rebuild the board in place; it is idempotent and safe to re-run, and never arms a second registration for the same board.
Never run `lavish-axi poll` for the board yourself: the armed source's supervised runner owns the blocking poll.
A result the adapter classifies terminal - an ended session, or one with no live session left to produce another result - retires the source instead of restarting the poll; `build` re-establishes the session and re-arms the source the next time anything calls it (see the known limitation below for when that matters).

## Handling a board wake

A Lavish wake whose source id matches `bin/fm-procevent-lavish.sh source-id "$(bin/fm-ticket-board.sh path)"` is a ticket-board result.
Load `process-event-sources` for the generic result-read and handled-acknowledgement contract, then run:

```sh
bin/fm-ticket-board-consume.sh <result-file>
```

This appends every freeform message in the captured result as one new Backlog ticket, then rebuilds and rearms the board so the new card is visible the next time the captain opens it.
A captured result that provably carries no queued content (the captain closed the board without typing anything) prints `captured: 0` and exits 0 with nothing changed - that is not news and needs no further action.
A nonzero exit from this script, including a `captured: 0` line followed by a failure, means the result DID carry content that could not be turned into a ticket - treat that as a real failure to investigate, never as silence.
Relay what was created to the captain in plain language (the ticket's title, not its internal id or the wake mechanics), then acknowledge with `bin/fm-procevent.sh handled <source-id> <sequence>` per the generic contract.

`bin/fm-ticket-board.sh build` verifies the session it gets back from `lavish-axi` is genuinely open and deliberately reopens it when the captain ended it from the browser (Send & End, or More -> End session) - `bin/fm-ticket-board.sh`'s header owns the verified detail. That happens on every `build` call, including the one this consume step runs right after appending a new ticket, so a captain submitting a ticket via "Send & End" keeps working with no manual recovery.
KNOWN LIMITATION: if the captain closes the board without typing anything, that is genuinely silence - no wake fires, and the adapter retires the source since it has nothing left to produce. Nothing then re-arms it on its own schedule; the board stays unarmed until something next calls `build`, which could be a while if no other board activity happens in the meantime. This is the inherited half of the limitation `bin/fm-bearings-board.sh` also carries, not something this skill auto-recovers from. If a captain reports a typed ticket never appearing and nothing else has touched the board since, run `bin/fm-ticket-board.sh build` by hand.

## Updating ticket status

There is no in-board status editing or drag-and-drop in v1.
Move a ticket to a new column with:

```sh
bin/fm-ticket-board.sh set-status <ticket-id> <backlog|in_progress|done>
```

This updates the store in place and rebuilds the board, so the captain sees the new column the next time they open it.
