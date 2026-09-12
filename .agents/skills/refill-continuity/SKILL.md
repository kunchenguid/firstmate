---
name: refill-continuity
description: >-
  Agent-only procedure for a desired-concurrency deficit wake. Use on
  `check: refill-deficit` to reconcile terminal work safely and refill clean
  independent capacity without letting one ambiguous slot block other pools.
user-invocable: false
metadata:
  internal: true
---

# Reconcile and refill

Load this skill on `check: refill-deficit`.
It composes the existing delivery, cleanup, backlog, and spawn owners; it does not replace their guards.

1. In a persistent secondmate home, first check the exact parent instruction inbox rendered in the secondmate charter.
   Handle every waiting record in numeric order before this routine refill wake, after any currently running guarded command returns.
2. Run `bin/fm-refill.sh status`, then `tasks-axi ready` against this home's configured backlog.
3. Read each ordinary direct report with `bin/fm-crew-state.sh <id>`.
   Treat `working` as productive.
   Inspect `done` and `failed` immediately; do not infer either state from endpoint presence or an old status event.
4. Reconcile terminal work through its existing lifecycle.
   Register a ready PR with `bin/fm-pr-check.sh`, use `bin/fm-pr-merge.sh` only when the recorded merge posture authorizes it, preserve a scout report, and call `bin/fm-teardown.sh` only after its normal landed-work and unresolved-decision gates pass.
   A refusal is evidence to investigate, never a reason to force, stash, reset, discard, or hand-remove a worktree.
5. After every successful teardown, re-run `tasks-axi ready` and dispatch one highest-priority dependency-cleared task through the normal intake and `bin/fm-spawn.sh` path.
   Re-read `bin/fm-refill.sh status` after each successful spawn and stop when its active count reaches the desired count.
6. Treat each candidate independently.
   A refused or ambiguous worktree slot blocks only that candidate and its proven shared pool.
   Continue evaluating ready tasks that use another repository, pool, or otherwise proven clean slot; never turn one ambiguous slot into a fleet-wide stop.
7. If no safe candidate remains, leave every refusal and ambiguity durable and let the deficit detector re-surface the unchanged condition at its bounded cadence.
8. Resume this harness's supervision protocol before ending the turn.

This procedure never grants merge authority and never weakens teardown safety.
