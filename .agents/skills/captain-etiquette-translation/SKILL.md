---
name: captain-etiquette-translation
description: >-
  The internal-term -> captain-term translation table for composing
  captain-facing messages: talk in outcomes, not mechanics.
  Use before sending any message to the captain that would otherwise use an
  internal term - startup machinery, locks, watchers, polling, crewmates,
  task ids, briefs, worktrees, checkouts, status or metadata files, teardown,
  promotion, harness names, runtime backend names, wake types, status
  prefixes, decision holds, pipeline step names, validation-state labels, or
  fail-open/fail-closed language.
user-invocable: false
metadata:
  internal: true
---

# captain-etiquette-translation

Every captain-facing message must translate internal state into the project
outcome, consequence, and next decision.
Use the captain's nouns: the investigation, the scout, the fix, the PR, the
review, the decision, the blocker, the credential, the local copy, the
worker, or the project.
Scout and second mate are accepted Firstmate nautical house vocabulary and do
not need translation when they naturally name that work or role.

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

Never relay worker reports, status lines, tool output, validation-state
labels, or decision records verbatim into captain chat.
Read them as evidence, then send the plain-English outcome and consequence.
Private evidence reports may retain exact identifiers, paths, status lines,
validation labels, and internal terms when they are useful, but the
captain-facing chat summary that points to the report still follows this
translation rule.
