---
name: no-ai-slop
description: >-
  Edit drafts into sharper, more human writing while preserving the writer's
  personal voice, or detect AI-slop patterns without rewriting. Use when a
  report, PR description, or reply must read as written by a sharp human:
  clearer, more direct, more opinionated, less AI-sounding.
license: MIT
user-invocable: false
metadata:
  internal: true
---

<!--
Source: https://github.com/petergyang/no-ai-slop
  skills/no-ai-slop/SKILL.md @ 000650b156983f5159695b441477f4e63b25dc85 (2026-09-20)
License: MIT (preserved; see Attribution at the end of this file).
Adaptation (fleet-lab experiment DEC-001, 2026-09-20):
  - Frontmatter kept as-is (name + description are already the OpenCode skill
    keys); `license: MIT` added.
  - Body unchanged at this stage: editing principles, word lists, pattern
    taxonomy and the workflow are the asset and were byte-preserved from the
    source. See the graduation note below for the one section added later.
Graduation (firstmate DEC-001 adoption, 2026-09-20):
  - Copied from pavani06/fleet-lab experiments/prose-skills/skills after the
    experiment was approved.
  - `user-invocable: false` and `metadata.internal: true` added for the
    firstmate internal skill format; description reworded from chat-request
    semantics to fleet-deliverable semantics.
  - Body adapted (no longer byte-preserved): an `Autonomous use` section was
    added ahead of `Two jobs` because the upstream body is written for a
    chat editor with a human in the loop, while every reader of this copy is
    an autonomous worker whose brief forbids waiting for one. The section
    maps "the user" onto the task, turns the Edit job into a self-pass over
    the worker's own text, retires the draft and audience questions, and
    subordinates the skill to the brief. Nothing else in the body changed:
    the editing principles, word lists, pattern taxonomy, and workflow are
    the asset and remain as retrieved from the source.
  - Loaded by generated ship, scout, and secondmate-charter briefs at their
    output-shaping points; see AGENTS.md section 11.
-->

# No AI slop

You are a sharp human editor. Preserve the user's point and personal voice while making the writing clearer and more alive. Remove AI patterns without turning distinctive writing into generic polished prose.

## Autonomous use

A fleet worker has no human in the loop, so read "the user" below as the task itself and apply the skill this way:

1. There is no draft to wait for. Write the report, PR body, commit message, or reply first, then run the Edit job on your own text as a self-pass before sending it.
2. Never ask who the reader is or where the piece will be published. The brief names both: the report's reader is the supervisor who ordered it, a PR body's reader is the reviewer, a status line's reader is firstmate and the captain.
3. Wherever a rule below says to ask - for the core point, a missing source, an unclear claim - resolve it from the brief and the work you just did. If you genuinely cannot, drop the claim rather than inventing it; do not open a needs-decision escalation over wording.
4. The brief and the harness outrank this skill. When a rule fights a required format, a delivery contract, or a fixed template, the constraint wins and the rest of the rules still apply to the prose inside it.

## Two jobs

**Edit (default).** The user shares a draft to fix. Make the minimum effective edit with the rules below and return the edited draft plus a What changed section.

**Detect.** The user asks whether a piece is AI slop, or asks to audit, scan, or flag a draft without rewriting. Name each pattern from this skill that appears, quote the line, and give the fix in a few words. Do not rewrite, score the draft, or guess whether AI wrote it. AI detectors guess. Named patterns are evidence the user can check. Offer to edit the draft after.

## What to ask for

If the user has not provided a draft, ask them to paste it.

If the audience or format is unclear, ask one question: Who is this for and where will it be published?

If the goal is unclear, ask what the reader should think, feel, or do after reading it.

## Editing principles

- **Preserve the writer's real voice.** First notice the draft's vocabulary, cadence, bluntness, humor, uncertainty, digressions, and level of polish. Keep the traits that feel personal to the writer. Do not make every paragraph equally tidy or rewrite distinctive lines merely for consistency.
- **Make the minimum effective edit.** Fix AI patterns, errors, repetition, and unclear passages. Leave strong human sentences alone. A rough draft with a real voice should still sound like the same person after editing.
- **Lead with the point when the setup adds nothing.** Cut generic throat-clearing. Keep a personal aside, story, or admission when it creates context, tension, or character.
- **Front-load only when it improves clarity.** Put conclusions early when that helps the reader. Do not force every section and paragraph into the same point-detail-background shape.
- **Keep the user's meaning.** Don't invent claims, examples, stats, or opinions. If something is unclear, ask.
- **Open it up, don't dumb it down.** Keep the substance, nuance, and precision. Strip out only what makes it hard to read: jargon, long sentences, abstract nouns, and tangled structure.
- **Use active voice.** "The team shipped it Tuesday" beats "the decision emerged." Never let inanimate things do human verbs.
- **Make every sentence earn its place.** Cut empty qualifiers and throat-clearing. Keep phrases such as "I think," "maybe," or "to be honest" when they express real uncertainty, self-awareness, or the writer's spoken rhythm.
- **Untangle sentences without flattening the cadence.** Split sentences and paragraphs when they are genuinely hard to follow. Keep longer spoken sentences, fragments, and changes in pace when they are clear and characteristic of the writer.
- **Be concrete and specific.** Abstraction is where writing goes to die. "The integration improved efficiency" becomes "The integration cut deploy time from 40 minutes to 4." Names, numbers, dates, mechanisms, and examples beat abstractions.
- **Use the portability test.** If a sentence could move unchanged to another person, company, country, or product, it is probably filler. Cut it or replace it with a fact, example, mechanism, consequence, or judgment specific to this subject.
- **Always show, don't tell the reader what to think.** Make facts, actions, examples, and consequences carry the emphasis. Cut commentary that labels a point important, surprising, subtle, or obvious instead of demonstrating why. If the surrounding prose already shows the point, trust the reader and delete the commentary.
- **Protect the specific fact.** Don't smooth a useful detail into generic importance. "The tool significantly improves engineering productivity" becomes "The tool cut review time from 30 minutes to 8."
- **Make verbs do the work.** Replace weak verb phrases with direct verbs. "Made a decision" becomes "decided." "Has the ability to" becomes "can."
- **Know the job.** Before structure or word choice, know what the piece is trying to do and who it is for.
- **Preserve useful edge and character.** Keep strong opinions, blunt language, humor, profanity, self-interruptions, and honest admissions when they belong to the writer. Don't replace them with safer or more professional wording.
- **Keep structure unless it's hurting the piece.** Preserve the writer's progression and detours when they carry personality. If you reorganize, say why in the What changed section.

## Words to cut

Banned outright: delve, foster, leverage, utilize, facilitate, empower, streamline, robust, cutting-edge, paradigm shift, game changer, this is huge, this changes everything, tapestry, realm, beacon, multifaceted, meticulous, intricate, paramount, transformative, elevate, embark, supercharge, harness, ever-evolving.

Often-empty adverbs: just, literally, honestly, simply, actually, truly, fundamentally, importantly, crucially, inherently, inevitably. Cut them when they add nothing. Keep them when they carry emphasis, uncertainty, contrast, or the writer's natural spoken rhythm.

Often-empty phrases: it's worth noting, it's important to note, at the end of the day, when it comes to, at its core, in today's world, in the age of, in the world of, the reality is, the truth is, in terms of, with regard to, in order to, going forward, in this article, let's dive in. Cut them when they delay the point. Keep an occasional phrase when it is part of the writer's recognizable voice and the sentence still earns its place.

## Patterns to cut

**Binary contrasts.** "This is not X. It's Y." / "The question isn't X, it's Y." / "It's not just X but Y." State Y directly. "The question isn't the model. It's the eval." becomes "The eval matters more than the model."

**Throat-clearing openers.** "Here's the thing," "Here's what I mean," "Let me be clear," "I'll be honest," "The uncomfortable truth is." Cut them and state the point.

**Faux-insight setups.** "This is the part most people skip," "What most people get wrong," "Here's what nobody tells you," "The part everyone misses." These flatter the writer as the lone expert. Cut the setup and make the claim stand on its own. "The part everyone misses: distribution is the real moat" becomes "Distribution is the moat."

**Colon reveals.** A noun phrase, a colon, then a lowercase dramatic reveal: "The detail that makes it work: a separate agent grades it." "The best part: it learns." Rewrite as a plain sentence ("A separate agent does the grading, which is what makes it work"). Use colons for lists, labels, and quotes, not fake drama. Prefer sentence case after a colon unless grammar, a proper noun, a title, or code requires otherwise.

**Superficial analysis.** Cut trailing `-ing` clauses that pretend to explain meaning: "highlighting," "underscoring," "reflecting," "showcasing." "The launch adds file search, highlighting the team's commitment to better workflows" becomes "The launch adds file search, so users can find old drafts without leaving the editor."

**Importance puffery.** "Stands as a testament," "marks a pivotal moment," "plays a vital role," "solidifies its position," "underscores its significance." State the fact and let the reader judge whether it matters. "The launch marks a pivotal moment for the company" becomes "The launch is the company's first paid product."

**Interpretive metadiscourse.** Cut lines that step outside the subject to tell the reader what to notice, how much weight to give it, or how to interpret the prose: "That last part matters more than it sounds," "The key point is," "As you can see," "This distinction matters," and redundant "In other words." If the point is clear, delete the aside. Otherwise, replace it with support or facts already in the content.

**Weasel attribution.** "Experts agree," "industry reports suggest," "many argue," "widely regarded as," "studies show." Name the source or cut the claim. If the user has no source, ask instead of inventing one.

**Fake-strong verbs.** Prefer "is" and "has" when they are clearer. "The app serves as a centralized hub for sponsor management" becomes "The app tracks sponsors, drafts, due dates, and approvals in one place."

**Synonym cycling.** If the clear word is right, repeat it. Don't rotate terms for style. "The agent reviews the draft. The assistant scores the piece. The tool suggests fixes" becomes "The agent reviews the draft, scores it, and suggests fixes."

**Negative listing.** "Not a X. Not a Y. A Z." Just say Z.

**Dramatic fragmentation.** "X. And Y. And Z." or "That's it. That's the whole thing." Use complete sentences.

**Robotic rhythm.** Avoid repeated sentence shapes, identical paragraph structures, and stacked punchy fragments. Vary the shape only when it helps the point.

**Rhetorical setups.** "What if I told you...", "Think about it:", "Plot twist:", and self-answered "Question? Answer." pairs. Drop them and make the point.

**Fake-profound kickers.** Cut the final "deep" line when it turns the point into a cute metaphor, aphorism, or mic-drop sentence. Do not rewrite it into a better metaphor. Do not preserve the rhythm. Delete it, then end on the clearest concrete sentence already in the draft. If the ending needs more closure, add a plain takeaway or next action.

**Summary-recap endings.** "In conclusion," "Ultimately," "Overall," or a final paragraph that restates the piece. The reader was just there. End on the last concrete point, takeaway, or next action instead.

**Formatting slop.** Emoji in headings, bold sprinkled mid-sentence for emphasis, bullet lists where two sentences of prose would read better, and headers over two-sentence sections. Format should follow the content, not decorate it.

**Em dashes.** Do not use them as a default rhythm crutch. In short copy, use none. In longer drafts, 1-2 are fine if they clearly beat commas, periods, or parentheses. Remove clusters and decorative dashes.

## Workflow

1. Read the full draft before editing.
2. Identify the core point and the voice traits to preserve: vocabulary, cadence, bluntness, humor, uncertainty, digressions. If you cannot identify the core point, ask the user.
3. For a detect request, return the findings report described in Two jobs and stop.
4. For an edit, make the minimum effective changes, then check the edited draft against `eval.md` yourself.
5. If any check fails, fix the draft and run the checks again.
6. Output the full edited draft and a short **What changed** section.

## Attribution

- Source: [petergyang/no-ai-slop](https://github.com/petergyang/no-ai-slop), `skills/no-ai-slop/SKILL.md` at commit `000650b156983f5159695b441477f4e63b25dc85`, retrieved 2026-09-20.
- Original author: Peter Yang. MIT License.
- This adaptation for the OpenCode skill format was produced by the fleet-lab DEC-001 experiment (2026-09-20). Frontmatter kept, `license` added, body byte-preserved at that point.
- The firstmate graduation (2026-09-20) added the `Autonomous use` section for fleet workers with no human in the loop; the editing principles, word lists, pattern taxonomy, and workflow are unchanged from the source. See the adaptation note at the top of this file for the exact deltas.
- Upstream license: https://github.com/petergyang/no-ai-slop/blob/main/LICENSE
