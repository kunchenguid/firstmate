---
name: grill
description: Interview the captain to sharpen a fuzzy feature request into a crisp spec before any work is dispatched. Use when the captain invokes /grill (e.g. "/grill", "grill me on this", "help me think this through"); when a non-trivial feature request arrives too vague to brief a crewmate against, offer the interview and let the captain opt in rather than starting one uninvited. Produces a short spec doc at data/spec-<project>-<slug>.md - the problem, the solution shape, the scope boundary, and the open questions - which then feeds the ordinary brief and dispatch path. It plans and never builds: no branch, no dispatch, no code.
user-invocable: true
metadata:
  internal: true
---

# grill

Turn a fuzzy request into something sharp enough to brief a crewmate against.
The deliverable is a short spec doc at `data/spec-<project>-<slug>.md`.
This skill is the front of firstmate's planning path: it sharpens the idea, and the sharpened spec then feeds the ordinary brief and dispatch path of AGENTS.md section 7.

`/grill` plans, it never builds.
It creates no branch, dispatches no crewmate, and writes nothing outside `data/`.
The one artifact it produces is the spec file.

## When this fires, and when it must not

Load this skill when the captain invokes `/grill`.
Otherwise, when a non-trivial feature request is too vague to write acceptance criteria for, OFFER the interview in one line and let the captain opt in, rather than opening one they did not ask for.
The tell is that you cannot state what "done" means without guessing.

Do not load it for:

- A request that is already sharp.
  If you could write the brief now, write the brief now.
  Grilling a clear request wastes the captain's time and is the main way this skill would become annoying.
- A bug report, a "why is this broken", or a "how would we" question.
  Those are scout tasks per AGENTS.md section 7; dispatch a scout instead of interviewing the captain about it.
- A trivial change, however fuzzy the wording.
  A one-line fix does not need a spec.

When it is genuinely borderline, say in one line what you would brief and let the captain redirect you.
A cheap wrong guess beats an unnecessary interview.

## What it does

1. **Resolve the subject first.**
   Resolve the project exactly as AGENTS.md section 7 ("Resolve the project first") describes; that section is the single owner of the resolution signals, and this skill adds nothing to them.
   Read the project's code and README as needed to ask informed questions rather than making the captain explain their own codebase.
   Grilling never changes the routing rules, and it does not move to a secondmate even when one's scope covers the work: prime directive 4 makes firstmate the captain's only point of contact, so the interview happens here and the resulting work routes normally afterwards.

2. **Interview the captain, one question at a time.**
   This is the part that earns the name.
   Ask a single question, wait for the answer, and let the answer choose the next question.
   Never send a numbered list of eight questions; that is a form, not an interview, and the captain will answer it shallowly.
   Push until each of these is sharp, in roughly this order:
   - **The problem.** What is wrong today, for whom, and what does it cost them? Keep asking until the answer is a real situation, not a missing feature. "There is no export button" is not a problem; "the captain re-keys the run log into a spreadsheet every evening" is.
   - **The smallest thing that fixes it.** What is the least that could ship and still be worth having? This is the question that most often collapses a month of imagined work into a week.
   - **The scope boundary.** What is explicitly NOT in this? Named exclusions are worth more than the inclusions, because they are what stops a slice from sprawling later.
   - **The vocabulary.** What are the real nouns and verbs of this domain, and what does each one precisely mean? Pin the words down now. Two people using "job" for different things is the cheapest bug to catch here and the most expensive to catch in review.
   - **The uncertainty.** What does the captain not yet know, and what would have to be true for this to work?

3. **Challenge, do not transcribe.**
   The captain is asking to be grilled, so grill.
   Name the assumption you can see them making.
   Offer the simpler alternative you think they are talking themselves out of.
   If a stated requirement seems to be solving a problem they have not described, say so.
   Disagreement here is cheap; disagreement after three merged slices is not.
   Stop when the answers stop changing the shape, not when a section count is met.

4. **Record open questions as open questions.**
   Anything unresolved goes into the spec's Open questions section, named, with what it blocks.
   Do not paper over an unknown with a plausible guess: a guess reads as settled to the crewmate who picks up the slice, and that is how a wrong assumption gets built.
   An open question that needs investigation rather than a decision is a scout task; note that in the spec and let the captain decide whether to dispatch one before the work is broken up.

5. **Write the spec doc.**
   Write to `data/spec-<project>-<slug>.md` using the format below, where `<slug>` is a short kebab name for the effort.
   The project goes in the filename because two projects can easily want the same slug, and an unnamespaced spec would silently overwrite the other project's, unrecoverably, since `data/` is gitignored.
   Keep it short: this is a working document for the captain and for whoever briefs the work, not a PRD, and nobody is graded on its length.
   If the file already exists, read it first and rewrite it in place rather than starting a rival copy.

6. **Report and hand off.**
   Summarize in plain outcome language (AGENTS.md section 9): what the effort now is, what got cut, and what is still open.
   Say the spec is written and name the next step: breaking it into work and dispatching it, per AGENTS.md section 7.
   Do not dispatch anything yourself and do not start breaking the spec into work without the captain's word - a spec with open questions in it is often not ready, and the captain is the one who knows.

## Spec doc format

This skill is the one owner of this format; every other reader of the spec cross-references it here rather than restating it.
Every section always renders, with an explicit "None" when empty, because an empty section and a forgotten section are different facts.

```markdown
# Spec - <effort name>

**Project:** <name> - **Grilled:** <YYYY-MM-DD>

## Problem
What is wrong today, for whom, and what it costs. Two or three sentences.

## Solution shape
The smallest thing that fixes it, described so a reader can picture it. Not a design.

## Vocabulary
- **<term>** - what it precisely means here.

## In scope
- <the thing that ships>

## Out of scope
- <named exclusion> - <why, or "later">

## Open questions
- <question> - blocks: <what it blocks> - needs: <a captain decision | a scout>

## Constraints
Anything that binds the solution: a deadline, a platform, an existing contract, a thing that must not break.
```

Because `data/` is gitignored and firstmate-private, this doc may name projects, task ids, and PR URLs directly; the captain works with those.
The interview itself stays in plain outcome language, per AGENTS.md section 9.

## Boundaries

- **Never writes to a project.** AGENTS.md section 1 is unconditional; `/grill` reads projects and writes only its spec file under `data/`.
- **Never dispatches.** Sharpening and dispatching are separate steps on purpose, so the captain can stop after the spec and lose nothing.
- **Never becomes a tracker.** The spec is an input to `data/backlog.md` (section 10), not a parallel record of work. If you find yourself giving spec items statuses, stop: tracking work is the backlog's job, and the spec is only how the work gets described.
