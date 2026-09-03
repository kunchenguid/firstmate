### Shipping

**You own the safety verdict, never the merge. Verify each PR independently, declare the verified run from the root, then hand it to the merge authority and keep your hands off the queue.** For "is this stack safe", "verify for landing", or the second half of a stack that **Babysit** already drove to green. Landing itself belongs to the merge authority on its explicit go-ahead; this playbook ends at a merge-ready declaration.

This is the half after `babysit.md`. Babysit makes a stack mergeable. Shipping decides what is actually safe to merge and hands the verified queue to the merge authority. Green is not safe, and the gap between those two words is where this playbook lives.

1. **Verify every PR independently before arming anything.** One subagent per PR, not batched, each a worker pass, each driving the real surface the change touches, against parent versus head. Each returns `PASS`, `PASS+NOTES`, or `FAIL` in its report so the record outlives the session. Safe means a verdict from an agent that did not write the code. CI green is not a verdict, and an approving bot review is not a verdict.
2. **Land only the contiguous verified run rooted at the bottom.** Walk up from the lowest unmerged PR and stop at the first one without a passing verdict, where both `PASS` and `PASS+NOTES` pass. A verified PR sitting above an unverified one is not landable, because merging it would pull the gap in underneath it. Report the ceiling as a PR number and say what breaks the chain.
3. **Re-check that the verdicts still describe the code.** A restack rewrites every SHA above it and silently invalidates every verdict without touching a single check. Compare `git patch-id` at the verdict SHA against the current head before trusting an older verdict, and re-verify anything that actually drifted. Twenty-one verdicts went stale this way in one run with no signal at all.
4. **Never arm merging. When every PR in the queue carries a clean independent verdict, declare the queue merge-ready and stop.** Report the ceiling PR number, each verdict with its producer and head SHA, and how merge readiness was confirmed from the forge's own state. The merge authority lands it on its explicit go-ahead, one PR at a time from the root.
5. **Never enable automatic merging on a stack, and never treat an automatic-merge field as authorization.** Only the root targets the protected trunk branch. If a previous run armed anything merge-shaped, report it and have the supervisor disarm it; confirm the field is back off before declaring readiness.
6. **Do not read automatic-merge fields as proof that a merge is authorized. Confirm merge readiness from the forge's own state, and if you cannot, say so rather than inferring it.
7. **Once the queue is handed off, stop touching the stack.** No restack, no speculative pushes. Independent work gets re-parented onto trunk and shipped on its own.
8. **Watch the queue, do not drive it.** Track each PR to its terminal state and report merges and the new ceiling. A stalled queue and a broken stack look identical from the outside, so diagnose a stall before mutating anything.
9. **Stop at the ceiling.** When the verified run is merged, report what landed, what the next unverified PR is, and what verifying it would take. Extending the run is a new pass through step 1, not a judgment call you make at 3am.

**Reply:** the verified run and its ceiling, each PR's verdict and who produced it, what you handed off and how readiness was confirmed, and what the next gap needs.


---
*Adapted for fleet use from pstack (MIT, upstream commit 7314f72): IDE and cloud-vendor references removed; autonomy is bounded by the brief; outward posting and agent-owned landing removed.*
