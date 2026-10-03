# Stale Lockfile PR Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `lockfile-only` pull request that moves no dependency version currently passes gate 8 with `none ≤ patch`, which reads as a safety clearance. It is not one. It means the update has already landed on main by other means and the pull request is stale. Make gate 8 fail, and say which of the two reasons applies.

**Architecture:** One condition in gate 8, two optional fields on `ClassificationResult` so the message can be specific, one branch in `render.ts`. No new gate, no new config, no new fetches.

**Tech Stack:** TypeScript (ESM, `node22` target), `node --import tsx --test`, pnpm.

## The behaviour change, exhaustively

Gate 8 sees these cases. **Rows 4 and 5 change. Nothing else does.**

| | the pull request | today | after |
|---|---|---|---|
| 1 | lockfile moved one package a **patch** | ✅ pass `patch ≤ patch` | unchanged |
| 2 | lockfile moved one package a **minor** | ❌ fail `minor > patch` | unchanged |
| 3 | lockfile moved one package a **major** | ❌ fail `major > patch` | unchanged |
| 4 | **lockfile read, no package moved** | ✅ **pass** `none ≤ patch` | ❌ **fail**, stale |
| 5 | **base lockfile could not be read** | ✅ **pass** `none ≤ patch` | ❌ **fail**, no delta computable |
| 6 | head lockfile unreadable, or `pnpm-lock.yaml` / `yarn.lock` | ❌ `unclassified` at gate 5 | unchanged |
| 7 | `dependabot-config` | ✅ pass `none ≤ none` | unchanged |
| 8 | ordinary PR (`package.json` + lockfile) | pass/fail on the real delta | unchanged |
| 9 | unenrolled repo or `mode: off` | gate 1 fails first | unchanged |

**The rule is one line: `changeClass === 'lockfile-only'` with `bumps.length === 0` fails gate 8.** Rows 4 and 5 both satisfy it and differ only in the sentence rendered.

## Why failing is right

`coverageFloor` already fails rather than skips when `codecov/project` never reported a percentage. `checksGreen` fails on an absent check. PLAT-1312 just removed the last place where a non-event read as success, when `skipped` counted GREEN.

Gate 8 passing on `none` is the same shape. A pass asserts *"the version jump is within the ceiling."* There is no version jump. Affirming a bound on something that does not exist is not a safety finding.

## Evidence

[bankrate/conductor-api#636](https://github.com/bankrate/conductor-api/pull/636), measured 2026-09-15.

Dependabot opened it on 19 August titled *"bump undici from 6.27.0 to 7.29.0"*. Verified directly by fetching both lockfiles and diffing the package maps:

* merge base (`90c476fd`) — 761 package entries, `node_modules/undici` at **7.29.0**
* head (`82e79c64`) — 767 entries, `node_modules/undici` at **7.29.0**
* packages with a changed version: **0**
* packages added: **5** — `@emnapi/core`, `@emnapi/runtime`, `@emnapi/wasi-threads`, `@napi-rs/wasm-runtime`, `@tybys/wasm-util`
* packages removed: 0

`base.sha` and the real merge base are the same commit, so zapp is diffing the right two trees. Main already carries undici 7.29.0. The title describes a bump that landed by other means.

zapp's verdict today: `✅ semverCap — none ≤ patch`, 16 of 18 gates passed, first failure `checksGreen`. The author is told to wait for a Terraform plan. The truth is the pull request is dead.

## Global Constraints

- **Key the condition on the CLASS, not on `maxDelta === 'none'`.** `dependabot-config` also reports `maxDelta: 'none'` with `bumps: []`, and that is correct there — its diff contains no lockfile and no manifest, so there is nothing to compare. Keying on `maxDelta` would fail every Dependabot config PR.
- **Do not add a `bumpsMeasured` boolean.** An earlier draft proposed one to tell "read and found nothing" from "did not read." It is unnecessary: on the evaluation path `classifyLockfileOnly` is only reached when `diffIsLockfileOnly` is true (`src/pipeline/index.ts:162`), which is the same condition as its own `authored.length === 0` trigger, so `lockfiles` is always a real object there. The only caller that passes a top-level `null` is `src/entrypoints/worker/worker.ts:233`, which reads `.bumps` for an outcome record and never calls `runGates`.
- **Row 5 fails deliberately.** A 404 on the base lockfile is ambiguous between "this pull request adds a lockfile for the first time" and "the base commit is gone." Both produce the same empty map. Failing costs a genuine first-lockfile pull request its gate 8 pass, which is acceptable — that is not a routine dependency bump and should not auto-merge. Passing would mean affirming a ceiling against a base that was never read, which is the defect this plan exists to remove. **Do not soften this into a pass without changing the plan.**
- **The verdict does not change for any pull request in the fleet today.** Every affected pull request already fails a later gate. What changes is `failedGate` and the rendered reason. Say so in the PR description so nobody reads "no verdicts changed" as "no effect."
- **`runGates` stays pure.** Everything needed is already on `ClassificationResult`.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## Sequencing

Independent of the gate 11 sample-honesty work, but both touch `render.ts` and `gates.ts`. If [zapp#77](https://github.com/bankrate/zapp/pull/77) is still open, fold this in rather than opening a third branch against the same two files.

---

- [ ] **Step 1: Verify the base and reproduce the evidence**

```bash
cd ~/Projects/zapp
git fetch origin && git log --oneline -1 origin/main
grep -n "gates.semverCap = " -A 4 src/pipeline/02-gates/gates.ts
grep -n "classifyLockfileOnly" -A 14 src/pipeline/01-classify/classify.ts
```

Expected: gate 8 is a bare `gate(RANK[...] <= RANK[...])` with no zero-bump branch, and `classifyLockfileOnly` skips a package when `from === undefined`.

Then confirm the finding on the real pull request rather than trusting the table above:

```bash
gh api repos/bankrate/conductor-api/pulls/636 --jq '"base \(.base.sha)\nhead \(.head.sha)\n\(.title)"'
```

Fetch `package-lock.json` at both SHAs with `-H "Accept: application/vnd.github.raw"`, build a name → version map from `.packages` (strip everything up to the last `node_modules/`, skip entries with `link: true`), and diff. **Expect zero changed versions and five additions.** If you get a changed version, stop — the premise is wrong and this plan needs rewriting.

- [ ] **Step 2: `classifyLockfileOnly` reports what it compared**

Tests first, in `tests/classify.test.ts`.

Two optional fields on `ClassificationResult`, both only meaningful for a lockfile-only diff:

```ts
  /** Lockfile-only diffs: packages present in head with no counterpart in base. */
  packagesAdded?: number;
  /** Lockfile-only diffs: whether a real base lockfile was read and compared. */
  baseCompared?: boolean;
```

Optional so every existing caller and test compiles untouched. `classifyLockfileOnly` sets both; no other path does.

Cases:

1. Base and head both parsed, one package moved patch → `bumps` has one entry, `baseCompared: true`, `packagesAdded: 0`.
2. Base and head both parsed, **no** package moved, three present in head only → `bumps: []`, `baseCompared: true`, **`packagesAdded: 3`**. This is conductor-api#636's shape and the plan's central fixture.
3. Base null (`lockfiles.base === null`), head parsed with 40 packages → `bumps: []`, **`baseCompared: false`**, `packagesAdded: 40`.
4. A package removed in head → still not a bump, and **not** counted in `packagesAdded`. Assert it, because the name invites the wrong reading.
5. `dependabot-config` → both fields **absent**. Assert `undefined`, not `0`/`false` — absent and zero are different facts and the render branch depends on it.
6. The `lockfiles === null` compatibility branch → both fields absent, `maxDelta: 'none'`, exactly today's shape. This is `worker.ts`'s path and must not change.

- [ ] **Step 3: Gate 8 fails on zero bumps — verdicts change here**

Tests first, in `tests/gates.test.ts`. Read the existing `semverCap` cases before writing and do not duplicate them.

1. `lockfile-only`, `bumps: []`, `baseCompared: true` → gate 8 **fails**, value carries `reason: 'no-version-moved'`.
2. `lockfile-only`, `bumps: []`, `baseCompared: false` → gate 8 **fails**, value carries `reason: 'base-not-compared'`.
3. `lockfile-only`, one patch bump → **passes**. Regression guard for rows 1-3.
4. `dependabet-config`, `bumps: []`, `maxDelta: 'none'` → **passes**. The row 7 guard, and the reason the condition keys on the class.
5. An ordinary manifest PR with bumps → unchanged.

Then the code:

```ts
// 8 — semver cap, against the max delta classify() already computed.
//
// A `lockfile-only` diff with ZERO bumps has no delta to cap. Passing would
// affirm "the version jump is within the ceiling" about a jump that does not
// exist — the same absence-reads-as-success shape PLAT-1312 removed when
// `skipped` stopped counting GREEN, and the same reason `coverageFloor` fails
// rather than skips when codecov never reported.
//
// Keyed on the CLASS, not on `maxDelta === 'none'`: `dependabot-config` also
// reports `none` with no bumps, and that is correct there — its diff contains
// no lockfile and no manifest, so there is nothing to compare.
gates.semverCap = classification.changeClass === 'lockfile-only' && classification.bumps.length === 0
  ? fail({
      delta: classification.maxDelta,
      cap: cls.semverCap,
      reason: classification.baseCompared === true ? 'no-version-moved' : 'base-not-compared',
      packagesAdded: classification.packagesAdded ?? 0,
    })
  : gate(
      RANK[classification.maxDelta] <= RANK[cls.semverCap],
      { delta: classification.maxDelta, cap: cls.semverCap },
    );
```

- [ ] **Step 4: The message**

`render.ts` formats gate 8 as `${delta} ${pass ? '≤' : '>'} ${cap}`, which would print `none > patch`. That is nonsense and is the whole reason this needs its own branch.

Tests first, in `tests/render.test.ts`. Both sentences, and assert the package count appears.

`reason: 'no-version-moved'`:

> No dependency version changed between the merge base and this head. 5 packages were added and none moved, so this pull request no longer performs the update its title describes. Rebase it to pick up main, or close it.

Singular/plural on "package", and when `packagesAdded` is 0 drop that clause entirely rather than printing "0 packages were added".

`reason: 'base-not-compared'`:

> The base lockfile could not be read, so no version delta could be computed for this pull request. A semver ceiling cannot be checked against a base that was never compared.

The one-line summary column needs a branch too. `none > patch` is wrong; use `no version moved` and `base not compared`.

**Do not say "this pull request does nothing."** It adds packages to the lockfile. The claim is narrower and has to stay narrow: it does not do what its title says.

- [ ] **Step 5: Docs and fleet check**

- `docs/policy.md` — document that gate 8 fails for a lockfile-only diff with no bumps, both reasons, and why `dependabot-config` is exempt.
- Re-run the open lockfile-only Dependabot pull requests across the 29 enrolled repos and record how many now fail gate 8 on `no-version-moved`. Known: conductor-api#636 is one. **Report the count in the PR description**, and confirm no pull request that previously reached `candidate` now fails — if one does, a real version moved and Step 2's diff is wrong.
- Get the enrolled repo list from the `zapp-enrollments` table in the QA account, filtering to records that have a `mode` attribute. The table also holds audit rows, which have no `mode`.
- Verify against a live pull request before calling it done. Toggle a non-blocking label to force a re-evaluation — `labeled` is in `PR_ACTIONS` (`src/entrypoints/worker/worker.ts:35`) and the `already_final` guard is only in the `check_suite` handler, so a label toggle re-evaluates even a final record. Remove the label afterwards.
