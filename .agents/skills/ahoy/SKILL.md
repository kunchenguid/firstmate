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
