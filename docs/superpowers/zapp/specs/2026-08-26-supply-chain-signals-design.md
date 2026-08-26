# Supply-chain signals

Design for the version-safety half of the
[policy-enhancement review](../../../../research/2026-08-26-zapp-policy-enhancement-review.md)
(2026-08-26): findings B1, B2 and B6.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec F**, the second of three. E fixes existing logic that fails open; G adds controls and
human override.

Status: **drafted 2026-08-26 for review — the design decisions below have not been discussed yet.**
Three are flagged inline as open.

## Composability

| | |
|---|---|
| **Touches** | `src/signals/publish-age.ts`, `src/risk.ts`, `src/render.ts`, `src/ledger.ts`, `src/evaluate.ts`, `policy-rules.yaml`, `scripts/build-rules.mjs` |
| **Depends on** | **Spec E** — E's reducer fix is in `combine()`, which this spec extends with a seventh signal. **Spec D** — overlaps on `render.ts`, `evaluate.ts` and `policy-rules.yaml`. |
| **Safe to parallelise with** | Nothing currently planned. Run after D and E have both landed. |
| **Blocks** | **Spec G** on `render.ts`, `evaluate.ts` and `policy-rules.yaml`. |

## What this adds

One question runs through all three findings: **is this specific version safe to take?** Today the
service asks how big the jump is, how old the release is, and whether it closes an advisory — but
never whether the version being installed is itself known-bad.

- **B1** makes the cooldown tiered by semver level and grades sub-24-hour releases as `high`.
- **B2** adds a seventh signal reading whether the target version carries advisories or is deprecated.
- **B6** records an adoption proxy for Phase 1 tuning, without grading on it.

## B2 · Target-version health — the seventh signal

`closesFinding` asks whether the change resolves an advisory **the repo already has**. Nothing asks
whether the version being installed carries a known advisory of its own. That is the event-stream
case: bumping *into* a compromised release.

**The data is already in hand.** `src/signals/publish-age.ts` calls
`api.deps.dev/v3/systems/npm/packages/{pkg}/versions/{v}` for `publishedAt`. The same response
carries:

```json
{
  "publishedAt": "...",
  "advisoryKeys": [{ "id": "GHSA-29mw-wpgm-hmr9" }, …],
  "isDeprecated": false,
  "deprecatedReason": "",
  "slsaProvenances": [],
  "attestations": [],
  "registries": ["https://registry.npmjs.org/"]
}
```

Verified live: `lodash@4.17.20` returns five GHSA ids. So this signal costs **zero additional
requests** — it reads fields already on the wire and currently discarded.

New signal `targetVersionHealth`, graded worst-of across every bumped package:

| Observation | Grade |
|---|---|
| Any advisory on any target version | `high` |
| Any target version deprecated, no advisory | `medium` |
| Clean | `low` |
| All lookups failed | `unknown` |

Advisories and deprecation share one signal rather than becoming two. They answer the same question —
"is this specific release something the ecosystem has flagged?" — and splitting them would push the
service to eight signals for one bit of extra resolution.

**The review's "provenance regression" idea is deliberately not built here.** Detecting that a new
version dropped the npm provenance its predecessor had requires fetching the **from** version too,
doubling deps.dev calls from one per bump to two — 22 requests for a PR #32-shaped change, inside a
30-second budget already shared with four GitHub calls. `slsaProvenances` and `attestations` are
recorded raw on the eval record so the data exists when someone wants to act on it, but no grade
derives from them yet.

> **Open decision 1.** Provenance regression is genuinely valuable against slow-burn attacks, which
> cooldown cannot catch (event-stream sat ~2.5 months). Worth the doubled call volume now, or
> recorded-only until the ledger shows it would have mattered?

## B1 · Tiered cooldown, and sub-day releases graded high

The deck said `<7 days`; the service shipped `cooldownDays: 3`. The research says 3 was right — it is
Dependabot's own default, and pnpm, npm, Yarn, Bun, Deno and uv all shipped equivalents in 2025–26.
cooldowns.dev's incident analysis found 8 of 10 prominent attacks had exploitation windows under a
week, several under a day: axios 2–3 hours, Nx 4–5 hours, `debug@4.4.2` **31 minutes**.

Two changes.

**Cooldown becomes per-semver-tier**, matching Dependabot's `semver-{major,minor,patch}-days`:

```yaml
  risk:
    cooldown:
      patch: 3
      minor: 3
      major: 7
    maxNewFindings: 0
    maxCoverageDropPct: 0
```

Each bump is measured against **its own** level's threshold, not the PR's max delta — a major among
ten patches gets the major window, which is the point of tiering. `cooldownDays` is removed.

**A release under 24 hours old grades `high`, not `medium`**, regardless of tier. The sub-day window
is where nearly every npm compromise actually did its damage, and grading it the same as a
two-day-old release loses exactly the distinction that matters.

So `publishAge` grades:

| Youngest bump | Grade |
|---|---|
| < 1 day | `high` |
| below its tier's cooldown | `medium` |
| at or above its tier's cooldown | `low` |
| every lookup failed | `unknown` |

Note this makes `publishAge` the first signal that can reach `high` on its own, which interacts with
Spec E's reducer floor: a sub-day release closing a CVE now stays `high`, because the reducer cannot
lower below the publish-age rank. That is the intended behaviour and the reason E lands first.

## B6 · Adoption proxy — recorded, never graded

Renovate's Merge Confidence gates automerge on release age plus adoption percentage plus crowd
passing percentage. We cannot buy the crowd data, but deps.dev exposes dependent counts:

```
GET /v3alpha/systems/npm/packages/{pkg}/versions/{v}:dependents
→ { "dependentCount": 25, "directDependentCount": 11, "indirectDependentCount": 14 }
```

**This is a `v3alpha` endpoint**, not `v3`. Alpha APIs change without notice, which is survivable
only because this field is recorded and never graded — a shape change degrades it to null and nothing
else moves.

**One call, for the governing bump only** — the package that set the PR's max semver delta, the same
one the rationale already names. Eleven extra requests for a field nothing grades on would not be
proportionate; one is.

Recorded on the eval record as `adoption: { dependentCount, directDependentCount }` or null. No
grade, no check-run row, no effect on any verdict.

> **Open decision 2.** Record-only fields are worth having *because* they cannot be gathered
> retroactively — the epic's exit criteria need ≥200 evaluations. But an alpha endpoint may simply
> stop working. Accept that, or skip B6 until deps.dev promotes it to v3?

## The seventh signal and the six-signal criterion

PLAT-1191's acceptance criterion says six signals. This makes seven, and every rendering that says
"graded on N of 6" becomes "of 7".

That is a deliberate supersession, recorded here so it reads as a decision: the criterion described
the signals known when the ticket was written, and the review established a seventh from evidence.
The ledger's `signalsGraded` count moves with it, so any Phase 1 query comparing evaluations across
the change must key on `rulesSha` — which is exactly what `rulesSha` is for.

> **Open decision 3.** Alternatively `targetVersionHealth` could fold into the existing
> `closesFinding` signal, keeping the count at six — "advisory posture of this change", covering both
> what it closes and what it introduces. Tidier against the ticket, worse in the check-run table,
> where one row would have to say two opposite things.

## Files

| File | Change |
|---|---|
| `src/signals/publish-age.ts` | Return the full deps.dev record, not just the timestamp; tiered thresholds; sub-day `high` |
| `src/signals/target-health.ts` | New — grade advisories and deprecation from the record publish-age already fetched |
| `src/signals/adoption.ts` | New — one `v3alpha` dependents call for the governing bump, record-only |
| `src/risk.ts` | Seventh signal in `RiskSignals` and the worst-of comparison |
| `src/render.ts` | Seventh table row; "of 7" |
| `src/ledger.ts` | `adoption`, raw provenance fields |
| `policy-rules.yaml` + validator | `cooldown` object replaces `cooldownDays` |

`publish-age.ts` currently returns only a timestamp per package. It grows to return the whole
version record so two signals can read one fetch — the alternative is fetching the same URL twice
per package.

## Error handling

| Condition | Behaviour |
|---|---|
| deps.dev v3 unavailable | `publishAge` and `targetVersionHealth` both `unknown`; grade computed from the rest |
| `advisoryKeys` absent from the response | Treated as unknown for that package, not as "no advisories" |
| deps.dev v3alpha unavailable or reshaped | `adoption` recorded null; nothing else affected |
| A package's version is unparseable | That package contributes nothing; others still count |

The distinction in row two is load-bearing: an absent field and an empty array mean different things,
and reading a missing `advisoryKeys` as "clean" would reproduce exactly the A1 inversion Spec E
exists to fix.

## Testing

- **Tiered cooldown** — a major inside 7 days but outside 3 grades `medium`; the same age as a patch
  grades `low`; the tier is taken from each bump's own level, proven with a mixed-level fixture.
- **Sub-day** — 23 hours grades `high`, 25 hours `medium` at a 3-day cooldown, asserted against an
  injected clock rather than wall time.
- **Target health** — the real `lodash@4.17.20` fixture with five advisories grades `high`; a
  deprecated-but-unadvised version grades `medium`; a clean version `low`; a response missing
  `advisoryKeys` grades `unknown`, never `low`.
- **Reducer interaction** — a sub-day release closing a CVE stays `high`, proving Spec E's floor
  holds against the new `high`.
- **Adoption** — one call for the governing bump only, asserted by call count; a 404 or reshaped
  response records null without failing the evaluation.
- **Regression** — PR #27 still a candidate; its risk grade may legitimately move, and the test
  records the expected new value rather than asserting it is unchanged.

## Out of scope

- **Provenance regression grading** — see open decision 1.
- **Socket-class behavioural diffs** (install scripts, network/fs access, ownership churn) — vendor
  territory, as the review says. Note it in the build-vs-buy discussion.
- **Ecosystems other than npm.** deps.dev covers more, but every enrolled repo is npm today.
- **Acting on any grade.** Shadow mode unchanged.

## Definition of done

- [ ] `cooldown` is per-semver-tier and validated at build time; `cooldownDays` is gone
- [ ] Each bump is measured against its own level's threshold
- [ ] A release under 24 hours old grades `high`
- [ ] `targetVersionHealth` grades advisories `high` and deprecation `medium`, from the existing call
- [ ] A response missing `advisoryKeys` grades `unknown`, never `low`
- [ ] Provenance and attestation fields are recorded raw on the eval record
- [ ] `adoption` is one call for the governing bump, record-only, null-safe against the alpha endpoint
- [ ] Renderings say "of 7"; the ledger's `signalsGraded` matches
- [ ] A sub-day release closing a CVE still grades `high`
- [ ] Both checks remain `neutral` and on no required-checks configuration
