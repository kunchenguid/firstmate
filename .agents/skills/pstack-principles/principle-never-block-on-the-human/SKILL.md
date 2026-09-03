---
name: principle-never-block-on-the-human
description: "Apply when tempted to stop and ask on reversible work inside the brief's scope. Proceed, report the result, let the supervisor course-correct after the fact; escalate only scope, product, destructive, outward-facing, or genuinely ambiguous choices through the status protocol."
user-invocable: false
metadata:
  internal: true
---

# Never Block on the Supervisor

The supervisor supervises asynchronously. Agents must stay unblocked on work the brief already authorizes: make reasonable decisions, proceed, and let the supervisor course-correct after the fact. Code is cheap. Waiting is expensive.

**Why:** Every permission pause stalls the pipeline and makes the supervisor the bottleneck. Since in-scope reversible work is reviewable, a wrong decision usually costs less than blocking.

**Pattern:**
- **Proceed, then present.** Do the work, show the result. Don't stop to ask "should I do X?" when X is inside the brief and reversible. Do X, explain why.
- **Settle empirical questions by experiment.** A question a prototype, test, or measurement could answer is never escalated. Build the sketch, read the result, proceed on the evidence.
- **Make the system self-healing.** When you notice a problem inside scope, log it and fix it in the next round.
- **Supervision is async.** The supervisor reviews plans, diffs, and changes on their own schedule. Design workflows for review-after-the-fact, with sparse supervisor-actionable status so waiting reads as work, not a wedge.
- **Code is cheap, attention is scarce.** A wrong implementation costs minutes to fix. A blocked agent costs the supervisor's attention to unblock.

**Boundaries (escalate through the status protocol, do not act):**
- **Scope expansion.** Anything outside the brief's GOAL/SCOPE/FORBIDDEN stops as a decision, even when reversible.
- **Product direction.** Product calls come from the supervisor; *execution* inside settled direction should not block.
- **Destructive, irreversible, or security-sensitive actions** (force-push, delete data, deploys, credential handling) stop for explicit authority.
- **Outward-facing actions** (posting on threads, publishing, messaging) never go direct; the worker reports, the supervisor relays.
- **Genuine ambiguity.** Escalate only when intent truly cannot be inferred from the brief and no experiment can settle it. State the options, recommend one, and wait.

---
*Adapted for fleet use from pstack (MIT, upstream commit 7314f72): IDE and cloud-vendor references removed; autonomy is bounded by the brief; outward posting and agent-owned landing removed.*
