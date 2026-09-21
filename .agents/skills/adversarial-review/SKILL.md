---
name: adversarial-review
description: >-
  Agent-only procedure for putting two reviewers on different models over one subject independently, then mediating a dynamic written exchange between them and turning the result into converged recommendations plus a short two-sided case on whatever stayed contested.
  Use when the captain asks for an adversarial run, a debate between models, a second independent read, or two models argued against each other, and when a consequential or expensive call would genuinely change based on a second independent read of the same evidence.
  Do not use for routine changes, bug fixes, implementation work, a question an existing report already settles, or any ordinary scout where the second reviewer would only agree; one scout stays the default.
  This is not security red-teaming and not adversarial testing of a product, which are ordinary scout or ship work.
user-invocable: false
metadata:
  internal: true
---

# Adversarial review

Two reviewers read the same subject on different models without seeing each other's work, then exchange written rounds that firstmate relays.
What the captain buys is the independence, not the argument.
Two reviews that quietly converged early are worth one review.

Full convergence is a good outcome, not a failed run.
Zero contested items means two independent reads reached the same place, which is the cheapest confirmation available and is worth exactly what it cost.
Never manufacture a disagreement, stretch an exchange, or hold back a concession to justify the spend.

## When it earns its cost

Use it when at least one of these is true.

- A direction, architecture, or programme call is consequential and expensive to unwind.
- A programme has stalled and the reason is itself contested.
- A recommendation the captain is being asked to approve has exactly one author and acting on it is expensive.
- The evidence is large or scattered enough that one reader plausibly misses a whole class of finding.
- The captain asks for it.

Do not use it when any of these is true.

- The work is a routine change, a bug fix, or an implementation task with a known path.
- An existing report, decision, or captain answer already settles the question.
- You can predict that the second reviewer would only agree.
- The answer would not change what gets built.
- The call must be made sooner than two full reviews plus mediation can deliver.
- The captain has already decided, in which case relay the decision rather than reopening it.

A single scout that names its uncertainty honestly beats an adversarial review that was never in genuine doubt.

## Models

The two sides must be different models from different providers.
Two models from one vendor share training and fail the same way, so a same-provider pair buys agreement rather than independence.

The captain's default pairing is Opus on the Anthropic side against `gpt-5.6-sol` at `max` effort on the other.
He may name a different model per provider at any time and that instruction wins.
Resolve the concrete harness, model, and effort through `AGENTS.md` section 4, `harness-adapters`, and any matched dispatch profile, exactly as any other spawn does.
Never invent a parallel selection mechanism here.
Confirm the model is currently available from that harness's own catalog rather than from this page, because model names move.

Run both sides at comparable effort.
An asymmetric pair makes the weaker side's concessions meaningless, because a concession then measures effort rather than evidence.
Before dispatch, confirm for each side separately that the resolved effort actually reaches its launch, because `bin/fm-spawn.sh` records an unsupported level in task metadata and omits the flag, and a harness adapter may accept a level only for particular models.
A side whose launch cannot carry the intended effort makes the pair asymmetric, so report that to the captain and let him pick the harness, model, or effort instead of launching the pair anyway.

The orchestration shape above each model is free and the two sides need not match.
One side may be a single reviewer while the other orchestrates subagents; what has to differ is the model, not the topology.

## Phase 1 - independent reads

Both sides are scouts under `AGENTS.md` section 7: the deliverable is a report, never a PR.

Write both briefs from one subject statement.
Give each side the same questions, the same evidence pointers, the same scope, and the same per-side spend bound.
Split the captain's pool in half by default and name that half in each brief as that side's own bound; he may set a different split or a different per-side figure.
Never state the whole pool to a side, because neither side can observe the other's consumption during phase 1 and two sides each spending the pool spend it twice.
Asymmetric briefs produce asymmetric reviews, and that difference is an artifact of your writing rather than a finding.

Tell each side, in its `## Firstmate spec`, that it is one of two independent reviewers, that the other exists, and that it must not read the other's directory or the exchange directory until firstmate says the exchange is open.
Each side writes its rounds inside its own worktree and names the path in its status line, because the generated scout brief already permits every write there and authorizes nothing outside it beyond the report and the status file.
Firstmate copies each round out of that worktree into the shared exchange directory as it relays it, named after the subject rather than after either task so neither side owns it: `data/<subject>-converge/`, holding one file per side per round.
Copy each round out before the worktree can be discarded, because the worktree is scratch and the exchange directory is the one durable record of what was exchanged.

Require each side to answer what has gone well, not only what went wrong.
A review that only finds faults is not a review, and a reviewer that never says so is not reading for the captain.

Hold both reports until both exist.
If one side finishes first it waits; handing it the other's report early destroys the only thing this pattern buys.

## Phase 2 - the exchange

Each round is one file per side, written inside that side's own worktree after reading the other side's latest material in full, which firstmate then copies into the exchange directory as it relays it.
Both sides are told to aim at one joint recommendation per question, and to treat anything still contested as the captain's to decide rather than theirs to win.

Both sides write their round simultaneously, so a pair of rounds routinely crosses: each answers the previous round rather than its counterpart.
Crossing is correct and preserves independence within the round, but it means an item can look contested only because one side had not yet seen the other's concession.
The mediator labels a crossed pair, and withholds the contested label from an item only when that unseen concession is the whole of the apparent disagreement.
An item both sides still take opposite positions on once each has seen the other's material is contested, whether or not the round that carried it crossed.

Every round obeys four rules.

1. **Concessions first.**
   Each round opens with a numbered list of what this side now accepts from the other, what it withdraws from its own earlier work, and what it got wrong.
   A round with nothing to concede says so explicitly and says what it checked before concluding that, rather than omitting the section.
   Conceding, withdrawing a recommendation both earlier passes accepted, and correcting your own report are results.
   The exchange is scored on what it corrects, not on who wins.

2. **Measure rather than argue.**
   When a contested claim can be settled by a bounded read-only check, run the check and report the exact command, the timestamp, and the result instead of arguing the point.
   A disputed number is a measurement, never a round.
   When two measurements of the same thing disagree, measure the disagreement itself rather than picking a side, because the gap is usually a defect in one side's method rather than a fact about the subject.
   Measurements stay read-only and must not reach a metered or paid surface outside the captain's stated allowance.

3. **Separate what is settled from what is open.**
   Each round carries an explicit settled list and an explicit open list.
   An item is settled when both sides have stated the same position, not when one side has stopped mentioning it.

4. **Write the contested items for the captain, not for the other agent.**
   Once an item looks like it will stay contested, each side writes its case in the captain's language, short, and including the strongest argument against its own position.

### What ends the exchange

The stop is a judgement about what the last round did, not a count.
Close the exchange as soon as any of these holds.

- Both sides' latest round carried no new concession and no new evidence.
- Every question is settled and neither side lists an open item, which can happen after a single round.
- The remaining disagreements are stable: each side has stated its position and the best case against itself, and neither moved this round.
- A further round would only restate positions already on record.
- The only thing standing between the sides is a call that belongs to the captain, which goes to him rather than being argued for another round.

Closing with an open item requires each side's captain-facing case under rule 4 to already exist for that item.
When one is missing, request exactly that case as the final round instead of closing, because the Contested bucket otherwise cannot be built without firstmate authoring a position it is forbidden to hold.

Never let a round happen merely because a round is available.

When a stopping condition fires with most questions still open, the subject was scoped too broadly; report the state as it stands and say so, rather than opening further rounds to work through the backlog.

## Firstmate's job is mechanical

Firstmate mediates and never argues.
It does not take a position, rank the arguments, add an argument of its own, tell a side which way to concede, or carry one side's case into the other's round in its own words.

Its complete list of moves:

1. Write the two briefs and spawn both scouts.
2. Hold each report until both exist, then open the exchange by steering both sides with the same instruction through `bin/fm-send.sh`, naming the other side's material and the exchange directory to read, and telling each side to write its rounds inside its own worktree and name the path.
3. Copy each round out of that side's worktree into the exchange directory and relay it to the other side unaltered, by its exchange path.
4. Point a side at a contested claim that a bounded free measurement could settle, or at a question it did not answer.
   This is the only input firstmate adds, and it is a pointer, never a position.
5. Decide after each round whether the exchange closes, and say which stopping condition fired.
6. Build the captain-facing outcome below.

## Outcome

Two buckets, and every item lands in exactly one of them, in the captain's own language.

**Converged.**
One clear recommendation per question, stated once.
Do not show him the argument that produced it, who conceded what, or how many rounds it took.
Never re-litigate a converged item in front of him.

**Contested.**
Everything the two sides did not agree on, including a proposal the other side never answered before the exchange closed.
One short paragraph per side, each naming what he gets and what he gives up on that path.
No transcript, no file references, no agent names, no round numbers.
He is choosing between two paths, so each paragraph exists to make one path's pro and con legible, not to win.
When one side never answered the item, say that plainly and have its proposer write the case against their own proposal, so the captain still gets both sides.

Every contested item is a captain call, so load `captain-hold-lifecycle` and register them before treating the review as complete.

Report both sides' spend and what the spend changed.
A test that could not have changed a recommendation should not have been run.
