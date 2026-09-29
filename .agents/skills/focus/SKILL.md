---
name: focus
description: >-
  Set, show, or clear the captain's opt-in project focus window when the captain invokes /focus, /focus off, or asks to focus on one project (or a small set) and hear about the others later.
  Also load it before telling the captain about any outcome while the wake drain prints a FOCUS WINDOW line, and whenever it prints a FOCUS HELD section.
user-invocable: true
metadata:
  internal: true
---

# focus

The focus window lets the captain work one project at a time without losing sight of the rest.
While it is set, non-urgent outcomes from other projects wait and then arrive together, grouped by project, when the window ends.
It is off until the captain sets it, and it changes only when the captain is told, never whether: held items stay listed in Bearings and on its board the whole time.
`bin/fm-focus.sh` owns the durable window record, the held-delivery ledger, the routing verdict, and the exact commands; read its header before first use.

## Invocations

- `/focus <project> [<project>...]` sets or replaces the window; `for <N> minutes|hours` or `until <UTC time>` bounds it with `--until`.
  Use the project names the registry and backlog `repo:` fields use; when the captain's words name no registered project, ask which one before setting anything.
  Confirm in one line which projects are in focus, until when, and that failures, security-sensitive items, credential needs, and anything blocking all work still come through at once.
- `/focus` with no project reports `bin/fm-focus.sh status` in plain words, including how many outcomes are waiting.
- `/focus off` runs `bin/fm-focus.sh clear` and delivers everything it prints in the same reply (see Delivering held outcomes).
- Only the captain sets or clears the window; never set, widen, or extend one on your own judgment.

## Before telling the captain about an outcome while a window is set

Every drain prints a `FOCUS WINDOW` line while a window is set.
Before any captain-facing report of an outcome, run `bin/fm-focus.sh route --task <id> --class <class> --summary <text>`:

- `failure`: a failed task, check, or merge.
- `security`: anything security-sensitive, destructive, or irreversible.
- `credential`: a needed credential or login.
- `blocking`: a blocker holding up all work, or one only the captain can clear right now.
- `review-ready`: a PR or local branch ready for the captain's review or merge.
- `completion`: routine finished work or investigation findings.
- `decision`: a decision that blocks nothing else.

Choosing the class is your judgment; when an outcome fits an urgent class and a holdable one, choose the urgent class.
For a secondmate's outcome, pass `--project` copied from the structured Bearings row or the secondmate's own record, never inferred from prose.
Report the outcome now only when `route` prints `deliver`; on `held`, leave it out of the reply, because the ledger now owns it.
If `route` fails, report the outcome now.
The window never changes authority: merges, answers, and escalations follow their usual rules, and a held decision stays open and answerable.

## Delivering held outcomes

When the window is cleared or its time runs out, `clear` or the drain's `FOCUS HELD` section lists every held outcome grouped by project.
Tell the captain all of them in one reply, one project at a time, after checking current state so an outcome that has since settled is described as settled.
Then run the printed `bin/fm-focus.sh delivered --through <seq>`; until then every drain presents them again, so an interrupted reply loses nothing.
