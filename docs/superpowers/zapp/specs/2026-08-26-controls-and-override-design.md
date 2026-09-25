# Controls and human override

Design for the "can a human stop this, and is this pull request shaped right" half of the
[policy-enhancement review](../../../../research/2026-08-26-zapp-policy-enhancement-review.md)
(2026-08-26): findings A3, A5, A6, B4 and B5.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec G**, the last of three. E fixes logic that fails open; F adds supply-chain detection.

Status: drafted 2026-08-26; both open decisions resolved in review 2026-08-26 and folded in — freeze
is global **and** per-repo, both in SSM; commit authorship is recorded, not gated, and shown in a
table that says so.

## Composability

| | |
|---|---|
| **Touches** | `src/gates.ts`, `src/render.ts`, `src/evaluate.ts`, `src/ledger.ts`, `policy-rules.yaml`, `scripts/build-rules.mjs`, new `src/runtime-config.ts`, `infrastructure/terraform/` |
| **Depends on** | **Spec D** (`gates.ts`, `render.ts`, `evaluate.ts`, `policy-rules.yaml`) and **Spec F** (`render.ts`, `evaluate.ts`, `policy-rules.yaml`) |
| **Safe to parallelise with** | Nothing. Last in the sequence. |
| **Blocks** | Advisory mode. A3 is a hard prerequisite — see below. |

## The through-line

Everything here answers one of two questions: **can a human stop this**, and **is this pull request
even the right shape to consider?** A3 and B4 are the override story; A6 and A5 are shape checks;
B5 is groundwork.

A3 is the one that gates the phase transition. The rest are small.

## A3 · The freeze switch cannot currently stop anything quickly

`policy-rules.yaml` compiles into `src/generated/rules.ts` at build time. That is right for gates and
thresholds — an invalid rules file fails the deploy rather than the Lambda, which is the whole point
of Spec A's design — but it makes `freeze` a **pull request, plus a build, plus a deploy**.

In shadow mode that is harmless: freezing changes some text on a check nobody acts on. **In advisory
or auto mode it is not an emergency stop at all**, and the deck's "checked atomically last" implies
semantics the implementation does not have. Chromium's autoroller doctrine — *stop the roller first,
then revert* — only works if stopping is instant.

**`freeze` moves to runtime configuration; everything else stays compile-time.**

### Where it lives

AWS Systems Manager Parameter Store, read once per evaluation, at **two** scopes:

| Parameter | Stops |
|---|---|
| `/zapp/freeze` | Everything, every repository |
| `/zapp/freeze/{owner}/{repo}` | That repository only |

```bash
aws ssm put-parameter --name /zapp/freeze --value true --overwrite                              # whole fleet
aws ssm put-parameter --name /zapp/freeze/bankrate/conductor-api --value true --overwrite       # one repo
```

Either is a one-command stop that takes effect on the next delivery, with no deploy and no PR.

**The two combine as OR, never as override.** A global `false` does not release a repo-level freeze,
and a repo-level `false` does not release a global one. "Override" is the wrong shape for an
emergency stop: it means one of the two switches can silently undo the other, which is precisely the
failure the single-switch rule elsewhere in this spec exists to prevent. Frozen means *anyone* who
can freeze has frozen it.

Both are read in **one** `GetParameters` call naming both keys, so per-repo scope costs no additional
round trip. `GetParameters` returns found and not-found separately, which is exactly the distinction
this needs: not-found is not-frozen, and a failed *call* is frozen.

### Why not a repository custom property

`fetchRepoProperties` already runs on every evaluation (Spec D), so a `merge_policy_freeze` property
would be genuinely free — no extra call at all. It is still the wrong home, for two reasons.

**The party being stopped could unset it.** Bankrate's org custom properties default to
`values_editable_by: org_and_repo_actors` — the same self-attestation caveat already recorded against
`resiliency_tier`. A repository admin editing away the freeze on their own repository turns the
emergency stop into a suggestion. Locking the property to `org_actors` would fix that and
simultaneously remove the only advantage a property had, which was letting a team stop their own
automation without filing anything.

**It would make GitHub a dependency of the stop.** A GitHub incident is a plausible reason to want
the freeze, and reading the flag from GitHub during one means the read fails, which fail-closed turns
into a fleet-wide freeze nobody can lift until GitHub recovers. SSM is a different provider from the
thing being controlled, which is what you want of a brake.

The cost of SSM is one extra API call per evaluation against a 30-second budget. That is the right
trade.

**This reverses a deliberate earlier decision, and the reason matters.** `infrastructure/terraform/main.tf`
carries `enable_ssm_permissions = false` with the comment: *"Config is read from Secrets Manager
only. Disable the module's default (team-wide, /platform/\*) SSM parameter read grant — we don't use
SSM."* That decision was about the **breadth** of the module's default grant, not about SSM. A grant
scoped to exactly `/zapp/freeze` is a different thing, and the comment is updated to say so rather
than silently contradicted.

Alternatives considered: a DynamoDB item (the client and IAM patterns already exist, but a dedicated
table for one boolean is heavy, and reusing `zapp-evaluations` would mix configuration into an
evidence store); a Secrets Manager entry (already wired, but a freeze flag is not a secret and
Secrets Manager charges per secret per month for something Parameter Store holds free).

### Caching and failure

**Never cached.** An emergency stop that takes effect "within five minutes" is not one. `GetParameter`
is single-digit milliseconds against a 30-second budget.

**An unreadable flag means frozen.** If SSM cannot be reached, the service cannot confirm it is
permitted to run, so it behaves as though it is not — gate 17 fails with the read error as its
reason. In shadow that costs nothing (checks say not-a-candidate); in later phases it is the only
defensible direction for a control whose entire purpose is stopping things.

A missing parameter is **not** an error: absent means not frozen, which is the state the service
ships in. Only a failed *call* means frozen — and because both scopes ride one `GetParameters`, a
failure freezes both, which is the correct blast radius for "we do not know whether we are allowed to
run".

### What stays in the rules file

`rules.freeze` is removed. Two switches with the same name in different places is how someone flips
the wrong one during an incident.

The global and per-repo SSM parameters are not that failure: they are one mechanism at two scopes,
combined by OR, and neither can quietly negate the other.

## B4 · Blocking labels and WIP titles

Kodiak has `blocking_labels` and `blocking_title_regex: "^WIP:"`; Mergify leans on label conditions
throughout. A `do-not-automerge` label is the cheapest possible human-override story, and worth
having **before** any team is asked to trust the system — "how do I opt this PR out" needs an answer
that is not "file a ticket".

New gate `notBlocked`, reading two new rules:

```yaml
  blockingLabels: ["do-not-automerge", "hold"]
  blockingTitlePattern: "^(WIP|DRAFT)\\b"
```

Labels come from `pull_request.labels[].name` in the payload. **On the `check_suite` re-evaluation
path they arrive from the PR fetch `src/pr-context.ts` already performs**, so both paths agree —
`EvalContext` grows a `labels: string[]` field rather than a second fetch.

A GitHub **draft** PR (`pull_request.draft === true`) also fails this gate. It is the same intent
expressed through a first-class GitHub feature, and checking only the title would miss it.

## A6 · Nothing checks the target branch

No gate verifies the PR targets the default branch. Every comparable tool conditions on `base` —
a PR into a long-lived feature branch has entirely different review expectations, and merging it
automatically is not what anyone enrolled for.

New gate `baseBranchAllowed`: `pull_request.base.ref` must equal the repository's default branch, or
match an explicit per-repo allow-list on the enrolment record. `EvalContext` grows `baseRef`; the
default branch comes from the payload's `repository.default_branch` on one path and the PR fetch on
the other.

## A5 · Bot identity is checked on the PR author only — recorded, not gated

Gate 2 checks `pull_request.user.login`. **A human can push commits onto a bot's branch and the PR
still passes**, because nothing looks at the commits. Dependabot signs its commits, so GitHub reports
them `verified`.

This spec **records** rather than gates: `GET /repos/{o}/{r}/pulls/{n}/commits` yields, per commit,
the author login and `verification.verified`. The eval record gains:

```json
"commitAuthorship": {
  "commits": 3,
  "allBotAuthored": true,
  "allVerified": true,
  "foreignAuthors": []
}
```

Recording first is deliberate. Making it a gate today would fail every PR where a maintainer pushed a
lockfile fixup onto a Dependabot branch — plausibly common, and nobody knows how common. Thirty days
of `allBotAuthored: false` counts answers that, and the gate lands in Phase 1 tuned rather than
guessed.

**But it is shown, not hidden.** Recording a security-relevant observation where only a DynamoDB
query can find it has a specific cost: nobody can tell the difference between "we decided not to gate
on this yet" and "we never thought of it". Commit authorship appears on the eligibility check in a
table that says plainly it enforces nothing — see below.

## B5 · Merge windows — recorded, not enforced

Business-hours-only merging is standard (Mergify `schedule`, Renovate `automergeSchedule`), and the
rationale is simply that someone is around to revert.

Recorded per evaluation as `wouldHaveMergedInWindow: boolean`, against a declared window:

```yaml
  mergeWindow:
    timezone: "America/New_York"
    days: [mon, tue, wed, thu, fri]
    hours: [9, 17]
```

No gate. Thirty days of data shows what fraction of would-have-approved PRs fall outside the window,
which is the number that should decide whether the window is worth enforcing — and whether a rate
budget is needed alongside it.

Rate budgeting (Renovate's `prHourlyLimit`) is **not** built. It needs merge history the ledger does
not yet hold, which is PLAT-1193's outcome records.

## Recorded, not enforced — a fourth tier, and a table for it

Spec F established three tiers: graded-and-surfaced, recorded-and-surfaced, and recorded-only. This
spec splits the third, because "recorded only" turned out to conflate two different things.

| Tier | Examples | Where it appears |
|---|---|---|
| Graded and surfaced | the 17 gates; the 7 risk signals | the main tables |
| Recorded and surfaced | each gate's and signal's observed value | the main tables' right column |
| **Recorded, shown, enforces nothing** | commit authorship, merge window, provenance regression, adoption | a second table, explicitly marked |
| Recorded only | nothing, once this ships | eval record |

The point of the new tier is the reader. A check that silently collects a security-relevant
observation and never mentions it is indistinguishable from one that never collected it — so a team
cannot tell what the service already knows, cannot argue with a value that looks wrong, and cannot
ask for it to become a gate. Showing it costs a few rows and buys the argument.

The eligibility check gains, below the gate table:

```markdown
### Recorded, not enforced

_These are observed on every evaluation and stored for tuning. **None of them affects the verdict
above.** They are shown so you can see what this service already knows, and tell us if a value looks
wrong._

| | Observation | Value |
|---|---|---|
| ℹ️ | Commit authorship | 3 commits, all bot-authored, all verified |
| ℹ️ | Merge window | outside 09:00–17:00 America/New_York |
```

The icon is deliberately **not** from the gate vocabulary (✅ ❌ ⏭️ ❓). A ✅ here would read as a
passed gate, which is the exact misreading this table exists to avoid; ℹ️ carries no verdict at all.

**The risk check gets the same treatment for Spec F's two record-only fields** — `provenanceLost` and
`adoption` — under the same heading and the same icon, so there is one convention rather than two.
Spec F's plan currently documents those as surfacing "in the weekly shadow report, not on your pull
request"; that line in `docs/policy.md` changes when this lands. It is a one-line edit and it is
noted here so it is not discovered later as a contradiction.

## Gates: 15 → 17

Inserted before `freezeOff`, which stays last:

| # | Gate | Passes when |
|---|---|---|
| 15 | `baseBranchAllowed` | `base.ref` is the default branch or on the repo's allow-list |
| 16 | `notBlocked` | No blocking label, no blocking title pattern, not a draft |
| 17 | `freezeOff` | The runtime flag is readable **and** false |

Both new gates read only `EvalContext` and rules, so `src/gates.ts` stays pure. The freeze flag is
fetched in `evaluate.ts` alongside the other hoisted fetches and passed in on `GateInput`, exactly as
Spec D does for check runs and repository properties.

## Files

| File | Change |
|---|---|
| `src/runtime-config.ts` | New — one `GetParameters` for both freeze scopes, never cached, unreadable means frozen |
| `src/gates.ts` | Two gates; `freezeOff` reads the runtime flag from `GateInput` |
| `src/pr-context.ts` | `labels`, `baseRef`, `isDraft`, `defaultBranch` on `EvalContext`, from both paths |
| `src/commit-authorship.ts` | New — record-only commit author and verification counts |
| `src/merge-window.ts` | New — pure window predicate |
| `src/evaluate.ts` | Hoist the freeze read; call the two recorders |
| `src/render.ts` | The "Recorded, not enforced" table, on **both** checks |
| `src/ledger.ts` | `commitAuthorship`, `wouldHaveMergedInWindow` |
| `infrastructure/terraform/` | `ssm:GetParameter` scoped to `/zapp/freeze` and `/zapp/freeze/*`; the global parameter itself |

The IAM grant covers the path prefix as well as the exact global key, because per-repo parameters are
created ad hoc during an incident and a grant that has to be widened first is not an emergency stop.
It remains far narrower than the module default (team-wide `/platform/*`) the original comment
rejected.

## Error handling

| Condition | Behaviour |
|---|---|
| The `GetParameters` call fails | **Frozen**, both scopes. Gate 17 fails with the read error as its reason. |
| Either parameter absent | Not frozen at that scope — absent is the shipped state |
| Global `true`, repo absent | Frozen |
| Global absent, repo `true` | Frozen |
| Global `false`, repo `true` | **Frozen** — OR, not override |
| A parameter holds a non-boolean string | **Frozen**, with the offending value in the reason. An unparseable stop is not a released one. |
| Commits fetch fails | `commitAuthorship` recorded null and rendered "not recorded"; no gate affected |
| PR has no labels | Empty array, gate 16 passes |
| Base branch cannot be determined | Gate 15 fails — an unknown target is not a known-safe one |

## Testing

- **Freeze** — global `true` fails gate 17; `false` passes; both absent passes; a **failed call**
  fails, with the error in the reason. That last one is the test that proves the fail-closed
  direction, and it is the one most likely to be written backwards.
- **Freeze scoping** — a repo-level `true` freezes only that repo, proven by evaluating a second repo
  in the same test and asserting it still passes. And `global: false` with `repo: true` must be
  **frozen** — the test that proves OR rather than override, and the one an implementer is most
  likely to invert while "fixing" the precedence.
- **One call, two keys** — the SSM client is asked once per evaluation, with both names, asserted by
  call count and by the names requested.
- **No caching** — two evaluations in one warm Lambda issue two calls, asserted by call count. A
  cached freeze flag is an emergency stop that does not stop.
- **Blocked** — each configured label blocks; an unlisted label does not; the title pattern matches
  `WIP:` and `DRAFT:` but not `wip-adjacent-word`; `draft: true` blocks independently of both.
- **Base branch** — the default branch passes; another branch fails; an allow-listed branch passes;
  an undeterminable base fails.
- **Context parity** — labels, `baseRef` and `isDraft` are identical whether built from a
  `pull_request` payload or a `check_suite` PR fetch. Same guard Spec C established.
- **Recorders** — commit authorship counts foreign authors correctly and records null on a failed
  fetch; the merge window predicate is tested against an injected clock across the boundary hours and
  a weekend.
- **The recorded-not-enforced table** — it renders on both checks; it uses ℹ️ and **never** a gate
  icon, asserted by matching the gate vocabulary against the section and finding nothing; a null
  recorder renders "not recorded" rather than a zero or a false; and a PR that fails a gate still
  shows the table, because that is when a reader is most likely to be looking.
- **The table changes no verdict** — the same fixture rendered with every recorded value at its worst
  produces the identical `verdict` and `failedGate` as with them at their best. This is the assertion
  that keeps "shown" from drifting into "enforced".
- **Regression** — PR #27 still a candidate at 17 of 17.

## Out of scope

- **Rate budgeting** — needs merge history from PLAT-1193's outcome records.
- **Gating on commit authorship** — recorded and shown here; graded once the data shows its
  false-positive rate, which is the same argument Spec F makes for provenance regression.
- **Auto-retry suppression after ejection** (the review's C3) — belongs with the ops runbook, which
  is a document rather than code.
- **Acting on any verdict.** Shadow mode unchanged.

## Definition of done

- [ ] `/zapp/freeze` exists; `aws ssm put-parameter` stops the fleet on the next delivery with no deploy
- [ ] `/zapp/freeze/{owner}/{repo}` stops one repository without touching the others
- [ ] Global `false` plus repo `true` is **frozen** — OR, never override
- [ ] Both scopes are read in one `GetParameters`, once per evaluation, never cached, proven by call count
- [ ] A failed call means frozen; an absent parameter means not frozen; a non-boolean value means frozen
- [ ] `rules.freeze` is removed from `policy-rules.yaml` — one switch, one place
- [ ] The `enable_ssm_permissions` comment explains the scoped grant rather than contradicting itself
- [ ] `baseBranchAllowed` and `notBlocked` land before `freezeOff`, which stays last at 17
- [ ] Draft PRs fail `notBlocked` independently of the title pattern
- [ ] Labels, base ref and draft state are identical across both trigger paths
- [ ] `commitAuthorship` and `wouldHaveMergedInWindow` are recorded and gate nothing
- [ ] Both checks carry a "Recorded, not enforced" table using ℹ️, never a gate icon
- [ ] The risk check's table shows Spec F's `provenanceLost` and `adoption`, and `docs/policy.md`'s
      "not on your pull request" line is corrected
- [ ] Worst-case recorded values produce an identical verdict to best-case — shown is not enforced
- [ ] PR #27 is still a candidate at 17 of 17
