---
name: ahoy
description: Recap visible session events and guide the user through visibly unanswered decisions when the user explicitly invokes /ahoy, with a Bearings fallback when /ahoy is the session's first real user message.
user-invocable: true
metadata:
  internal: true
---

# ahoy

Give the user a concise session-only recap without gathering fresh state.

0. Before anything else, check whether this session has already taken the helm: a `SESSION START` digest for this home must be visible in the session history.
   If it is not, run `bin/fm-session-start.sh` once and read its digest before producing any recap.
   Run-tier harness surfaces run it automatically at session open, so this step is normally already satisfied and costs one glance; it is the safety net for surfaces that cannot run it on a hook, and for any path where a skill would otherwise act first.
   Session startup always precedes this skill's own logic, and the digest it produces is operational input, never a user message or a recap event.

1. Inspect only conversation or session history already visible to the current Director.
2. Find the most recent real user-authored message before the current `/ahoy` invocation.
   A user boundary is an ordinary user-role message unless it matches one of the narrow operational exclusions below.
   Exclude messages that begin with the current U+2063 `FIRSTMATE_OP:` injection prefix.
   Exclude legacy bare-marker away-mode injections only when U+2063 is immediately followed by `Supervisor escalate (`.
   Exclude a message that is exactly a record-backed operational doorbell that `bin/fm-operational-input.sh doorbell-kind` recognizes from its stdin; Claude Code, which strips U+2063, receives away-mode escalations this way.
   Exclude only the exact, verbatim legacy unmarked session-start payload ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.``; quoted, prefixed, or otherwise modified variants are ordinary user messages.
   Custom-role messages such as Pi's `firstmate-sessionstart-nudge` are not user messages.
   System, developer, tool, watcher, guard, away-mode, and other injected operational messages are not user messages.
   Never infer user authorship merely because a synthetic message appears in the user-role transcript.
   Do not exclude an ordinary user message merely because it begins with U+2063 followed by other text, contains ASCII `FIRSTMATE_OP:` without a leading U+2063, quotes or embeds a current operational message after ordinary user text, quotes or mentions the legacy session-start payload, or adds any text to that payload.
   Apply the current exclusion only when U+2063 `FIRSTMATE_OP:` begins at the first character of the whole message: `Captain quote: ` followed by that current prefix is a user boundary.
   The legacy session-start exclusion applies only to the verbatim payload above; for example, ``user quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` is a user boundary.
3. If no prior real user message exists, load [`../bearings/SKILL.md`](../bearings/SKILL.md) and follow it exactly.
   Bearings alone owns its gathering, artifact, and response contract.
   Do not restate that contract or combine a session recap with Bearings output.
4. If a prior real user message exists, preserve the ordinary recap interval: recap what happened after that message and before the current invocation.
   Include concrete outcomes, landed work, failures, decisions made, new decisions needed, and work still running only when those events appear in that visible interval.
   Use user-facing outcome language and preserve every full PR URL present in that interval.
5. Additionally inspect the entire session history visible to the current Director before the current invocation for every explicit user decision that remains unanswered, including decisions raised before the ordinary recap boundary.
   A later unrelated user message establishes a recap boundary but does not close an earlier decision.
   Treat a decision as closed only when a later visible response substantively resolves it, chooses an option, declines it, grants or denies the requested approval, or otherwise directly addresses that decision.
   Include every visibly supported open decision once, and deduplicate by the decision's substance when the ordinary interval recap already represents it or its wording differs.
6. The normal recap branch is session-history-only, apart from the step 0 helm check.
   Do not call Bearings, shell commands, team snapshots, status readers, GitHub or browser APIs, tools, or file reads or writes.
   Create no report, persist nothing, and do not guess current live state beyond the last visible event.
7. If no ordinary events occurred after the previous user message but an older visibly open decision exists, report that decision instead of claiming nothing happened.
   If neither ordinary events nor visibly open decisions exist, say directly in one sentence that nothing happened after the previous user message.

8. After the normal recap, when the existing visibly open decision inventory contains decisions, begin a guided decision-clearing flow by presenting only the single open decision judged most impactful by the Director.
   Say the ordering is the Director's pick.
   Give enough escalation-quality context to decide easily: the decision, why it matters, the options, and a recommendation.
9. When the user answers the presented decision, present the next highest-impact decision from that existing inventory in the same form.
   Continue one decision at a time until none remain, without starting this flow when the inventory is empty.

The current `/ahoy` message is outside the recap interval.
A previous `/ahoy` is a real user message and may be the next interval boundary.
If context compaction makes the prior boundary unavailable, state that the exact session boundary is unavailable and summarize only visibly supported events.
Compacted history supports an open decision only when both its request and its still-unanswered status are visible; report uncertainty instead of reconstructing hidden requests or answers.
Do not silently invoke Bearings unless this is genuinely the first real user message.
