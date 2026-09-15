---
name: goal-prompt-builder
description: >-
  Agent-only procedure for turning a vague task into a concise, auditable `/goal` planning artifact.
  Use when a Codex crewmate needs to refine an idea, choose a project scenario, ask targeted questions,
  or render a goal without executing it.
metadata:
  internal: true
---

# goal-prompt-builder

Use this skill when a crewmate must turn an incomplete task idea into an auditable `/goal` artifact.
This skill is for planning and clarification only.
It never edits project files, dispatches a crewmate, creates a worktree, invokes `bin/fm-spawn.sh`, opens or merges a PR, starts a server, schedules background work, or executes the rendered goal.
Firstmate owns dispatch, supervision, delivery, and merge authority.

## Interaction contract

Use `hybrid` mode by default.
Use `step-by-step` mode when the caller supplies only a short or ambiguous idea.
Use `full-description` mode when the caller supplies a complete specification and only extraction is needed.
In every mode, ask one question at a time when a material gap remains.
Extract facts already supplied by the caller and ask for only the next missing fact that materially affects the goal.
Do not present a batch of unresolved questions or invent an answer to avoid asking.
When the current task record already contains an answer, do not ask for it again.
Keep the conversation in the user's language while preserving commands, file paths, identifiers, and section names exactly.

Return the rendered artifact to the caller when the contract is complete.
Readiness means that the plan is auditable and ready for a separate Firstmate workflow, not that implementation has finished.

## Detect the project type

Inspect the available repository signals before selecting verification defaults.
Use the narrowest matching type and ask one question for any missing command that the type cannot establish.

- Node or TypeScript: `package.json`, `tsconfig.json`, or the repository's documented package scripts.
- Python: `pyproject.toml`, `setup.cfg`, or the repository's documented test configuration.
- Go: `go.mod` and the repository's documented test command.
- Rust: `Cargo.toml` and the repository's documented test or check command.
- Swift: `Package.swift` and the repository's documented test command.
- Static or documentation-heavy: the repository's documented formatter, link checker, or build command.
- Unknown: ask for the exact test, build, type-check, or documentation command before rendering acceptance criteria.

Project type selects verification defaults only.
It does not authorize running those commands during refinement or change the task's scope.

## Select a scenario

Select the first scenario that accurately describes the requested artifact.
Use the scenario name in the rendered metadata when a caller needs to classify the goal.

- `refactor`: a bounded change to an existing subsystem with a clear after-state.
- `feature`: a structured behavior addition with explicit user-facing or API scenarios.
- `batch`: a known, enumerable set of similar items.
- `archaeology`: a read-only investigation that produces evidence or documentation.
- `ui-audit`: a read-only comparison of an implementation with an existing design or specification.
- `gatekeeper`: a read-only readiness assessment of named changes or branches without merging them.
- `custom`: a task that does not fit the other scenarios and needs an explicit scope.

Scenario selection is subordinate to a reusable format skill when one is available.
Do not treat a production classifier as an evaluation loop merely because it uses words such as judge, evaluate, or verdict.

## Reusable format skills

Recognize these portable format patterns before applying a generic scenario.
If the current repository exposes a matching format skill, invoke it through the Codex skill mechanism and let that skill own its specialized `Done when` and `Stop if` skeleton.
If no matching skill is available, preserve the pattern as a planning constraint without inventing an execution loop.

- `ciclo-avaliativo`: iterative improvement of generated output judged by a stated rubric rather than only by tests.
- `harness-de-engine`: a verification instrument that compares a real engine result with a baseline through machine-readable evidence.
- `gabarito-rotulado`: a labeled fixture or gold set that makes quality comparisons reproducible.
- `erradicacao-ate-zero`: measured discovery, categorized remediation planning, and a count that must reach zero.

Prefer `ciclo-avaliativo` for qualitative output judgment and `erradicacao-ate-zero` for a countable zero target.
Use `harness-de-engine` or `gabarito-rotulado` alone only when the request is specifically for that instrument.

## Collect the goal inputs

Collect these five inputs incrementally and do not render until each one is concrete.

1. `Objective` states the intended after-state with a measurable or observable result.
2. `Scope` names the files, directories, subsystem, interface, or evidence boundary that the task may address.
3. `Constraints` states hard rules, compatibility requirements, project defaults, and forbidden changes.
4. `Done when` lists three to eight concrete proofs of completion.
5. `Stop if` lists at least three mechanically detectable conditions that require pausing and returning control to the caller.

Reject vague objectives such as improve or optimize until the observable after-state is specified.
Reject a scope that says only the repository or everything unless the caller supplies an enumerated boundary.
Keep acceptance criteria and stop conditions tied to artifacts, commands, counts, outputs, or named states.

## Render the `/goal`

Render exactly these sections in this order.

```text
/goal <objective with a concrete after-state>.

Scope: <specific files, subsystem, interface, or evidence boundary>.

Constraints:
  - <hard rule>
  - <project default or compatibility rule>

Done when:
  1. <concrete artifact or command result>
  2. <concrete artifact or command result>
  3. <concrete artifact or command result>

Stop if:
  - <mechanically detectable condition>
  - <mechanically detectable condition>
  - <mechanically detectable condition>
```

Every `Done when` item must name an artifact, command result, output, or count.
At least one `Done when` item must require the relevant output to be recorded or shown, not merely an exit code.
For code with existing tests, include a regression guard that forbids rewriting tests solely to make them pass.
For read-only scenarios, require evidence that only the allowed report or documentation files changed and stop if source code changes.
Do not add token budgets, autonomous execution instructions, PR instructions, merge instructions, worktree instructions, or background-process instructions to a goal.

## Auditability check

Score the draft against these ten checks before returning it.

- The objective names a concrete after-state.
- The scope names a bounded location or evidence set.
- No unqualified vague quantifier remains.
- Constraints include applicable project defaults and hard boundaries.
- `Done when` contains three to eight items.
- Each `Done when` item names a concrete proof.
- At least one proof includes recorded output.
- `Stop if` contains at least three conditions.
- Every stop condition is mechanically detectable.
- The artifact is at most 4,000 characters and contains no token-budget directive.

All ten checks are mandatory preconditions for rendering the goal, and a score cannot override a failed check.
Render only when all ten checks pass and report the resulting score as 10/10.
If any check fails, ask the next highest-value clarification question rather than presenting a weak goal.
If a deterministic validator is already supplied by the current task, use it as an additional check, but do not add or install a validator as part of this skill.

## Handoff boundary

Show the final `/goal`, its scenario, its auditability score, and a short rationale for the scope and guards.
Do not claim that the task is implemented or that a card is complete because the goal was rendered.
If the caller asks to execute, dispatch, monitor, commit, push, open, or merge anything, return the ready artifact and state that the separate Firstmate workflow owns that action.
