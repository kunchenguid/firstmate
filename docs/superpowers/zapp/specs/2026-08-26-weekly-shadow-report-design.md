# Weekly shadow report

Design for the epic's M4 / T12 — the scheduled report that turns the decision ledger into something a
human reads.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec I**, and it is **deliberately pulled forward** from the end of the epic. Review on
2026-08-26 established that the service is now recording a meaningful amount of data with **no read
path at all** — visible only by querying DynamoDB by hand, which nobody will do. Collecting data
nobody looks at is how a broken recorder stays broken for six weeks.

Status: **drafted 2026-08-26 for review.** Two open decisions flagged inline.

## Composability

| | |
|---|---|
| **Touches** | `src/index.ts` (a third dispatch branch), new `src/report/`, `infrastructure/terraform/` (EventBridge rule, IAM), `.github/workflows/deploy.yml` is untouched |
| **Depends on** | Nothing structurally — it reads whatever ledger fields exist and renders what it finds |
| **Safe to parallelise with** | **F, G and H.** It writes no application logic those specs touch, and it renders fields defensively rather than assuming a schema. |
| **Blocks** | Nothing. |

Its independence is the argument for pulling it forward: it can be built now, in parallel, and each
later spec's new fields simply start appearing in it.

## Why now rather than at M4

Three tiers of data exist (Spec F states the principle). Tier three — recorded but never graded — is
already accumulating and will grow substantially:

- `provenanceLost` per bump (Spec F)
- `adoption` dependent counts (Spec F)
- `commitAuthorship` and `wouldHaveMergedInWindow` (Spec G)
- outcome records (Spec H)

None of it surfaces anywhere. Two concrete failure modes follow. A recorder that silently breaks —
deps.dev withdrawing its alpha endpoint, a GitHub response shape changing — produces null for weeks
and looks like data. And Phase 1's thresholds are supposed to be *derived* from this corpus, which
requires somebody having looked at it before the derivation meeting.

## The third role

`lambda-deploy` deploys exactly one function per environment — `<app-name>-<env>` — which is why
PLAT-1233 put the receiver and worker in one function dispatched on event shape. **The same
constraint applies here**: a separate report Lambda would be created by Terraform and never receive
code.

So the report is a **third branch in `src/index.ts`**, dispatched on an EventBridge scheduled event:

```ts
if (isScheduledEvent(event)) return report(event);   // { source: 'aws.events' }
if (isSqsEvent(event)) return worker(event);
return receiver(event);
```

The discriminator is `event.source === 'aws.events'`, which neither an SQS batch nor a Function URL
request carries.

**The report role needs a longer budget than the request roles.** A weekly scan of the evaluations
table is bounded by a week of data rather than one pull request, so the function timeout may need to
rise — and if it does, the queue's visibility timeout must keep its 6:1 ratio, which affects the
worker. That coupling is the one real cost of sharing a function.

> **Open decision 1.** Alternative: keep the report out of the Lambda entirely and run it as a
> scheduled **GitHub Actions workflow** in the zapp repo, reading DynamoDB through the existing OIDC
> role. That sidesteps the shared-timeout coupling and the one-function constraint completely, and
> puts the report's own logs where a human already looks. It costs a second deployment path and a
> second place the report's code can live.

## What it says

The epic specifies the content; this adds the tier-three section.

**Headline** — the number the phase exists to produce:

> **Did any would-have-approved pull request get reverted?** *(This week: no. Cumulative: no, across
> 47 would-have-approved evaluations.)*

**Would-have-approved rate**, weekly and cumulative, per repository and overall.

**Gate-failure breakdown** — which gate blocks most, ranked. This is the number that tells you
whether a rule is doing work or just failing everything, and it is the direct input to Phase 1
threshold tuning.

**Risk-grade distribution**, and per signal, how often each graded `unknown`. A signal that is
`unknown` 90% of the time is not contributing and should be either fixed or removed — that is
invisible today.

**Per-repository readiness** against the exit criteria: evaluation count, would-have-approved rate,
reverts.

**Recorder health** — the tier-three section, and the reason for pulling this forward:

> `adoption` unavailable on 4 of 31 evaluations (deps.dev v3alpha)
> `provenanceLost` recorded on 31 of 31 · 2 packages lost provenance this week
> `commitAuthorship` recorded on 31 of 31 · 3 pull requests had non-bot commits
> `wouldHaveMergedInWindow` false on 6 of 31

Each line is both the data and its own health check: a recorder that stops working shows up as a
denominator that stops matching.

## Delivery

Slack, via the `SLACK_WEBHOOK` organisation secret the deploy workflow already uses.

The report is also written to S3 as JSON alongside the human-readable post, so a later analysis does
not have to re-derive a week's aggregates or scrape Slack. Cheap, and the epic already anticipates an
S3 archive for the ledger.

> **Open decision 2.** Which Slack channel? The epic does not name one. `#platform-tools-support`
> exists per the FreshService routing, but a weekly report may not belong in a support channel.

## Schedule

EventBridge, weekly. Monday morning is the obvious slot — the week's data is complete and there is a
working week to act in.

The query is a scan of `zapp-evaluations` bounded by `sk >= eval#<week-start>`. At Phase 0 volumes —
hundreds of records — a scan is fine and a purpose-built index is not worth the schema. That
assumption is stated here so it can be revisited rather than inherited: at ~200 evaluations a week
across five repositories it remains fine; at fifty repositories it does not.

## Files

| File | Responsibility |
|---|---|
| `src/report/query.ts` | Read a week of evaluations and outcomes; aggregate |
| `src/report/render.ts` | Slack Block Kit body and the JSON artifact |
| `src/report/index.ts` | Orchestrate; post; archive |
| `src/index.ts` | Third dispatch branch |
| `infrastructure/terraform/` | EventBridge rule, S3 bucket, `dynamodb:Query`/`Scan` and `s3:PutObject` grants |

`src/report/` is a directory rather than one file because querying, aggregating and rendering are
independently testable and the rendering will change far more often than the querying.

## Error handling

| Condition | Behaviour |
|---|---|
| No evaluations this week | Report posts anyway, saying so. A silent week is indistinguishable from a broken schedule. |
| Slack post fails | Throw — the scheduled invocation fails visibly and the S3 artifact is still written first |
| S3 write fails | Logged; the Slack post still goes out |
| A ledger record is missing a field a later spec added | Rendered as "not recorded", never as zero |

The last row is what makes this parallel-safe with F, G and H: the report renders fields defensively,
so it can ship before the fields it will eventually show exist.

## Testing

- **Aggregation** — fixture ledgers producing known rates; a week with zero evaluations; a week where
  every evaluation was a non-candidate.
- **The headline** — a fixture containing a would-have-approved evaluation joined to a `reverted`
  outcome must produce **yes**, and it is the single most important assertion in this spec. A report
  that says "no reverts" because the join silently failed is worse than no report.
- **Recorder health** — a field absent from every record renders "not recorded"; present on some
  renders the fraction.
- **Defensive rendering** — a ledger fixture written before Spec F, containing no `adoption` field at
  all, renders without throwing.
- **Dispatch** — an EventBridge event routes to the report; an SQS batch and a Function URL request
  still route where they did.

## Out of scope

- **Acting on the report.** It informs; it changes nothing.
- **A dashboard or query UI.** Slack plus the JSON artifact is the read path for Phase 0.
- **Per-repository reports.** One fleet-wide post.
- **Alerting on thresholds** — that is Phase 1, once the thresholds exist.

## Definition of done

- [ ] A weekly EventBridge event produces a Slack post
- [ ] The post leads with whether any would-have-approved pull request was reverted
- [ ] Gate-failure breakdown is ranked
- [ ] Per-signal `unknown` rates are shown, so a non-contributing signal is visible
- [ ] The recorder-health section shows each tier-three field's coverage as a fraction
- [ ] A week with no evaluations still posts
- [ ] A ledger record missing a newer field renders "not recorded", never zero
- [ ] The JSON artifact is archived to S3 before the Slack post
- [ ] The report dispatches without breaking the receiver or worker routes
