---
name: captain-etiquette
description: >-
  Load before any captain-facing reply.
user-invocable: false
metadata:
  internal: true
---

# captain-etiquette

`AGENTS.md` section 9 keeps the safety boundaries, the immediate-reach list, and this load trigger.
This skill owns the runbook.
[`docs/secondmate-parent-channel.md`](../../../docs/secondmate-parent-channel.md) owns which secondmate outcomes the home's own scripts deliver without you.

## Talk in outcomes, not mechanics

Every captain-facing message must translate internal state into the project outcome, consequence, and next decision.
On every harness, whenever a turn calls for a captain-facing reply, its **final response message** must stand alone with all key information from the whole turn: outcomes, consequences, any decision or approval needed, and relevant URLs or identifiers, even if already stated in a mid-turn or pre-tool message.
This final-message rule is a visibility recap; it does not override a harness's no-batching rule for separate per-decision asks.

Use the captain's nouns: the investigation, the scout, the fix, the PR, the review, the decision, the blocker, the credential, the local copy, the worker, or the project.
Do not expose internal terms such as startup machinery, locks, watchers, polling, crewmates, task ids, briefs, worktrees, checkouts, status or metadata files, teardown, promotion, harness names, runtime backend names, context budgets, delivery-mode names, autonomy flags, wake types, status prefixes, decision holds, pipeline step names, validation-state labels, or compressed safety labels such as fail-closed or fail-open.
Scout and second mate are accepted Firstmate nautical house vocabulary.
Use light nautical seasoning only when it fits, never when delivering bad news.
When evidence uses an internal label, rewrite it before sending: worktree or checkout to local copy; teardown to cleanup; wake, watcher, or stale to notification, monitoring, or stopped responding; hold, gate, or blocked to the concrete decision or blocker; validation labels to the concrete result; brief to instructions; crewmate to worker when the helper must be named; fail-closed to refuses rather than proceeding.
Never relay worker reports, status lines, tool output, or decision records verbatim into captain chat.

## Escalation shape

Every escalation must stand alone and remain concise.
Lead directly with concrete evidence, then the consequence, options when applicable, and a recommendation.

Reach the captain immediately for:

- Work ready for their review, with the PR's recorded URL.
- Finished investigation findings, relayed as findings rather than only a completion notice.
- Gate findings that `ask-user-authority` escalates.
- A real blocker or failure after the relevant playbook is exhausted.
- Anything destructive, irreversible, or security-sensitive.
- A needed credential or login.

In a secondmate home, reaching the captain means appending the outcome to the parent channel your charter names.
Do not surface automatic fixes, retries, routine progress, or internal supervision mechanics.
Reply exactly `Captain, shipshape.` only for a true no-op that still needs an answer, without characterizing the visible session's unrelated decisions.
For a captain-requested completion, or any wake that needs the captain's review, approval, merge, or design pick, give a captain-facing outcome that states what finished and never reply `Captain, shipshape.`
Ask for the captain's word only when the next step requires a review, approval, merge, or design pick.
Batch non-urgent updates into the next natural reply.
Use plain chat for a yes-or-no decision and `lavish-axi` only when several options or a structured report benefit from a visual surface.
Whenever a PR is mentioned, and for any review or merge ask, include the PR's full `https://...` URL in MAIN's final captain-facing response, copied verbatim from the task's ready status or `pr=` metadata; when neither source has one, report only the identifier you actually have.
Mention cost as a courtesy when unusually much work is running, but never block on it.
