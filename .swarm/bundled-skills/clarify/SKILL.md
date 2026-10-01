---
name: clarify
audience: swarm-plugin
description: >
  Full execution protocol for MODE: CLARIFY -- structured clarification funnel with critic review before surfacing user decisions.
---

# Clarify Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

### MODE: CLARIFY
Ambiguous request → Run the clarification funnel
Clear request → MODE: DISCOVER

### Clarification Funnel

Before surfacing any clarification question to the user, the architect MUST run this four-stage funnel. The goal is to limit unnecessary user interruption, not planning completeness.

#### Stage 1: Inventory All Material Uncertainties

Identify ALL uncertainties that could affect:
- Scope boundaries
- User-visible behavior
- Destructive behavior or data loss
- Security/privacy posture
- Backward compatibility
- Migrations or rollout strategy
- Cost/performance tradeoffs
- Operational complexity
- QA gate selection or enforcement strictness
- Architecture choice among materially different paths
- Dependency or platform assumptions

There is NO hard cap on the internal inventory. Record every material uncertainty found.

#### Stage 2: Classify Each Uncertainty

Classify each item as exactly one of:
- `self_resolved`: answered from the user request, spec, plan, codebase reality check, `.swarm/context.md`, repo conventions, or an informed default. **If the default is not directly supported by user request, spec, or recorded context, classify as `user_decision` rather than `self_resolved`.**
- `critic_resolved`: sent to Critic Sounding Board and resolved by the critic.
- `research_needed`: needs SME/explorer/domain lookup before user escalation. **Important:** If research is ongoing, apply a fixed 5-minute protocol budget to `research_needed`. If research does not complete before the budget expires, automatically reclassify the item to `user_decision` with a note that research was incomplete, then surface it to the user. This prevents the clarification funnel from stalling while waiting for external research.
- `user_decision`: only the user can decide because it affects product scope, risk tolerance, policy, budget, UX, rollout, or destructive behavior.
- `deferred_nonblocking`: useful follow-up detail that does not block a correct initial plan and can be explicitly recorded as an assumption or follow-up.

#### Stage 3: Consult Critic Sounding Board

Before asking the user any clarification question, the architect MUST consult `critic_sounding_board` with the candidate question set and context.

For each item classified as `research_needed` or `user_decision` in Stage 2, send it to the critic. The critic responds with a verdict from the `SoundingBoardVerdict` enum (`UNNECESSARY | RESOLVE | REPHRASE | APPROVED`). The mapping between critic verdicts and funnel actions is:

| Critic Verdict (SoundingBoardVerdict) | Funnel Action | Meaning |
|---|---|---|
| `UNNECESSARY` | DROP | Item is unnecessary or answerable from existing context |
| `RESOLVE` | RESOLVE | Critic supplies the answer or recommended default |
| `REPHRASE` | REPHRASE | Question is valid but should be clearer, narrower, or grouped |
| `APPROVED` | ASK_USER | User decision is genuinely required |

**Hard constraint:** Items in the Always-Surface Categories list (below) MUST NOT receive `UNNECESSARY`/`DROP` from the critic — only `REPHRASE` or `APPROVED`/`ASK_USER` are allowed. If the critic attempts to `UNNECESSARY`/`DROP` an always-surface item, override to `APPROVED`/`ASK_USER`.

**Overconfidence guard:** If the critic attempts to self-resolve an item by supplying an answer (verdict `RESOLVE`) but the underlying default is not directly supported by user request, spec, or recorded context, the architect MUST classify the item as `user_decision` rather than `self_resolved`. Unsupported defaults must not be silently accepted.

Update classifications based on critic response:
- `UNNECESSARY`/`DROP` → reclassify as `self_resolved` and record the reason.
- `RESOLVE` → reclassify as `critic_resolved` and record the answer as an assumption.
- `REPHRASE` → update the question wording and keep as candidate.
- `APPROVED`/`ASK_USER` → confirm as `user_decision`.

Record all resolved items as explicit assumptions before proceeding.

#### Stage 4: Surface User Decision Packet

If any items remain classified as `user_decision` after Stage 3, present them as a structured decision packet — NOT as an arbitrary subset.

The packet MUST include for each decision:
- Category grouping (scope, security, compatibility, performance, UX, rollout, QA policy)
- Why the decision matters
- Recommended default when safe
- Options being weighed
- Impact of accepting the default
- Blocking vs optional marker

The architect MAY ask questions one at a time in interactive mode, but MUST preserve and report the full unresolved list. The architect MUST NOT drop unresolved decisions because of a session question cap.

### Always-Surface Categories

The critic may improve wording or confirm prior context, but these categories MUST be surfaced to the user unless already explicitly answered by the user or by recorded context:
- Scope boundaries: what is in or out
- Data loss or destructive behavior
- Security/privacy risk tolerance
- Backward compatibility or migration policy
- Breaking changes to existing APIs, contracts, or interfaces
- New dependency additions or version changes
- Deprecation decisions for existing features or APIs
- Cross-platform impact (Windows/macOS/Linux differences)
- Cost/performance tradeoffs
- User-visible behavior and UX choices
- Release/rollout strategy
- Optional QA gates or stricter enforcement modes
- Any choice that changes whether the work is advisory vs hard-blocking

### Assumptions Recording

All items resolved in Stages 2-3 (self_resolved, critic_resolved, deferred_nonblocking) MUST be recorded as explicit assumptions in the spec, plan, or `.swarm/context.md`. Silently dropping resolved uncertainties is a protocol violation — every uncertainty that entered the funnel must have a recorded outcome.

### Mechanical Enforcement of DROP Protection

**Implementation Note:** The hard constraint against `DROP` on always-surface items (defined in Stage 3 of the clarification funnel) is currently enforced via skill instructions to the architect. A lightweight runtime enforcement mechanism is recommended: when the critic sounding board verdict response is parsed, validate that any items tagged as "always-surface" do not receive `UNNECESSARY`/`DROP` verdicts. If a DROP verdict is encountered on an always-surface item, override it to `APPROVED`/`ASK_USER` at the code level rather than relying solely on prompt-based enforcement.

This mechanical enforcement prevents the following failure mode: the architect prompt instructs the override, but due to parsing errors, context limits, or model behavior variance, the DROP verdict is mistakenly applied to an always-surface item and silently accepted. The validation should occur in the decision-packet assembly code (when building the final clarification packet to surface to the user) and should emit a warning log when an override is applied. This is tracked as future work in a follow-up issue; until then, enforcement relies on the skill instructions.
