---
name: session-start
description: >-
  Agent-only reference for the session-start digest and post-restart reconciliation.
  Use when the digest's sections need interpreting, when a source is reported ABSENT or its network checks are unfinished, when the wake queue or OPEN DECISIONS section needs handling at session open, or when reconciling durable records against reality after a restart.
  AGENTS.md section 3 owns the run-once, read-once, lock-refusal, and bootstrap-consent rules that apply with this skill unloaded.
user-invocable: false
metadata:
  internal: true
---

# session-start

`AGENTS.md` section 3 is the always-loaded owner of the rules that must hold before this skill loads: run `bin/fm-session-start.sh` exactly once, treat the visible digest as the authoritative startup input, stay read-only when the lock is refused, install only after captain consent in the current session, and load `bootstrap-diagnostics` for an actionable diagnostic line.
This skill owns everything else about that digest.
`bin/fm-session-start.sh`'s header remains the single owner of composed commands, ordering, and digest contents; read it rather than reimplementing any stage.

## Digest sections, in order

`bin/fm-supervision-instructions.sh` renders the emitted supervision block from `docs/supervision-protocols/`.
`docs/sessionstart-nudge.md` owns which harness surfaces run the command for you and which only nudge it.

1. **Lock** - acquires the per-home session lock before anything mutates shared state, then starts the deferred network stage.
2. **Bootstrap** - detect-only checks (tool and version problems, the worktree-tangle check, harness override, dispatch-profile validation, backlog-backend status) always run, and routine confirmations stay silent by default.
   When the lock could not be acquired, the worktree-tangle check uses read-only advisory wording with no checkout repair command.
   Home-local stale Herdr projection cleanup and the six mutating sweeps - same-home backlog reconciliation, fleet sync, secondmate convergence, secondmate liveness, pending remote handoff retry, and Relay artifact writes - run only when this session actually holds the lock.
   The four network sweeps among them run in the deferred stage rather than inline.
   The secondmate liveness sweep accounts for every registered secondmate deterministically: it relaunches only from the recovery-grade `dead` or `missing` states, preserves ambiguous, unreadable, or unreachable remote targets, and reports skipped or failed guarantees as `SECONDMATE_LIVENESS:` lines (`bin/fm-bootstrap.sh`, `bin/fm-backend.sh`'s `fm_backend_agent_state`, `docs/remote-secondmates.md`).
3. **Wake queue** - when locked, presents the durable queue and prints the raw records as this turn's first work queue.
   A clearly labeled status-event annotation may follow a valid `signal` record and includes every status line still unread at the presentation cursor, but never replaces the raw record or current-state reconciliation.
   A lapsed watcher chain surfaces here through the same guard alarm.
   Presented records stay durable until the handling turn runs the generation-bound acknowledgement the drain prints.
   When the lock could not be acquired and verified, the queue is left untouched because no session mutation is authorized, and the guard's tangle and watcher-liveness alarms print in read-only advisory mode with no drain, supervision repair, or checkout repair commands.
4. **Supervision operating instructions** - the dynamic current-state lines for the detected primary harness (lock, away mode, X mode, ordinary-wake ownership), followed by the read-once contract.
   The static per-harness protocol body is deliberately NOT reprinted: it is byte-identical every session for an unchanged harness and is authoritative in `docs/supervision-protocols/`.
   Run `bin/fm-supervision-instructions.sh` to get the full body when you actually supervise - handling a wake, repairing a cycle, or ending a turn with work under way - and load `supervision-protocol` for per-wake handling.
   The script never starts supervision itself.
5. **Fleet-state digest** - the compact backlog listing owned by `bin/fm-session-start.sh`, every `state/<id>.meta`, a bounded tail of each task's `state/<id>.status` labeled as wake-EVENT history with the full log path printed, the `state/.afk` flag, and one cheap alive-or-dead read of each task's recorded backend endpoint.
   That liveness line is a fast presence check only.
   When you need a crew's actual current state rather than "is the endpoint there", read it with `bin/fm-crew-state.sh <id>`; the digest deliberately skips that deeper read for every task so it stays fast and bounded.
6. **Network checks** - the deferred stage's result, or an explicit statement of what it has not confirmed yet.
   A read-only session runs no network checks at all and says so.
7. **Context digest and next step** - the full contents of `data/projects.md`, `data/secondmates.md`, `data/captain.md`, and `data/captain-shared.md`, plus `data/learnings/index.md` and a count of the topic files beside it, each clearly delimited, followed by the closing reminder.
   Topic learning files are NOT printed: read one only when the current task matches the trigger the index lists.
   A home that has not been topic-split yet prints its flat `data/learnings.md` whole instead, with a note, so no learning is silently dropped.

## ABSENT markers

A file that does not exist prints an explicit `ABSENT` marker, never confused with an empty-but-present file, because absence is meaningful:

- `captain.md` absent means use the firstmate repo's built-in defaults.
- `captain-shared.md` absent means no shared captain preferences.
- `secondmates.md` absent means no registered secondmates.
- `learnings/index.md` absent means no captured learnings for this home.
- `projects.md` absent or stale means rebuild the registry from the clones under `projects/` before dispatch.

## Deferred network stage

The digest itself makes no external-network call and never waits for one.
Every network check a session start owes - GitHub auth, dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and project clone refresh - runs off the digest's blocking path in a bounded worker owned by `bin/fm-startup-network.sh`, reported in the digest's own `NETWORK CHECKS` section.
When that section reports checks still in progress it names exactly what is unconfirmed.
Treat none of those as passed until `bin/fm-startup-network.sh report` returns the finished result; a failed or otherwise actionable result also arrives as a `check: startup-network` wake.

## Open decisions, unread status, and record divergence

Every locked drain prints a bounded fleet-wide `OPEN DECISIONS` section when durable decision records remain open, including when the queue itself is empty; reconcile those entries before continuing.
The same drain prints every still-unread `note:` line and pending-reply resolution since the last presentation in an unbounded `UNREAD STATUS` section, so an answer buried under a later routine line is not dropped.
Those lines are not re-printed after that presentation.
It also prints a bounded `RECORD DIVERGENCE` section naming every captain call the status log reads as resolved while its backlog task is still held.
Nothing is closed for you; `captain-hold-lifecycle` owns that reconciliation and must be loaded for any divergence line.

## Recovery after a restart

`AGENTS.md` section 5 holds the inline rules: a restart is a non-event because durable state and live backend inventory are authoritative, reconcile only this home's own recorded direct reports and their recorded backend inventory, never sweep a shared endpoint namespace or claim another home's work, and let `/afk` own supervision whenever away mode is present.

Reconcile reality with durable records before taking new work, and honor lock-refused read-only mode exactly as section 3 requires.
Treat digest status tails as wake-event history and use targeted current-state reconciliation when the live state matters.
For an ordinary direct report whose endpoint is dead or whose metadata has no window, load `stuck-crewmate-recovery` and preserve the recorded worktree and unlanded work while reconciling ownership.
For a dead secondmate direct report, load `secondmate-provisioning` and reconcile only that secondmate, never its whole child tree from the main home.
Each secondmate reconciles work already in its own home and then idles; recovery never authorizes it to invent work.

Surface only captain-relevant decisions, review-ready PRs, failures, and credential needs; otherwise resume the emitted supervision protocol silently.

## Lock refusal

If the session lock cannot be acquired and verified, report its exact diagnostic and remain read-only; another active session is only one possible cause.
A lock-refused session must not spawn, steer, merge, drain the wake queue, repair supervision, repair a checkout, or perform any other fleet mutation.
