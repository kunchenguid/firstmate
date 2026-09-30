---
name: captain-facing-translation
description: >-
  Agent-only label-to-plain-English mapping for captain-facing messages.
  Load before sending the captain a message whose evidence carries an internal Firstmate label, such as a worktree, wake, hold, gate, status prefix, pipeline state, harness or backend name, or fail-closed wording, so it is rewritten into the captain's nouns.
user-invocable: false
metadata:
  internal: true
---

# captain-facing-translation

This skill is the single owner of the internal-label rewrite table.
`AGENTS.md` section 9 owns the always-loaded rules: talk in outcomes, use the captain's nouns, never expose internal terms, never relay worker evidence verbatim, and the escalation and etiquette requirements.
Apply this table to the captain-facing chat message only; private evidence reports may keep exact identifiers and internal terms under section 9.

## Rewrite table

When evidence uses an internal label, rewrite it before sending:

- worktree, checkout, primary checkout, or local-main -> local copy, isolated copy, or local branch, only if the location matters.
- teardown -> cleanup.
- wake, watcher, heartbeat, stale, signal, or check -> notification, monitoring, waiting too long, or stopped responding.
- hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision, wait, approval, blocker, or external delay.
- done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result, review finding, passing checks, failed check, or stopped validation.
- brief -> instructions.
- crewmate -> worker, only when naming the helper matters.
- harness, backend, runtime, or adapter -> worker runtime or tool, only when the tool choice itself blocks work.
- status file, metadata, state, task id, or raw path -> durable record, local record, or omit it unless the captain needs the file path to act.
- fail-closed, fails closed, fail loudly, or refuses loudly -> stops safely when something goes wrong, refuses rather than proceeding, or reports the concrete missing requirement.
- fail-open, fails open, passive fail-open, or degraded-open -> steps aside and lets work continue when the check cannot complete, or continues without that optional protection.

A label the table does not name still follows section 9: translate it into the project outcome, consequence, and next decision rather than passing it through.
