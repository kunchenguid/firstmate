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
For each candidate, preserve explicit `harness`, `model`, and `provider`; `harness-adapters` owns identity, and model/provider never infer harness:

- task/profile fit and required reasoning class
- raw applicable headroom (`effectivePercentRemaining` or tightest applicable percentage)
- effective pace, signed reserve per window, and worst reserve (`worstReservePercentPoints` or minimum signed reserve)
- whether applicable windows/summary are ahead, or pace is `unknown`
- schema note when pace fields are absent

Stale raw windows are diagnostic, never headroom.
Grok's `credits.remaining` is a prepaid balance unrelated to `percentRemaining`; never read it as exhaustion.
Read all windows named by `boundedBy`, `limitingWindowIds`, `aheadWindowIds`, `behindWindowIds`, `onPaceWindowIds`, and `unknownWindowIds`.

## Authentication is scoped to the selected surface

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it.
`bin/fm-auth-preflight.sh` owns surface resolution, the captain-approved bounded preflight, exactly one post-preflight quota retry for every resolved candidate, and sanitized output; its `--help` owns flags and mechanics.
Run it per candidate instead of resolving a surface by hand or launching a vendor CLI yourself.
Read its verdict as facts, not as a route: `eligible=no` means drop that candidate and state the omission with its reason, and only an array with no eligible candidate left reaches the captain.
`authStatus=usable` with `headroom=unknown` means authentication is fine and headroom is unmeasured, never a credential or login problem.
`authStatus=unknown` with `reason=no-auth-evidence` means a verified harness/model relationship has no quota-axi authentication surface; keep it eligible with unknown auth and headroom, do not launch another harness's CLI, and prefer known sustainable evidence when comparable.
`authStatus=expired` is a short-lived session token the owning vendor renews on next use, not a sign-out.
Reserve login wording for `authStatus=unusable` or a failed preflight.

## Pace semantics

`reservePercentPoints = percentRemaining - timeRemainingPercent`.
Negative reserve means usage is ahead of reset pace and creates conservation pressure.
Positive reserve means usage is behind reset pace.
`on_pace` is neutral.
Conservation pressure is present for effective pace status `ahead`, effective pace status is `mixed` and any `aheadWindowIds` remain, or a bounding window is `ahead`.
`unknown` is valid explicit uncertainty from quota-axi, not parser failure or permission to assume health.

## Selection order

Apply only among candidates satisfying required fit and strongest reasoning class.
Never use pace or raw headroom to silently replace that reasoning class.

1. Unresolved relationship, unresolved authentication, or malformed configuration: stop and report the tuple and concrete evidence.
   Unmeasurable quota alone is not unresolved and never triggers this rule.
2. All-tight: keep strongest reasoning; dispatch inside it or report if blocked.
3. Comparable fit/reasoning: prefer no ahead pressure over pressure, even with higher raw headroom.
4. Among pressured candidates, prefer the least-negative worst applicable reserve.
5. Sustainable candidates: use known pace plus raw headroom.
   Prefer known sustainable evidence over `unknown` when comparable.
   An authenticated candidate whose headroom is unmeasurable stays eligible at lower preference; disclose that unmeasured headroom in the dispatch record.
   Do not collapse those facts into an opaque composite score.
6. If unresolved pace changes the choice, report uncertainty.
7. Absent pace or older schema: do not crash, fabricate pace, or treat absence as healthy/`on_pace`.
   Compare raw headroom only, state pace is unavailable, and keep safety rules.
8. Genuine ties: stop and report every tied candidate for captain choice.
   Do not select by array order, harness name, or another arbitrary identity ordering.
   Report duplicate concrete profiles as a configuration error.

Name the inspectable facts used for every candidate.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label.
