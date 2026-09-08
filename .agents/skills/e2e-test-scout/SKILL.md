---
name: e2e-test-scout
description: >-
  Agent-only procedure for scaffolding and dispatching an E2E test-scout task.
  Use before resolving board-source or no-story routing, before calling
  bin/fm-brief.sh --test-scout, and before spawning the resulting scout.
  Owns --source selection, the no-story front door, harness pin, grounding
  techniques, and Phase-1 trust posture; the generated brief owns the fixed pipeline text.
user-invocable: false
metadata:
  internal: true
---

# e2e-test-scout

Load this before scaffolding or dispatching an E2E test-scout task, and before resolving board-source or no-story routing.
`bin/fm-brief.sh --test-scout --source <ado|jira|none>` owns the generated pipeline boilerplate, copy-out checklist, and trust-posture sentence.
This skill owns the judgment calls that brief text cannot encode.

## Harness pin

Pin `claude` for the E2E execution worker.
The underlying `story-export`, `test-case-generation`, and `test-execution` skills are Claude Code personal skills installed under `~/.claude/wep-core` (or the equivalent installed location).
Do not treat this capability as harness-agnostic: another harness will not auto-load those skills.

## Resolve `--source`

Choose exactly one before scaffolding:

1. Azure DevOps board exists for the project -> `--source ado` (worker runs `story-export` first; put org/project details in the filled Task).
2. Jira board exists instead -> `--source jira` (worker uses `jra-axi` from `github.com/lytv/jira-axi` to pull the same title/description/acceptance-criteria shape).
3. No board, but an already captain-approved requirements file is on disk -> `--source none` and put that absolute path in `{TASK}`.

`--source none` means only "the story is already approved and on disk".
It is never the answer to "there is no story yet".

## No-story front door

When there is no board AND no already-approved requirements file, do not scaffold `--test-scout` yet.
Route through the `ba-requirements` discuss/plan/execute skills in `~/.claude/wep-core` (or the equivalent installed location) to draft a story and obtain the captain's explicit approval first.
Only after that approval may you hand-author a requirements file and then scaffold with `--source none`.

For a solo or no-board project (as with math-island): draft from available material (README, live exploration), present the draft to the captain, get sign-off, write the approved file, then proceed with `--source none`.
Never let a worker invent acceptance criteria as a silent test oracle.

## Grounding techniques

Two techniques from the math-island run are approved and must be named in the Task or report when used:

1. **Direct interaction-event dispatch.** When no accessible role, label, or test-id exists (raw canvas or hand-rolled graphic), dispatch the interaction event on the element instead of forcing a click that keeps missing, and flag those cases low-confidence.
2. **Deterministic state seeding.** When app state lives only in the browser and live navigation would be flaky or slow, seeding the app's own persisted state to reach a screen deterministically is approved; record what was seeded, why, and which production path it bypassed.

## Trust posture

Every test-scout report states its findings as unconfirmed pending captain review.
There is no automated trust gate in this phase.
Do not add a parsed or free-text `yoloqa` field to the project registry.

## Scaffold and fill

After `--source` is resolved and any no-story front door has closed:

```sh
bin/fm-brief.sh <task-id> <repo-name> --test-scout --source <ado|jira|none> [--herdr-lab]
```

Fill `## Captain's intent` (`{TASK}`) with the target URL, requirements-source specifics (export scope, Jira query, or approved file path plus provenance), and scope.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with any Firstmate build constraints for this run.
Run `bin/fm-spawn.sh <task-id> <project-dir> --scout --harness claude`.
`KIND` remains scout.
