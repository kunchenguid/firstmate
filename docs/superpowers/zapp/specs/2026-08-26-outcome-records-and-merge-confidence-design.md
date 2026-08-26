# Outcome records and internal merge confidence

Design completing [PLAT-1193](https://redventures.atlassian.net/browse/PLAT-1193) (T9's `outcome#`
half) and [PLAT-1195](https://redventures.atlassian.net/browse/PLAT-1195) (T11), and building an
eighth risk signal on top of them.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec H.** It exists because of an idea raised in review on 2026-08-26 that turned a
scoped-out ticket into a blocker for something we want.

Status: **drafted 2026-08-26 for review.** Three open decisions flagged inline.

## Composability

| | |
|---|---|
| **Touches** | `src/worker.ts`, `src/ledger.ts`, `src/risk.ts`, `src/render.ts`, `src/evaluate.ts`, `infrastructure/terraform/dynamodb.tf`, new `src/outcomes.ts`, new `src/signals/internal-confidence.ts` |
| **Depends on** | **Spec G** (`worker.ts` routing, `render.ts`, `evaluate.ts`) and **Spec F** (`risk.ts` signal set) |
| **Safe to parallelise with** | **Spec I** — the weekly report reads the ledger and writes no application code these files touch |
| **Blocks** | Nothing planned. This is the last of the review-derived specs. |

## Why this stopped being optional

The review listed outcome records under "structural items before advisory mode", justified by the
exit criterion: *"zero would-have-approved PRs subsequently reverted"* is unmeasurable without them.
True, and on its own that is a reason to build them **eventually**.

Review on 2026-08-26 produced a second reason that is stronger. Renovate gates automerge on **Merge
Confidence** — release age, adoption percentage, and *crowd passing percentage*, the last built from
telemetry across thousands of repositories. We cannot buy that data.

**But we can build the same signal from our own fleet.** If `bankrate/repo-a` took
`fastify@5.12.0`, merged it, and nothing reverted or broke afterwards, that is real evidence for
`bankrate/repo-c`'s pending bump of the same package to the same version. It is crowd passing
percentage where the crowd is us.

The raw material is **already being recorded**: every eval record carries `classification.bumps` with
name, from and to. What is missing is the other half — did it merge, and did it stay merged. That is
exactly what outcome records are.

So outcome records are no longer only "measure the exit criterion". They unlock a signal we cannot
otherwise obtain at any price.

## Outcome records

A second record type under the existing partition key, so a pull request's evaluations and its fate
sort together:

```
pk = repo#<owner>/<name>#pr#<number>
sk = eval#<ISO>        ← exists today
sk = outcome#<ISO>     ← new
```

Four outcomes, in the order they can occur:

| Outcome | Detected from | Meaning |
|---|---|---|
| `merged` | `pull_request` action `closed` with `merged: true` | It landed |
| `closed` | `pull_request` action `closed` with `merged: false` | Abandoned — a real signal about the change |
| `reverted` | `push` to the default branch containing a revert of the merge commit | It landed and was taken back |
| `post_merge_failure` | A required check failing on the default branch after the merge commit | It landed and broke something |

Each record carries the `headSha` it resolves, so it joins to the evaluation that saw that code —
the epic's rule that a verdict can never apply to code it did not see runs in both directions.

### Routing `push`, finally

`push` has been subscribed on the App and dropped by the worker since PLAT-1233. Revert detection is
the first thing that needs it.

Detection is deliberately narrow: on a push to the default branch, examine each commit message for
GitHub's revert convention (`Revert "<original subject>"`) and for `This reverts commit <sha>`. When
the reverted SHA matches a merge commit recorded in an outcome, write a `reverted` record against the
same pull request.

**This will miss reverts that do not follow the convention** — a hand-written fix that undoes the
change without saying so, a force-push, a follow-up PR that reverses it. That is accepted: a missed
revert understates harm, and the alternative is diffing every push against every merged change, which
is expensive and still not exhaustive. The weekly report states the limitation beside the number so
nobody reads "zero reverts" as "nothing went wrong".

> **Open decision 1.** `post_merge_failure` is the loosest of the four. A required check failing on
> the default branch after a merge may have nothing to do with that merge — a flaky test, an
> unrelated infrastructure change, an expired credential. Attribute it to the most recent merge
> anyway and let the weekly report show the noise, or omit this outcome until there is a
> narrower attribution rule?

## The confidence signal

New signal `internalConfidence`, eighth in the set:

> For each bumped package at its target version, how many *other* enrolled repositories have already
> merged that exact package at that exact version without a subsequent revert or post-merge failure?

Graded on the weakest link — the package with the least corroboration, since one unproven package in
a group is the exposure:

| Prior clean merges elsewhere | Grade |
|---|---|
| ≥ 3 repositories | `low` |
| 1–2 repositories | `medium` |
| 0, with the fleet large enough to expect some | `high` |
| Fleet too small for the question to mean anything | `unknown` |

That last row matters more than it looks. **With one enrolled repository this signal is `unknown` on
every evaluation, forever**, and that is correct rather than a defect — "nobody else has taken this"
means nothing when there is nobody else. The threshold is a rule value, and the epic's exit criteria
already require ≥5 pilot repositories.

### The query

Answering it needs a lookup by package and version, which the ledger cannot do today — its only index
is `gsi-rules-sha`.

A new GSI, `gsi-package-version`, keyed on a synthesised `pkg#<name>@<version>` attribute written on
every **outcome** record, projecting the repo and outcome type. One query per bumped package, run
only for candidates.

Writing the attribute on outcome records rather than eval records is deliberate: the question is
"who *successfully took* this", and evaluations that never merged are not evidence of anything.

> **Open decision 2.** An outcome record covers a whole pull request, which may carry eleven bumps.
> A DynamoDB item can hold one partition-key value per index, so eleven packages need either eleven
> `pkg#` items per outcome, or a different store. Eleven small items per merge is cheap and simple;
> it also means the outcome table's item count is driven by bump count rather than PR count. Accept
> that, or introduce a separate `package-outcomes` table with its own shape?

## Recorded, and this time also surfaced

Spec F's principle says record everything cheap, surface what changes a reader's action. Outcome
records are the first thing that is *recorded after the fact* — the pull request is closed by the
time they exist, and there is no check run left to update.

They therefore surface **only** through the weekly report (Spec I) and direct queries. The check-run
table gains a row for `internalConfidence`, since that *is* graded and does change what a reader
concludes, but nothing re-renders a closed pull request's checks.

## Files

| File | Responsibility |
|---|---|
| `src/outcomes.ts` | Write outcome records; revert-message parsing |
| `src/signals/internal-confidence.ts` | Query `gsi-package-version`, grade on the weakest link |
| `src/worker.ts` | Route `pull_request` action `closed`; route `push` to the default branch |
| `src/ledger.ts` | Outcome record shape and the `pkg#` attribute |
| `src/risk.ts`, `src/render.ts` | Eighth signal, eighth row |
| `infrastructure/terraform/dynamodb.tf` | `gsi-package-version` |

## Error handling

| Condition | Behaviour |
|---|---|
| `push` with no revert convention in any commit | Nothing written. Not an error. |
| A reverted SHA matching no recorded merge | Logged `revert_unmatched`, nothing written — it reverted something we never evaluated |
| The confidence query fails | Signal `unknown`; evaluation continues |
| Fleet below the meaningfulness threshold | Signal `unknown` with that as its stated reason |
| An outcome arrives for a PR with no evaluations | Written anyway — it is still a fact, and the join is by key rather than by lookup |

## Testing

- **Revert parsing** — GitHub's default `Revert "..."` subject; the `This reverts commit <sha>` trailer;
  a commit mentioning the word "revert" in prose that must not match; a multi-commit push where one
  commit reverts and the others do not.
- **Outcome routing** — `closed` with `merged: true` writes `merged`; with `merged: false` writes
  `closed`; a push to a non-default branch writes nothing.
- **Confidence grading** — the weakest-link rule across a multi-package fixture; a package with three
  clean merges elsewhere; one with a merge that was later reverted, which must **not** count as
  corroboration; the small-fleet `unknown` path.
- **The join** — an outcome record's `headSha` matches the evaluation that graded that SHA, so the
  weekly report can answer "was any would-have-approved PR reverted".

## Out of scope

- **Acting on confidence.** Shadow mode unchanged; the signal grades and records only.
- **Reverts that do not follow the convention** — stated as a limitation rather than solved.
- **Cross-org evidence.** Only `bankrate` repositories enrolled in this service count.
- **Backfill.** Outcome records begin when this ships; prior merges are not reconstructed.

> **Open decision 3.** Backfill is technically possible — the GitHub API can list merged PRs and
> their commits for enrolled repos — and it would give the confidence signal a starting corpus
> instead of a cold start. Worth a one-off script, or accept the cold start and let the data
> accumulate?

## Definition of done

- [ ] `pull_request` action `closed` writes a `merged` or `closed` outcome record
- [ ] `push` to the default branch is routed and revert commits are matched to recorded merges
- [ ] A revert that matches no recorded merge is logged, not written
- [ ] Outcome records carry the `headSha` they resolve
- [ ] `gsi-package-version` exists and answers "who else merged this package at this version"
- [ ] A package whose prior merge was reverted does not count as corroboration
- [ ] `internalConfidence` grades on the weakest link and reads `unknown` below the fleet threshold
- [ ] Renderings say "of 8"
- [ ] Both checks remain `neutral` and on no required-checks configuration
