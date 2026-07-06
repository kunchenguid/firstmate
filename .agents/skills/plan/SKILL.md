---
name: plan
description: Plan a feature or change with the captain before it becomes work - resolve the target project, match ceremony to the size of the change, shape the spec (plain chat for tiny changes, a Lavish surface with clickable design forks for medium and large ones), then on approval turn the spec into a tracked backlog story, a crewmate brief, and a normal firstmate dispatch. Use when the captain invokes /plan (e.g. "/plan <feature> [project]") or says "let's plan X", "plan this feature", or wants to think a change through before building it.
user-invocable: true
metadata:
  internal: true
---

# plan

Turn a fuzzy intent into an approved spec, then into a tracked story that flows through firstmate's normal delivery machinery.
This is a supervisor-side skill: firstmate plans, the captain steers, and a crewmate builds.
A sharp spec buys a silent run - every ambiguity left here becomes either a mid-run interruption or a wrong thing caught late at review, so resolve it here.

Prime directive #1 holds throughout: reading the project to plan concretely is what read access is for, but never edit, commit to, or run state-changing commands in anything under `projects/`.
Do not start implementing here: the plan is this skill's product, and the dispatched crewmate builds it.
All clarifying dialogue stays in the harness chat; the Lavish surface exists only for fork-clicking and annotation.

## Step 1 - Resolve the target project

Use the normal intake rules (AGENTS.md section 7): an explicit project name wins, a clear follow-up inherits its referent's project, and otherwise match the message content against `data/projects.md`, in-flight backlog items, and the projects' own code and READMEs.
One confident match: proceed, stating the project in plain outcome language so a wrong guess costs one correction.
More than one plausible match, or none: ask a one-line question.
Give the change a short kebab `<slug>`; it seeds the story id in step 5.

## Step 2 - Weigh the ceremony

Match planning weight to the change; do not give every request the full treatment.

- **Tiny** (a copy fix, a config flip, a one-file tweak): a one-line goal plus acceptance criteria, confirmed in chat.
  No Lavish artifact.
  On the captain's yes, go straight to step 5.
- **Medium** (a feature, a multi-file change, anything with a real design choice): the full four-field spec, shaped on a Lavish surface with clickable forks via steps 3 and 4.
- **Large** (a new subsystem, an architecture-level change): draft a short design note and review it with the captain in chat first, then run steps 3 and 4 to settle the spec.
- **Bug**: plan the reproduction explicitly at whatever size the fix warrants - the repro becomes the regression test, recorded in the spec's verification field.

The four-field spec, at every size that reaches step 5: Goal & why · Acceptance criteria · Out of scope · Verification.

## Step 3 - Read the ground, then build the plan surface

Do not plan blind: read enough of the target project to plan concretely - entry points, the modules the change touches, existing patterns, tests, and how it builds and ships.
Real constraints and sharp edges you find become forks and open questions.

Open the relevant Lavish playbooks before writing any HTML - they are the contract, not a suggestion:

```sh
lavish-axi playbook plan        # overall structure
lavish-axi playbook diagram     # Mermaid architecture/flow/sequence
lavish-axi playbook input       # the clickable design forks
lavish-axi design               # design source + CDN snippets (Mermaid, Tailwind/DaisyUI)
```

Match the target project's design system when it has one; otherwise use the Lavish-recommended Tailwind/DaisyUI CDN, and state which you used.
Write the artifact to `.lavish/plan-<slug>.html` under this firstmate home (`.lavish/` is gitignored scratch - the surface is never committed anywhere).
Structure it, top to bottom, so decisions and risks are obvious at a glance:

1. **Intent** - one line: what we are building and why.
2. **Architecture** - Mermaid diagram(s) of the target state; add a current-vs-target view when it clarifies.
3. **Design forks** - each branch point rendered as a clickable choice (Lavish `input` playbook) with 2-4 options, a terse tradeoff per option, and your recommended option marked.
4. **Open questions** - unknowns that block or shape the work but are not clean either/or forks.
5. **Step plan** - ordered implementation steps concrete enough that a crewmate can execute without guessing, scoped to the chosen fork branches.

## Step 4 - Review loop

Open the surface and long-poll for the captain's steer:

```sh
lavish-axi .lavish/plan-<slug>.html
lavish-axi poll .lavish/plan-<slug>.html   # run as a harness-tracked background task; never kill it
```

On each round of feedback: lock in the fork options the captain clicked, fold in annotations and queued prompts, answer clarifying questions in chat, and revise the artifact so diagrams and steps reflect the chosen branches; then re-poll.
Fix fresh error-severity `layout_warnings` before looping back to the captain.
Converge on explicit approval ("looks good", "ship it", "go") or the captain ending the session.
A plan with unresolved forks is not settled - surface what is still open rather than guessing.

## Step 5 - Approval becomes a story, a brief, and a dispatch

Once the captain approves:

1. **Mint the story id**: the kebab `<slug>` plus a short random suffix, e.g. `add-alerts-k3` (the AGENTS.md section 2 task-id form).
2. **Track the story**: `tasks-axi add <id> "<title>" --kind ship --repo <project> --start`.
   Omit `--start` and add `--blocked-by <other-id>` (repeatable) when the story must queue behind in-flight work per the normal readiness classification.
   When the tasks-axi backend is unavailable or opted out, hand-edit `data/backlog.md` per AGENTS.md section 10 instead.
3. **Fill the brief**: `bin/fm-brief.sh <id> <project>`, then replace the `{TASK}` placeholder in `data/<id>/brief.md` with the approved spec in the four-field form (Goal & why · Acceptance criteria · Out of scope · Verification).
   The brief is the spec's durable home; the Lavish surface stays disposable.
4. **Dispatch** (only when the story starts now): `bin/fm-spawn.sh <id> projects/<project>`, through the normal spawn discipline - load `harness-adapters` first, and when `config/crew-dispatch.json` exists consult it and pass an explicit `--harness`.
   The story then flows through the project's recorded delivery mode and gate exactly like any other ship task, and supervision is the normal AGENTS.md section 8 protocol.
5. **Close out**: end the Lavish session with `lavish-axi end .lavish/plan-<slug>.html` once the spec is captured in the brief, and report the handoff to the captain in plain outcomes - the project, the forks as resolved, and that the work is now building toward a review.

## Principles

- Front-load the thinking: ten minutes sharper on a fork saves an hour of wrong build.
- Never inline the captain's browser feedback text into a shell command; pass artifact content through files.
- Keep the surface scannable: diagrams and clickable forks over walls of prose.
- The captain stays the trigger for merge; the dispatched story stops at its mode's normal approval gate.
