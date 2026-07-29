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
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning/tie safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`quota-axi` remains data-only and never recommends a route.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.

## Collect facts

Run `quota-axi --json` once per intake and reuse that snapshot for every candidate.
For each candidate, preserve its explicit `harness`, `model`, and `provider` tuple and record only the following inspectable facts; `harness-adapters` owns identity, and the model or provider never determines the harness:

- task/profile fit and required reasoning class
- raw applicable headroom (`effectivePercentRemaining` or the tightest applicable remaining percentage)
- effective pace status, signed reserve per applicable window, and worst applicable reserve (`worstReservePercentPoints` when present, else the minimum signed reserve)
- whether any applicable window or effective summary is ahead of reset, or any applicable pace is `unknown`
- schema note when pace fields are absent

Stale raw windows are diagnostic only, never current headroom.
Read every bounding window named by `boundedBy`, `limitingWindowIds`, `aheadWindowIds`, `behindWindowIds`, `onPaceWindowIds`, and `unknownWindowIds`.

## Pace semantics

`reservePercentPoints = percentRemaining - timeRemainingPercent`.
Negative reserve means usage is ahead of reset pace and creates conservation pressure.
Positive reserve means usage is behind reset pace.
`on_pace` is neutral.
Conservation pressure is present when effective pace status is `ahead`, effective pace status is `mixed` and any `aheadWindowIds` remain, or any applicable bounding window itself has pace status `ahead`.
`unknown` is valid explicit uncertainty from quota-axi, not a parser failure and not permission to assume the window is healthy or exhausted.

## Selection order

Apply only among candidates that already satisfy required fit and the strongest reasoning class the request needs.
Never use pace or raw headroom to silently replace that reasoning class.

1. Unresolved relationship or quota data: stop and report the candidate.
2. All-tight: keep the strongest-reasoning class; dispatch inside it or stop and report that the tight choice cannot proceed.
3. When fit and reasoning are comparable, prefer a candidate without ahead-of-reset conservation pressure over one with conservation pressure, even when the pressured candidate has somewhat higher raw remaining percentage.
4. Among pressured candidates, prefer the least-negative worst applicable reserve.
5. Among sustainable candidates, use known behind/on-pace evidence plus raw headroom transparently.
   Prefer known sustainable evidence over `unknown` pace when otherwise comparable.
   Do not collapse those facts into an opaque composite score.
6. If the dispatch choice materially hinges on unresolved pace, report the uncertainty rather than inventing a conclusion.
7. Absent pace or older schema: do not crash, fabricate pace, or silently reinterpret absence as healthy/`on_pace`.
   Compare raw applicable headroom only, state that pace is unavailable, and keep every other safety rule.
8. Genuine ties: stop and report every tied candidate for captain choice.
   Do not select by array order, harness name, or another arbitrary identity ordering.
   Report duplicate concrete profiles as a configuration error.

Name the inspectable facts used for every candidate.
After selecting a candidate, check authentication only through that tuple's authentication surface; another harness CLI cannot block it.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label.
