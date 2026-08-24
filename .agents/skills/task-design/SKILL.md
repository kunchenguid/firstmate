---
name: task-design
description: >-
  Design/prototype member of the planning family.
  Use when task-grill determines a design question exists, or whenever the captain asks to prototype or explore a design ("prototype it", "design it").
  Builds a throwaway interactive artifact with Lavish so the captain answers one question by driving the thing instead of reading prose.
user-invocable: false
metadata:
  internal: true
---

# task-design

A prototype is a throwaway artifact that answers exactly one design question.
This skill rewrites Matt Pocock's MIT-licensed `prototype` skill for Firstmate's operating model, with Lavish as the build-and-review surface.

## Trigger

Run this skill whenever `task-grill` determines a design question exists; all non-Simple planning work passes through grill, so this step is mandatory there.
The captain may also invoke it at any time by asking for a prototype or a design exploration.
Do not build one when established evidence already answers the question.

## Pick the question branch

Identify which question the captain needs answered, from the grill output, the surrounding code, or by asking.
The branches produce very different artifacts, so choosing wrong wastes the whole prototype.

- "Does this logic or state model feel right?" - build ONE interactive HTML demo that pushes the state model through the hard cases.
- "What should this look like?" - build several radically different UI variants, comparable side by side.

If genuinely ambiguous and the captain is unreachable, match the surrounding work (a backend module leans logic; a page or component leans UI) and state that assumption at the top of the artifact.

## Write the artifact where the plan lives

Put every prototype under `projects/<project>/docs/features/<feature-slug>/design/`, beside the spec and tickets it feeds.
State the question in one visible paragraph at the top of the artifact so the answer can be checked against it later.
Keep each prototype a single self-contained HTML file with no framework, bundler, or server.

### Logic branch

Build one demo anyone can drive by clicking.
Isolate the model under test as a pure module inside the file (a reducer, a state machine, or pure functions), with the page as a thin shell that calls into it and never the reverse.
Write every label in domain language rather than code terms, so a non-developer can judge the model.
Provide always-available free-play buttons plus guided scenario tabs covering the happy path, an awkward edge case, and an attempt at something that should be illegal.
Re-render the full relevant state after every action, calling out what changed where that helps a reviewer follow.

### UI branch

Draft three variants by default and cap at five, because more stops being radically different and becomes noise.
Make variants disagree about structure - layout, information hierarchy, primary affordance - not merely color or copy; redo any pair that comes out too similar.
Render them side by side, or switchable within one artifact, using the target project's real design system and realistic data density so judgments transfer.
Prefer mounting the variants in the shape of the real destination page over an empty canvas, which hides design problems.

## Review loop through Lavish

Open the finished file with `lavish-axi <file>`, then keep `lavish-axi poll <file>` running in the foreground until the captain annotates, chooses, or ends the session.
Apply requested changes to the same artifact and continue the same session rather than spawning competing copies.
When feedback resolves the question, stop; do not iterate past it.
Current `lavish-axi --help` owns the exact poll, annotation, and session-end mechanics; follow it rather than restating those details here.

## Rules both branches inherit

1. Clearly marked throwaway - name and header say prototype, so nothing lands in production by accident.
2. Trivially runnable - opening the file is the entire setup.
3. No persistence by default - state lives in memory, and only a persistence-shaped question touches a scratch store named for wiping.
4. Skip polish - no tests, no error handling beyond what keeps it runnable, no abstractions; learning speed is the point.
5. Surface the state - show the full relevant state after every action or variant switch.

## Retention and graduation

Prototypes stay as uncommitted working documents under `design/`, like the family's other planning artifacts.
Never treat a demo itself as deliverable code or move it wholesale into spec or implementation.
Only validated decision snippets graduate into `spec.md` - a reducer signature, a state list, a winning variant's structural choice - and the demo stays behind in `design/`.

## Record the verdict before moving on

Record the question and its answer in `grill.md`'s decision log, or in the spec's Decisions section once that spec exists.
Hand anything still unresolved back to grill or the captain-decision lifecycle instead of guessing.

## Family boundaries

`task-grill` owns whether a design question exists and the decision log.
`task-planning` owns wayfinder/spec/ticket artifacts and dispatch.
This skill owns only building and reviewing the prototype, and never spawns implementation crews.
