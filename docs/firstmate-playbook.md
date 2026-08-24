<!--
Firstmate SOFT playbook - the swappable dispatch grammar loaded into the
session-start digest by bin/fm-session-start.sh (the HARD contract is AGENTS.md;
this is the swappable grammar). A per-home override at config/firstmate-playbook.md
replaces this file wholesale when present. Editing this doc changes the fleet's
dispatch grammar with no code change (story fmops-07 §2, §7b; architecture.md §11).
SAFETY BOUNDARY (HARD): this playbook tunes only the dispatch GRAMMAR. It can
never relax AGENTS.md's hard rules, merge authority, or the destructive/
irreversible/security boundaries - those stay authoritative in AGENTS.md, which
loads first. A playbook is guidance, not a safety override. Model-invoked only;
the firstmate engine stays the coordination substrate (no ak CLI, no in-session
orchestrator).
-->

# Firstmate playbook - the orchestrator dispatch grammar

Firstmate barely uses the kit's routing/verification layer today.
Adopt these five patterns as a SOFT dispatch layer on top of the durable,
restart-surviving, multi-harness engine.
They change how briefs are written and how "done" is judged - not the engine.

## 1. Route-record taxonomy (a standard crew-brief header)

Every brief opens with one auditable route line:

```
Route: <class> | size: <trivial|standard|epic> | risk: <low|elevated|high> | domains: <n>
```

Classes: build-feature, fix-defect, investigate-explain, review-audit,
ship-release, create-content, plan-campaign, analyze-performance, design-visual,
operate-infra, document, meta-capability.
Risk is the highest-risk link, not the average.
Modifiers bend the route: `size: epic` inserts planning + phase split;
`risk: elevated|high` inserts verify/review links; `domains: 2+` adds one
sub-link per domain.
The header makes every dispatch decision inspectable after the fact.

## 2. The 7-field delegation contract (in every brief)

Every brief carries exactly:

1. **task** - the outcome, not the mechanics.
2. **files-to-read** - the context to load first.
3. **files-may-modify** - the write boundary (disjoint across parallel crews).
4. **acceptance** - the verifiable done condition.
5. **constraints** - what must not change / must hold.
6. **report-path** - where the deliverable lands (the native report path).
7. **status-line** - the one-line status protocol firstmate reads.

## 3. Arbiter verification discipline

Nothing is "done" until an INDEPENDENT route verifies the claims, checks, and
artifacts.
This generalizes firstmate's merge-gate habit into a reflex: the crew that did
the work never certifies its own completion; a separate judgment route (a review
skill, a fresh reader, or the merge gate) confirms the acceptance criteria are
actually met before teardown.
At elevated/high risk the verify link is never collapsed.

## 4. Kongming-style escalation (advisor, not model-swap)

On a hard fork, bring in a strong-model ADVISOR for one autonomous reply rather
than switching the worker's session model (the advisor persona is `kongming`,
strongest model, advisory-only).
Wire it into firstmate's blocked/needs-decision protocol: a worker stuck on a
hard problem escalates for counsel, keeps ownership, and firstmate stays the
decision point.

## 5. Risk-tiered gates

Align the quality bar with firstmate's needs-decision/blocked boundary:

- **low** - the executor's own checks suffice.
- **elevated** - a verify link plus self-review before "done".
- **high** - verify + an independent reviewer + explicit captain confirmation
  before any irreversible step (merge, deploy, destructive or security-sensitive
  action).
  This is exactly firstmate's captain-decision boundary; the taxonomy just names
  when the confirmation is mandatory.

These are grammar and preference, not the model.
The engine (durable, restart-surviving, multi-harness) stays the coordination
substrate; an in-session orchestrator that dies with the session is deliberately
NOT adopted for coordination.
