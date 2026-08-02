---
name: parallel-ideation
description: >-
  Run several ideation or brainstorming skills in parallel on one subject and turn their outputs into a single synthesis.
  Use when the captain invokes /parallel-ideation or asks to run multiple ideation, brainstorming, or design-thinking skills in parallel on the same subject and synthesize the results.
user-invocable: true
metadata:
  internal: true
---

# parallel-ideation

Coordinate several different ideation or brainstorming skills against one subject so their disagreement, not only their overlap, becomes the deliverable.
This skill is generic over the roster: the captain supplies which skills run at intake, and nothing here hard-codes a particular ideation skill, plugin, or harness.
The procedure has five stages.
Follow them in order; do not improvise a parallel loop while a client is waiting.

## Why this exists

One ideation skill yields one question set.
Several different skills on the same raw subject yield several different question sets, and the resolution comes from the friction between them.
The cost is coordination, and this skill is that coordination written down.

## 1. Intake

1. Capture the subject in one paragraph, in the source's own words.
   Do not summarize, rephrase, or normalize it before the crews see it, because each rostered skill is supposed to interrogate the raw statement.
2. Confirm the roster with the captain: which ideation or brainstorming skills run, with one crewmate per skill.
   The roster is captain-supplied and may change between runs; never invent a default roster.
3. Resolve the harness per crew from what actually provides that skill.
   A skill delivered as a harness-specific plugin can only run on that harness, so the roster can force a harness pin that differs from this home's usual crewmate default.
   Perform that check against the skill's real delivery surface before spawn; do not assume a fixed harness name here.
   Resolve the pin through the routing precedence `AGENTS.md` section 4 owns, and when delivery makes a harness mandatory, confirm it with the captain and carry it as the explicit per-task captain override that precedence already ranks first.
   Load `harness-adapters` before any spawn so the pin is applied through the ordinary dispatch path.
4. Resolve the repository the crews will be spawned into before dispatch.
   A spawn allocates a worktree, so a subject with no repository yet must go through the `project-management` skill first rather than mid-run.
5. Assign a durable run id for this parallel run (the id that will own the shared premise note and the synthesis).
   Prefer a single backlog or task identity that groups the crew scouts so cleanup and history stay legible.

## 2. Shared premise note

1. Create `data/<run-id>/facts.md` in the firstmate home yourself and remain its only writer.
   Crews never edit this file.
2. Seed it with the raw subject paragraph from intake, plus any fact the captain has already confirmed at that moment.
3. Every crew brief must instruct the crew to read this note before starting and again after each relayed answer.
4. The note's purpose is to stop the crews drifting into incompatible premises, which would make their reports impossible to compare at synthesis.
5. Append only captain-confirmed facts.
   Do not write firstmate guesses, unconfirmed crew assumptions, or product choices firstmate invents on its own authority.

## 3. Dispatch

1. Spawn one crewmate per rostered skill as a scout: the deliverable is a report, never a PR.
   Ordinary scout lifecycle, briefs, and isolation rules in `AGENTS.md` section 7 still apply; this skill only owns the parallel coordination on top of them.
2. Each crew brief must:
   - name exactly one skill from the roster for that crew to run;
   - carry the absolute firstmate-home path to the shared premise note, never the relative `data/<run-id>/facts.md` form, because a crew reads it from an isolated project worktree where that relative path resolves to nothing or to an unrelated file, and require the re-read rule above;
   - carry the raw subject paragraph without firstmate rewriting it;
   - restate that crewmates never address the captain and that all captain communication flows through firstmate;
   - tell the crew how to raise a question: append a keyed `blocked:` line and stop, rather than guessing a product answer.
3. Apply any harness pin resolved at intake for that crew when spawning.
4. Record the run as under way and supervise under the ordinary supervision contract.

## 4. Question loop

1. Collect questions rather than relaying them one at a time as they arrive.
   Wait for a natural batch boundary (for example every crew has either blocked or finished a first pass, or a bounded wait has elapsed with open questions) before showing the captain anything.
2. Deduplicate across crews before the captain sees them.
   Near-identical questions merge into one item that records which crews asked it.
   The same question arriving three times is signal about importance, not three separate questions.
3. Send the captain one batch at a time in plain chat, or a structured surface when the batch is large enough that reading it as prose is worse.
   Phrase each item as a decision or clarification in captain-facing language, with the asking crews attributed when that attribution helps.
4. When the captain answers, relay each answer only to the crews that asked that question.
   Append every confirmed fact to the shared premise note.
   Tell every crew in the run, including those that did not ask, to re-read the premise note so premises stay aligned.
5. Firstmate does not answer a crew's question on its own authority when the question is a product choice that belongs to the captain, regardless of the project's autonomy posture.
   Only captain-confirmed facts enter the premise note and the relay.
6. Repeat the loop until every crew has written its report or a genuine blocker requires captain or firstmate action outside this skill.

## 5. Synthesis, seats verification, and close

1. Each crew must write its report before its scratch worktree can be discarded.
   Do not clean up a crew that has not left a self-contained report.
2. Read every report completely.
3. Produce one synthesis document for the run.
   Recommended path: `data/<run-id>/synthesis.md`, or another durable captain-facing path the captain requested at intake.
   The synthesis must include, at minimum:
   - the raw subject statement used for the run;
   - a short map of which rostered skill each crew ran;
   - the shared findings where the crews agreed, attributed only when attribution still matters;
   - an explicit contradictions section for every material point where the crews disagreed, with each position attributed to the crew that held it;
   - a record of the seats pass below: which seats ran, and any seat that came back as a hole.
4. Do not average, blend, or silently drop a minority position.
   Preserving the contradiction is the deliverable's main value, because agreement between the crews was already cheap to obtain.
5. After the synthesis is written and before the run is closed, load `seats` and run a readonly inspection of the synthesis document together with the crew reports it was built from.
   This skill owns only when the inspection happens, what it is pointed at, and what is done with what comes back; `seats` owns how seats are chosen, dispatched, and ranked.
   If `seats` cannot run in this home, stop and report that to the captain as a blocker on the run rather than closing a synthesis the captain asked to have verified.
6. Choose seats for the question actually in front of this run, not from a fixed list in this skill.
   The `seats` starting points for deciding a design are a useful pointer when the synthesis is design-shaped; do not freeze that or any other roster into this skill.
   `seats` owns a mandatory single approval pause where the captain confirms the chosen seats, so the close of this run carries one captain approval point outside the stage 4 batching contract.
7. Seats are readonly for this use.
   Firstmate remains the only writer of the synthesis, and seats return findings only.
8. Rank what comes back under the ranking rules `seats` owns, then fold surviving findings into the synthesis yourself.
   This same step owns writing the record of the seats pass into the synthesis: which seats ran, and any seat that came back as a hole.
9. The crews' attributed contradictions section must survive the seats pass.
   A seat finding may add to it, sharpen it, or add a new contradiction, but must never be used to collapse a minority crew position into a single agreed answer.
   Preserving that disagreement is the run's main deliverable and outranks a seat's tidier conclusion.
10. A dead seat is a hole in the coverage of the check: never retry it and never soften it into an empty finding set.
    When any seat is a hole, say plainly in the close that the inspection was partial.
11. Any decision the run surfaced but did not resolve - whether from the crews or from the seats pass - follows `decision-hold-lifecycle` before the run is treated as complete.
12. Cleanup happens only after every report exists, the synthesis is written, and the seats pass has finished.
    The seats pass runs before scout worktrees are discarded, so a finding that requires re-reading a crew's scratch state can still be answered.
    Tear down scout worktrees only through the ordinary landed-report and unresolved-decision completion path; never force discard without explicit authority.
13. This seats pass is a deliberate bounded exception to firstmate's usual rule that delegated work goes through `bin/fm-spawn.sh`: `seats` launches its own readonly workers through its own scripts, those workers never write the synthesis document and never write any crew worktree, and it is not a precedent for routing other work around the ordinary spawn and supervision path.

## Out of scope

- Choosing the roster for the captain.
- Answering product questions in place of the captain.
- Turning the synthesis into implementation without a separate ship authorization.
- Hard-coding which ideation skills, plugins, or harnesses participate.
- Choosing, dispatching, or ranking seats (owned by `seats`).
- Freezing a seats roster into this skill.
- Collapsing attributed crew contradictions because a seat preferred a single answer.

## Cross-references

- Spawn, scout briefs, and cleanup: `AGENTS.md` section 7 and section 11; `bin/fm-brief.sh` and `bin/fm-spawn.sh` own mechanics.
- Harness pins and skill-invocation: `harness-adapters`.
- Missing repository at intake: `project-management`.
- Unresolved captain decisions at close: `decision-hold-lifecycle`.
- Seats verification of the synthesis: `seats`.
- Captain-facing outcome language: `AGENTS.md` section 9.
