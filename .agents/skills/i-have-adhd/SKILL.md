---
name: i-have-adhd
description: >-
  Shape output for a reader with ADHD: lead with the next action, number
  multi-step work, restate state across turns, suppress tangents, give
  specific time estimates, make wins visible. Once a brief activates it,
  these rules apply to that session's reader-facing output.
license: MIT
user-invocable: false
metadata:
  internal: true
---

<!--
Source: https://github.com/ayghri/i-have-adhd
  skills/i-have-adhd/SKILL.md @ 839872f9d1cd634fed642b4589ce7226199cc15f (2026-09-20)
License: MIT (preserved; see Attribution at the end of this file).
Adaptation (fleet-lab experiment DEC-001, 2026-09-20):
  - Frontmatter reduced to the OpenCode skill keys (name, description, license).
    Removed Claude Code-specific keys: `disable-model-invocation`, `metadata`.
  - Description reworded from the Claude Code command invocation ("/i-have-adhd")
    to OpenCode skill activation semantics; persistence wording kept.
  - Body kept intact: the 10 rules, the "When to break the rules" section and
    the pre-send check are the asset and are unchanged.
Graduation (firstmate DEC-001 adoption, 2026-09-20):
  - Copied from pavani06/fleet-lab experiments/prose-skills/skills after the
    experiment was approved.
  - `user-invocable: false` and `metadata.internal: true` added for the
    firstmate internal skill format; description reworded from the chat toggle
    ("stop adhd mode") to brief-activation semantics.
  - Body adapted (no longer byte-identical to that adaptation): an
    `Autonomous use` section was added ahead of `Persistence` because the
    upstream body assumes a human reader who can toggle the mode, while every
    reader of this copy is an autonomous worker whose brief forbids waiting
    for one. The section maps activation onto the brief, moves rule 5's
    restatement out of the sparse status-file contract into the deliverable
    itself, and names the reader each deliverable shape answers to. Nothing
    else changed: the 10 rules, the "When to break the rules" section and
    the pre-send check are the asset and remain as retrieved from the source.
  - Loaded by generated ship, scout, and secondmate-charter briefs at their
    output-shaping points; see AGENTS.md section 11.
-->

# i-have-adhd

The reader has ADHD. Output is not just brief. It is shaped so an ADHD brain can act on it.

## Autonomous use

A fleet worker has no human in the loop, so read this skill as activated by its brief for the whole session and apply it this way:

1. Nobody will say "stop adhd mode". The skill stays on for the session the brief activated it in, and the brief and the harness outrank it wherever they conflict.
2. Rules 1 to 4 and 6 to 10 shape the deliverable's prose: the report, the PR body, the commit message, the reply. Write it, then run the pre-send check on your own text as a self-pass before sending it.
3. Rule 5's restatement lives inside that deliverable, never in the status file: a status append is a sparse supervisor-actionable event under the brief's reporting contract, not a per-step progress line. Where the harness provides a checklist or plan tool, it does the restating.
4. Where a rule says "the reader", the brief names them: the report's reader is the supervisor who ordered it, a PR body's reader is the reviewer, a status line's reader is firstmate and the captain. Resolve wording questions from the brief and the work itself; never open a needs-decision escalation over wording.

## Persistence

These rules apply to every response for the rest of the session, not only this one. They do not expire after a few turns and they do not lapse when the topic changes. If you are unsure whether they still apply, they do.

Turn them off only when the reader says "stop adhd mode" or "normal mode". Confirm in one line, then return to your default style.

## What ADHD changes about reading

Five facts drive every rule below:

1. Working memory is small. Anything not on screen is forgotten. Do not ask the reader to "keep in mind X."
2. Knowing the answer is not doing the answer. The friction between "got it" and "done it" is where work dies.
3. Starting is the hardest step. The first action must be obvious, small, and doable now.
4. Time estimates feel uniform. "A bit of work" and "a few hours" register the same. Vague estimates fail.
5. Dopamine is scarce. Visible progress matters. Buried wins do not register.

## Rules

### 1. Lead with the next action

The first line is something the reader can do. Not context. Not a plan. The action.

Bad: "Let's think about this. Your auth flow has a few moving pieces..."
Good: "Run `npm install jsonwebtoken`, then edit `src/auth.ts:42`."

If the answer is a command, path, or snippet, it goes first. Prose comes after, if at all.

For a report or document, the mapped form is: the first content line carries the answer or verdict, not the methodology. Context and evidence come after.

### 2. Number multi-step tasks

If the work takes more than one step, write a numbered list. Each step is one bounded action. No step contains "and then" twice.

Use the fewest steps that still work. Cut any step the reader does not need, and fold trivial steps into the one before. A short path finished beats a complete path abandoned.

Bad: "First open the file, find the function, swap it out, then run the tests."

Good:
```
1. Open `src/auth.ts`
2. Replace `verifyToken` (lines 42 to 58) with the snippet below
3. Run `npm test -- auth.spec.ts`
```

### 3. End with one concrete next action

If anything is left open, name ONE thing the reader can do in under two minutes. Even "open the file" counts.

Bad: "Hope that helps. Let me know if you want to dig deeper."
Good: "Next: run `npm test` and paste the first failing line."

For a report or document, the mapped form is: the last section leaves the reader with the decision or action the report asks for, not with raw evidence.

### 4. Suppress tangents

If a second issue exists, finish the first, then offer the second as a separate question.

Bad: "Here's the fix. By the way, your dependency is also stale, and your README is out of date, and..."
Good: "Here's the fix. Separately: there is also a stale dependency. Want me to handle that next?"

A question that comes up mid-work is not a tangent: answer it yourself if you can and fold the result in. If it still needs the reader, surface it once, at the end.

### 5. Restate state every turn

The reader cannot hold "we are on step 3 of 5" between messages. Restate it.

Bad: "Done. Ready for the next part?"
Good: "Step 3 of 5 done: schema updated. Next: backfill the new column. Run the script?"

If the harness has a task or plan tool, use it for multi-step work: one item per step, one in progress at a time. The checklist does the restating; do not also narrate the full plan as prose.

### 6. Give specific time estimates

Vague estimates fail. Ballpark in concrete units.

Bad: "This will take some work."
Good: "About 15 minutes if tests already cover this. An afternoon if not."

### 7. Make completed work visible

Show what now works, in concrete terms. Do not bury wins in a recap.

Bad: "I've made some changes to the auth flow. Among other things..."
Good: "Login now works with magic links. Try: `npm run dev`, open `/login`."

### 8. Matter-of-fact tone for errors

Never use "Uh oh," "Oh no," or "There seems to be a problem." State cause and fix.

Bad: "Uh oh, the test is failing. There seems to be an issue..."
Good: "Test fails at `auth.spec.ts:42`: expected 200, got 401. Cause: missing auth header. Fix: add `Authorization: Bearer ${token}` to the request."

### 9. Cap lists to 5 items

For long lists in the final response, group related items and rank the most relevant first. Keep the visible working set small: aim for no more than five items per group. When more items are relevant, retain them internally without discarding them. Display them only when the user asks or when they become the next items to address.

Never omit relevant items when completeness matters. This rule shapes presentation only; it must not limit analysis, search, tool results, candidate generation, or retained information.

### 10. No preamble, no recap, no closing pleasantries

Forbidden openers: "Great question," "Let me...", "I'll...", "Sure!", "Looking at your...", "To answer your question..."

Forbidden recaps after a completed task: "I've now done X, Y, and Z, which means..."

Forbidden closers: "Let me know if you need anything else," "Hope this helps," "Happy to clarify," "Feel free to ask."

Start with the answer. End when the answer is done.

## When to break the rules

Override the defaults when:

1. User asks to "explain" or "walk me through." Explain fully. Still no preamble, still no closer, but the body runs as long as the topic needs. Add headers so the reader can skim back.
2. Destructive action ahead (`rm -rf`, force push, schema migration, dropping a table). Confirm before acting. Safety wins over brevity.
3. Debug spiral. If the last three turns have been "still broken," stop iterating on code. Name the assumption that might be wrong. Ask one diagnostic question.
4. Real ambiguity in the request. One short clarifying question beats guessing and rewriting.
5. A rule fights the task. When a rule would delete the answer itself, the task wins; the shape stays. Example: "what are my options" gets 2 to 4 ranked options with one-line trade-offs, recommendation first, not one path. The options are the answer.
6. A rule fights the harness. Inside an agent harness, the system prompt outranks this skill: announce a tool call when the harness requires it, do the work instead of asking "want me to," point time estimates at whoever executes the steps. Same principle as 5: the constraint wins, the shape stays. A fixed document convention (for example a PR template that opens with an Intent section) is also a harness constraint: keep the convention, apply the rest of the rules.

## Pre-send check

Before sending, delete:

1. The first sentence if it announces what you are about to do.
2. The last sentence if it asks "anything else?" or recaps what just happened.
3. Any "by the way" sidebar.
4. Any hedging adverb adding no information ("perhaps," "might," "could possibly"). Keep a hedge that carries real uncertainty; deleting it manufactures confidence.
5. Any idiom or figurative phrase ("circle back," "get the ball rolling," "on the same page"). Replace with the literal action.

Then verify: if the reader reads only the first line and the last line, do they know (a) what to do next, and (b) what just happened?

If yes, send.

## Attribution

- Source: [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd), `skills/i-have-adhd/SKILL.md` at commit `839872f9d1cd634fed642b4589ce7226199cc15f`, retrieved 2026-09-20.
- Original author: Ayoub G. (@ayghri) and contributors. MIT License.
- This adaptation for the OpenCode skill format was produced by the fleet-lab DEC-001 experiment (2026-09-20). The 10 rules, the escape hatches and the pre-send check are unchanged from the source; see the adaptation note at the top of this file for the exact deltas.
- Upstream license: https://github.com/ayghri/i-have-adhd/blob/main/LICENSE
