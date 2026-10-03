# Policy rules, enrollment, and the eligibility evaluator

Design for [PLAT-1189](https://redventures.atlassian.net/browse/PLAT-1189) (T5 — `policy-rules.yaml`
v1 + loader) and [PLAT-1190](https://redventures.atlassian.net/browse/PLAT-1190) (T6 — the eleven
eligibility gates), plus a deliberately minimal slice of
[PLAT-1188](https://redventures.atlassian.net/browse/PLAT-1188) (T4 — enrollment) and
[PLAT-1193](https://redventures.atlassian.net/browse/PLAT-1193) (T9 — the decision ledger).

Epic: [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184) — Merge-policy service, Phase 0
shadow mode. Implemented in `bankrate/zapp`.

**This is Spec A of two.** Spec B covers PLAT-1191 (T7 — the six risk heuristics) and follows
immediately; it depends only on the rules file this spec defines. Split because T5 + T6 + T7 is the
entire M2 decision engine, which is more than one spec should carry.

Status: drafted 2026-08-25, awaiting review.

## Goal

Replace zapp's placeholder evaluator with a real eligibility verdict, so the next validation run on
`bankrate/platform-cicd-v2-demo` shows genuine gate results instead of "no verdict yet" — and so
every evaluation is recorded with a value per gate, which is the dataset Phase 1 is meant to justify.

## Starting state

Verified by inspection on 2026-08-25, not assumed.

PLAT-1233 shipped. `bankrate/zapp` `main` carries `receiver.ts`, `worker.ts`, `deliveries.ts`,
`queue.ts`, `checks.ts`, `github.ts`, `enrollment.ts`, `evaluate.ts`, and Terraform for the SQS
queue, DLQ, dedupe table and alarms. Both check runs post live: PR #37 on the demo repo carries
`merge-policy/eligibility` and `merge-policy/risk`, both `neutral`, both showing the placeholder
text.

What this spec changes: `evaluate.ts` (placeholder → real), `enrollment.ts` (env var → rules file).
Everything else it adds is new.

`postShadowCheck` is **not** touched. The shadow-mode invariant — conclusion is structurally always
`neutral`, and that function is the only path to the check-runs API — carries over unchanged.

### The three live pull requests

These are the ground truth this design is built against, and they become the test fixtures.

| PR | Author | Files | Expected verdict |
|---|---|---|---|
| [#27](https://github.com/bankrate/platform-cicd-v2-demo/pull/27) | `dependabot[bot]` | `package.json` +7/-7, `pnpm-lock.yaml` +93/-78 | **candidate: yes** — `dep-minor` |
| [#32](https://github.com/bankrate/platform-cicd-v2-demo/pull/32) | `dependabot[bot]` | `package.json` +11/-11, `pnpm-lock.yaml` +593/-445 | not a candidate — fails `classificationPermits` **and** `tierFloor` (9 of 11 pass) |
| [#37](https://github.com/bankrate/platform-cicd-v2-demo/pull/37) | `iscooter` (human) | `PLAT-1233-VALIDATION.md` +13/-0 | not a candidate — fails `botAllowlisted` |

Three PRs, three distinct failure modes, one real pass. That is what makes the validation run
meaningful rather than a demonstration that the code runs.

Three details these PRs settle that a design written from the ticket alone would get wrong:

1. **Lockfile churn dwarfs everything else.** PR #32 changes 22 authored lines and 1,038 generated
   ones. A `max_lines` ceiling counting raw diff lines rejects every dependabot PR on noise. The
   size gate must count only non-generated files.
2. **Bot PRs carry no Jira key.** Gate 3 (ticket linkage) would fail every bot PR, making the whole
   exercise vacuous. The bot registry carries `ticketRequired` per bot — the same exemption
   `github-pr-jira-check` already grants bots through `SKIP_AUTHORS`.
3. **The author login is `dependabot[bot]`.** That is what `pull_request.user.login` holds in the
   webhook payload. `gh pr list` renders the same account as `app/dependabot`; configuring that
   string would fail the allowlist silently, on every PR, with no error.

## The rules file

`policy-rules.yaml`, at the repo root. Two top-level sections: `rules` (policy) and `repos`
(enrollment).

```yaml
version: 1

rules:
  # Checked last, atomically, by gate 11. A single switch that makes every PR
  # a non-candidate without touching any other rule.
  freeze: false

  # Matched against pull_request.user.login from the webhook payload.
  # NOT the `app/dependabot` form the gh CLI renders.
  bots:
    - login: "dependabot[bot]"
      ticketRequired: false
    - login: "bankrate-security[bot]"
      ticketRequired: false
    - login: "devin-ai-integration[bot]"
      ticketRequired: true

  # Files whose content is generated, not authored. Excluded from BOTH the size
  # gate's file count and its line count: a lockfile's 1,038 changed lines carry
  # no review burden, and counting them makes every size ceiling meaningless.
  generatedPaths:
    - "**/pnpm-lock.yaml"
    - "**/package-lock.json"
    - "**/yarn.lock"
    - "**/.terraform.lock.hcl"

  changeClasses:
    lockfile-only:
      semverCap: none
      maxFiles: 0
      maxLines: 0
      allowedPaths: ["**/pnpm-lock.yaml", "**/package-lock.json", "**/yarn.lock"]
      deniedPaths: []
      tierFloor: 1
      classifications: [sandbox, internal-tool, prod-service]

    dep-patch:
      semverCap: patch
      maxFiles: 3
      maxLines: 60
      allowedPaths: ["package.json", "**/package.json", "**/pnpm-lock.yaml", "**/package-lock.json", "**/yarn.lock"]
      deniedPaths: [".github/**", "infrastructure/**", "Dockerfile"]
      tierFloor: 2
      classifications: [sandbox, internal-tool, prod-service]

    dep-minor:
      semverCap: minor
      maxFiles: 3
      maxLines: 60
      allowedPaths: ["package.json", "**/package.json", "**/pnpm-lock.yaml", "**/package-lock.json", "**/yarn.lock"]
      deniedPaths: [".github/**", "infrastructure/**", "Dockerfile"]
      tierFloor: 2
      classifications: [sandbox, internal-tool]

    dep-major:
      semverCap: major
      maxFiles: 3
      maxLines: 60
      allowedPaths: ["package.json", "**/package.json", "**/pnpm-lock.yaml", "**/package-lock.json", "**/yarn.lock"]
      deniedPaths: [".github/**", "infrastructure/**", "Dockerfile"]
      tierFloor: 3
      # Empty on purpose: no repo classification permits a major bump in v1.
      # Defining the class anyway — rather than leaving majors unclassified —
      # buys a precise rationale ("major bumps aren't eligible on a sandbox
      # repo") instead of a useless one ("unrecognized change class").
      classifications: []

repos:
  - repo: bankrate/platform-cicd-v2-demo
    classification: sandbox
    ciTrustTier: 2
    mode: shadow
    stageEnabled: false
```

### How it reaches the Lambda, and why that satisfies the acceptance criteria

The file is **never read at runtime**. A build step, `pnpm run build:rules`, parses it, validates it
against a schema, and emits `src/generated/rules.ts` — a frozen object plus the SHA — which esbuild
bundles like any other module. `pnpm run build` depends on it, and the Dockerfile's build stage runs
it, so an invalid rules file fails the image build and therefore the deploy.

That is PLAT-1189's first acceptance criterion — *"invalid rules file fails deploy, not runtime"* —
obtained structurally rather than by a runtime check that could be skipped. It also means no YAML
parser in the Lambda bundle and no parse cost on the hot path.

`rulesSha` is the **git blob SHA** of `policy-rules.yaml`: `sha1("blob " + byteLength + "\0" +
content)`, byte-identical to what `git hash-object policy-rules.yaml` prints. Computable from the
file's bytes alone, which matters because the Docker build stage has no `.git` directory — and it is
still literally the file's git SHA, which is what the ticket asks for. A test asserts the generated
value matches `git hash-object` on the real file.

### Enrollment (the minimal T4 slice)

`repos` entries carry the epic's schema minus `enrolledBy`, `enrolledAt` and `sourceSha` — those are
artifacts of the PR-sync automation that full T4 builds, and they are derivable from git history
for a file that is only ever changed by a reviewed PR.

`isEnrolled(repoFullName)` keeps its name, its signature shape and its call site in `worker.ts`.
Only the body changes, from an `ENROLLED_REPOS` env-var lookup to a rules-file lookup, and it gains
a sibling `enrollmentFor(repoFullName)` returning the full record for gates 9 and 10. The
`ENROLLED_REPOS` variable and its Terraform plumbing are removed.

PLAT-1188 remains open for the DynamoDB table and the automatic PR→table sync. This slice
deliberately does not build either; it just stops the gates from being blocked on them.

## The eleven gates

A pure function over `(pull_request payload, changed files, enrollment record, rules)`. Each gate
returns `pass`, `fail`, `unknown` or `skipped`, along with the value it observed.

| # | Gate | Passes when |
|---|---|---|
| 1 | `enrolled` | Repo present in `repos` and `mode !== "off"` |
| 2 | `botAllowlisted` | `pull_request.user.login` is in `rules.bots` |
| 3 | `ticketLinked` | A Jira key is present, or the matched bot has `ticketRequired: false` |
| 4 | `conventionalTitle` | PR title matches the Conventional Commits form |
| 5 | `changeClass` | The diff classifies as something other than `unclassified` |
| 6 | `pathsAllowed` | Every changed path matches `allowedPaths` and none matches `deniedPaths` |
| 7 | `size` | Non-generated files ≤ `maxFiles` and non-generated lines ≤ `maxLines` |
| 8 | `semverCap` | Max semver delta ≤ the class's `semverCap` |
| 9 | `classificationPermits` | The repo's `classification` is in the class's `classifications` |
| 10 | `tierFloor` | The repo's `ciTrustTier` ≥ the class's `tierFloor` |
| 11 | `freezeOff` | `rules.freeze` is `false` |

Gates 6 through 10 all read the change class. When gate 5 yields `unclassified` they record
`skipped` — not `fail`, because "we could not compute this" and "this rule was violated" are
different facts and the shadow report must not conflate them.

More than one gate can fail on a single PR, and the record keeps all of them. PR #32 fails both
`classificationPermits` (no classification permits `dep-major`) and `tierFloor` (`dep-major`
requires tier 3; the demo repo is tier 2). `failedGate` names only the first, which is what the
check-run rationale leads with; the full map is what the gate-failure breakdown queries.

Gate 3 reuses `github-pr-jira-check`'s `containsJiraKey` and its committed `JIRA_PROJECT_KEYS` list,
ported over. The strict hydrated-key matcher matters here: the lenient fallback matches any
`[A-Z]+-[0-9]+` token, which happily accepts `UTF-8` and `SHA-256` out of a PR body.

### One deliberate deviation: evaluate all, report the first

PLAT-1190 says *"any 'no' ends it and the PR is simply not a candidate."* Read literally, that
produces an eval record with one gate populated and ten blank — which destroys the gate-failure
breakdown that the whole shadow phase exists to produce, and which the epic's own record schema
shows fully populated.

So: **every computable gate is evaluated and recorded; `failedGate` records the first failure in
ticket order.** The verdict is identical either way — one `fail` anywhere means not a candidate —
but the dataset answers "which gate blocks most PRs?" instead of only "did this PR pass?".

Ordering still matters for `failedGate`, and gate 11 is still evaluated last.

## Change classification

Read from the `package.json` patch hunk returned by `GET /repos/{owner}/{repo}/pulls/{number}/files`
— never from the PR title, and never from the dependabot summary table in the body. The epic is
explicit that semver deltas come from the manifest diff, and a bot-authored body is no more
trustworthy than a bot-authored title.

Classification order:

1. Only generated paths changed → `lockfile-only`
2. `package.json` changed and every non-generated change is a dependency version line →
   `dep-patch` / `dep-minor` / `dep-major`, by the **maximum** delta across all changed dependency
   lines
3. Anything else → `unclassified`

**Max delta governs.** A group of eleven patches is `dep-patch`; one major among them makes the
whole PR `dep-major`. This matches how a reviewer actually reads a grouped bump, it fails safe, and
it is the only rule that makes the demo repo's real PRs classifiable — every dependabot PR there is
grouped.

A version string that cannot be parsed as semver (a git URL, a tag, a workspace protocol) makes the
whole PR `unclassified`. Never guessed, never skipped over.

## The eval record

DynamoDB table `zapp-evaluations`:

- `pk` = `repo#<owner>/<name>#pr#<number>`
- `sk` = `eval#<ISO-8601 timestamp>`
- GSI `gsi-rules-sha` on `rulesSha`

Each record carries `headSha`, `rulesSha`, `mode`, the full per-gate map (verdict plus observed
value for all eleven), `changeClass`, `failedGate`, and `eligibility.verdict`. This matches the
epic's schema for the eligibility half; the `risk` half arrives with Spec B.

Writes are best-effort: a ledger failure is logged and **does not** fail the delivery. The check run
is the user-visible product and must not be lost because a table write failed. This is a departure
from how every other failure in the worker behaves, and it is deliberate — stated here so it reads
as a decision rather than an oversight.

Scoped short of full PLAT-1193: no S3 immutable archive, no `outcome#` records, no verdict GSI.
Those need T9 proper, and T11 for outcomes.

## What the check run says

`merge-policy/eligibility` stops being a placeholder. For PR #32:

> **Not a candidate — `dep-major`**
>
> The largest version jump in this pull request is a **major** (`@semantic-release/changelog`
> 6.0.3 → 7.0.0). Major dependency bumps are not eligible for automation on a `sandbox` repository.
>
> Gates passed: 9 of 11 · First failure: `classificationPermits`
>
> This check is informational and never blocks. Tracking: PLAT-1184.

For PR #27:

> **Would have been a candidate — `dep-minor`**
>
> 6 dependency updates, largest jump minor (`fastify` 5.11.2 → 5.12.0). Repository is `sandbox` at
> CI-trust tier 2; `dep-minor` requires tier 2. All 11 gates passed.
>
> Shadow mode: nothing was approved or merged. Tracking: PLAT-1184.

For PR #37:

> **Not a candidate — author is not an automation account**
>
> This pull request was opened by `iscooter`, a human. The merge-policy service only evaluates pull
> requests from allow-listed automation accounts.
>
> First failure: `botAllowlisted`
>
> This check is informational and never blocks. Tracking: PLAT-1184.

`merge-policy/risk` keeps its placeholder text until Spec B, with the wording adjusted to say the
risk evaluator specifically — not the whole service — is not yet connected, since that will no
longer be true of eligibility.

## Files

| File | Responsibility |
|---|---|
| `policy-rules.yaml` | The rules and enrollment records. Reviewed, versioned, SHA-stamped. |
| `scripts/build-rules.mjs` | Parse, validate, compute the blob SHA, emit the generated module. Build-time only. |
| `src/generated/rules.ts` | Generated, committed, never hand-edited. Frozen rules object + `RULES_SHA`. |
| `src/rules.ts` | Typed accessors over the generated object; the seam every consumer reads through. |
| `src/enrollment.ts` | `isEnrolled` (body rewritten) + `enrollmentFor`. |
| `src/classify.ts` | Diff → change class + max semver delta. Pure. |
| `src/gates.ts` | The eleven gates. Pure function, no I/O. |
| `src/pr-files.ts` | `GET /pulls/{n}/files`, paginated. The only new GitHub call. |
| `src/jira-key.ts` | Ported `containsJiraKey` + `JIRA_PROJECT_KEYS`. |
| `src/ledger.ts` | Eval-record write. Best-effort. |
| `src/evaluate.ts` | Orchestration: fetch files, classify, run gates, render, return verdicts. |

The eleven gates live in one file because they share the rules type and are read as a ladder; the
file is a list of small pure functions plus a runner, not a tangle. `classify.ts` is separate
because semver parsing is the fiddliest logic here and deserves its own test surface.

## Error handling

| Condition | Behaviour |
|---|---|
| `GET /pulls/{n}/files` fails | Throw — the worker releases its claim and SQS retries, as today |
| `package.json` patch absent from the API response | `unclassified`; gates 6–10 `skipped` |
| Unparseable version string | `unclassified`; recorded with the offending string |
| Repo not in `repos` | Gate 1 fails; no GitHub calls made; check still posts |
| Ledger write fails | Log `ledger_write_failed`, continue — the check run still posts |
| Generated rules module missing | Build failure, not a runtime failure |

Logging keeps `src/log.ts`'s existing rule: repo, PR number, SHAs, gate names and verdicts are safe;
PR title and body content are not, and are never logged even though the gates read them.

## Testing

Fixture-driven, per PLAT-1190's acceptance criterion that every gate is covered passing and failing.

- **Captured fixtures.** The real webhook payloads and `pulls/{n}/files` responses for PRs #27, #32
  and #37, committed under `tests/fixtures/`. These three exercise a full pass, a
  classification-denied fail, and an author fail against genuine data.
- **Synthetic fixtures** for the gates the three real PRs do not exercise: `freezeOff`,
  `tierFloor`, `pathsAllowed`, `size`, `conventionalTitle`, `ticketLinked` with
  `ticketRequired: true`, and `enrolled` with `mode: off`. Each gets a passing and a failing case.
- **Classification** — grouped bumps where the max is patch, minor and major; a lockfile-only diff;
  an unparseable version; a mixed source-plus-manifest diff.
- **Rules loader** — each schema violation fails the build with a message naming the offending path;
  `RULES_SHA` matches `git hash-object policy-rules.yaml`.
- **Ledger** — the record carries all eleven gate verdicts; a write failure does not propagate.

### Live validation

A fresh PR on `bankrate/platform-cicd-v2-demo`, plus re-running the existing #27 and #32 by pushing
to them or redelivering their webhooks. Success is all three showing the verdicts tabulated above,
all still `neutral`, all still non-blocking, and three eval records present in `zapp-evaluations`.

## Out of scope

- **PLAT-1191 (T7), the six risk signals** — Spec B, immediately following.
- **PLAT-1192 (T8), the required-checks snapshot** — gates do not read other checks' state.
- **Full PLAT-1188 (T4)** — the DynamoDB enrollment table and PR→table sync stay open.
- **Full PLAT-1193 (T9)** — S3 archive, `outcome#` records, verdict GSI stay open.
- **Routing `check_run` / `check_suite` / `status` / `push`** — still dropped, as T8 owns them.
- **Prod rollout** — QA only, as with PLAT-1233.

## Definition of done

- [ ] `policy-rules.yaml` exists with the bot registry, four change classes, and the demo repo enrolled
- [ ] An invalid rules file fails `pnpm run build`, and therefore the Docker build and the deploy
- [ ] `RULES_SHA` equals `git hash-object policy-rules.yaml`, asserted by a test
- [ ] Every evaluation output carries `rulesSha`
- [ ] All eleven gates implemented, each with a passing and a failing test
- [ ] Every gate's verdict and observed value recorded, with `failedGate` naming the first failure
- [ ] Grouped bumps classify by max semver delta, from the manifest diff only
- [ ] The size gate ignores generated files in both its file and line counts
- [ ] `ENROLLED_REPOS` removed from the code and the Terraform
- [ ] Eval records land in `zapp-evaluations`; "all evals under rules SHA X" is one query
- [ ] A ledger write failure does not lose the check run
- [ ] PRs #27, #32 and #37 produce the three verdicts tabulated above, live
- [ ] Both checks remain `neutral` and on no required-checks configuration
