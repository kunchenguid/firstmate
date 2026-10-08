---
name: session-start-recovery
description: Load when the session-start digest reports unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.
user-invocable: false
metadata:
  internal: true
---

# Session-start recovery

The digest itself makes no external-network call and never waits for one.
Every network check a session start owes - GitHub auth, dead-secondmate relaunch, restored-worker recovery, secondmate convergence, pending handoff delivery, and project clone refresh - runs off the digest's blocking path in a bounded worker owned by `bin/fm-startup-network.sh` and is reported in the digest's own `NETWORK CHECKS` section.
The locked startup inactive-outcome scan joins that worker so a slow local current-state read cannot block the digest; its findings use the ordinary durable wake queue.

1. **Lock** - acquires the per-home session lock first, before anything mutates shared state, then starts the deferred startup stage above.
2. **Bootstrap** - detect-only checks (tool/version problems, the worktree-tangle check, harness override, dispatch-profile validation, backlog-backend status) always run, but routine confirmations stay silent by default.
   When the lock could not be acquired, the worktree-tangle check uses read-only advisory wording without a checkout repair command.
   Home-local stale Herdr projection cleanup and the seven bootstrap MUTATING sweeps - same-home backlog reconciliation, fleet sync, secondmate convergence, secondmate liveness, restored-worker recovery, pending remote handoff retry, and Relay artifact writes - run only when this session actually holds the lock from step 1; the five network ones among them run in the deferred stage rather than in this section.
   The secondmate liveness sweep deterministically accounts for every registered secondmate: it relaunches only from the recovery-grade `dead` or `missing` states, preserves ambiguous, unreadable, or unreachable remote targets, and reports skipped or failed guarantees as `SECONDMATE_LIVENESS:` lines (`bin/fm-bootstrap.sh`; `bin/fm-backend.sh`'s `fm_backend_agent_state`; `docs/remote-secondmates.md`).
   Ordinary supervision continues the same guarantee through the watcher's cadence-gated liveness tick over the shared `bin/fm-secondmate-liveness-lib.sh`, so a mate that dies mid-session is relaunched without waiting for the next session start.
   Restored-worker recovery (`bin/fm-restored-recover.sh`) covers the opposite case after a machine restart: an alive ship, scout, or secondmate parked on a harness startup gate or running outside its recorded worktree is relaunched there by a detached job with its own bound, and any `RESTORED_WORKER:` result arrives later as a `check: restored-workers` wake rather than in the digest.
3. **Wake queue** - when locked, drains and presents the durable wake queue without running the inactive-outcome scan inline, and prints the raw records prominently as this turn's first work queue; a clearly labeled status-event annotation may follow a valid `signal` record and includes every status line still unread at the presentation cursor, but never replaces the raw record or current-state reconciliation, and a lapsed watcher chain still surfaces here via the same guard alarm.
   Presented records remain durable until the handling turn runs the generation-bound acknowledgement printed by the drain.
   Every locked drain also prints a bounded fleet-wide `OPEN DECISIONS` section when durable decision records remain open, including when the queue itself is empty; reconcile those entries before continuing.
   A main drain may also print a bounded, one-shot `STATUS OUTCOME BACKSTOP` when a task's newest captain-facing status event has no covering supervision-branch outcome; handle it as a recovered wake even when no queue row remains.
   The same drain prints every still-unread `note:` line and pending-reply resolution since the last presentation in an unbounded `UNREAD STATUS` section, so an answer buried under a later routine line is not dropped; those lines are not re-printed after that presentation.
   It also prints a bounded `RECORD DIVERGENCE` section naming every captain call the status log reads as resolved while its backlog task is still held; nothing is closed for you, and `captain-hold-lifecycle` owns the reconciliation.
   When the lock could not be acquired and verified, the queue is left untouched because no session mutation is authorized, and the guard's tangle/watcher-liveness alarms still print in read-only advisory mode without drain, supervision repair, or checkout repair commands.
4. **Supervision operating instructions** - after the wake queue and before both digests, the digest emits exactly one operating block for the detected primary harness, followed by the read-once contract that governs them.
   The script itself never starts supervision; the emitted harness protocol owns the exact wait or wake mechanism.
5. **Fleet-state digest** - after that read-once contract and ahead of the context digest, the compact backlog listing owned by `bin/fm-session-start.sh`; every `state/<id>.meta`; a bounded tail of each task's `state/<id>.status` (labeled as wake-EVENT history, not current state, with the full log path printed for a deeper read); the away or quiet posture (`state/.afk-contract`, plus the `state/.afk` daemon flag where a daemon runs); and one cheap alive/dead read of each task's recorded backend endpoint.
   That liveness line is a fast presence check only, not a full state read - when you need a crew's actual current state (a run-step, not just "is the pane there"), read it with `bin/fm-crew-state.sh <id>` as before; the digest deliberately skips that deeper, slower read for every task so it stays fast and bounded.
6. **Network checks** - after the fleet-state digest, the deferred stage's result, or an explicit statement of what it has not confirmed yet.
   A read-only session runs no network checks at all and says so.
7. **Context digest and next step** - last of the bulk sections, the full contents of `data/projects.md`, `data/secondmates.md`, `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, each clearly delimited, followed by the closing reminder.
   A file that does not exist prints an explicit `ABSENT` marker, never confused with an empty-but-present file: absence is meaningful (`captain.md` absent means use the firstmate repo's built-in defaults, `projects.md` absent means rebuild it from the clones under `projects/`, etc.).
   The closing reminder points back to the emitted supervision block and preserves only the lock, afk, Relay, and read-once reminders.

Bootstrap detects first, asks for consent, and installs only after the captain approves in the current session.
Do not dispatch until the essential launch tools are present and GitHub authentication is good; presentation availability follows `bootstrap-diagnostics` and does not block nonvisual work.
Use `gh-axi` for GitHub, `chrome-devtools-axi` for browser work, and compatible `lavish-axi` for visual decisions or reports; consult current help rather than memorizing flags.
A silent bootstrap section needs no action; for any printed actionable diagnostic line, load `bootstrap-diagnostics` and follow its owner procedure.
`BOOTSTRAP_INFO:` lines are completed no-action facts and do not require loading a skill.
`secondmate-provisioning` owns startup secondmate sync, liveness, and inherited local-material convergence.
