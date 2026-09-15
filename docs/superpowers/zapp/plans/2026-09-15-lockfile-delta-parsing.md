# Lockfile Delta Parsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `lockfile-only` asserting `maxDelta: 'none'` without having read the lockfile. Measure the real semver delta by parsing the lockfile at base and head, so gate 8 stops passing vacuously and the six bump-dependent risk signals have something to grade.

**Architecture:** `classify()` stays **pure**. The lockfile is fetched in the caller and passed in as a parsed name → version map per side, exactly as `sections` already is for the manifest. A new pure module `src/pipeline/01-classify/lockfile.ts` parses `package-lock.json` into that map and is the only place that knows a lockfile format. `classify()` diffs the two maps through the existing `deltaLevel`, producing real `DependencyBump[]` and a real `maxDelta`. Unsupported formats return `null`, which propagates as *unknown*, never as `none`.

**Tech Stack:** TypeScript (ESM, `node22` target), `node --import tsx --test`, GitHub contents API via the existing `githubRequest`, pnpm.

**Ticket:** [PLAT-1322](https://redventures.atlassian.net/browse/PLAT-1322)

---

## Does this resolve the 2-of-4 `minSignalsGraded` problem?

**Yes — 6 of 9, against a floor of 4.** Verified signal by signal against the code on 2026-09-15 rather than assumed, because the answer turns on whether each signal needs the bumped package to appear in a *manifest*, and only one of them does.

| Signal | Today | After this plan | Why |
|---|---|---|---|
| `semverDistance` | `unknown` | ✅ **graded** | `risk.ts:63` needs only `bumps.length > 0` |
| `publishAge` | `unknown` | ✅ **graded** | sourced from **api.deps.dev** keyed on `(name, version)` — manifest-independent |
| `targetVersionHealth` | `unknown` | ✅ **graded** | same `BumpRecord` fetch, same reason |
| `closesFinding` | `unknown` | ✅ **graded** | advisory lookup by name/version; counts toward `signalsGraded` |
| `newFindings` | ✅ graded | ✅ graded | non-bump signal, unaffected |
| `coverageDelta` | ✅ graded | ✅ graded | non-bump signal, unaffected |
| `depType` | `unknown` | ⚠️ **still `unknown`** unless Task 6 lands | `dep-type.ts:88` rejects any package absent from the head manifest. A transitive dep is in no manifest, ever. |
| `internalConfidence` | `unknown` | ❌ still `unknown` | `internal-confidence.ts:112` short-circuits on `fleet < minFleetForConfidence`. Fleet is **29**, the floor is **50**. Gated on enrolment, not on bumps. |
| `deploymentHealth` | `unknown` | ❌ still `unknown` | `minDeployments: 10`, which no repo clears (PLAT-1318) |

**2 → 6.** Task 6 takes it to 7 by giving `depType` a real answer for transitive packages instead of `unknown`.

Margin matters more than the headline, because these are network-dependent. If deps.dev is unreachable, `publishAge` and `targetVersionHealth` both drop and the count is **4** — exactly at the floor, no slack. If the advisory lookup also fails, it is **3** and the PR correctly reads `unknown` rather than approving on thin evidence. That is the right failure mode, but it means **`minSignalsGraded: 4` is satisfied by a margin of two, not by a wide one.** Do not treat this as headroom to spend.

### The risk layer already anticipated this

Worth reading before starting, because it establishes that the doctrine is settled and only gate 8 disagrees. `risk.ts:55-60`:

> `maxDelta: 'none'` is ambiguous on its own: it means either "every bump was a no-op" or "classify() never looked inside a lockfile-only change" — the latter is not the same fact as "nothing changed," so a zero-bump PR grades `unknown` here regardless of what `maxDelta` says.

The risk layer already refuses to trust the classifier's `none`. This plan extends that distrust to the gate layer, where it is currently absent.

## Volume consequence — measured, not estimated

Swept every Dependabot pull request (last 30 per repo, open and closed) across all 29 enrolled repositories and selected those whose changed files are lockfiles only. **39 such pull requests.** Max delta found inside each:

| max delta in the lockfile | count | share | verdict after this plan |
|---|---|---|---|
| contains a **minor** | **24** | 62% | `semverDistance` grades `medium`; `maxRiskGrade: low` → **blocked at risk** |
| **patch-only** | **14** | 36% | grades `low`, reaches 6 signals → **approves and merges** |
| contains a **major** | 1 | 3% | **fails gate 8** |

So candidate volume for the class drops by roughly two thirds. **Do not read that as a loss.** Today all 39 park: `signalsGraded: 2` means `shouldApprove` returns `false` while `shouldEnable` can return `true`, which is PLAT-1320's enable-and-park. The real change is:

> **from 39 candidates of which 0 can complete, to 14 candidates of which 14 can complete.**

State that framing in the PR description. "Lockfile candidates fell 64%" read on its own will look like a regression to anyone watching the weekly report.

---

## Global Constraints

- **`classify()` MUST stay pure.** It currently takes `files` plus a pre-fetched `sections` map and does no I/O. Fetch both lockfiles in the caller and pass parsed maps in the same way. Do not make `classify()` async, and do not thread `githubRequest` into it — several callers (`recordClosure`, `backfill-outcomes`) legitimately have no network context and pass `sections: null`.
- **Never parse the patch.** The files API omits `patch` above a size threshold and lockfile diffs cross it routinely. `classify()` already fails closed on that for manifests (*"has no patch in the API response — too large to classify"*); for lockfiles it would be the common case, not the edge. Fetch whole files at base and head. This is the single most important design point and the reason a regex over the diff — which is how PLAT-1322's evidence was gathered — is not acceptable in the shipped path.
- **Absent is unknown, never `none`.** An unparseable, unsupported, or unfetchable lockfile yields `null`, and `null` must reach a verdict of `unclassified` or an explicitly unknown delta. Reproducing the very bug this plan fixes, one level down, is the main way this work goes wrong. `deltaLevel`'s doc comment states the rule; follow it.
- **`.terraform.lock.hcl` is in `generatedPaths`.** A PR touching only it classifies as `lockfile-only` today. It is a Terraform *provider* lock, not an npm lockfile, and provider majors are real. The npm parser must not be handed it — return `null` for it rather than an empty map, because an empty map would diff to "nothing changed" and re-create the false `none`.
- **One format, honestly.** Ship `package-lock.json` only. `pnpm-lock.yaml` and `yarn.lock` return `null` until separately implemented. One correct parser beats three approximate ones, and `package-lock.json` covers the measured evidence including conductor#431.
- **`maxDelta` is the max across all bumps**, consistent with grouped manifest bumps today. A single lockfile diff can move hundreds of transitive packages; worst-wins is correct and is why 62% of the corpus lands at `medium`.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## Decisions — one needs sign-off before Task 4

Tasks 1–3 are safe to start immediately; they add measurement without changing any verdict. **Task 4 changes verdicts and needs Scott's confirmation of the recommendation below before it is written.**

**The question:** once a lockfile-only PR has a real `maxDelta`, what class does it get?

| | Option | Consequence |
|---|---|---|
| **A** | Route through `LEVEL_FOR_CLASS` → `dep-patch` / `dep-minor` / `dep-major` | `lockfile-only` shrinks to "literally no version moved", i.e. near-never. It also imposes `dep-patch`'s **`minCoveragePct: 60`**, **`tierFloor: 2`** and **`maxResiliencyTier: gold`** on lockfile changes that carry none today. `redirect-management-api-v2` is **Platinum** — above gold — so it loses its only remaining candidacy path entirely. |
| **B** ✅ | Keep the class, give it **`semverCap: patch`** | Patch-only lockfile PRs stay `lockfile-only` with its loose limits — now *verified* rather than assumed. Minor and major fail gate 8 with a precise reason. Platinum repos keep working. The `# generated content only; safe anywhere` comment becomes defensible because it is finally conditional on a measured delta. |
| **C** | Keep `semverCap: none` | Every lockfile PR that moves anything fails gate 8. Safest, and throws away all 14 mergeable PRs. |

**Recommend B.** It is the only option that both closes the hole and keeps the 14 patch-only PRs — which are the entire upside of this work. `semverCap: patch` rather than `none` because "no resolved version moved at all" is a state that essentially never occurs in a Dependabot lockfile PR, so `none` is option C wearing a different hat.

**A known inconsistency B leaves behind, recorded so it is not discovered later as a surprise.** After PR #74, a *manifest* minor on a gold prod-service repo is permitted (`dep-minor`). Under B a *lockfile* minor is not. Arguably backwards — a lockfile bump of a **direct** dependency happened *within a range its maintainer chose*, which is a sanction a manifest bump does not have. But for a **transitive** dependency there is no declared range and nobody sanctioned anything, and conductor#431 is transitive. The parser can tell these apart (is the name in the root manifest?), so the principled refinement is a direct/transitive split with different caps. **That is deliberately not in this plan** — it needs its own decision and the 14-PR win does not depend on it. Note it in the PR description as follow-on work.

---

- [ ] **Step 1: Verify the base and reproduce the arithmetic**

```bash
cd ~/Projects/zapp
git fetch origin && git rev-list --count HEAD..origin/main
grep -n "maxDelta: 'none', bumps: \[\]" src/pipeline/01-classify/classify.ts
grep -n "minSignalsGraded:\|minFleetForConfidence:\|maxRiskGrade:" policy-rules.yaml
grep -n "not found in the head manifest" src/pipeline/03-risk/signals/dep-type.ts
```

Expected: `0` behind; the hardcoded `maxDelta: 'none'` at ~`:135`; `minSignalsGraded: 4`, `minFleetForConfidence: 50`, `maxRiskGrade: low`; and `dep-type.ts:88`'s manifest rejection.

Then confirm the defect on the real pull request before changing anything:

```bash
gh api repos/bankrate/conductor/pulls/431/files --jq '[.[].filename]'
gh api repos/bankrate/conductor/contents/package.json --jq .content | base64 -d | grep -c hono
```

Expected: `["package-lock.json"]` and `0`. That is a major bump of a package declared in no manifest, which zapp currently grades as no change at all.

- [ ] **Step 2: `lockfile.ts` — the parser, pure and tested first**

Create `tests/lockfile.test.ts` before the module. Cases:

1. A `package-lock.json` v3 fixture with `packages: { "node_modules/foo": { version: "1.2.3" } }` → map `{ foo: "1.2.3" }`.
2. Nested paths — `node_modules/a/node_modules/b` → keyed as `b`, not the full path. Decide and **state in a comment** whether two different nested copies of the same package at different versions collapse; recommend keeping the **highest delta** rather than last-wins, so the diff cannot under-report.
3. Scoped packages — `node_modules/@hono/node-server` → `@hono/node-server`. This is the conductor#431 shape; get it right.
4. The root `""` entry and any `link: true` / workspace entries → **excluded**. They are not third-party versions.
5. A v1 lockfile (`dependencies`, no `packages`) → `null`. Do not half-support it; `null` means unknown and fails closed.
6. Malformed JSON → `null`, no throw.
7. An empty `packages` object → **`null`, not `{}`**. See the constraints: an empty map diffs to "nothing moved" and silently re-creates the bug.

Then write `src/pipeline/01-classify/lockfile.ts` exporting something like `parseLockfile(filename: string, content: string): Record<string, string> | null`, returning `null` for any filename that is not a `package-lock.json` — which is what keeps `.terraform.lock.hcl`, `pnpm-lock.yaml` and `yarn.lock` honest rather than wrong.

- [ ] **Step 3: Diff the maps inside `classify()` — still no verdict change**

Tests first, in the existing `tests/classify.test.ts`. Extend `classify()`'s signature with an optional pre-parsed pair, defaulting to `null` so every existing caller and test compiles untouched:

```ts
lockfiles: { base: Record<string, string>; head: Record<string, string> } | null = null,
```

Cases:

1. `authored.length === 0` and `lockfiles === null` → **exactly today's behaviour**, so `recordClosure` and `backfill-outcomes` are unaffected. Assert this explicitly; it is the compatibility contract.
2. `lockfiles` supplied, one package `1.2.3 → 1.2.4` → `bumps` has one entry, `maxDelta: 'patch'`.
3. `@hono/node-server` `1.19.14 → 2.1.0` → `maxDelta: 'major'`. **The conductor#431 regression test.** Name it after the PR.
4. Mixed patch + minor + major → `maxDelta: 'major'`; assert `bumps` contains all three, because the risk signals grade over the whole array.
5. A package present in head and absent from base (newly added transitive) → decide and test. Recommend **ignore** for delta purposes: there is no `from` version, so `deltaLevel` has nothing to compare and inventing `major` would be as much a fabrication as `none` is today. Record it in `bumps` only if a `from` exists.
6. A package removed in head → ignore, same reasoning.
7. A version that is not bare `x.y.z` (git URL, `npm:` alias, workspace protocol) → `deltaLevel` returns `null` → propagate to `unclassified`, matching the manifest path's existing rule. Do **not** skip it silently.

Reuse `deltaLevel` and `RANK` as they are. Do not write a second semver comparator.

- [ ] **Step 4: The class and cap decision — verdicts change here**

**Do not start until the Decisions section above is signed off.** Assuming **B**:

- `policy-rules.yaml`: `lockfile-only.semverCap: none` → `patch`. Replace the `# generated content only; safe anywhere` comment on `maxResiliencyTier` — it is currently false and is quoted in PLAT-1322 as such. The new comment should say the loose limits are conditional on a *verified* patch-only delta, and name conductor#431 as the reason the old claim was wrong.
- Leave `tierFloor: 1`, `classifications`, `minCoveragePct: 0` and `maxResiliencyTier: platinum` alone. Changing them is option A by increments.
- Tests: a lockfile-only PR with `maxDelta: 'patch'` passes gate 8; `minor` and `major` fail it with `{ delta, cap }` naming the real delta. Assert the failure **value**, not just the verdict — the whole point is that the reason is now true.

Note `maxLines: 0` / `maxFiles: 0` on the class need no change: gate 7 counts authored files only, so a lockfile-only PR is 0/0 and passes regardless.

- [ ] **Step 5: Wire the fetch in the caller**

Find where `fetchManifestSections` is called on the eligibility path and add the lockfile fetch beside it, using the same shape:

```ts
`/repos/${repoFullName}/contents/${path}?ref=${sha}`  // Accept: application/vnd.github.raw
```

Two calls — base SHA and head SHA — for each lockfile in the diff. Requirements:

- **Never throw.** Mirror `fetchManifestSections`: log a warning and return `null` on any non-ok response. A delivery must not fail over this.
- Fetch **only** when the diff actually contains a lockfile the parser supports. Do not add two requests to every evaluation of every PR.
- A 404 on the **base** side is legitimate — the lockfile may be newly added — and must yield `null`, not an empty map.
- Lockfiles are large. Check whether `githubRequest` imposes a response size limit and say so in a comment either way; a truncated lockfile that still parses as JSON is the worst possible outcome here.

- [ ] **Step 6: `depType` learns "transitive" (takes 6 signals to 7)**

Currently `dep-type.ts:88` returns `unknown` for any package absent from the head manifest. A transitive package is absent from every manifest by definition, so without this step `depType` is permanently `unknown` for exactly the population this plan unlocks.

But *"not in the manifest"* is not an unknown — it is a **known fact about the dependency**, and arguably a distinct risk category: a transitive dependency is not imported by this repo's own code, so its blast radius differs from a direct one. Recommend grading it rather than abstaining, with a `transitive` section value alongside `production` / `development`.

**Read PLAT-1311 before touching this file.** It rewrites the same rejection path for *nested* manifests, where the package genuinely is declared and the fetch is simply looking in the wrong place. The two are different facts with different remedies and must not be collapsed into one branch:

- PLAT-1311: declared in a nested manifest → **find it**, grade it normally.
- This plan: declared nowhere → **grade it transitive**.

If PLAT-1311 has not landed, implement the transitive branch as the fallback *after* the manifest lookup fails, so 1311 can later insert the nested lookup ahead of it without rework. Say that in a comment.

If grading transitive is rejected on review, this step reduces to a comment explaining why `depType` is permanently `unknown` for lockfile-only, and the count stays 6. Either is acceptable; silently leaving it unexplained is not.

- [ ] **Step 7: Ledger, docs, and live validation**

- **Reclassification of history.** Existing `lockfile-only` rows asserted `maxDelta: 'none'`. Do **not** backfill — the rows are accurate records of what the classifier believed. Confirm the stamped `rulesSha` (or add a classifier version) makes them readable as *graded under the pre-parse classifier*. If nothing on the row distinguishes them, that is a finding: raise it rather than silently rewriting history.
- `docs/policy.md` — state what `lockfile-only` now knows about its own contents, which formats are parsed, and that unsupported formats fail closed.
- Weekly report — the class's candidate count will drop ~64%. Check whether the report would present that as a regression and, if so, make it legible. This is the single most likely way correct work gets read as a bug.
- **Live validation.** Replay conductor#431 and assert gate 8 now fails naming `major`. Then re-run the fleet sweep and confirm the observed split lands near 14 patch-only / 24 minor / 1 major; a large divergence means the parser disagrees with the patch-regex that produced those numbers, and the parser is not automatically the one that is right — investigate before shipping.
- Comment on **PLAT-1320** with the measured post-change `signalsGraded` for a real patch-only lockfile PR. That ticket's central claim is that 4 is arithmetically unreachable for this class; this closes it out with evidence rather than assertion.
