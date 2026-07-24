---
name: ahoy
description: Recap visible session events since the prior real captain message plus visibly unanswered captain decisions when the captain explicitly invokes /ahoy, with a Bearings fallback when /ahoy is the session's first real captain message.
user-invocable: true
metadata:
  internal: true
---

# ahoy

Give the captain a concise session-only recap without gathering fresh state.

1. Inspect only conversation or session history already visible to the current first mate.
2. Find the most recent real captain-authored message before the current `/ahoy` invocation.
   A captain boundary is an ordinary user-role message unless it matches one of the narrow operational exclusions below.
   Exclude messages that begin with the current U+2063 `FIRSTMATE_OP:` injection prefix.
   Exclude legacy bare-marker away-mode injections only when U+2063 is immediately followed by `Supervisor escalate (`.
   Exclude the exact legacy unmarked session-start payload ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.``
   Custom-role messages such as Pi's `firstmate-sessionstart-nudge` are not captain messages.
   System, developer, tool, watcher, guard, away-mode, and other injected operational messages are not captain messages.
   Never infer captain authorship merely because a synthetic message appears in the user-role transcript.
   Do not exclude an ordinary captain message merely because it begins with U+2063 followed by other text, contains ASCII `FIRSTMATE_OP:` without a leading U+2063, quotes or embeds a current operational message after ordinary captain text, quotes or mentions the legacy session-start payload, or adds any text to that payload.
   Apply the current exclusion only when U+2063 `FIRSTMATE_OP:` begins at the first character of the whole message: `Captain quote: ` followed by that current prefix is a captain boundary.
   Apply the legacy startup exclusion as a literal whole-message match: ``Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` is a captain boundary.
3. If no prior real captain message exists, load [`../bearings/SKILL.md`](../bearings/SKILL.md) and follow it exactly.
   Bearings alone owns its gathering, artifact, and response contract.
   Do not restate that contract or combine a session recap with Bearings output.
4. If a prior real captain message exists, preserve the ordinary recap interval: recap what happened after that message and before the current invocation.
   Include concrete outcomes, landed work, failures, decisions made, new decisions needed, and work still running only when those events appear in that visible interval.
   Use captain-facing outcome language and preserve every full PR URL present in that interval.
5. Additionally inspect the entire session history visible to the current first mate before the current invocation for every explicit captain decision that remains unanswered, including decisions raised before the ordinary recap boundary.
   A later unrelated captain message establishes a recap boundary but does not close an earlier decision.
   Treat a decision as closed only when a later visible response substantively resolves it, chooses an option, declines it, grants or denies the requested approval, or otherwise directly addresses that decision.
   Include every visibly supported open decision once, and deduplicate by the decision's substance when the ordinary interval recap already represents it or its wording differs.
6. The normal recap branch is session-history-only.
   Do not call Bearings, shell commands, fleet snapshots, status readers, GitHub or browser APIs, tools, or file reads or writes.
   Create no report, persist nothing, and do not guess current live state beyond the last visible event.
7. If no ordinary events occurred after the previous captain message but an older visibly open decision exists, report that decision instead of claiming nothing happened.
   If neither ordinary events nor visibly open decisions exist, say directly in one sentence that nothing happened after the previous captain message.

The current `/ahoy` message is outside the recap interval.
A previous `/ahoy` is a real captain message and may be the next interval boundary.
If context compaction makes the prior boundary unavailable, state that the exact session boundary is unavailable and summarize only visibly supported events.
Compacted history supports an open decision only when both its request and its still-unanswered status are visible; report uncertainty instead of reconstructing hidden requests or answers.
Do not silently invoke Bearings unless this is genuinely the first real captain message.
