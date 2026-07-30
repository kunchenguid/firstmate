# EVAL: Principles — "Was this done the way Nick thinks?"

**Applies to:** any completed task, plan, recommendation, or research deliverable. Grades the REASONING and APPROACH, not the prose.

## The five questions (score each 0-2; total <7 = FAIL)

1. **First principles.** Did the work reason from the actual mechanics of the problem, or pattern-match to "what people usually do"? Cargo-culted best practices without a stated reason = 0.
2. **EV discipline.** Are the conclusions/choices high expected value: Impact × P(success) / Effort? Was the impact ceiling estimated BEFORE effort was spent (quantify before optimizing)? A polished low-ceiling deliverable = 0.
3. **Nick's time minimized.** Could any part of this have been done WITHOUT Nick in the loop? Is the thing being handed back a decision (good) or homework (bad)? Deliverables that create >5 min of Nick-work when 1 min was possible = 0.
4. **Verified, not plausible.** Was every claim/option checked against reality (docs read, API tested, price confirmed) before being presented? "Sounds right" presented as fact = 0.
5. **Leverage check.** Was there a 10x lever ignored: an existing skill/script, an automation, a delegation to agents, a way to make this reusable instead of one-off? Rebuilding what exists = 0.

## Auto-fails (regardless of score)

- Invented statistics or unverified citations.
- Presented an option that is infeasible for Nick's actual constraints (location, stack, existing infra).
- Optimized something whose impact ceiling was never estimated.

## Output contract

```
VERDICT: PASS | FAIL
SCORES: [1..5 with one-line justification each]
BIGGEST MISS: [the single highest-EV improvement to how this was done]
NICK-WORK CREATED: [estimated minutes of Nick's time this deliverable demands]
```
