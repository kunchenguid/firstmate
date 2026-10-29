# intake.question: addyosmani/agent-skills

Extends the one concise question firstmate asks at intake, scaled to how unclear the ask is.
It runs in firstmate's chat at intake, where the captain is present, before any brief exists, and never inside a worker, because `interview-me` and `idea-refine` both need a live, responsive person by their own rules.

## Choosing the tier

Write the captain's own words to a scratch file and run `bin/fm-best-practices.sh intake addyosmani/agent-skills <ask-file>`.
Its `tier` row is one Choice over the first three tiers, and its `idea` row is one Noul; both are routed in one request.
The captain's own words are read in code and win over the routed answer: "skip the interview" is tier 1, "interview me" or "grill me" is tier 4, and "ideate" or "refine this idea" is an idea.
Low confidence, no key, a never-send match, an error, or a timeout falls back to tier 2, the one question of today, and to no idea.

## The four tiers

1. A clear or reversible ask gets no question: state the assumption you are taking and proceed.
2. One real ambiguity gets one question with a hypothesis and a best guess attached, as today.
3. A big, underspecified build, missing who it is for, why, what success looks like, or the binding constraint, which is `interview-me`'s own trigger, gets the full interview in chat.
4. "interview me" or "grill me" gets the full interview, always.

## Running the interview

Ask one question at a time, each with a guess attached, until the skill's test passes: you can predict the captain's reaction to the next three questions you would ask.
Keep the skill's floor: after several rounds with answers still unpredictable, stop and say that something foundational is missing.
The confirmed statement of intent, outcome, user, why now, success, constraint, and out of scope, becomes the task's `## Captain's intent`, kept in the brief and the work item rather than in the skill's `docs/intent/` file in the project.
The interview does not block work: you may start a knowledge-only research scout on the parts already clear while it runs, and you write the brief once the intent is confirmed.
For big work the interview comes before the staged map scout, so the map is drawn against a confirmed intent.

## An idea to explore

When the ask is an idea with no direction yet, dispatch a scout; its brief's routing gives its report `idea-refine`'s one-pager shape, and `handoff-review.md` owns what happens when it reports.
The chain, in the skill's own words: `interview-me` when the captain is unsure what they want at all, `idea-refine` with an idea but no direction, and `spec-driven-development` once the direction is chosen.
