---
name: orchestrated-delivery
description: >-
  Load before briefing a delegated task as an orchestrated role pipeline, or when leading that pipeline.
  Applies only to genuinely complex or risky tasks or an explicit captain request, not ordinary delegated work.
user-invocable: false
metadata:
  internal: true
---

# Orchestrated delivery

## Select the delivery shape

Use orchestration only when the task is genuinely complex or risky, or the captain explicitly requested it.
Ordinary delegated work stays with one worker rather than acquiring this pipeline by default.
Firstmate launches one ordinary orchestrator crewmate through `bin/fm-spawn.sh`, using harness `pi`, model `openai-codex/gpt-6-astra`, and this task's assessed effort.
The orchestrator receives the task brief and owns planning, role selection, handoffs, and the whole pipeline.
Dispatch prerequisites remain owned by [AGENTS.md section 4](../../../AGENTS.md#4-harness-and-runtime-dispatch) and [harness-adapters](../harness-adapters/SKILL.md).
Firstmate supervises only the orchestrator endpoint and never tracks individual sub-agents.

## Choose the smallest sufficient roster

| Role | Agent definition | Purpose |
| --- | --- | --- |
| Explorer | [`fm-orchestrated-explorer`](agents/fm-orchestrated-explorer.md) | Map relevant code, behavior, dependencies, and unknowns. |
| Researcher | [`fm-orchestrated-researcher`](agents/fm-orchestrated-researcher.md) | Resolve external knowledge gaps with primary-source evidence. |
| Worker | [`fm-orchestrated-worker`](agents/fm-orchestrated-worker.md) | Implement the accepted change against explicit criteria. |
| Tester | [`fm-orchestrated-tester`](agents/fm-orchestrated-tester.md) | Exercise the implementation and report reproducible results. |
| Reviewer | [`fm-orchestrated-reviewer`](agents/fm-orchestrated-reviewer.md) | Independently assess correctness and scope in a fresh context. |
| Integrator | [`fm-orchestrated-integrator`](agents/fm-orchestrated-integrator.md) | Verify the final joined or landed result against the accepted criteria. |

Each linked definition owns its exact model, tool allowlist, and fresh-session mode.
Effort is this task's assessed class, not a per-role pin.
Use these role definitions, not the package's generic `worker`, `scout`, or `researcher` profiles.

The orchestrator records the selected roles and the concrete coverage reason for each before spawning them.
Any implementation requires the minimum chain Worker -> Tester -> Reviewer.
Add Explorer only for real unknowns about the repository or existing behavior, and Researcher only for real unknowns requiring external evidence; name the unanswered question before adding either.
Add Integrator when the task's final state must be verified after joining or landing, rather than relying on checks against separate or earlier results.
Knowledge-only tasks select the evidence-producing roles they need without inventing implementation stages.
The roster is not fixed: omit every optional role whose coverage condition is absent.

## Verify sub-agent support before using the roster

The `subagent` tool is supplied by the installed [pi-interactive-subagents package](https://github.com/amosblomqvist/pi-interactive-subagents), not Pi core or Firstmate scripts.
Check `pi list`, the loaded tool schema, and the installed package's README and launch implementation before claiming the selected roster is runnable.
The installed fork requires tmux, an orchestrator running inside it, and a saved Pi session; a Pi crewmate does not gain usable sub-agents merely by being on Pi.
Keep the orchestrator as the ordinary Firstmate-launched crewmate; the role definitions grant no further spawning.
Use `subagents_list` for discovery, never to poll running children.
Verify the selected definitions resolve as global and match their linked source files, including `session-mode`; report a project override or incompatible installed package to firstmate rather than dispatching a different roster.

Every Pi-family launch through `fm-spawn` provisions the namespaced definitions into the same global agent directory that the new process reads, through [`bin/fm-pi-role-agents.py`](../../../bin/fm-pi-role-agents.py).
That script's help owns the directory resolution, conflict checks, and update mechanics.
Global discovery reaches arbitrary project worktrees without adding project-local resources, changing project trust, or requiring a trust dialog for these definitions.
Existing project resources retain Pi's normal trust behavior; this provisioning does not approve them.
The sub-agent package itself and tmux must already be installed.
These definitions do not declare `thinking`.
The package appends thinking to the model at launch, so pass `model` as `<that definition's model>:<task effort>` and keep the definition's model pin.
Read the class from this crewmate's `effort=` metadata; use it only when it is one of `low`, `medium`, `high`, `xhigh`, or `max`, otherwise omit the suffix rather than inventing `max`.
Keep the roster pins intact; a changed installed package still requires checking the effective loadout rather than assuming its behavior.
[Runtime verification](../../../docs/verification/runtime-backends.md#orchestrated-pi-role-definitions) records the live six-role proof and its refresh command.

## Spawn and carry the handoff

After the support check passes, call `subagent` with the table's `agent` definition, a unique role-specific `name`, the absolute task-worktree `cwd`, and a self-contained `task`.
For example, the Worker call shape is `subagent({agent: "fm-orchestrated-worker", name: "worker-implementation", cwd: taskWorktree, model: "openai-codex/gpt-5.6-luna:<task-effort>", task: handoff})`.
The `model` argument carries that role's pinned model plus this task's effort; it is not a model substitution.
The `name` labels a role and does not select its definition.
Create the Reviewer with `fm-orchestrated-reviewer` and a fresh name on every review, never by resuming an earlier session; its definition selects `standalone`.
The Reviewer must never be the agent that implemented the change under review.
Give Tester, Reviewer, and Integrator verification-only assignments rather than the general worker's implementation remit.

Every handoff carries the accepted task scope, acceptance criteria, constraints, selected delivery path, task-worktree boundary, relevant files and revision or diff identity, evidence so far, unresolved questions, and the receiving role's precise deliverable.
Pass evidence and reproduction instructions, not an assumption that a fresh session remembers earlier turns.
These role handoffs prepare the task deliverable; the selected delivery path and landing gates remain owned by [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle).

1. Resolve the selected Explorer and Researcher questions before planning changes that depend on their answers.
   Explorer returns a code map and observed behavior; Researcher returns sourced findings and remaining uncertainty.
   Independent questions may run concurrently.
2. The orchestrator turns those findings, or the already sufficient brief, into a bounded implementation handoff for Worker.
   Worker returns the change summary, exact changed-state identity, criteria covered, and any known gaps.
3. Tester receives that implementation plus the criteria and exercises the relevant end-user behavior and regressions.
   Its handoff includes exact commands or steps, results, failures, and untested limits tied to the tested state.
4. Reviewer receives the accepted criteria, diff, and test evidence in its fresh context.
   It returns actionable findings or a supported clean assessment, with each finding tied to the reviewed state and criterion.
5. Before selected delivery validation begins, corrections go back through Worker -> Tester -> a fresh Reviewer so earlier evidence is not reused for changed code.
   Delivery validation and finding ownership after that point remain with [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle), not a competing sub-agent fix loop.
6. When selected, Integrator receives the component results, join or landing identity, review findings and resolutions, and prior test evidence.
   It verifies the actual final state and reports discrepancies or evidence that the joined result satisfies the criteria; this assignment grants no landing authority.

The tool returns an acknowledgement immediately, then delivers each completed result asynchronously to the orchestrator, not firstmate.
After spawning, work on independent tasks or end the turn for automatic result delivery; never poll or infer completion from the acknowledgement.

## Boundaries and reporting

Every sub-agent stays inside the orchestrator's task worktree and receives that boundary explicitly; `cwd` selects a directory, not a filesystem sandbox.
The orchestrator coordinates writes and verification so evidence refers to a stable result rather than another role's changing files.
Sub-agents' prohibition on addressing the captain is owned by [AGENTS.md section 1](../../../AGENTS.md#1-identity-and-prime-directives).
For destructive, irreversible, outward-facing, and security-sensitive actions, preserve the accepted task scope and the authority boundaries in [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle).
A sub-agent needing a decision uses `ask_question` to return it to the orchestrator, which routes it through the normal `needs-decision` path in [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle).

Only the orchestrator writes Firstmate status reports; child summaries and questions return through the sub-agent tools.
Emit sparse `working:` lines naming the current role and gate when that transition matters to supervision, and one `done:` or `failed:` line for the delivery outcome.
The existing status protocol and lifecycle completion criteria remain owned by [AGENTS.md section 7](../../../AGENTS.md#7-task-lifecycle) and the generated task brief.
