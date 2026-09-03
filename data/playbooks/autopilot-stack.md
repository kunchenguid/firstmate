### Autopilot-stack

**You own the stack, never the landing. Build and verify the queue with full autonomy, then hand the supervisor one linear stack for review; the merge authority lands it.** For "autopilot-stack", "stack them, don't ship", "build the stack, I'll land it". The sibling of **Autopilot-full**. The owner loop and the verification gate are the same; only the terminal differs. There a clean verdict declares merge-ready on independent PRs. Here it appends a link to the one reviewed chain, and nothing ships without the merge authority.

1. **Run the owner loop unchanged.** One worker per PR owns its change end to end: build, registration of its own PR, self-proof (gates, CI, receipts), skeptical reviewer-feedback triage, a slop-strip (the **unslop** skill), **no-comments** (the **no-comments** skill), and babysit to green per `babysit.md` (verify only; landing belongs to the merge authority). Owners parallelize when the work is self-contained. Every owner keeps a `decisions.tsv` trail per the **show-me-your-work** skill, never committed, returned in its report.
2. **Audit on the wake chain.** The root runs audit ticks roughly every 30 minutes on a supervisor recheck chain: worker liveness per owner, progress, and protocol adherence.
3. **Hold the supervisor gates.** State-then-wait, so a request to state the plan is not a go. On the supervisor's stop, every owner takes an immediate zero-writes hold.
4. **Verify at STACK-READY.** The owner reports STACK-READY with the exact head SHA. The root verifier-fan-outs that SHA: parallel independent verifier passes re-running the gates at that SHA, a live runtime floor over the load-bearing behavior, and a receipts-and-diff audit that distrusts the PR body. The fan-out aggregates to one verdict. Findings go back to the owner, and nothing enters the stack unverified.
5. **Append on a clean verdict, never ship.** No owner merges, arms merging, or closes. A clean verdict appends the PR to the one linear stack, in verified order or an order the supervisor specified.
6. **Single writer on topology, parallel writers on builds.** An owner pushes only its own branch (never force-push without explicit supervisor authority; `git push --force-with-lease` only with that authority, after an ls-remote check), and reports its tip and intended parent. The root owns stack topology and registers each append in the program ledger: branch tip, intended parent, verdict SHA. A worker pushes only its own branch and never pulls branches below its own into its walk.
7. **Absorb drift at the root, then re-verify what moved.** The root absorbs trunk movement by restacking the chain; when a restack surfaces conflicts in an owner's files, that owner fixes its own slice and the root pushes the result. A restack rewrites every SHA above it and voids the verdicts at the old SHAs. Compare `git patch-id` at each verdict SHA against the new head. Anything that actually drifted goes back through step 4 before delivery. The countersign rule is unchanged from Autopilot-full. A genuinely new pin raises a stop for the root's fresh countersign; absorbing drift of landed values is not a raise.
8. **Deliver the chain.** The deliverable is one linear chain of verified PRs, reviewable bottom-up in the PR list, every link carrying its verifier verdict in the handoff report. The supervisor reviews and the merge authority lands it.

**Choosing between the autopilots.** Autopilot-full when the PRs are independent and each can be declared ready on its own. Autopilot-stack when the supervisor wants review before landing, the work is sequenced or coupled, or merge authority is withheld.

**Reply:** links to the stack root and tip, a one-line verdict summary per link, and anything parked or excluded with the reason.


---
*Adapted for fleet use from pstack (MIT, upstream commit 7314f72): IDE and cloud-vendor references removed; autonomy is bounded by the brief; outward posting and agent-owned landing removed.*
