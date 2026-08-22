---
name: plainenglish
description: >-
  The reply-shape half of firstmate's captain communication contract: one paragraph, at most two sentences, leading with the ask or the answer.
  Use when the captain invokes /plainenglish, asks why replies are shaped this way, says replies are too long or that questions are getting lost, or asks to turn the standing per-turn reminder off or back on.
user-invocable: true
metadata:
  internal: true
---

# plainenglish

This skill owns the shape of a captain-facing message.
`AGENTS.md` section 9 owns everything else about captain communication: outcome-not-mechanics translation, the internal-term rewrites, and which events are worth reaching the captain for at all.

## The contract

One paragraph, at most two sentences.
Not two sentences per paragraph, and not a short summary followed by the detail underneath it.
Lead with the ask or the answer, then delete every clause that is not needed to act on it.
Evidence, options, tradeoffs, and reasoning belong in a file, a task note, or a review surface the captain can open, and the message carries the pointer rather than the content.
A full PR URL, a file path, or a one-word status still counts as leading with the answer.

## Why the shape and not just the length

The failure this prevents is a buried ask, not verbosity for its own sake.
When a question arrives under three paragraphs of reasoning, the captain has to read all of it to find the one thing being asked, and the decision is what he actually opened the message for.
Splitting the same words across more paragraphs makes that worse, not better, which is why the rule counts paragraphs and sentences rather than lines.
Compression is the work: if two sentences will not hold it, the surplus is evidence that belongs in an artifact, not a third sentence.

## The one standing exception

An escalation must still stand alone and carry its evidence, which `AGENTS.md` section 9 requires and this skill does not override.
It still obeys the shape - concrete evidence first, then the consequence and the decision being asked for, with options and supporting detail in the artifact the message points at.
Only where an escalation genuinely cannot be acted on without one more fact does the sentence count yield, and it yields by exactly that fact.

## How the reminder arrives

[`bin/fm-plainenglish-hook.sh`](../../../bin/fm-plainenglish-hook.sh) prints one compressed line of this contract at prompt submission, and the harness adds that line to the same turn's context.
Its header owns the mechanism and the reasoning for that event: no harness fires a hook between composing a reply and the captain reading it, so the rule has to arrive before composition rather than gate the output.
Claude is the tracked transport, registered in `.claude/settings.json`; a primary on a harness with no prompt-submission context injection simply operates on this contract from `AGENTS.md` section 9 with no reminder.
The reminder is inert outside a genuine primary home, so a crewmate in its own task worktree never sees it.

## Turning it off

Write `off` into `config/plainenglish` in this home, which is local and gitignored like every other `config/` item.
An absent file, an empty file, or any other value means on, and deleting the file turns the reminder back on.
It takes effect on the captain's next message with no restart, and `docs/configuration.md` owns the schema.

Turning the reminder off stops the per-turn injection only.
It does not repeal the contract above, which `AGENTS.md` section 9 keeps in force for every home.

## When the captain invokes /plainenglish

State the contract back in the shape it describes, and mention the off switch only when the captain asked about turning it off or on.
