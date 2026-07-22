# Interaction patterns: how to talk to firstmate

How to phrase a request to the captain so firstmate dispatches the right shape of work.
The [README](../README.md) covers install and the basic chat loop; this document covers the specific vocabulary that triggers each named dispatch pattern.
Agent-facing detail (exact routing, exact skill names) lives in `.agents/skills/pattern-triggers/SKILL.md`; this is the human-facing companion.

## Why patterns, not commands

firstmate is not a slash-command tool.
You talk to it in plain language, the way you'd brief a project manager.
The five patterns below are not new syntax to memorize; they're names for five shapes of work firstmate can already dispatch, so you can ask for the shape you want instead of getting whatever shape firstmate guesses.
Each one maps onto the same architect/builder/fusion idea fusion-harness uses inside a single Pi session, just applied at the scale of a real fleet of crewmate agents in real git worktrees producing real PRs.

## The five patterns

### "Give me your opinion on X"

Two independent takes, side by side, no merge.
Use when you want to see how two different models/harnesses approach the same open question, or when you don't yet trust either answer alone.
You get both full reports; nothing is filtered or summarized on your behalf.

**Example:** "Opinion: should we use polling or webhooks for the sync job?"

### "Plan X" / "Figure out how to X"

Two independent proposals, then one reconciled plan.
Use when the scope is genuinely open, not when you already know what you want built.
If you already know the four things you want, just say so directly, brief and dispatch is faster and cheaper than fusion planning.
This pattern earns its cost on ambiguity, not on well-specified work - a real run on 2026-07-21 spent about ten minutes and thirty cents on two workers proposing entirely different, both-wrong milestones before the third synthesis step reconciled them into the right one, because the request was genuinely open-ended.

**Example:** "Plan the next milestone for the payments service" (open) vs. "Build a `/refund` endpoint that reverses a charge and emails a confirmation" (already scoped - just ask for this directly, skip planning).

### "Build X" / "Ship X" / "Fix X"

The ordinary path.
One crewmate, its own isolated worktree, the project's normal delivery pipeline, a PR when done.
This is the default; most requests should just look like this.

### "Review X" / "Check my work on X"

A dedicated critique pass against something that already exists - code, a PR, a document, a decision.
Different from asking a question: review means "find what's wrong with this," not "tell me about this."
For higher-stakes work, ask for a second review on a different model family explicitly - a real cross-family review on 2026-07-21 caught a genuine bug that four same-family review passes in a row had all missed.

**Example:** "Review PR 42 before I merge it" vs., for something you want extra confidence on, "Review PR 42, then get a second opinion from a different model."

### "Run the team on X" / a request that's really several related pieces of work

The full pipeline: plan produces a milestone and its issues, each issue ships as its own parallel task, then everything is checked to make sure the pieces actually work together before you're asked to approve anything.
That last step matters and is easy to skip by accident: on 2026-07-21, four issues each individually passed their own tests, and two of them were still incompatible with each other in a way nothing but a dedicated cross-issue check caught.
If firstmate ever reports a multi-piece milestone ready without mentioning that check, ask whether it ran.

**Example:** "Run the team on the observability milestone - stats, threading, TTL batching, and the sweeper."

## What you don't need to specify

Which project (firstmate resolves this from context or asks if it's ambiguous), which harness or model builds it (routed automatically by task type and difficulty), or the delivery mode (already configured per project).
You only need to signal the *shape* - how many perspectives, whether it's new work or a check on existing work, whether it's one piece or several that need to compose.
