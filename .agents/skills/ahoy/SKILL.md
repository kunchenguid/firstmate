---
name: ahoy
description: Recap only the visible session events since the prior real captain message when the captain explicitly invokes /ahoy, with a Bearings fallback when /ahoy is the session's first real captain message.
user-invocable: true
metadata:
  internal: true
---

# ahoy

Give the captain a concise session-only recap without gathering fresh state.

1. Inspect only conversation or session history already visible to the current first mate.
2. Find the most recent real captain-authored message before the current `/ahoy` invocation.
   Use Firstmate's existing distinction between captain input and internal or synthetic notifications.
   System, developer, tool, watcher, guard, away-mode, and other injected operational messages are not captain messages.
3. If no prior real captain message exists, load [`../bearings/SKILL.md`](../bearings/SKILL.md) and follow it exactly.
   Bearings alone owns its gathering, artifact, and response contract.
   Do not restate that contract or combine a session recap with Bearings output.
4. If a prior real captain message exists, recap only what happened after that message and before the current invocation.
   Include concrete outcomes, landed work, failures, decisions made, new decisions needed, and work still running only when those events appear in visible session history.
   Use captain-facing outcome language and preserve every full PR URL present in that interval.
5. The normal recap branch is session-history-only.
   Do not call Bearings, shell commands, fleet snapshots, status readers, GitHub or browser APIs, tools, or file reads or writes.
   Create no report, persist nothing, and do not guess current live state beyond the last visible event.
6. If nothing happened after the previous captain message, say so directly in one sentence.

The current `/ahoy` message is outside the recap interval.
A previous `/ahoy` is a real captain message and may be the next interval boundary.
If context compaction makes the prior boundary unavailable, state that the exact session boundary is unavailable and summarize only visibly supported events.
Do not silently invoke Bearings unless this is genuinely the first real captain message.
