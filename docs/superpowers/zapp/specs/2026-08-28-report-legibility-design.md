# Weekly report legibility: dots, a trail, and honest denominators

Design for rewriting the weekly shadow report so a human reads it in ten seconds and can follow any number down to its source — plus the seven correctness and framing findings from the 2026-08-28 provenance analysis.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec J.** It is the first spec in this epic driven by a reader complaint rather than a missing capability: the report is accurate and nobody wants to read it.

Status: **drafted 2026-08-28 for review.** Two decisions resolved in review before drafting — dots-only in the channel, and interpret-with-the-number-attached. Two open decisions flagged inline.

## Composability

| | |
|---|---|
| **Touches** | `src/report/render.ts`, `src/report/query.ts`, `src/report/index.ts`, new `docs/weekly-report.md`, `docs/policy.md` |
| **Depends on** | Nothing. Specs D–I have all landed; this changes presentation and four computed fields. |
| **Safe to parallelise with** | Anything outside `src/report/`. It touches no gate, no signal, and no ledger write. |
| **Blocks** | Nothing. |

## The problem, stated precisely

The current post is six sections at identical visual weight, carrying **four caveat blocks** — hedges nearly outnumber facts. Three specific failures:

**It reports without interpreting.** `medium: 11` and `adoption: 5 of 71` both leave the reader to work out whether that is fine or alarming. Neither is obvious, and one of them is wrong (below).

**It has no hierarchy.** "Did anything get reverted" — the question the entire phase exists to answer — sits in the same visual weight as a recorder-coverage fraction.

**It has no trail.** A single `docs/policy.md` link at the very bottom. A reader who doubts a number has nowhere to go.

The fix is not more prose. It is three layers with one job each.

## The three layers

| Layer | Answers | Where |
|---|---|---|
| **1 · Dots** | "Do I need to care this week?" | The channel post — headline plus 3–4 one-line dots |
| **2 · Numbers** | "What exactly happened?" | Threaded replies, one per section |
| **3 · Provenance** | "Where does this come from, and what does it mean?" | `docs/weekly-report.md`, anchored per section |

Threads are the mechanism because they need nothing new: `chat.postMessage` returns a `ts`, and replies attach by passing it as `thread_ts`. The existing `chat:write` scope already covers it. The channel shows one post; the detail is one click away and collapsed by default.

**Layer 3 is why the docs move matters.** Putting the provenance analysis in the repo is not housekeeping — it is the bottom of the trail. Without it, "dive deeper" terminates in a Slack message.

### Layer 1: the channel post

```
Weekly Shadow Report — week of 24 Aug

No would-have-approved pull request was reverted.
2 of 6 pull requests would have been candidates.

• Eligibility is doing real work — 59 of 71 evaluations were blocked,
  and 34 of those were CI that had not reported yet
• Risk graded every candidate medium (11 of 11) — expected this early;
  few repos and thin history pull grades down
• adoption and provenance read 5 of 71, but they only ever run on
  candidates — the real figure is 5 of 12

🧵 Numbers, tables and caveats in thread · full reference in docs/weekly-report.md
```

Six lines. Every number in it is also a claim about what the number means.

### Layer 2: the thread

One reply per section, in a fixed order every week so a returning reader knows where to look: **eligibility · risk · outcomes · recorders**. Each reply carries the table that section currently renders inline, plus that section's caveat, plus a link to its anchor in `docs/weekly-report.md`.

Fixed order matters more than it sounds: a thread whose shape changes weekly is a thread nobody learns to skim.

### Layer 3: `docs/weekly-report.md`

New, and seeded from the provenance research file — but only its **durable half**. That document currently mixes two kinds of content, and only one belongs in the repo:

| Content | Goes to |
|---|---|
| Provenance map, DynamoDB schema, what `unknown` means per signal, the caveats | `docs/weekly-report.md` |
| The seven findings | This spec's plan, as work items |

`docs/policy.md`'s current "Where the weekly shadow report's numbers come from" section (33 lines of line-anchored links) is **replaced by a pointer**. It is the wrong place for it: `policy.md` answers "why did this check say that about my pull request", and a weekly fleet report is a different question for a different reader.

## Interpretation that cannot go stale silently

This is the part most likely to be built wrong, so it gets the most precision.

"Expected this early; few repos and thin history" is true today and becomes a **lie** once ten repositories are enrolled. An interpretation with no expiry is worse than a raw number, because a raw number never claims to be fine.

So every interpreted sentence is generated from a **stated precondition over the data**, and disappears when its precondition stops holding. Not a constant string with a comment; a rule.

```ts
interface Interpretation {
  /** Does this reading apply to this week's data at all? */
  applies: (a: WeeklyAggregate) => boolean;
  /** The sentence, with its own numbers substituted in. */
  render: (a: WeeklyAggregate) => string;
}
```

Three concrete rules, each with its precondition:

| Dot | Precondition | When the precondition fails |
|---|---|---|
| "expected this early" on a medium-heavy risk distribution | fewer than `minFleetForConfidence` repos enrolled **and** ≥1 signal `unknown` on every graded evaluation | The sentence is omitted. A medium-heavy week in a mature fleet gets the bare distribution and no reassurance. |
| "mostly CI that had not reported" | ≥50% of blocked evaluations failed a `CI_DEPENDENT_GATES` member | Reports the top gate plainly instead, with no transience claim |
| "the real figure is 5 of 12" | a candidate-scoped recorder's coverage differs from its all-evaluation coverage | Omitted once scope and denominator agree |

**The test that keeps this honest:** a fixture with 12 enrolled repositories and a medium-heavy distribution must render **no** "expected this early" sentence. That single assertion is what stops the reassurance outliving its basis.

> **Open decision 1.** `CI_DEPENDENT_GATES` currently lives in `src/evaluate.ts` as a private constant (`checksGreen`, `coverageFloor`). The report needs the same set to call a failure transient. Export it from `evaluate.ts`, or restate it in the report? Exporting couples the report to the evaluator; restating risks the two drifting so the report calls a failure transient that the evaluator has stopped treating as re-evaluable. I lean **export** — a drift here produces a confidently wrong sentence, and the coupling is one `ReadonlySet` of gate names.

## The seven findings

Ranked by whether they mislead a reader or merely cost them time. All seven land in this spec; the plan sequences them.

### F1 · Gate-failure counts render blank — the whole distribution is invisible

The Count column is empty in the live post while the Gate column renders. Only difference: `rawText` for names, `rawNumber` for counts (`render.ts:100,166`). Hidden as a result: `checksGreen` 34, `classificationPermits` 20, `changeClass` 3, `botAllowlisted` 2 — the section the spec calls the direct input to Phase 1 tuning, currently conveying nothing but an ordering.

**Fix:** `rawText(String(count))`, the cell type proven to render in that same table. Delete `rawNumber` entirely; it has one call site.

**Why the tests missed it, and what to add:** `tests/report-render.test.ts:49-51` asserts the cell *shape* — `type: 'raw_number'`, numeric `value`, string `text`. Slack accepts the block, the run goes green, nothing displays. Two prior commits (`b604f57`, `9a6b969`) show this was already being chased against live Slack by trial and error.

A payload-shape test cannot catch a rendering failure. What *can*: a rule that every table cell in the payload is `raw_text` with non-empty text. That is narrower than the current test and it would have failed on this bug.

### F2 · `adoption` and `provenance` are candidate-only, reported against all evaluations

Both are written inside `assessRisk`, which runs only when `verdict === 'candidate'`. Their ceiling is **12**, not 71. "5 of 71" implies 66 misses; 59 of those could never have been anything else. The true reading is 5 of 12.

`commitAuthorship` and `wouldHaveMergedInWindow` *are* all-evaluation fields, so 33 of 71 is honest for them. The section mixes two populations under one heading and gets one wrong.

**Fix:** each recorded field declares its scope, and the denominator follows it.

```ts
const RECORDED_FIELDS = [
  { field: 'adoption', note: 'deps.dev v3alpha', scope: 'candidates' },
  { field: 'provenance', scope: 'candidates' },
  { field: 'commitAuthorship', scope: 'evaluations' },
  { field: 'wouldHaveMergedInWindow', scope: 'evaluations' },
] as const;
```

Rendered with the population named — `5 of 12 candidates`, `33 of 71 evaluations`. Without the label a reader cannot tell which population a fraction covers, which is how this became wrong in the first place.

### F3 · The headline rate is per-evaluation, and one pull request dominates it

**PR #27 alone accounts for 40 of the 71 evaluations.** The `check_suite` re-evaluation path writes a fresh record per delivery, so a single busy pull request can move every evaluation-level number in the report. "12 of 71 evaluations would have been approved" is arithmetically correct and answers a question nobody asked.

Live: 6 distinct pull requests, 2 with at least one candidate verdict.

**Fix:** the **pull-request** rate becomes the headline figure — `2 of 6 pull requests would have been candidates`. The evaluation-level fraction moves to the thread, where its skew can be stated beside it. `WeeklyAggregate.overall` gains `distinctPrs`.

This is the finding most likely to change somebody's conclusion, which is why it is in the headline rather than a footnote.

### F4 · `cumulativeApproved` is misnamed and feeds the headline

It is *this week's* distinct approved PRs. `render.ts:144` already carries a comment admitting it. The headline reads "2 pull requests would have been approved **this week**" off a field called `cumulative` — and the epic's exit criteria genuinely do want a cumulative figure, so the next person needing one will find a field that looks right and is not.

**Fix:** rename to `distinctApproved`. A real cumulative number needs a query the report does not make; noted in Out of scope.

### F5 · Signal-health denominators move with schema vintage, silently

`targetVersionHealth` reads `0 of 5` and `internalConfidence` `1 of 1`, in a column of `0 of 11`s, with nothing explaining the shift. Both accurate — those signals did not exist for older records. **Seven distinct `rulesSha` values in one week.**

**Fix:** the thread's signal table gains a column for how many evaluations *could* have carried each signal, and the section states that a denominator below the graded-evaluation count means the signal is newer than some records. A reader comparing rows then sees a fact rather than an inconsistency.

### F6 · One candidate has no risk grade, for a legitimate reason nothing surfaces

`eval#2026-08-25T18:55:50.750Z`, PR #27, `rulesSha 3c2d6e20`, no `trigger` attribute — written before the risk heuristics shipped. `riskGrades` correctly skips it: 11 grades for 12 candidates.

Not a defect, but exactly the one-off discrepancy that costs somebody an afternoon in the Phase 1 meeting, with nothing in the report to resolve it.

**Fix:** the risk reply states graded-vs-ungraded candidates when they differ, and names the reason as pre-dating the field.

### F7 · The scan is unbounded above and grows with the table, not the week

`fetchWeek`'s `FilterExpression` is `sk >= "eval#<since>"` — a floor only. Because `'o' > 'e'` lexicographically, **every `outcome#` row passes regardless of date**, and there is no upper bound at all; `withinWindow()` does the real filtering client-side. Correct today at 89 items, and documented.

**Not fixed here, deliberately.** It is a read-cost question, not a legibility one, and this spec should not grow a performance workstream. What this spec *does* add is the trigger: the report's own thread states the item count it scanned, so the number somebody would need to notice the problem is in front of them weekly rather than discovered during an incident.

The code's note says a scan stops being fine around fifty repositories. The real trigger is total item count, and the table has no TTL by design.

## Files

| File | Change |
|---|---|
| `src/report/interpret.ts` | **New** — the `Interpretation` rules and the dot generators. Pure; takes a `WeeklyAggregate`, returns strings. |
| `src/report/render.ts` | Splits into a channel-post renderer and a thread-reply renderer; `rawNumber` deleted |
| `src/report/query.ts` | `distinctPrs`; `distinctApproved` rename; recorder scopes; per-signal eligible counts; scanned-item count |
| `src/report/index.ts` | Post the parent, then the replies with its `ts` |
| `docs/weekly-report.md` | **New** — layer 3, seeded from the provenance analysis |
| `docs/policy.md` | The 33-line provenance section becomes a pointer |

`interpret.ts` is a separate module rather than more functions in `render.ts` because it is the only part of this system that encodes a judgment, and judgments deserve their own test file and their own review.

## Error handling

| Condition | Behaviour |
|---|---|
| Parent post fails | Throw before attempting any reply. Nothing partial is published. |
| A thread reply fails | **Parent stays up**, run goes red, the failing section is named in the error. The parent carries the essential content; losing a detail reply degrades the report rather than voiding it. |
| A later reply fails after an earlier one succeeded | Same — no attempt to delete what already posted. A thread missing its fourth reply is legible; a half-deleted thread is not. |
| An interpretation's precondition throws | That dot is omitted and logged. A missing dot beats a report that failed to post. |
| Zero evaluations | Parent posts the empty state explicitly; no replies. Unchanged from today, and still load-bearing — a silent week must not look like a broken schedule. |

## Testing

- **Interpretation preconditions** — the load-bearing group. A 12-repo fixture with a medium-heavy distribution renders **no** "expected this early". A week where under half of blocked evaluations are CI-dependent renders no transience claim. A recorder whose scope and denominator agree gets no "real figure is" sentence.
- **Every table cell is `raw_text` with non-empty text** — asserted across the whole payload, parent and replies. This is the rule that would have caught F1, and it is narrower than the shape test it replaces.
- **Denominators** — a fixture with candidate-scoped and evaluation-scoped recorders renders two different populations, each named.
- **Headline is PR-level** — a fixture with one pull request evaluated forty times and one evaluated once produces "1 of 2 pull requests", not a 40-weighted evaluation fraction. Built directly from the live skew.
- **Thread order is fixed** — replies come back in the declared order regardless of which sections have content.
- **Parent survives a failed reply** — the parent's `ts` is returned and the error names the section.
- **Docs anchors resolve** — every anchor the render links to exists as a heading in `docs/weekly-report.md`. A trail that dead-ends is worse than no trail, and this is the assertion that keeps it live as either file is edited.

> **Open decision 2.** Anchor checking couples a test to a markdown file's headings, which is unusual and mildly brittle — a heading reworded without touching the renderer fails the suite. The alternative is trusting the links and finding out from a reader. I lean **keep the test**: this spec's whole premise is that the trail is the product, and a broken trail is invisible to everyone except the person who most needed it.

## Out of scope

- **Fixing the unbounded scan** (F7) — surfaced weekly, not solved here.
- **A real cumulative approved count** — needs a cross-week query the report does not make. F4 only stops the current field pretending to be one.
- **Per-repository posts.** One fleet-wide post, unchanged.
- **Alerting on thresholds.** Phase 1, once thresholds exist.
- **Changing any gate, signal, or ledger write.** This spec reads and renders; it computes nothing new about a pull request.

## Definition of done

- [ ] The channel post is the headline plus 3–4 dots, and nothing else
- [ ] Every dot carries both a claim and its number
- [ ] Thread replies land in a fixed order: eligibility · risk · outcomes · recorders
- [ ] Every reply links to its own anchor in `docs/weekly-report.md`
- [ ] "Expected this early" is generated from a precondition and vanishes when it fails, proven by a 12-repo fixture
- [ ] Gate-failure counts are visible in the rendered post *(F1)*
- [ ] No table cell in any payload is `raw_number`, asserted across parent and replies *(F1)*
- [ ] Recorder fractions name their population; candidate-scoped fields divide by candidates *(F2)*
- [ ] The headline rate is per pull request; the per-evaluation fraction is in the thread with its skew stated *(F3)*
- [ ] `cumulativeApproved` is renamed `distinctApproved` *(F4)*
- [ ] The signal table shows how many evaluations could have carried each signal *(F5)*
- [ ] Graded-vs-ungraded candidates are stated when they differ *(F6)*
- [ ] The thread states the item count scanned *(F7)*
- [ ] `docs/weekly-report.md` exists and `docs/policy.md`'s provenance section is a pointer to it
- [ ] A failed thread reply leaves the parent up and turns the run red
- [ ] Zero evaluations still posts
