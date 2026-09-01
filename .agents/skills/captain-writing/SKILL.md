---
name: captain-writing
description: >-
  Agent-only revision discipline for prose the captain reads, and for prose firstmate writes AS the captain in an outward channel.
  Load before sending a substantive captain-facing message, before sending anything composed in the captain's name, and before writing a report, brief body, or artifact copy the captain will read.
  Owns the two-question test, the bracket pass, the tic list, and the separate-reviser rule that keeps the check independent of the author.
user-invocable: false
metadata:
  internal: true
---

# Captain writing

Good writing is simple and clear.
Complicated is easy; simple is hard.
`AGENTS.md` section 9 owns *what* a captain-facing message must contain - the outcome, the consequence, the next decision, and the vocabulary translation.
This skill owns *how the prose is revised* before it is sent.

Draft normally, then revise against this file.
Do not try to write the final version in one pass; the discipline is the second pass, not a better first one.

## The separate reviser

A drafter is the worst reviser of its own draft, because it reads the intent it meant rather than the words it wrote.
So the revision pass is done by a **different agent** that never saw the reasoning behind the draft.

Send that agent the draft and this file's rules, and nothing else.
No task context, no justification, no explanation of what the draft is trying to achieve.
It is checking the words, and context is exactly what would let it excuse them.

Its instruction is to return the revised prose and a short list of what it cut and why.
Read that list: a reviser that cut something load-bearing means the draft buried the point, which is itself the finding.

### How to reach the reviser

Do not use the harness's own delegation tool.
`bin/fm-subagent-pretool-check.sh` blocks it for the primary on purpose, because work started that way has no durable fleet record and dies with the session.
A revision pass is also not fleet work: it produces no project change, needs no worktree, and would be absurd as a backlog item, so `fm-brief.sh` plus `fm-spawn.sh` is the wrong shape too.

Use a plain independent model invocation instead, run from a scratch directory so it inherits no repository context:

```sh
claude -p "$(cat <prompt-file>)" --model sonnet
```

Build the prompt file as: the reviser instruction, then this file verbatim, then the draft.
Tell it explicitly not to read files or explore, so it judges the words rather than the situation.
That call is a subprocess, not a delegated agent, so it stays outside the fleet's dispatch contract while still giving a reviser that genuinely never saw the reasoning.

A smaller, faster model is the right choice here.
The task is applying a fixed rule list to short prose, and a cheap pass that actually happens every time beats an expensive one that gets skipped.

Apply this to substantive prose, not to every line.
A one-line acknowledgement, a yes-or-no answer, or a `Captain, shipshape.` needs no second pass, and routing one through an agent is waste.
Use it when the message carries findings, a recommendation, a review, an escalation, or anything written in the captain's name.

When no second agent is available, do the pass yourself against the rules below and say that the check was self-administered, because it is the weaker version.

## Two questions

For each line of the draft, ask:

1. What am I really trying to say?
2. Have I said it in the clearest way possible?

If a sentence fails either question, rewrite it.
Boil ideas down to their essence.
Use plain language unless there is a good reason not to.

## The bracket pass

The fastest way to improve writing is to eliminate clutter.
After drafting, bracket everything unnecessary [or redundant], then cut what is bracketed.
Brackets before deletion, because they feel less final and you therefore bracket more honestly.
After the pass, look again and cut more.

Bracket targets:

- **Tacked-on infinitives**: "I hope [to begin] to address".
- **Adverbs that repeat their verb**: "I [hurriedly] ran", "[silently] loses".
- **Timid qualifiers**: "It was [a bit] like", "[In a sense,] I was", "[fairly]", "[somewhat]", "[essentially]".
- **Explanations of the obvious**: sentences that explain what the reader already knows or the surrounding text already shows.
- **Editorializing asides**: "[a nice touch]", "[full stop]", "[which is why this matters]" - decoration, not content.

## Eliminate tics

A tic is a construction leaned on heavily.
Check every revision for these:

- **Em-dash chains**: three clauses spliced with dashes. Break into two or three short sentences. This repo also forbids the em dash outright; use a plain dash.
- **"Not just X, but Y"** and **"The point isn't X, it's Y"**: usually the sentence only needs Y.
- **Stacked appositives**: "the vehicle is X, and the punchline is that once...". State the fact directly.
- **"Which is why" / "and so"** connectives: the causation is usually clear without them.
- **"As" pile-ups**: "As I left, I watched as the dish slid, as my name was called...". Vary the construction.
- **Flourishes in technical prose**: keep one only if it carries real content in few words. Cut the rest.
- **Opening framing sentences**: an abstract sentence placed before the fact, instead of the fact.

Tics vary by writer.
When revising someone else's text, read for repeated constructions first, then revise those.

## Examples

**Em-dash chain, appositive framing:**

- Before: "The vehicle is the X2C Hamiltonian, and the punchline is that once your tensors become complex spinor tensors, the standard factorization machinery - Cholesky, THC, positive-semidefinite double factorization - silently loses its assumptions."
- After: "Its tensors are complex spinor tensors, which breaks the assumptions behind Cholesky, THC, and standard double factorization."

**Announcing instead of stating:**

- Before: "This is the crux of the method: positivity is replaced by sign bookkeeping."
- After: "Sign bookkeeping replaces positivity."

**One long sentence into declaratives:**

- Before: "Uranium chemistry where spin-orbit coupling is the physics, complex spinor tensors are the tax, and both methods get rebuilt to pay it honestly."
- After: "Uranium chemistry needs spin-orbit coupling. Spin-orbit coupling means complex spinor tensors. This document rebuilds both methods around that fact."

## Writing as the captain

When the prose goes out in the captain's name, clarity is necessary but not sufficient: it also has to sound like him.
Read his own recent messages in that same conversation and match the observed capitalisation, length, and sign-off habits before revising.
Most people write far more tersely in chat than an assistant does, so a correctly-revised message can still be wrong by being three times too long.
The separate reviser is told to preserve the captain's voice and cut length, never to make the prose more formal.

## Scope

Apply to prose: chat messages, reports, briefs, captions, artifact copy, documentation, summaries.
Never "simplify" quoted material, technical terms, code, equations, identifiers, or precise claims; clarity never trades away correctness.
Short is not the goal, clear is.
A longer sentence that says exactly one thing beats a compressed sentence that says two things badly.
