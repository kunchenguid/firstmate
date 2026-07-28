---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array from current quota-axi output, including quota-window pace signals.
  Load when a dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the pace-aware profile-array selection procedure.
The concise always-loaded intake boundary remains in `AGENTS.md` section 4.
`docs/configuration.md` owns the `config/crew-dispatch.json` schema only.
`quota-axi` remains data-only and never recommends a route.
Firstmate owns the judgment.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.

## When to load

Load this skill whenever a matched dispatch rule or the configured default resolves to a profile array (more than one candidate), before choosing the concrete `--harness`, `--model`, and `--effort` passed to `fm-spawn`.
Keep using `harness-adapters` for harness verification, model/provider discovery, and effort fallback.

## Intake boundary this skill does not relax

1. Explicit per-task captain overrides still win over configured profiles.
2. Configured profile matching precedence is unchanged: best-fit rule, then configured default, then static crewmate harness.
3. Malformed `config/crew-dispatch.json` remains an actionable error; never select around it.
4. Every configured candidate in the matched array must be accounted for.
5. If any harness/model/provider relationship, applicable quota data, or interpretation cannot be established, stop and report that candidate instead of omitting it, guessing, falling back, or calling the result quota-informed.
6. When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it solely to conserve quota; stop and report the tight choice if that class cannot proceed.
7. Genuine ties must remain free of array-order or harness bias.

## Collect inspectable facts for every candidate

For each candidate profile:

1. Establish the harness/model/provider relationship from current authoritative discovery owned by `harness-adapters`.
   Fail loudly on an unresolved relationship.
2. Run `quota-axi --json` once per intake and reuse that snapshot for every candidate.
3. Read the applicable effective-availability record for that candidate's provider and model scope.
4. Read every bounding window relevant to that candidate, including windows named by `boundedBy`, `limitingWindowIds`, and any pace window-id lists on the effective record.
5. Record these inspectable facts, never a hidden score:
   - task/profile fit
   - reasoning class required by the captain request or task ambiguity
   - raw applicable headroom (`effectivePercentRemaining` or the tightest applicable remaining percentage)
   - effective pace status when present
   - signed reserve for each applicable window and the effective worst reserve when present
   - whether any applicable window or effective summary is ahead of reset
   - whether any applicable pace is `unknown`
   - schema compatibility note when pace fields are absent

## Pace signals

quota-axi `schemaVersion` 3 window pace uses:

- `reservePercentPoints = percentRemaining - timeRemainingPercent`
- Negative reserve means usage is ahead of reset pace and creates conservation pressure.
- Positive reserve means usage is behind reset pace.
- `on_pace` is neutral.

Effective-availability pace summaries may report `ahead`, `behind`, `on_pace`, `mixed`, or `unknown`.

Treat conservation pressure as present when:

- effective pace status is `ahead`, or
- effective pace status is `mixed` and any `aheadWindowIds` remain, or
- any applicable bounding window itself has pace status `ahead`.

An effective `mixed` result is never healthy merely because one window is behind.
Any remaining `aheadWindowIds` keep conservation pressure.

Signed reserve comparison uses the worst applicable reserve, preferring the producer field `worstReservePercentPoints` when present and otherwise the minimum signed reserve across applicable bounding windows.

## Selection procedure

Apply these steps only among candidates that already satisfy required task/profile fit and the strongest reasoning class the request genuinely needs.
Never use pace or raw headroom to silently replace that reasoning class with a weaker one.

1. **Unresolved relationship or quota data**
   Stop and report the blocked candidate.
2. **Strongest-reasoning / all-tight**
   If every remaining candidate is tight, keep the strongest-reasoning class and either dispatch inside that class or stop and report that the tight choice cannot proceed.
   Do not conserve quota through an unapproved downgrade.
3. **Conservation pressure vs sustainable pace**
   When fit and reasoning class are comparable, prefer a candidate without ahead-of-reset conservation pressure over one with conservation pressure, even when the pressured candidate has somewhat higher raw remaining percentage.
4. **Among pressured candidates**
   Prefer the least-negative worst applicable reserve.
   Example: worst reserve `-4` is safer than `-18` when other inspectable facts are comparable.
5. **Among sustainable candidates**
   Use known behind/on-pace evidence plus raw headroom transparently.
   Do not collapse those facts into an opaque composite score.
   Prefer known sustainable evidence over `unknown` pace when otherwise comparable.
   Between known sustainable candidates, prefer the clearly better inspectable pair of pace reserve and raw headroom; state both facts in the choice rationale.
6. **Unknown pace**
   `unknown` is valid explicit uncertainty from quota-axi, not a parser failure and not permission to assume the window is healthy or exhausted.
   Prefer known sustainable evidence when otherwise comparable.
   If the dispatch choice materially hinges on unresolved pace, report the uncertainty rather than inventing a conclusion.
7. **Absent pace / older schema**
   `schemaVersion` 2 payloads or missing pace fields must degrade explicitly and safely.
   Do not crash, fabricate pace, or silently reinterpret absence as healthy/`on_pace`.
   Compare raw applicable headroom only, state that pace is unavailable, and keep every other safety rule above.
8. **Genuine ties**
   If every inspectable selection fact is equal, stop and report every tied candidate for captain choice.
   Do not select by array order, harness name, or another arbitrary identity ordering.
   Report duplicate concrete profiles as a configuration error.

The intake rationale must name the inspectable facts used for every candidate.
Never conclude with an unexplained "best quota" label.

## Acceptance scenarios

These scenarios are normative examples of the procedure above.

### Higher raw quota but materially ahead vs lower raw quota on/behind pace

Candidate A has higher `effectivePercentRemaining` but conservation pressure from an ahead bounding window.
Candidate B has lower raw headroom, no conservation pressure, and known behind or on-pace evidence.
Choose B when fit and reasoning class are comparable.

### Mixed effective pace with an ahead bound

Effective pace status is `mixed` and `aheadWindowIds` is non-empty.
Treat the candidate as conservation-pressured even if another window is behind or on pace.

### Both candidates ahead with different worst reserves

Both candidates have conservation pressure.
Choose the least-negative worst applicable reserve when fit and reasoning class are comparable.

### Known sustainable versus unknown

Candidate A has known behind or on-pace evidence.
Candidate B has comparable fit, reasoning class, and raw headroom but `unknown` pace.
Prefer A.
If the only way to prefer one side depends on unresolved pace and no known sustainable candidate remains, report the uncertainty.

### Every candidate tight while strongest-reasoning applies

All candidates are tight on real headroom.
Keep the strongest reasoning class required by the request.
Do not pick a weaker class only to save quota.
Dispatch inside that class or stop and report that the tight strongest-class choice cannot proceed.

### Genuine tie without array-order or harness bias

Two candidates match on fit, reasoning class, conservation pressure, worst reserve, pace class, raw headroom, and unknown flags.
Choosing either array order or a standing harness preference is forbidden.
Stop and report both tied candidates for captain choice.

### schemaVersion 2 or absent-pace compatibility

Older quota-axi output or missing pace fields still allow array resolution.
Compare raw headroom only, state that pace is unavailable, and do not invent ahead/behind/on_pace.

## Sanitized producer shape

Validate consumers against a sanitized `schemaVersion` 3 shape derived from quota-axi 0.1.15 or newer:

- top level: `schemaVersion`, `generatedAt`, `providers[]`
- each provider: `provider`, `windows[]`, `quotaSemantics.effectiveAvailability[]`
- each window may carry `percentRemaining` and `pace` with `status`, optional `timeRemainingPercent`, optional `reservePercentPoints`
- each effective-availability entry may carry `effectivePercentRemaining`, `boundedBy`, `limitingWindowIds`, and `pace` with `status`, optional `aheadWindowIds`, optional `behindWindowIds`, optional `worstReservePercentPoints`, optional `worstReserveWindowId`

Never persist live provider balances, reset timestamps, account identifiers, or other private account details in tracked fixtures.
