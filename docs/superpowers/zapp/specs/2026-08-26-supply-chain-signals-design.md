# Supply-chain signals

Design for the version-safety half of the
[policy-enhancement review](../../../../research/2026-08-26-zapp-policy-enhancement-review.md)
(2026-08-26): findings B1, B2 and B6.

Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec F**, the second of three. E fixes existing logic that fails open; G adds controls and
human override.

Status: drafted 2026-08-26; three open decisions resolved in review 2026-08-26 and folded in.

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

### Provenance regression — fetched and recorded, deliberately not graded

Detecting that a new version dropped the npm provenance its predecessor carried requires fetching the
**from** version too, doubling deps.dev calls from one per bump to two.

**That cost is affordable, and an earlier draft of this spec overstated it.** Twenty-two requests at
concurrency 8 is three waves; at a 3-second per-request ceiling that is ~9 seconds worst case, and
typically well under one second against 834-byte responses. The function's budget is 30 seconds and
it also makes four GitHub calls. It fits.

Worth being precise about what that budget is, because it is easy to assume otherwise: **GitHub
imposes no limit here.** Its 10-second webhook expectation applies to the *receiver*, and since
PLAT-1233 the worker sits behind SQS. The 30 seconds is our own choice in
`infrastructure/terraform/main.tf`, raisable to Lambda's 15-minute ceiling if work ever justifies it,
provided the queue's visibility timeout keeps its 6:1 ratio.

So the reason not to grade provenance regression is **not** cost. It is that nobody knows its
false-positive rate. Packages legitimately stop publishing provenance — tooling migrations,
maintainer changes, CI rewrites — and grading on it today would be guessing at a threshold rather
than deriving one.

Therefore: **fetch the from-version, record `provenanceLost` per bump, grade nothing.** Thirty days
of data answers the question the grade would otherwise have to assume. This is the same argument
Spec G makes for commit authorship.

## Recorded versus surfaced — the principle

This spec is the first to add a meaningful amount of data that is collected but never graded, so the
rule belongs here and the later specs reference it.

**Record everything cheap to collect. Surface only what changes a reader's action.**

Storage is nearly free and retroactive collection is impossible — a field not written today cannot be
recovered for the 200 evaluations the epic's exit criteria need. But a check run someone reads on
their own pull request is diluted by every value that does not help them decide something.

Three tiers result:

| Tier | Examples | Lives in |
|---|---|---|
| Graded and surfaced | the gates; the seven risk signals | check-run table + eval record |
| Recorded and surfaced | each signal's observed value, in the table's right column | check-run table + eval record |
| **Recorded only** | `provenanceLost`, `adoption`, and Spec G's commit authorship and merge window | eval record only |

Tier three has no read path today: it is visible only by querying `zapp-evaluations` directly, which
nobody will do casually. **Spec I brings the weekly shadow report forward to be that read path**,
which is why it is sequenced alongside this work rather than left at the end of the epic. Collecting
data with no one looking at it is how a broken recorder stays broken for six weeks.

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

**The alpha dependency is accepted, with one requirement: we must know when it breaks.** A shape
change or a withdrawn endpoint degrades `adoption` to null, which by itself is silent — and a field
that has been quietly null for six weeks is worse than one that was never collected, because it looks
like data.

So a failed or unparseable dependents response logs `adoption_unavailable` with the status and
package. That line is what the weekly report (Spec I) counts, so a persistent failure surfaces as a
number someone reads rather than as an absence nobody notices. It never fails a check run and never
affects a verdict.

## The seventh signal and the six-signal criterion

PLAT-1191's acceptance criterion says six signals. This makes seven, and every rendering that says
"graded on N of 6" becomes "of 7".

**The deviation is accepted deliberately: more signals is a better service.** The criterion
described the signals known when the ticket was written, and the review established a seventh from
evidence. Folding `targetVersionHealth` into `closesFinding` to preserve the number was considered
and rejected — one row would have to say two opposite things ("closes an advisory" and "introduces
one"), which is worse for the human reading it than a count that moved.

The ledger's `signalsGraded` moves with it, so any Phase 1 query comparing evaluations across the
change must key on `rulesSha` — which is exactly what `rulesSha` is for.

## Files

| File | Change |
|---|---|
| `src/signals/publish-age.ts` | Return the full deps.dev record, not just the timestamp; fetch the from-version too for provenance; tiered thresholds; sub-day `high` |
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

- **Grading on provenance regression** — recorded here, graded once the data shows its false-positive rate.
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
- [ ] The from-version is fetched and `provenanceLost` recorded per bump, grading nothing
- [ ] Provenance and attestation fields are recorded raw on the eval record
- [ ] A failed dependents lookup logs `adoption_unavailable` with status and package
- [ ] `adoption` is one call for the governing bump, record-only, null-safe against the alpha endpoint
- [ ] Renderings say "of 7"; the ledger's `signalsGraded` matches
- [ ] A sub-day release closing a CVE still grades `high`
- [ ] Both checks remain `neutral` and on no required-checks configuration
