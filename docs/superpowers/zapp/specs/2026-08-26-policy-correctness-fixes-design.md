# Policy correctness fixes

Design for four places where `bankrate/zapp`'s existing decision logic fails **open** — grading a
change safer than the evidence supports. From the
[policy-enhancement review](../../../../research/2026-08-26-zapp-policy-enhancement-review.md)
(2026-08-26), findings A1, A2, A4 and B3.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec E**, the first of three cut from that review. F covers supply-chain signals; G covers
controls and human override.

Status: drafted 2026-08-26, design approved in chat, awaiting written review.

## Composability

| | |
|---|---|
| **Touches** | `src/classify.ts`, `src/risk.ts`, `src/signals/scan-findings.ts` and their tests |
| **Depends on** | Nothing. Applies to `main` at v1.5.0 as-is. |
| **Safe to parallelise with** | **Spec D** (scan gates and resiliency tier), which touches `gates.ts`, `render.ts`, `evaluate.ts`, `coverage.ts` and `policy-rules.yaml` — no file overlap, including tests. |
| **Blocks** | **Spec F**, which extends `combine()` in `src/risk.ts` with a seventh signal. E's reducer fix is in that same function, so E lands first. |

No rules-file change, so no `RULES_SHA` churn and no conflict with any branch that edits
`policy-rules.yaml`.

## Why these four together

Each is a case where the code reaches a *more permissive* verdict than its inputs justify, and each
is a pure function with no I/O. They share a shape: the fix is a comparison, and the test is a table.

They are worth doing before any new detection, because a new signal layered over logic that
misgrades its inputs inherits the misgrade.

The review lists two more code findings — A5 (commit authorship) and A6 (base branch) — which are
**not** here. Those add new checks rather than correcting existing ones, and A5 needs a GitHub call.
Both are in Spec G.

## A1 · Six of GitHub's eight check conclusions currently read as clean

`src/signals/scan-findings.ts:55`:

```ts
const failed = found.filter((run) => run.conclusion === 'failure').length;
```

A Cycode run that completes as `cancelled`, `timed_out`, `stale` or `action_required` is not
`failure`, so it contributes nothing to `failed`, and the signal grades **low**. A commit that was
never actually scanned reads as a clean scan — the exact inversion that module's own header calls
"the single most dangerous thing this module could do".

Three buckets replace the single comparison:

| Conclusion | Bucket |
|---|---|
| `success`, `neutral`, `skipped` | reported clean |
| `failure`, `action_required` | a finding |
| `cancelled`, `timed_out`, `stale`, `null` | **`unknown`** — not scanned in practice |

`action_required` sits with findings rather than with `unknown` because it is a definite non-green
outcome the scanner deliberately emitted; something needs a human. The other three mean the scan did
not produce a verdict at all, which is what `unknown` means everywhere else in this service.

An `unknown` here removes the signal from the worst-of comparison and decrements `signalsGraded`, so
the check run says "graded on 4 of 6" and names the reason — the existing machinery, no new
plumbing.

### Note for whoever lands this alongside Spec D

Spec D's `checksGreen` gate already treats `success`/`neutral`/`skipped` as green and everything else
as not-green. Today the two disagree; after both land they agree. If D has already merged when this
starts, reuse its `GREEN` set rather than defining a second one.

## A2 · A downgrade classifies as an upgrade

`deltaLevel()` in `src/classify.ts` compares version components without direction:

```ts
if (a[1] !== b[1]) return 'major';
if (a[2] !== b[2]) return 'minor';
```

`5.12.0 → 5.11.2` returns `minor`, identically to `5.11.2 → 5.12.0`. A downgrade into a
known-vulnerable version rides the routine `dep-minor` path.

A new sibling, `isDowngrade(from, to): boolean | null`, is checked in `classify()` **before** the
level is computed. Any downgrade yields `unclassified`, with the reason naming the package and both
versions: *"version downgrade: `fastify` ^5.12.0 → ^5.11.2"*.

**Not a new change class.** A `dep-downgrade` class would need a size ceiling, a tier floor, a semver
cap and a classification list, none of which anyone has reasoned about. Downgrades from allow-listed
bots are rare enough that failing closed costs nothing real, and inventing four thresholds to admit
them would.

`isDowngrade` returns `null` on an unparseable version, matching `deltaLevel`'s existing convention,
and `classify()` treats null the same way it already does — `unclassified`.

## A4 · The security reducer can override the cooldown

`combine()` in `src/risk.ts`:

```ts
const finalRank = closes ? Math.max(0, worstRank - 1) : worstRank;
```

A release published **hours ago** grades `medium` on publish age. If it also closes an open advisory,
the reducer drops the whole grade to `low`. But rushed and fabricated security releases are a
documented attack pattern, and fresh publish age is precisely the signal that catches them. The
reducer currently cancels out the one thing standing between us and that case.

Two changes, both in the fail-closed direction:

1. **The reducer applies only when `publishAge` is known.** It is a *concession*, and granting a
   concession on absent data is the pattern this service refuses everywhere else.
2. **It can never reduce the grade below `publishAge`'s own rank.**

```ts
const publishAgeKnown = signals.publishAge.grade !== 'unknown';
const floor = publishAgeKnown ? RANK[signals.publishAge.grade] : 0;
const finalRank = closes && publishAgeKnown
  ? Math.max(floor, worstRank - 1)
  : worstRank;
```

The reducer still does its job where it should: a `high` from semver distance, with a mature package
closing a CVE, still reduces to `medium`.

Dependabot deliberately exempts security updates from its cooldown. That is a defensible choice for
*notifying* a human, and the wrong one for *unattended merge* — a human reading a Dependabot PR can
notice a suspicious release; an auto-merge cannot. The spec keeps the cooldown supreme and records
the divergence here so it reads as a decision rather than an oversight.

## B3 · A 0.x minor is a de-facto major

Semver promises no compatibility below 1.0, and Renovate's automerge guidance excludes pre-1.0
packages outright (`matchCurrentVersion: "!/^0/"`). Today `0.1.0 → 0.2.0` grades `minor` and rides
the `dep-minor` path with a `silver` tier ceiling.

**When the `from` version's major component is `0` and the minor component changes, the delta ranks
`major`.**

`0.1.1 → 0.1.2` deliberately stays `patch`. The review's citation is specifically that a 0.x *minor*
is a de-facto major; shifting 0.x patches up a level as well would be inventing policy rather than
implementing it, and the change class already caps size and paths for patch bumps.

The rule keys on the **from** version, not the to: `0.9.0 → 1.0.0` is already `major` by the normal
comparison, and `1.0.0 → 1.1.0` is unaffected.

## Files

| File | Change |
|---|---|
| `src/signals/scan-findings.ts` | Three conclusion buckets replacing one equality check |
| `src/classify.ts` | `isDowngrade()`; direction checked before level; 0.x minor ranks major |
| `src/risk.ts` | Reducer gated on known publish age, floored at its rank |

No new modules, no new dependencies, no rules-file or infrastructure change.

## Error handling

Nothing here adds a failure mode. Each change makes an existing path reach a stricter verdict on the
same inputs:

| Input | Before | After |
|---|---|---|
| Scanner `cancelled` | signal `low` | signal `unknown`, excluded from worst-of, named in the check |
| `5.12.0 → 5.11.2` | `dep-minor` | `unclassified`, reason names both versions |
| Fresh release closing a CVE | grade `low` | grade `medium` |
| `0.1.0 → 0.2.0` | `dep-minor` | `dep-major` |

## Testing

Table-driven, since all four are pure functions:

- **Conclusions** — all eight of GitHub's values plus `null`, each asserted into its bucket. The
  regression that matters: `cancelled` must not grade `low`.
- **Direction** — downgrade, upgrade and equal at each of the three semver positions; an unparseable
  version still returns null; a downgrade's `unclassified` reason names the package and both
  versions.
- **Reducer** — the full grade matrix with `publishAge` known and unknown, asserting the reducer
  never lowers below the publish-age rank and never applies at all when publish age is unknown; plus
  the case it must still serve, `high` + mature package + closes advisory → `medium`.
- **0.x** — minor, patch and major bumps below 1.0, with `1.x` controls proving the normal path is
  untouched.

### The regression that guards all four

**PR #27 must remain a `dep-minor` candidate and PR #32 a `dep-major` non-candidate**, asserted
against the committed fixtures. Every one of these fixes makes the service stricter, and a stricter
service that flips the one pull request demonstrating a pass has broken something. If a fixture
verdict changes, the fix is wrong — not the fixture.

## Out of scope

- **A5 (commit authorship) and A6 (base branch)** — new checks, not corrections. Spec G.
- **B1, B2, B6** — new detection. Spec F.
- **A3 (runtime freeze)** — Spec G.
- **C1** — already closed. The App holds `checks:write` as its only write permission, verified
  2026-08-26; the review's claim that it still has `pull_requests:write` and `merge_queues:write` is
  stale.
- **C2 (outcome records)** — PLAT-1193 and T11, existing tickets.
- **C4 (monorepo `dep-type`)** — correctly deferred until the first monorepo enrols.

## Definition of done

- [ ] `cancelled`, `timed_out`, `stale` and a null conclusion each grade the scanner signal `unknown`
- [ ] `action_required` counts as a finding
- [ ] `success`, `neutral` and `skipped` still count as reported clean
- [ ] A version downgrade yields `unclassified`, with both versions named in the reason
- [ ] The security reducer does not apply when publish age is unknown
- [ ] The security reducer never lowers the grade below the publish-age grade
- [ ] The reducer still lowers `high` to `medium` for a mature package closing an advisory
- [ ] `0.1.0 → 0.2.0` ranks `major`; `0.1.1 → 0.1.2` stays `patch`; `1.x` behaviour is unchanged
- [ ] PR #27 is still a `dep-minor` candidate and PR #32 still a `dep-major` non-candidate
- [ ] No change to `policy-rules.yaml`, so `RULES_SHA` is untouched
