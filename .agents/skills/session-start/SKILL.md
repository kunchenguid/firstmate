---
name: session-start
description: >-
  Load at every session start after `bin/fm-session-start.sh`.
user-invocable: false
metadata:
  internal: true
---

# session-start

`AGENTS.md` section 3 keeps the lock-refused read-only boundary and this load trigger.
Run `bin/fm-session-start.sh` exactly once at session start before loading this skill.
Its header owns composed commands, ordering, and digest contents.
Do not reimplement it by separately running its lock, bootstrap, initial wake-drain, or deferred-network components.
Run-tier harness surfaces run this command at session open while the rest only nudge it; `docs/sessionstart-nudge.md` owns adapter tiers, source routing, and compatibility.

## Digest

Read the complete digest once and trust it as this turn's startup and recovery input.
If the harness shows only a preview and persists the full output to a file, read that file before acting.
Do not separately re-read the context, backlog, metadata, or bulk status inputs it just printed unless a source was reported absent or corrupt, older history is specifically needed, or a targeted workflow must inspect before writing.
An `ABSENT` captain, shared-captain, secondmate, or learnings file means the firstmate repo's built-in defaults, no shared captain preferences, no registered secondmates, or no captured learnings; rebuild an absent or stale project registry from the clones before dispatch.

The digest itself makes no external-network call.
Treat none of the deferred network checks as passed until `bin/fm-startup-network.sh report` returns the finished result; a failed or otherwise actionable result also arrives as a `check: startup-network` wake.

## Bootstrap and tools

Bootstrap detects first, asks for consent, and installs only after the captain approves in the current session.
Do not dispatch until the essential launch tools are present and GitHub authentication is good; presentation availability follows `bootstrap-diagnostics` and does not block nonvisual work.
Use `gh-axi` for GitHub, `chrome-devtools-axi` for browser work, and compatible `lavish-axi` for visual decisions or reports; consult current help rather than memorizing flags.
A silent bootstrap section needs no action; for any printed actionable diagnostic line, load `bootstrap-diagnostics` and follow its owner procedure.
`BOOTSTRAP_INFO:` lines are completed no-action facts and do not require loading a skill.
A restart must be a non-event because durable state and live backend inventory, not conversation memory, are authoritative.
