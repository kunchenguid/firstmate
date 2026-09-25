# Weekly shadow report

Design for the epic's M4 / T12 — the scheduled report that turns the decision ledger into something a
human reads.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec I**, and it is **deliberately pulled forward** from the end of the epic. Review on
2026-08-26 established that the service is now recording a meaningful amount of data with **no read
path at all** — visible only by querying DynamoDB by hand, which nobody will do. Collecting data
nobody looks at is how a broken recorder stays broken for six weeks.

Status: drafted 2026-08-26; both open decisions resolved in review 2026-08-26 and folded in — the
report is a scheduled GitHub Actions workflow, posting to `#bankrate-platform-notifications`.

## Composability

| | |
|---|---|
| **Touches** | New `src/report/`, new `.github/workflows/weekly-report.yml`, `infrastructure/terraform/` (a read-only OIDC role and an S3 bucket). **`src/index.ts` and the Lambda are untouched.** |
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

Spec G puts these on the check runs in a "Recorded, not enforced" table, which tells a reader what
was observed **on their own pull request**. That is not the same read path as this one. Nobody can
see from a single check run that a recorder has been null for six weeks, or that one signal grades
`unknown` 90% of the time — those are fleet-and-time questions, and only an aggregate answers them.

Two concrete failure modes follow. A recorder that silently breaks —
deps.dev withdrawing its alpha endpoint, a GitHub response shape changing — produces null for weeks
and looks like data. And Phase 1's thresholds are supposed to be *derived* from this corpus, which
requires somebody having looked at it before the derivation meeting.

## Not in the Lambda

`lambda-deploy` deploys exactly one function per environment — `<app-name>-<env>` — which is why
PLAT-1233 put the receiver and worker in one function dispatched on event shape. A separate report
Lambda would be created by Terraform and never receive code, so sharing the function was the only way
to run it there.

**Sharing has a real cost.** A weekly scan is bounded by a week of data rather than one pull request,
so the report needs a longer timeout than the request roles — and raising the function timeout drags
the queue's visibility timeout with it to keep the 6:1 ratio. A reporting job would then be able to
change how the *worker* fails. That is a bad coupling to accept for a job that nothing depends on.

**So the report runs as a scheduled GitHub Actions workflow in `bankrate/zapp`**, reading DynamoDB
through an OIDC role. This sidesteps the one-function constraint entirely rather than working around
it, and puts the report's own logs and failure notifications where a human already looks — a failed
scheduled workflow is visible in the Actions tab and in the repository's existing notifications,
whereas a failed EventBridge invocation is visible only in CloudWatch.

```yaml
# .github/workflows/weekly-report.yml
on:
  schedule:
    - cron: '0 13 * * 1'      # Mondays 09:00 America/New_York (EDT); 08:00 in EST
  workflow_dispatch:           # so it can be run on demand, which the Lambda path could not
permissions:
  id-token: write
  contents: read
```

`workflow_dispatch` is not incidental. Being able to regenerate the report on demand — after fixing a
renderer, or when someone asks a question mid-week — is worth more than it costs, and the scheduled
Lambda had no equivalent.

**The cost is a second place the code can live and a second deployment path.** It is bounded: the
report shares `src/` with the service, is typechecked and tested by the same `pnpm test`, and runs
under `tsx` exactly as the tests do. It is not a separate project, and nothing else moves out of the
Lambda.

The role is new and **read-only** — `dynamodb:Query` and `dynamodb:Scan` on `zapp-evaluations` plus
`s3:PutObject` on the archive prefix. It is deliberately not the deploy role: a reporting job has no
business holding permissions that can change the service.

### The one thing this loses

Schedule reliability. GitHub delays `schedule` triggers under load, sometimes by tens of minutes, and
skips them entirely on repositories with no activity for 60 days. Neither matters for a weekly report
whose whole purpose is that somebody reads it during the week — and the second is not reachable for a
repository under active development. Stated here so it is a known property rather than a surprise.

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

Slack, to **`#bankrate-platform-notifications`** (`C081N1H2P5K`).

**This needs a new secret, and it is a human setup step.** The existing org secret `SLACK_WEBHOOK` is
a single incoming webhook, and an incoming webhook is bound to one channel at creation — it is the
generic deploy-notification hook and will not post here. The report reads a **repository** secret
`SLACK_REPORT_WEBHOOK` on `bankrate/zapp`, created from a webhook bound to that channel.

Two wrinkles worth knowing before someone tries:

- **The channel is private.** A webhook can post to a private channel, but it must be created by
  somebody who is in it, and the owning app has to be added to the channel. That is a Slack workspace
  action, not something the implementation can do.
- **A repository secret, not an org one.** Org secrets are visible to every repository that inherits
  them; this webhook only needs to exist in one place, and the narrower scope costs nothing.

If the secret is absent the workflow **fails loudly rather than skipping the post**. A report that
silently stops being delivered is the same failure this whole spec exists to catch.

The report is also written to S3 as JSON alongside the human-readable post, so a later analysis does
not have to re-derive a week's aggregates or scrape Slack. Cheap, and the epic already anticipates an
S3 archive for the ledger.

## Schedule

Weekly, Monday morning — the week's data is complete and there is a working week to act in.

The query is a scan of `zapp-evaluations` bounded by `sk >= eval#<week-start>`. At Phase 0 volumes —
hundreds of records — a scan is fine and a purpose-built index is not worth the schema. That
assumption is stated here so it can be revisited rather than inherited: at ~200 evaluations a week
across five repositories it remains fine; at fifty repositories it does not.

Running outside the Lambda removes the timeout pressure that made this worth worrying about: an
Actions job has six hours, so the scan can page as far as it needs without anyone tuning a budget.

## Files

| File | Responsibility |
|---|---|
| `src/report/query.ts` | Read a week of evaluations and outcomes; aggregate |
| `src/report/render.ts` | Slack Block Kit body and the JSON artifact |
| `src/report/index.ts` | Entry point: orchestrate; post; archive |
| `.github/workflows/weekly-report.yml` | Schedule, OIDC assume, `tsx src/report/index.ts` |
| `infrastructure/terraform/` | S3 bucket and a **read-only** OIDC role: `dynamodb:Query`/`Scan` on the evaluations table, `s3:PutObject` on the archive prefix |

`src/report/` is a directory rather than one file because querying, aggregating and rendering are
independently testable and the rendering will change far more often than the querying.

## Error handling

| Condition | Behaviour |
|---|---|
| No evaluations this week | Report posts anyway, saying so. A silent week is indistinguishable from a broken schedule. |
| `SLACK_REPORT_WEBHOOK` absent | **Fail the job.** Never skip the post silently. |
| Slack post fails | Throw — the workflow run goes red in the Actions tab, and the S3 artifact is still written first |
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
- **The Lambda is untouched** — `src/index.ts` still routes exactly two ways, asserted by the
  existing dispatch tests passing unmodified. If this spec's implementation had to edit them, it took
  the wrong path.
- **Missing secret fails** — the entry point with no `SLACK_REPORT_WEBHOOK` exits non-zero and says
  which secret, rather than returning success having posted nothing.

## Out of scope

- **Acting on the report.** It informs; it changes nothing.
- **A dashboard or query UI.** Slack plus the JSON artifact is the read path for Phase 0.
- **Per-repository reports.** One fleet-wide post.
- **Alerting on thresholds** — that is Phase 1, once the thresholds exist.

## Definition of done

- [ ] A scheduled workflow run produces a Slack post in `#bankrate-platform-notifications`
- [ ] `workflow_dispatch` regenerates it on demand
- [ ] The OIDC role is read-only — it cannot deploy, write to the ledger, or change the service
- [ ] An absent `SLACK_REPORT_WEBHOOK` fails the run rather than skipping the post
- [ ] `src/index.ts` and the Lambda's timeout are unchanged
- [ ] The post leads with whether any would-have-approved pull request was reverted
- [ ] Gate-failure breakdown is ranked
- [ ] Per-signal `unknown` rates are shown, so a non-contributing signal is visible
- [ ] The recorder-health section shows each tier-three field's coverage as a fraction
- [ ] A week with no evaluations still posts
- [ ] A ledger record missing a newer field renders "not recorded", never zero
- [ ] The JSON artifact is archived to S3 before the Slack post
- [ ] Post-merge failures are shown separately from reverts, with the attribution rule stated (Spec H)
- [ ] The backfilled fraction of confidence corroboration is shown (Spec H)
