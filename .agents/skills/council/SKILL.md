---
name: council
description: >-
  Create and operate the thin persistent read-only model council when the captain invokes /council or naturally asks to create, question, accept, reject, rerun, retry, or close a council.
  Keeps exact Claude Fable and Codex GPT-5.6 Sol participant conversations across rounds, requires project-specific provider disclosure consent, and routes implementation to a separate ordinary task only after an explicit accept-and-implement instruction.
user-invocable: true
metadata:
  internal: true
---

# council

Use this skill for every captain request concerning a persistent model council.
Run `bin/fm-council.sh --help` before the first mutation in a session because that output owns exact commands, fields, phase transitions, storage, and safety mechanics.

## Captain-facing workflow

Translate natural language into one of six outcomes: create, ask, accept, accept and implement, reject or rerun, and close.
Use the captain's council name in chat and keep script identifiers out of captain-facing messages.

For create, require one name, one absolute local project path, and at least two exact profiles.
The MVP supports only `claude/claude-fable-5/xhigh` and `codex/gpt-5.6-sol/xhigh`, and an unsupported profile is a blocker rather than permission to substitute.
A new council always gets fresh participant conversations.
It receives the project's active accepted decisions by default, while an explicit clean-slate request maps to `--clean-slate` and omits them.
After create, load `harness-adapters`, inspect each fresh exact endpoint for its already-verified trust or bypass confirmation, handle only that dialog, and verify both participant interfaces are idle before the first ask.

Provider disclosure is security-sensitive and project-specific.
If the script names a missing provider consent, ask the captain whether the filtered project view may be sent to that provider for that exact project.
Run `provider-consent ... --acknowledge-project-disclosure` only after an explicit yes in the trusted conversation, and never infer consent from council creation or from consent for another project or provider.
Do not run a live council round merely to validate orchestration unless that project-specific consent already exists.

For ask, pass one complete task with all stated constraints.
One council must finish, reject, or retry its current round before another task begins, while unrelated councils may proceed independently.
After `ask`, use `wait` for the bounded collection wait, then `collect` available answers.
Name every unavailable profile honestly.
If exactly one answer is available, describe it as the only available answer and use `present --kind only`; never call it a winner.
With several answers, independently compare correctness, project grounding, safety, and feasibility, then freeze either the best answer or a short synthesis with `present --kind best|synthesis`.
Do not expose one participant's answer to another before collection.

`present` is the captain-visible canonical proposal.
On a plain acceptance, run `accept` and report the saved decision plus any participant whose delivery is deferred.
On “accept and implement”, run `accept-and-implement`, then follow its structured result by creating a separate ordinary Firstmate implementation task under the normal lifecycle.
Council participants never edit or implement the source project.

A rejection records no result.
Use `reject` to return the council to idle, or `rerun --clarify` to discard the result and immediately send a fresh independent round with the added constraint.
After Firstmate restarts during collection, use `recover` once and tell the captain the interrupted round needs explicit retry; use `retry` only when they request it or their original instruction already clearly authorizes retrying interrupted work.
Never respawn a participant merely because Firstmate restarted.

Close only on an explicit captain command.
Run `close` and, if it fails partway, rerun it: journal-confirmed members are skipped, while an endpoint-identity refusal remains a blocker requiring inspection, never permission to guess a pane or broaden cleanup.
Closing clears only that council's participant conversations and does not affect another council or create an implementation task.

## Outcome phrasing

After a result is presented, give the conclusion first, then one or two reasons, then unavailable profiles if any, and ask only whether to accept, accept and implement, reject, or rerun with a constraint.
After acceptance, say that the exact shown decision was saved before participant notification.
After accept and implement, name the newly created ordinary work separately so recommendation and implementation authority remain distinct.
