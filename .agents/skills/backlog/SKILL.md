---
name: backlog
description: >-
  Captain-invocable intake procedure for turning a wall of text into filed backlog items.
  Use when the captain invokes /backlog, or says "add this to the backlog" with pasted text.
  Owns splitting the text into discrete items, classifying project/kind/priority, deduping against
  the existing backlog, routing secondmate-scope items, holding captain-owned questions, and reporting
  the result. Filing never dispatches work.
user-invocable: true
metadata:
  internal: true
---

# backlog

Turn a captain's wall of text - a brain dump, a pasted list, a rambling paragraph of asks - into
filed backlog items without dispatching anything.
This skill owns the intake PROCEDURE only; `tasks-axi` remains the one backlog executable and
`AGENTS.md` section 10 owns the backlog contract this procedure files into.

## Procedure

1. **Split.**
   Break the pasted text into discrete items - one per distinct ask, bug, idea, or question.
   Keep captain decision words VERBATIM in each item's body; do not paraphrase or summarize them
   away.
   Keep each item's title succinct even when its body quotes the captain at length.

2. **Classify each item.**
   - Project: resolve independently per `AGENTS.md` section 7 intake, against the `data/projects.md`
     registry, work under way, and project code or README; ask one concise question only when
     multiple or no projects plausibly match.
   - Kind: `ship`, `scout`, or `task` (a non-code operational item).
   - Priority: apply this fixed rubric, in order, and stop at the first row that fits.
     - P0 - security issue or live exposure.
     - P1 - blocks the captain or breaks production correctness.
     - P2 - normal ship work.
     - P3 - design work or an idea worth capturing.
     - P4 - someday, no urgency.
     An explicit captain priority signal in the pasted text (an explicit "P1", "urgent",
     "whenever", "someday", and the like) overrides the rubric for that item.

3. **Dedupe, then file.**
   Filing and merging are routine backlog mutations, so use compatible `tasks-axi` when the configured
   backend selects it, and the documented manual hand-edit path to `data/backlog.md` otherwise, per
   `AGENTS.md` section 10 and `docs/configuration.md` "Backlog backend"; that doc owns the exact
   `config/backlog-backend` mechanics.
   Check the item against the existing backlog (`tasks-axi list`, or a read of `data/backlog.md` on
   a manual-backend home) before filing.
   When an existing item already covers the same work, merge into it instead of creating a twin:
   `tasks-axi update <id> --body-file <path> --archive-body` on the tasks-axi backend, or on a
   manual-backend home write the merged body in place and keep the superseded text directly below
   it under an `_Archived <date>:_` marker line, so the prior body stays recoverable per
   `AGENTS.md` section 10 instead of being appended forever or dropped.
   Otherwise file a new item (`tasks-axi add`, or the equivalent manual entry) with its classified
   kind and priority.

4. **Route.**
   For an item whose project or domain matches a registered secondmate `scope:` in
   `data/secondmates.md` per `AGENTS.md` section 7, file it in the main backlog first, then hand it
   off with `bin/fm-backlog-handoff.sh`; that script owns the move mechanics and fleet-level
   validation.
   Everything else stays in the main `data/backlog.md`.

5. **Hold captain-owned questions.**
   When an item is itself a question only the captain can answer rather than actionable work, file
   it and hold it for the captain with the question in the hold reason, following
   `captain-hold-lifecycle`.
   Load that skill before holding; it owns the hold/answer mechanics and completion gate.

6. **Report.**
   Echo one compact report back to the captain: each item's id, its filed/merged/held outcome, and
   its priority.
   Batch at most one clarification back to the captain for the whole intake, covering every
   ambiguous item at once, rather than asking item by item.

7. **Never dispatch.**
   Filing an item, including a P0 or P1 item, never starts work on it.
   Dispatch follows the normal `AGENTS.md` section 7 intake path on its own trigger.
