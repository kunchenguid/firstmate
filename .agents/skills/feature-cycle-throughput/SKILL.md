---
name: feature-cycle-throughput
description: >-
  Agent-only playbook for finishing non-trivial ship work as fast as quality allows.
  Use before intake or dispatch of authz, money, multi-iteration UI, or multi-decision product ships;
  when stacking captain decisions onto a cursor (or other follow-up-queue) worker;
  when the only next step is captain staging, sign-off, or merge;
  and when scoping dual-tool UI verification to surfaces this tip actually changed.
user-invocable: false
metadata:
  internal: true
---

# feature-cycle-throughput

This skill is the single owner of Firstmate's feature-cycle throughput procedure.
Captain priority: large features must complete as fast as quality allows so business experiments are not blocked.
Hard delivery invariants still win - never merge without word, never violate project-specific unlock-on-spend or live-Stripe gates, and never discard unlanded work.

Evidence: 2026-07-17 Inspect.Properties org-members + credits campaign (org-members PR #28, credits PR #29).
Wall clock was dominated by serial product iterations, mid-flight A/B decisions, Cursor follow-up pile-ups, staging tip-deploy latency, and parked agents waiting on captain review - not by the first coding pass.

## When to load

Load before writing the brief or spawning for any non-trivial ship that touches authz, money, multi-iteration UI, or multi-decision product work.
Load again when applying a batch of captain locks to a follow-up-queue harness, when parking a tip that only awaits captain sign-off, or when deciding whether a tip needs a fresh dual-tool UI pass.
Skip for trivial one-shot fixes, docs-only, scout-only, or pure test-mock work unless the captain expands scope mid-flight.

## Intake decision matrix

Before the first ship spawn, lock the matrix below in the brief (or ask the captain once).
Do not discover A/B product options inside review.

Copy and fill:

```text
Feature-cycle intake matrix
- Goal / experiment unlocked:
- Authz (who can see / edit / spend / admin):
- Editability (which fields mutable; who; when):
- Money edge cases (packs, grants, refunds, legacy vs new, unlock-on-spend):
- In scope this tip:
- Explicitly out of scope:
- PR slice plan (behavior-first vs craft follow-on):
- Captain feedback loop (screenshots / local / one tip-deploy per round):
- Hard streams already under way (avoid a second money/authz stream unless accepted):
- Dual-tool surfaces this tip will change (chrome-devtools-axi + Playwright):
```

Ask the captain once when any cell is ambiguous.
Prefer the path that unblocks the next captain experiment sooner without violating hard delivery invariants.

## PR slicing (behavior vs craft)

Prefer a behavior and authz PR green first.
Ship visual craft as a follow-on PR, or as a clearly scoped second tip, when pixel polish matters.
Do not reopen authz review on every layout tweak.
If craft and behavior are inseparable for a safe ship, say so in the brief and keep the craft delta minimal.

## UI feedback and tip-deploy batching

Prefer one staging tip-deploy per captain feedback round.
Use screenshots or local browser checks for pure layout when that is enough.
Do not tip-redeploy after every micro-tweak unless the captain asked for a live redeploy.
Batch accepted layout notes into one deploy, then wait for the next round.

## Force-apply captain locks (follow-up queue)

When the captain returns several decisions at once, force-apply them as one locked list.
Never leave the same decisions stacked as unread follow-ups on a cursor (or any harness with a follow-up queue).

Procedure:

1. Interrupt the running turn (`Ctrl-C` on cursor; use the harness interrupt from `harness-adapters` for other adapters).
2. If a follow-up panel is still open, dismiss it with `Esc` so the composer is clear.
3. Send one `fm-send` message that lists every locked decision and the exact action for each.
4. Confirm the worker is acting on that single locked list, not draining stale follow-ups.

Cross-ref: `.agents/skills/harness-adapters/SKILL.md` cursor "Follow-up queue thrash" quirk for the adapter-local keystrokes.
This skill owns the when-and-why; harness-adapters owns the keystroke facts.

## Park when waiting on the captain

If the only next step is captain staging review, sign-off, or merge approval:

1. Record the tip SHA, PR or checklist URL, and what the captain must verify.
2. Keep the branch and durable task records.
3. Exit the worker or leave it truly idle without re-steering.
4. Do not deep-inspect false wedge or stale signals from a deliberately parked pane.
5. Resume only when the captain returns a decision or new work lands on that tip.

An idle parked tip is healthy supervision, not a stuck worker.

## Dual-tool scope

Keep chrome-devtools-axi plus Playwright for user-visible UI or authz surfaces that this tip actually changed.
Docs-only, test-mock-only, or pure review-fix commits do not need a fresh dual-tool pass.
Vitest alone is not the ship bar for UI surfaces unless the captain explicitly waives live or browser verification for that task.
Explore or repro with chrome-devtools-axi, then lock the finding in Playwright.

## One hard stream

Avoid running two high-risk money or authz PRs that both need frequent captain decisions at once.
Serialize those streams unless the captain explicitly accepts the supervision tax.
Independent low-risk tips may still run in parallel.

## Token-efficiency notes

Pay tokens where they buy wall-clock reduction: intake matrix, one locked decision send, one tip-deploy per feedback round.
Do not pay tokens for: re-asking settled matrix cells, draining stacked follow-ups one by one, redeploying for every micro-tweak, or re-steering a parked tip that only awaits captain sign-off.
Prefer short status outcomes over narrating internal supervision mechanics.
When tradeoffs appear, prefer the path that unblocks the next captain experiment sooner without violating hard delivery invariants.
