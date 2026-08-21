---
name: fleet-dashboard
description: >-
  Agent-only reference for the Admiral's Fleet Dashboard, the task board that replaced the Lavish status page.
  Use before adding a card, changing a card's status/agent/title/captain, adding a link or a note to one of its tabs, or starring it.
  Use on every fleet-auditor sweep, to read the board's claimed state and to record what the sweep found.
  Whether working as firstmate directly or as a crewmate or secondmate briefed on dashboard-facing work.
user-invocable: false
metadata:
  internal: true
---

# fleet-dashboard

The dashboard is a purpose-built task board for the Admiral, not a mirror of any backlog.
It owns its own persistent records; nothing here is scraped or generated from `data/backlog.md`.
A card exists on it only because something explicitly put it there through `bin/fm-dashboard.sh` (or the HTTP API it wraps) - see `docs/dashboard.md` for the full architecture and the drift-risk that choice implies.

**Agents never touch `bin/fleet-dashboard/web/` or the database directly.**
Every change goes through `bin/fm-dashboard.sh`, which is deliberately one command per action.
A command that needs three round-trips to record one update gets skipped under time pressure, and the board rots exactly like the duplicate backlog that once hid the Admiral's largest project from him.
Run `bin/fm-dashboard.sh --help` for the exact current flag syntax; this skill is about *when* and *why*, not a second copy of that syntax.

## Before you can talk to the board

The server has to be running and reachable.
`bin/fm-dashboard.sh server-status` tells you both the process state and whether the API answers.
If it is down and you are the one responsible for this home's dashboard, `bin/fm-dashboard.sh start` brings it up; otherwise treat an unreachable board the same way the board's own UI does - loudly, not as "nothing to report."
If you are on a secondmate host, the board lives on the primary; point `config/dashboard-url` (or `$FM_DASHBOARD_URL`) at the primary's reachable address rather than assuming localhost.

## Putting a task up

Use `add` the moment a task is received and belongs on the board - this is what "you put it up on the dashboard" means in the Admiral's own words.
Always pass `--prompt` (or `--prompt-file`) with his own words, unedited: that becomes the card's first tab and must never be paraphrased.
`--captain` takes `firstmate`, `dj`, or `river` - whichever of the three is actually driving the work.
New cards default to `not_started`; only set `--status` explicitly if work is already under way.
Starting a card at `needs-attention` needs `--reason` too, same rule and same server-side guard as changing to it later (see "The seven statuses" below).

When the task you are about to spawn is the thing that serves an existing card, pass `--card <card-id>` to `bin/fm-spawn.sh` instead of following up with `ref`/`agent`/`status` calls by hand: the spawn links the card's `backlog_ref`/`agent` to the task id and advances it to `working` itself, and `bin/fm-teardown.sh` later advances it to `testing` from that same recorded identity once the task actually lands. When you are instead handing the serving work off to a secondmate, pass that same `--card <card-id>` to `bin/fm-backlog-handoff.sh` for the one item being handed off - it links the card the same best-effort way, keyed to the secondmate rather than a task id that does not exist yet. See `docs/dashboard.md` "The mechanical card link" for both. Reach for the manual `ref`/`agent`/`status` calls below only for a card whose serving work was never spawned or handed off with `--card` (already under way before this existed, or run by hand outside those scripts).

## The seven statuses

Use exactly these, never a synonym, so the board's filters and the auditor's checks stay meaningful.

`needs-attention` and `testing` are easy to conflate and are opposite in the one way that matters: **`testing` is optional to him; `needs-attention` is blocking on him.** If he never looks at a `testing` card, nothing is lost - the work is otherwise complete. If he never looks at a `needs-attention` card, the work is stuck. Put a card in `needs-attention` only when it genuinely cannot proceed without him - a decision, an answer, a physical action, something only he can do or judge. A card that is simply done and could use his eyes stays in `testing`.

- `needs-attention` - the work cannot proceed without him: a decision, an answer, a physical action, anything only he can supply. `--reason` is REQUIRED - the server refuses the status change without one - and that text renders directly on the card so he can act without opening it. This is the loudest status on the board and sorts first; do not use it for routine progress or for something an agent could resolve on its own. Test every reason against what he would actually DO on reading it: if the honest answer is "read it" or "know it," it is a report, not an ask, and does not belong here - put the update in a status note instead. The server also mechanically refuses a reason that opens or closes a clause with an obvious report-shaped phrase ("being chased", "in progress", "investigating", and similar - see `bin/fleet-dashboard/server/validation.py`'s `REPORT_SHAPED_PHRASES`), but passing that check is not the same as being a real ask: it is a narrow fixed-phrase guard against carelessness, not a judge of intent, and it will let a report through if it is phrased differently. It also only reads the edges of a clause, so an ordinary noun mid-sentence ("approve the $400 monitoring subscription renewal") is left alone. The fleet auditor's age-based sweep (below) is the check that catches those - it is not replaced by the server guard, and the server guard is not replaced by it.
- `not-started` - received, nothing begun yet.
- `working` - an agent is actively on it right now, not "queued" or "about to start."
- `paused` - the Admiral paused it. Only he pauses a task; do not set this because a crew went idle for another reason - that is a stalled task, not a paused one, and belongs in a status update or the auditor's discrepancy log instead.
- `waiting` - started, then blocked on something else. Pass `--waiting-on <other-id>` whenever the blocker is itself a card on this board, so the card gets the button linking to it. Use `--reason` even when there is no target card.
- `testing` - done and uploaded for his real-world review. He marks it complete from here; you do not preemptively flip it to complete on his behalf.
- `complete` - done and approved by him. Reopening (his action, from the card) returns it to `not_started`, not back to `working` - work has to actually resume before it is `working` again.

## The four tabs

Every `note` call names a `--tab`: `interpretation`, `communication`, or `needs`.
The prompt is not a tab you write to - it is set once at `add` time.

- **Interpretation**: your read on what he meant, only when you genuinely have one worth recording. Do not add an interpretation note just to fill the tab - an empty tab is the correct, honest state when there is nothing to add, and the board renders that calmly rather than as a problem.
- **Communication**: the ongoing back-and-forth about this specific task. He can also post here directly from the card; read it before assuming he has not responded.
- **Needs**: a succinct list of what you need from him, with a link wherever there is one. This is also where a file or a build goes up for his review - attach it as a link here (or via the `link` shorthand), not by writing a path or "see the PR" into the text.

## Links: how he receives anything to review

`bin/fm-dashboard.sh link <id> --url <url> [--label <text>]` is how the fleet sends the Admiral something to look at.
The server rejects (400) any link that is not a full `http(s)://` URL, any link whose host is local-only and will not resolve on his phone, and **any GitHub or pull-request link at all** - standing order 17, enforced structurally so it cannot slip through as a copy-paste habit.
If a link is rejected, that is not a bug to route around - find or make a URL that actually opens on his phone and report the outcome in words if nothing else exists yet.

## Reading the board

`list` (optionally `--status`, `--captain`, `--starred`, `--sort`) and `show <id>` are read-only and safe to call as often as you need.
Add `--json` to either for machine-readable output when scripting a sweep.

## The fleet auditor's sweep

If you are the fleet auditor (or standing in for it), your job every cycle is to check the board's claims against live reality, not to trust the board's own text:

1. `bin/fm-dashboard.sh list --status working --json` - for each, confirm a real agent is actually on it (live crew/session state, not the card's own say-so). Anything claiming `working` with no corroborating live activity is a genuine discrepancy.
2. `bin/fm-dashboard.sh list --status waiting --json` - confirm the blocker is still real. If a `waiting_on_id` card is already `complete`, or the external condition it names has cleared, that is a discrepancy: the card is stale, not honestly waiting.
3. `bin/fm-dashboard.sh list --status paused --json` - confirm each is still genuinely paused by the Admiral's own word, not just quiet. If one has been unpaused, confirm it is *actually being worked* - an unpaused-but-idle task is exactly the failure this check exists to catch.
4. `bin/fm-dashboard.sh list --status needs-attention --json` - check each `needs_attention` card's own `show <id>` for how long it has actually sat in that status (its status history has the timestamp it last changed to `needs_attention`). **Age itself is the finding here, asymmetrically with every other status**: a `needs-attention` card that has sat for hours with no reply from him means he was not asked clearly, or the ask never reached him - log it even when the card's claim is otherwise accurate. A `testing` card sitting for the same length of time is not a discrepancy at all - `testing` is optional to him by design, so its age proves nothing. Do not apply this age check to any status but `needs-attention`. Separately, read the reason itself and judge whether it is a genuine ask by the same "what would he DO" test from the statuses section above - the server's mechanical guard only catches a fixed list of report-shaped phrases, so a reason that dodges that list but still only reports progress will reach the board unflagged; log it here as a discrepancy the way you would any other false claim, since this judgment call is exactly what the mechanical guard cannot make and does not replace.
5. For anything you log as a discrepancy, use `bin/fm-dashboard.sh audit-log <id> "<what you found>"`. Be concrete: state what the card claims and what you actually observed, so firstmate can act without re-deriving it.
6. If you cannot verify a card at all (no linked reference, no way to check from where you sit), that is **not** a discrepancy - do not log it as one. Silence on an unverifiable card is correct; a false "wrong" trains the Admiral to ignore the log exactly the way an always-red marker already has once.
7. When the sweep finishes, always call `bin/fm-dashboard.sh audit-run --duration-seconds <n> --checked <n> --discrepancies <n>`, even when nothing was wrong. This is what lets the page show "clean" as a real, timed answer instead of an absence.
8. If the sweep itself fails partway (a source you needed was unreadable, a check errored out), log that with `--kind error` via `audit-log --fleet "<what broke>"` rather than silently posting a shorter, quieter run. A failed check must never look identical to a clean one.
9. Read the current cadence with `bin/fm-dashboard.sh audit-interval get` at the start of each cycle rather than assuming the last-known value; the Admiral can change it from the page at any time.

The routine, on-interval cadence above runs on its own now, on a host timer, whether or not any agent is present to remember it - see `docs/dashboard.md` "The timer". Doing a live sweep by hand is still the right move for the judgment calls that timer cannot make mechanically (cross-home working verification, whether a paused card is still genuinely paused), or when the Admiral asks for one directly; record it through the same `audit-log`/`audit-run` commands either way.

## What not to do

- Do not write to `bin/fleet-dashboard/web/*` or the SQLite file to "fix" a card faster - that is exactly the bypass this skill and the API exist to prevent.
- Do not invent an interpretation, a need, or a communication entry that did not happen, to make a tab look complete.
- Do not report a status the underlying work does not actually match, even briefly "to keep the board tidy."
- Do not treat the dashboard as a second backlog to keep in sync by hand across two systems - if you are duplicating backlog content onto a card, stop and read `docs/dashboard.md`'s "Why the board owns its own records" section first.
