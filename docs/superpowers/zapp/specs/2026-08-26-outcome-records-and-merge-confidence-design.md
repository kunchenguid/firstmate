# Outcome records and internal merge confidence

Design completing [PLAT-1193](https://redventures.atlassian.net/browse/PLAT-1193) (T9's `outcome#`
half) and [PLAT-1195](https://redventures.atlassian.net/browse/PLAT-1195) (T11), and building an
eighth risk signal on top of them.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec H.** It exists because of an idea raised in review on 2026-08-26 that turned a
scoped-out ticket into a blocker for something we want.

Status: drafted 2026-08-26; all three open decisions resolved in review 2026-08-26 and folded in —
`post_merge_failure` is tracked, package rows live in the existing table, and history is backfilled.

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

### `post_merge_failure`, and its honest attribution rule

This is the loosest of the four and it is **tracked anyway**. The reason is the question the phase
exists to answer: *did our verdict predict the outcome?* You cannot compare an eligibility and risk
grade against reality while only recording the outcomes that are easy to attribute — that selects for
the cases where nothing went wrong, which is the one bias that would make the whole corpus useless.

So the rule is stated, narrow, and its noise is disclosed rather than hidden:

> A required check failing on the default branch is attributed to the **most recent merge commit that
> is an ancestor of the failing commit** — provided that merge is one we evaluated, and the same
> check was passing on the commit immediately before it.

The second clause does real work. Attributing to a merge after a check was *already* red just
re-blames an existing failure on the next person through the door. Requiring a green-to-red
transition means the attribution is at least about a change in state.

It will still be wrong sometimes: a flaky test, an expired credential, an unrelated infrastructure
change landing in the same window. That is accepted, and handled three ways:

- Every record carries `attribution: 'inferred'` — never presented as established fact.
- The record names the check and both commit SHAs, so any individual case can be re-judged later
  without re-deriving it.
- The weekly report shows post-merge failures **separately** from reverts, never summed into one
  "things went wrong" number, and states the attribution rule beside the count.

Crucially, `post_merge_failure` does **not** silently disqualify a package from corroborating the
confidence signal — it is disclosed instead. A revert is a human deciding the change was wrong; a
post-merge check failure is an inference, and letting an inference suppress corroboration across the
fleet would spread one bad attribution everywhere. So the signal counts the merge and *says* it was
followed by a failure, leaving the reader to weigh it. See "The confidence signal" below.

## The confidence signal

New signal `internalConfidence`, eighth in the set:

> For each bumped package at its target version, how many *other* enrolled repositories have already
> merged that exact package at that exact version and **not reverted it**?

Graded on the weakest link — the package with the least corroboration, since one unproven package in
a group is the exposure:

| Prior clean merges elsewhere | Grade |
|---|---|
| ≥ 3 repositories | `low` |
| 1–2 repositories | `medium` |
| 0, with the fleet large enough to expect some | `high` |
| Fleet too small for the question to mean anything | `unknown` |

**A revert disqualifies; an inferred post-merge failure does not.** A revert is a human judgment that
the change was wrong. A post-merge failure is this service's own inference and may be misattributed —
suppressing corroboration on it would broadcast one bad guess to every repository considering that
package. So a merge followed by a post-merge failure still counts, and the signal's value records how
many of its corroborating merges carried one:

```json
"internalConfidence": {
  "weakest": { "package": "pg", "version": "8.23.0", "repos": 3, "withPostMergeFailure": 1 }
}
```

which renders as `pg@8.23.0: 3 repos (1 later had a failing check)`. The reader gets the count and the
caveat in one line, rather than a number quietly reduced by a rule they cannot see.

That last row matters more than it looks. **With one enrolled repository this signal is `unknown` on
every evaluation, forever**, and that is correct rather than a defect — "nobody else has taken this"
means nothing when there is nobody else. The threshold is a rule value, and the epic's exit criteria
already require ≥5 pilot repositories.

### The query

Answering it needs a lookup by package and version, which the ledger cannot do today — its only index
is `gsi-rules-sha`.

A new GSI, `gsi-package-version`, keyed on a synthesised `pkg#<name>@<version>` attribute, projecting
the repo and outcome type. One query per bumped package, run only for candidates.

The attribute goes on outcome-derived records rather than eval records deliberately: the question is
"who *successfully took* this", and evaluations that never merged are not evidence of anything.

### One item per bump, in the existing table

A DynamoDB item holds one partition-key value per index, so a pull request carrying eleven bumps
needs eleven indexed items. **They stay in `zapp-evaluations` under the pull request's existing
partition key**, rather than moving to a separate `package-outcomes` table:

```
pk = repo#<owner>/<name>#pr#<number>
  sk = eval#<ISO>                              ← the evaluation
  sk = outcome#<ISO>                           ← merged / closed / reverted / post_merge_failure
  sk = outcome#<ISO>#pkg#fastify@5.12.0        ← one per bump, carries pkgVersion for the GSI
  sk = outcome#<ISO>#pkg#pg@8.23.0
  …
```

Three consequences, all wanted:

- **Grouping is free.** One `Query` on `pk` returns the pull request's evaluations, its outcome, and
  every package row together, already sorted. No join, no second table, no cross-table consistency
  question. Whatever transformation Phase 1 wants can be done against that.
- **The item count is driven by bump count, not PR count.** Accepted. Eleven ~200-byte items per
  merge is negligible at any volume this service will see, and the alternative buys nothing except a
  second thing to provision, grant, back up and reason about.
- **The shared `sk` prefix keeps them together.** `begins_with(sk, 'outcome#<ISO>')` returns one
  outcome and exactly its packages, so a mis-parsed revert can be corrected without touching
  neighbouring outcomes.

Each package row carries `pkgVersion` (the GSI key), `repo`, `outcome`, `headSha`, `mergedAt`, and
`backfilled`. Deliberately denormalised: the confidence query reads the GSI projection alone and must
never need a follow-up read per corroborating repository.

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
| `src/outcomes.ts` | Write outcome and per-package records; revert-message parsing; the post-merge attribution rule |
| `src/signals/internal-confidence.ts` | Query `gsi-package-version`, grade on the weakest link |
| `src/worker.ts` | Route `pull_request` action `closed`; route `push` to the default branch; route `check_suite`/`check_run` completions on the default branch |
| `src/ledger.ts` | Outcome record shape, per-package rows, the `pkgVersion` attribute |
| `src/risk.ts`, `src/render.ts` | Eighth signal, eighth row |
| `scripts/backfill-outcomes.mjs` | New — one-off historical reconstruction, idempotent |
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
- **Backfilling `post_merge_failure`.** See below — the other three outcomes are backfilled; this one
  is not.

## Backfill

Without it the confidence signal reads `unknown` on every evaluation until the fleet has merged the
same package version three times *after* this ships — plausibly months. The raw material already
exists in GitHub, so the cold start is avoidable.

**A one-off script, `scripts/backfill-outcomes.mjs`, run manually.** No Lambda change, no schedule, no
new deployment path. It reuses the shipped `classify()` and the ledger's writer, so a backfilled row
is byte-shaped identically to a live one.

### What it does, per enrolled repository

1. `GET /repos/{o}/{r}/pulls?state=closed&per_page=100`, paginated, filtered to `merged_at != null`
   and an author on the `bots` allow-list. Bounded by `--since`, default 180 days.
2. For each: `GET /repos/{o}/{r}/pulls/{n}/files` → `classify()` → the bumps. **The same parser the
   service uses**, so a PR that would not classify today does not get invented bumps.
3. Write `outcome#<merged_at>` with `outcome: 'merged'`, `headSha`, `mergeCommitSha`,
   `backfilled: true`.
4. Write one `outcome#<merged_at>#pkg#<name>@<version>` row per bump.
5. Revert sweep: `GET /repos/{o}/{r}/commits?sha={default_branch}&since={oldest merged_at}`, scan
   messages with the same parser `src/outcomes.ts` uses, and rewrite any matched pull request's
   outcome to `reverted`.

Written with `PutItem` and `attribute_not_exists(sk)`, so re-running it is safe and it can never
overwrite a record the live service wrote.

### What it deliberately does not do

**No `post_merge_failure` backfill.** Reconstructing it needs the default branch's check-run history
plus the green-to-red transition test, for every commit in the window. That is a large number of API
calls to produce the *least* trustworthy of the four outcomes, and the attribution rule was never
running at the time. A backfilled record simply has no post-merge-failure information, which is
honest; the field is absent rather than `false`.

**No eval records.** Backfill reconstructs what happened, never what this service would have decided.
Manufacturing retroactive verdicts under today's `rulesSha` would corrupt the one dataset the shadow
phase exists to produce.

### The flag is load-bearing

Every backfilled row carries `backfilled: true`, and three things depend on it:

- The exit-criterion headline — "did any would-have-approved PR get reverted?" — counts **live
  records only**. Backfilled merges were never evaluated, so they cannot corroborate or refute a
  verdict that does not exist.
- The confidence signal **does** count them; that is the point. But because they carry no post-merge
  failure information, corroboration drawn from them is weaker than it looks.
- So the weekly report shows what fraction of corroboration is backfilled. A signal reading `low` on
  three backfilled merges and zero live ones is a different claim from one reading `low` on three
  live ones, and the reader is told which they have.

## Definition of done

- [ ] `pull_request` action `closed` writes a `merged` or `closed` outcome record
- [ ] `push` to the default branch is routed and revert commits are matched to recorded merges
- [ ] A revert that matches no recorded merge is logged, not written
- [ ] Outcome records carry the `headSha` they resolve
- [ ] One `pkg#` row per bump, under the pull request's own partition key, so a single `Query`
      returns evaluations, outcome and packages together
- [ ] `post_merge_failure` is attributed only on a green-to-red transition on the default branch,
      carries `attribution: 'inferred'`, and names both commit SHAs
- [ ] The weekly report shows post-merge failures separately from reverts, with the rule stated
- [ ] `gsi-package-version` exists and answers "who else merged this package at this version"
- [ ] A package whose prior merge was **reverted** does not count as corroboration
- [ ] A package whose prior merge had an inferred post-merge failure **does** count, and the signal
      says how many of its corroborating merges did
- [ ] `internalConfidence` grades on the weakest link and reads `unknown` below the fleet threshold
- [ ] `scripts/backfill-outcomes.mjs` reconstructs `merged`, `closed` and `reverted` using the
      shipped `classify()`, is idempotent via `attribute_not_exists(sk)`, and writes no eval records
- [ ] Every backfilled row carries `backfilled: true`; the exit-criterion headline counts live
      records only; the weekly report shows the backfilled fraction of corroboration
- [ ] Renderings say "of 8"
- [ ] Both checks remain `neutral` and on no required-checks configuration
