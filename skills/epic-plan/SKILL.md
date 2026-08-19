---
name: epic-plan
description: Give every story in a scaffolded epic a real, phased implementation plan by invoking the fleet's actual ck-plan planner (ClaudeKit's ck-plan, as a CLI where present or as an agent-invoked skill) once per story, producing a per-story plan directory of plan.md + phase-*.md. The story file's implementation-plan section becomes a POINTER to that plan directory - the plan is never hand-written into the story. Use after /epic-scaffold, once the stories exist and before the review gate. Third skill in the epic pipeline; hands off to /epic-review.
user-invocable: true
---

<!-- maintainers: public, installer-facing skill. Keep it standalone and harness-agnostic - no private paths, no tool-specific or single-harness syntax. It is one of six epic-pipeline skills (epic-new -> epic-scaffold -> epic-plan -> epic-review -> epic-handoff -> epic-ship) that share one voice and one output format. This skill DRIVES a real planner (ClaudeKit's ck-plan). `ck` is NOT guaranteed to be a shell CLI - on most harnesses it is the agent-invoked `ck:ck-plan` skill, so the skill detects the capability rather than assuming a CLI. It must not reimplement planning - defer to `ck plan --help` (CLI) or the ck-plan skill for the exact contract; the hand-authored fallback exists only for harnesses with no ck at all. -->

# epic-plan

Turn each scaffolded story into a real, phased implementation plan - produced by the fleet's actual planning tool, not written by hand.
For every story the epic contains, you run the planner once and get back a per-story plan directory: a `plan.md` and one `phase-*.md` per phase.
The story's implementation-plan section then points at that directory.
When the story is later dispatched, the worker follows the plan directory's concrete phases instead of improvising - which is the whole point: a plan a human reviewed beats a plan invented mid-implementation.

You are the PLANNER.
You do not review the epic and you do not write the plans by hand - you drive the planning tool per story and wire each story to its plan directory.

## When to use

- `/epic-scaffold` produced an epic with standard stories, and each story now needs its implementation plan before the review gate.
- A story's scope changed and its plan directory needs regenerating.

## Why a real planner, not a hand-written section

A hand-written "implementation plan" inside a story tends to be a paragraph of good intentions.
The real planner researches the codebase, breaks the work into phases with success criteria and risks, and writes structured files a worker can execute step by step.
Running it per story is what keeps dispatch honest: the worker has phases to follow, so it does not hallucinate the shape of the work.

## Procedure

Do this once per story in the epic.

1. **Pick the plan directory for the story.**
   Use a stable, per-story location so plans do not collide - one directory per story id:

        plans/<epic>/stories/<id>-plan/

   This is relative to the repo the story targets (the planner's default project scope is that repo's `./plans/`).
   Keep `<epic>` and `<id>` exactly as they appear in the story frontmatter so the plan directory is traceable to the story.

2. **Run the real planner in full mode, scoped to that directory.**
   `ck` is ClaudeKit's ck-plan planner, but it is NOT guaranteed to be a shell command on your PATH - on most harnesses it is an agent-invoked skill.
   So detect the capability, in this order, and use the first one that exists:

   1. **`ck` CLI on PATH.** If `command -v ck` succeeds, run the ClaudeKit CLI directly:

          ck plan create --title "<story id>: <story heading>" --phases "Research,Implement,Test" --dir plans/<epic>/stories/<id>-plan --source skill

      This scaffolds `plan.md` and one `phase-*.md` stub per phase.
      `ck plan --help` is the single owner of the exact flags and modes; defer to it rather than duplicating them here.

   2. **The real ck-plan skill (primary path).** Otherwise, invoke your harness's ck-plan skill - for example `/ck:ck-plan` on a Claude-family harness, or the equivalent skill invocation on your harness.
      Point it at this story and the target plan directory `plans/<epic>/stories/<id>-plan/` and ask for the same output: a `plan.md` plus one `phase-*.md` per phase.
      This is the same tool as the CLI, driven the way your harness invokes skills, and satisfies the requirement to use the real ck-plan.

   3. **Hand-authored fallback (no ck on this harness).** If neither a `ck` CLI nor a ck-plan skill is available, author the same-shape plan directory by hand: write `plan.md` and one `phase-*.md` per phase with the same content a plan carries - overview, requirements, architecture, related files, implementation steps, success criteria, and risks.
      Note in `plan.md` that ck was unavailable on this harness and the plan was authored directly, so a reviewer knows why.

   Whichever path you take, use full mode (research + phased breakdown), not a fast skip, because the story is about to be reviewed and then executed - and the output is the same either way: a per-story plan directory the story points at.

3. **Read before you write - every generated file.**
   The CLI and skill paths write real stub files.
   Before composing any long content, read `plan.md` and every generated `phase-*.md` stub - a directory listing is not enough, and on some tools skipping a stub read gets that file's write rejected.
   Only after that read pass, fill `plan.md` and each phase with the real plan: overview, requirements, architecture, related files, implementation steps, success criteria, and risks.
   (The hand-authored fallback creates these files itself, so there is nothing to read first - just write the same content.)

4. **Point the story at its plan directory - do not inline the plan.**
   In the story's implementation-plan section, replace the placeholder with a pointer, not a copy:

        ## Implementation plan

        See the plan directory: `plans/<epic>/stories/<id>-plan/` (plan.md + phase-*.md).
        The dispatched worker follows those phases in order.

   The plan lives in one place - the plan directory - so it cannot drift from a second copy pasted into the story.

5. **Move to the next story** and repeat until every story has a plan directory and a pointer.

## Output

Report back exactly this shape:

- **Stage:** plan
- **Epic:** `<slug>` - `<title>`
- **Plans:** one line per story - `<id>` -> `plans/<epic>/stories/<id>-plan/` (N phases)
- **Pointers:** every story's implementation-plan section points at its plan directory (confirm none is hand-written inline)
- **next:** /epic-review (run it as a different agent - the review gate is independent)
