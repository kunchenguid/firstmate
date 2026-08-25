# Readable check output, and re-evaluating when CI finishes

Design for the follow-up work on `bankrate/zapp` after PLAT-1233, PLAT-1189, PLAT-1190 and
PLAT-1191 landed. Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0
shadow mode.

**This is Spec C.** Spec A built the rules file, the eleven gates and the eval ledger; Spec B built
the six risk signals. Both shipped. This spec fixes what the first real readers saw.

Status: drafted 2026-08-25, awaiting review.

## What prompted this

The two checks are live on
[PR #27](https://github.com/bankrate/platform-cicd-v2-demo/pull/27). Read as a stranger would read
them, three things are wrong.

**The verdict is prose, not evidence.** `merge-policy/eligibility` says *"All 11 eligibility gates
passed"* without saying what the eleven are or what each saw. A reader who wants to know why their
PR was or wasn't a candidate — or who wants to argue that a gate is wrong — has nothing to point at.

**It ends with a Jira link that means nothing to its audience.** *"Tracking: PLAT-1184"* is useful
to the team building the service and noise to everyone else, who cannot open it and would not care
if they could.

**The risk check is honest but useless.** It reads *"graded on 4 of 6 signals"*, with scanner
findings and coverage both unavailable, because the evaluation ran at `20:01:15` — **before CI had
finished**. That is the timing hole Spec B documented and deferred. Now that the checks are real
and in front of people, it is the most visible defect in the service.

## Goal

Make both checks legible to an engineer who has never heard of this project, and make the risk
grade complete by re-evaluating as CI reports.

Shadow mode is unchanged. The conclusion stays structurally `neutral`, nothing is approved, merged
or blocked.

## Starting state

Verified on 2026-08-25 against the live service and the deployed App.

| Fact | Detail |
|---|---|
| Deployed | `zapp` v1.4.0; `src/` carries gates, signals, risk, render, ledger |
| App | `neutral-planet`, **app id `4702073`**, installation `156198964` |
| App events | `check_run`, `check_suite`, `merge_group`, `merge_queue_entry`, `pull_request`, `push`, `status` |
| Worker routing | Only `pull_request`; `check_suite` is in `KNOWN_UNROUTED` and dropped |
| Check posting | `postShadowCheck` is **create-only** — `POST /repos/{o}/{r}/check-runs` |
| Docs | `docs/architecture.md`, `docs/call-flows.md` — both written for people working *on* zapp |

Two things this means, which shape the whole design:

**`check_suite` is already subscribed.** No GitHub App change is needed for the re-evaluation
trigger; the events are already being delivered and thrown away by `KNOWN_UNROUTED`.

**Create-only posting has not bitten yet, but will immediately.** PR #27's head SHA carries exactly
one `merge-policy/eligibility` and one `merge-policy/risk`, because exactly one evaluation has run
for that commit. The moment re-evaluation exists, every push would accumulate a fresh pair per CI
system that completes.

## Part 1 — Check-run output

### Eligibility

```markdown
**Would have been a candidate — `dep-minor`**

7 dependency updates, largest jump **minor** (`fastify` ^5.11.2 → ^5.12.0).

| | Gate | Result |
|---|---|---|
| ✅ | enrolled | shadow |
| ✅ | botAllowlisted | `dependabot[bot]` |
| ✅ | ticketLinked | not required for this author |
| ✅ | conventionalTitle | — |
| ✅ | changeClass | `dep-minor` |
| ✅ | pathsAllowed | — |
| ✅ | size | 1 file, 14 lines (max 3 / 60) |
| ✅ | semverCap | minor ≤ minor |
| ✅ | classificationPermits | `sandbox` |
| ✅ | tierFloor | tier 2 ≥ 2 |
| ✅ | freezeOff | — |

**11 of 11 gates passed.** Nothing was approved or merged — this service runs in shadow mode.

This check is informational. It is **not required** and **will never block your pull request**.

[What is this, and how do I suggest a check? →](https://github.com/bankrate/zapp/blob/main/docs/policy.md)
```

All eleven rows, always, in the fixed `GATE_ORDER`. The point of the table is that a reader can see
what was checked without asking anyone, and a collapsed or filtered table defeats that on exactly
the pull requests where someone is curious.

Icons: `✅` pass, `❌` fail, `⏭️` skipped, `❓` unknown. On a rejection the failing row is what the
eye lands on, and the lead line still names the first failure as it does today.

The `Result` column carries the **observed value**, not a restatement of the gate. `size` shows
`1 file, 14 lines (max 3 / 60)`; `tierFloor` shows `tier 2 ≥ 2`. A gate with nothing meaningful to
report renders `—` rather than inventing text.

### Risk

This is what PR #27 would actually render after CI completes, on the demo repo as it is configured
today — **5 of 6**, not 6, because Dependabot alerts are disabled on that repository:

```markdown
**Risk: medium** — graded on 5 of 6 signals

| | Signal | Observed |
|---|---|---|
| ⚠️ | Version distance | minor — `fastify` ^5.11.2 → ^5.12.0 |
| ✅ | Publish age | youngest 7 days (`@types/pg`), cooldown 3 |
| ❓ | Closes a known finding | Dependabot alerts are disabled for this repository |
| ✅ | New scanner findings | 0 of 3 checks failing |
| ✅ | Coverage change | unchanged at 62.99% |
| ⚠️ | Dependency type | 6 production, 1 development |

Legend: ✅ low · ⚠️ medium · ❌ high · ❓ not available

This check is informational. It is **not required** and **will never block your pull request**.

[What is this, and how do I suggest a check? →](https://github.com/bankrate/zapp/blob/main/docs/policy.md)
```

Risk signals are graded, not pass/fail, so grade maps onto the same icon vocabulary rather than
introducing a second one — `✅` low, `⚠️` medium, `❌` high, `❓` unavailable — with the legend
inline so nobody has to guess.

An unavailable signal keeps its row and puts its reason in the `Observed` column, which replaces
today's separate "Not available for this evaluation" list. One table, one place to look.

Signal labels are prose (`Version distance`, `Closes a known finding`), not the camelCase internal
names. The eligibility table keeps its internal gate names on purpose — those are the identifiers
someone would cite when proposing a rules change, and they match `policy-rules.yaml`.

### Both checks

`Tracking: PLAT-1184` is removed. The policy-doc link replaces it as the last line: same position,
same "where do I go next" role, aimed at the actual audience.

Everything else stays: the lead verdict line, the "informational, never blocks" sentence, and
`renderRiskNotEvaluated()` for non-candidates — which gains the doc link and loses the Jira line
like the others.

## Part 2 — `docs/policy.md`

A new reader-facing page in the zapp repo, linked from both checks. Its audience is someone whose
pull request just got a check from a service they have never heard of — **not** someone working on
zapp, which is what `README.md`, `docs/architecture.md` and `docs/call-flows.md` already serve.

Contents:

1. **What this service does, in three sentences**, including that it cannot merge or approve
   anything and that its checks never block.
2. **The eleven eligibility gates** — a table of gate name, what it checks, and why it exists. The
   gate names match the check-run table and `policy-rules.yaml`, so a reader can move between the
   three without translating.
3. **The six risk signals** — what each measures, what makes it low, medium or high, and what makes
   it unavailable.
4. **Change classes** — `lockfile-only`, `dep-patch`, `dep-minor`, `dep-major`, their thresholds,
   and the max-delta-governs rule for grouped bumps, which is the one most likely to surprise
   someone.
5. **Repository classification and CI-trust tier** — what `sandbox` / `internal-tool` /
   `prod-service` mean and what a tier is.
6. **How to suggest a check, or argue one is wrong** — open a PR against `policy-rules.yaml`, which
   is reviewed like any other change, and the thresholds are the numbers in that file. This is the
   section the whole page exists for.

Written by hand rather than generated from `policy-rules.yaml`. Generated prose reads like a config
dump, and the "why does this gate exist" content — which is what invites a good suggestion — has
nowhere to live in generated output. The cost is that the doc can drift from the deployed
thresholds; it is accepted because the doc's job is explaining intent, and the check run itself
always shows the *actual* values it compared against.

## Part 3 — Updating check runs in place

`postShadowCheck` becomes `upsertShadowCheck`:

1. `GET /repos/{owner}/{repo}/commits/{headSha}/check-runs?check_name={name}` — verified live to
   return exactly our run with `app.id: 4702073`.
2. If any returned run's `app.id` matches this App's id, `PATCH /repos/{owner}/{repo}/check-runs/{id}`.
3. Otherwise `POST` as today.

The App id comes from `getGitHubConfig().app_id`, already in Secrets Manager and already loaded for
JWT signing. Nothing new is configured, and no constant is hard-coded.

**The shadow invariant now has two write paths, and that is the risk this section has to manage.**
Today `conclusion: 'neutral'` appears once. With an upsert there are a POST body and a PATCH body,
and a future edit could plausibly change one and not the other. So the request body is built by a
single private function that both paths call, and the test asserts `neutral` on the captured body
regardless of which verb was used. The invariant stays structural rather than becoming a convention.

Without this, every re-evaluation stacks another pair of check runs on the commit — six to eight per
push once Part 4 lands.

## Part 4 — Re-evaluating when CI reports

The worker routes `check_suite` with `action === 'completed'`, and drops it otherwise.

### The self-trigger loop

**Events whose `check_suite.app.id` equals this App's own id are dropped first, before anything
else.** Our check runs live in our own check suite; its completion fires `check_suite: completed`
for app `4702073`; routing that would re-evaluate, upsert, complete our suite again, and loop
forever — burning GitHub rate limit and rewriting the same check indefinitely.

This is load-bearing, not defensive. It is the first condition in the handler and it has its own
test.

### Getting from a check suite to a pull request

`check_suite.pull_requests[]` gives the PR number and head SHA. When it is empty — which happens for
fork-originated pull requests — the event is logged and dropped; there is nothing to evaluate
against. All of the demo repo's dependabot pull requests are same-repo, so this path is exercised in
testing rather than in the live validation.

**The payload carries no PR title, body, or author**, which gates 2, 3 and 4 all need. So the
check-suite path fetches the pull request — `GET /repos/{owner}/{repo}/pulls/{number}` — where the
`pull_request` path already has everything inline.

Both paths converge on the same `EvalContext` through a new `src/pr-context.ts`, so `evaluate()` is
unchanged and cannot tell which trigger it is serving.

### Why every completion, rather than waiting for the last

GitHub never emits an "all checks finished" event, and each App completes its own suite — Cycode,
Codecov and Actions are three separate suites on this repo. Waiting for the expected set to be
complete is PLAT-1192's job and needs its expected-set enumeration across rulesets and classic
branch protection.

Re-evaluating on **every** non-self completion is simpler and self-healing: roughly three or four
re-evaluations per push, each upserting the same two check runs, with the check becoming more
complete as each CI system lands. The last one to finish leaves a fully-populated grade. Because the
evaluator is a stateless full recompute pinned to the head SHA, running it repeatedly is correct by
construction rather than by care.

## Consequence: the ledger becomes a time series

Spec A's acceptance criterion — *"every push/synchronize on an enrolled PR produces exactly one eval
record"* — **is superseded here.** Four check-suite completions produce four evaluations and
therefore four records per push.

Records are appended, not overwritten. The sequence is genuinely useful evidence: it shows signals
filling in as CI reports, and a Phase 1 reviewer asking "what did we know, and when?" can answer it.
Overwriting would erase exactly that.

Two things make the series navigable:

- A new top-level `trigger` attribute on each record — `pull_request` or `check_suite` — so a query
  can select one kind or count re-evaluations.
- `sk` is already `eval#<ISO timestamp>`, so the **latest record for a head SHA is the
  authoritative one** and a `ScanIndexForward: false, Limit: 1` query returns it.

The revised criterion: *every evaluation produces exactly one eval record, and the most recent
record for a head SHA is the one that saw the most complete data.*

## Error handling

| Condition | Behaviour |
|---|---|
| `check_suite` from our own App | Dropped first, logged `self_check_suite_ignored`. Never evaluated. |
| `check_suite` action other than `completed` | Dropped, logged |
| `check_suite.pull_requests` empty | Dropped, logged `check_suite_no_pull_requests` |
| `GET /pulls/{n}` fails | Throw — claim released, SQS retries, as with any GitHub failure |
| Check-run lookup GET fails | Fall back to `POST`. A duplicate check run is a far better outcome than a lost one. |
| `PATCH` fails | Throw — the delivery retries |
| Repo not enrolled | Dropped before any fetch, as today |

Logging is unchanged: repo, PR number, SHAs, gate names, grades and counts are safe; PR title and
body are not.

## Testing

- **Rendering** — gate and signal tables built from the existing PR #27, #32 and #37 fixtures.
  Assert all eleven gate rows are present in `GATE_ORDER`, all six signal rows are present, that the
  correct icon accompanies each verdict and grade, that **no output contains `PLAT-1184`**, and that
  every output ends with the policy-doc link.
- **Unavailable signals** render as a row with `❓` and a reason in `Observed`, with no separate
  "not available" block.
- **Upsert** — an existing run for our app id is PATCHed to its id; a run belonging to a *different*
  app with the same name is ignored and a POST is made; no runs means POST; a failed lookup falls
  back to POST. And the invariant test: every captured body, POST or PATCH, carries
  `conclusion: "neutral"`.
- **Check-suite routing** — a completed suite from another app evaluates; **a completed suite from
  app id `4702073` does not**, asserted by the evaluator never being called; a non-`completed`
  action drops; an empty `pull_requests` array drops.
- **Context parity** — a context built from a `check_suite` payload plus a fetched pull request is
  field-for-field identical to one built from the equivalent `pull_request` payload. This is what
  keeps the two trigger paths from diverging.
- **Ledger** — the `trigger` attribute is written and distinguishes the two paths.

### Live validation

Push a commit to PR #27 and watch the checks through CI completion. Success is:

- Exactly **one** `merge-policy/eligibility` and **one** `merge-policy/risk` on the head SHA after
  all CI has finished — the upsert working.
- The risk check reading **5 of 6 signals**, with scanner findings and coverage now populated —
  up from the 4 of 6 it shows today. The sixth stays `❓` while Dependabot alerts remain disabled on
  the repository; expect 6 of 6 only if that setting is turned on first.
- Both tables rendering, neither check mentioning PLAT-1184, both linking the policy doc.
- Multiple eval records for that SHA, the latest being the most complete.
- No runaway: the count of `merge-policy/*` check runs stops growing once CI settles, and the logs
  show `self_check_suite_ignored` entries proving the loop guard fired.

## Out of scope

- **PLAT-1192 (T8)** — the required-checks snapshot, the expected-set enumeration, and the
  ten-minute reconcile sweep. This spec gets complete signals by re-evaluating often rather than by
  knowing when to stop.
- **Routing `check_run`, `status`, `push`** — still dropped. `check_suite` is coarser and enough.
- **Enabling Dependabot alerts** on the demo repo — still a repo-owner decision. If it stays
  disabled, the risk table shows `❓` on that row with the reason, which is now visible in the table
  instead of a separate block.
- **Prod rollout** — QA only.
- **Acting on any verdict.** Shadow mode is unchanged.

## Definition of done

- [ ] Eligibility renders all eleven gates as a table in `GATE_ORDER`, with observed values
- [ ] Risk renders all six signals as a table, with the icon legend inline
- [ ] Unavailable signals appear as `❓` rows with their reason, not a separate block
- [ ] No check-run output contains `PLAT-1184`
- [ ] Both checks, and the not-evaluated variant, link `docs/policy.md`
- [ ] `docs/policy.md` explains the gates, signals, classes, tiers, and how to propose a change
- [ ] Check runs are updated in place; one pair per head SHA regardless of re-evaluation count
- [ ] `conclusion: "neutral"` asserted on both the POST and PATCH bodies
- [ ] `check_suite: completed` from another app triggers re-evaluation
- [ ] `check_suite` from app id `4702073` is dropped, with a test proving the evaluator is not called
- [ ] Contexts built from either trigger are field-for-field identical
- [ ] Eval records carry `trigger`; the latest record per head SHA is the most complete
- [ ] PR #27 shows **5 of 6** signals after CI completes (6 of 6 only if Dependabot alerts get
      enabled on the repo), with exactly one check run per name
