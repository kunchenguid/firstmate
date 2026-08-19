---
name: epic-plan
description: Give every story in a scaffolded epic a real, phased implementation plan by authoring a per-story plan directory of plan.md + phase-*.md directly, with genuine planning rigor - overview, requirements, architecture, related files, steps, success criteria, and risks. The story file's implementation-plan section becomes a POINTER to that plan directory - the plan is never hand-written into the story body. Use after /epic-scaffold, once the stories exist and before the review gate. Third skill in the epic pipeline; hands off to /epic-review.
user-invocable: true
---

<!-- maintainers: public, installer-facing skill. Keep it standalone and harness-agnostic - no private paths, no tool-specific or single-harness syntax. It is one of six epic-pipeline skills (epic-new -> epic-scaffold -> epic-plan -> epic-review -> epic-handoff -> epic-ship) that share one voice and one output format. The PRIMARY mechanism is authoring the plan directory directly with real rigor, because that works on any harness with no external CLI. A planning CLI is an OPTIONAL accelerator only when one genuinely exists and works; do not make the skill depend on it. -->

# epic-plan

Turn each scaffolded story into a real, phased implementation plan - authored with genuine rigor, not left as a paragraph of good intentions inside the story.
For every story the epic contains, you produce a per-story plan directory: a `plan.md` and one `phase-*.md` per phase.
The story's implementation-plan section then points at that directory.
When the story is later dispatched, the worker follows the plan directory's concrete phases instead of improvising - which is the whole point: a plan a human reviewed beats a plan invented mid-implementation.

You are the PLANNER.
You do not review the epic - you write each story's plan directory and wire each story to it.

## When to use

- `/epic-scaffold` produced an epic with standard stories, and each story now needs its implementation plan before the review gate.
- A story's scope changed and its plan directory needs regenerating.

## Why a phased plan directory, not a hand-written section

A hand-written "implementation plan" inside a story tends to be a paragraph of good intentions.
A real plan directory breaks the work into phases with success criteria and risks, in structured files a worker can execute step by step.
Writing one per story is what keeps dispatch honest: the worker has phases to follow, so it does not hallucinate the shape of the work.

## Procedure

Do this once per story in the epic.

1. **Pick the plan directory for the story.**
   Use a stable, per-story location so plans do not collide - one directory per story id:

        plans/<epic>/stories/<id>-plan/

   This is relative to the repo the story targets (plans live in that repo's `./plans/`).
   Keep `<epic>` and `<id>` exactly as they appear in the story frontmatter so the plan directory is traceable to the story.

2. **Author the plan directory directly, with real rigor.**
   This is the primary mechanism and it works on any harness with nothing but a text editor.
   Create `plan.md` and one `phase-*.md` per phase in the directory above.
   Use phases that fit the story - `Research`, `Implement`, `Test` is the default shape; adjust when the work genuinely calls for it.
   `plan.md` holds the story-level overview, requirements, architecture, and the list of phases.
   Each `phase-*.md` holds that phase's overview, requirements, architecture notes, related files, concrete implementation steps, success criteria, and risks.
   Plan in full - research the codebase first, then write the phased breakdown - because the story is about to be reviewed and then executed; a skipped-research plan is the paragraph of good intentions you are replacing.

3. **Optional accelerator: a real planning CLI, only if one genuinely works here.**
   Some fleets ship a planning CLI that scaffolds the same `plan.md` + `phase-*.md` shape.
   Do NOT assume one exists, and do NOT reach for a fleet planning skill whose CLI may be missing - that stalls the story on a command that is not there.
   Use a CLI only when you have confirmed it is real and runnable on this harness, for example both of:

        command -v ck            # the binary is on PATH
        ck plan --help           # prints a real `plan` subcommand, not an error

   If, and only if, both hold, you MAY let that CLI scaffold the stubs (for example `ck plan create --dir plans/<epic>/stories/<id>-plan`; defer to `ck plan --help` for its exact flags), then still fill them per step 4.
   If either check fails, ignore the CLI entirely and author the directory by hand per step 2 - that is the expected path, not a fallback.

4. **Read before you write - every plan file.**
   Whether you scaffolded the files by hand or with a CLI, read `plan.md` and every `phase-*.md` before composing long content into them.
   A directory listing is not enough.
   Only after that read pass, fill each file with the real plan: overview, requirements, architecture, related files, implementation steps, success criteria, and risks.

5. **Point the story at its plan directory - do not inline the plan.**
   In the story's implementation-plan section, replace the placeholder with a pointer, not a copy:

        ## Implementation plan

        See the plan directory: `plans/<epic>/stories/<id>-plan/` (plan.md + phase-*.md).
        The dispatched worker follows those phases in order.

   The plan lives in one place - the plan directory - so it cannot drift from a second copy pasted into the story.

6. **Move to the next story** and repeat until every story has a plan directory and a pointer.

## Output

Report back exactly this shape:

- **Stage:** plan
- **Epic:** `<slug>` - `<title>`
- **Plans:** one line per story - `<id>` -> `plans/<epic>/stories/<id>-plan/` (N phases)
- **Pointers:** every story's implementation-plan section points at its plan directory (confirm none is hand-written inline)
- **next:** /epic-review (run it as a different agent - the review gate is independent)
