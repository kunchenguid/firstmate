### Autonomous run

**You own the exit condition. Define done, then drive to it without stopping.** For "run until done" hand-offs.

1. State the exit condition as a checkable predicate before the first iteration (tests green, repro fixed, all N PRs merged, pixel-diff zero). A vague goal stalls; a predicate lets you stop.
2. Pick the wake mechanism as a supervision wait (a watcher plus heartbeat, not a busy loop). An event to watch (CI, a merge, a ref advancing) is reported to the supervisor with the exact predicate to wake on, with a long time-based recheck as fallback. No event gets a fixed-interval sleep loop sized to when the result is worth re-checking.
3. Each iteration makes the smallest change the evidence justifies, verifies it against the predicate, commits if it advanced, discards changes that didn't help. Belt-and-suspenders that "might help" gets reverted, not left to ride.
   Sequence the work via the **sequence-verifiable-units** principle skill, verifying each unit before the next instead of batching checks at the end.
4. Mid-run discoveries are yours within the brief's scope. Address broken skills, related bugs, flaky verifiers, review noise, tooling failures, orphaned follow-ups, and fixable drift yourself. Put out-of-band fixes in their own branch. Do not park reversible work for the supervisor. Surface only irreversible actions, genuine product or preference calls no experiment can settle, or a real dead end, as a decision through the status protocol. Keep the predicate as the main drive, and return to it after each side fix.
5. Checkpoint every iteration via the **show-me-your-work** skill, a row for what changed and whether the predicate moved. A run with no trail can't be audited or resumed.
6. Stop when the predicate is met. A plateau is not a stop, so keep going and pivot your approach to push past it. Surface a genuine dead end rather than spinning, and never relax the predicate to declare victory.

**Reply:** the exit condition, iterations run, what landed, what was discarded, final predicate state.


---
*Adapted for fleet use from pstack (MIT, upstream commit 7314f72): IDE and cloud-vendor references removed; autonomy is bounded by the brief; outward posting and agent-owned landing removed.*
