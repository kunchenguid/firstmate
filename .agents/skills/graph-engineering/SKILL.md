---
name: graph-engineering
description: >-
  Agent-only method for designing and evaluating bounded autonomous improvement loops and deciding whether measured needs justify chains, planning, parallel workers, experiment DAGs, or knowledge graphs.
  Load before proposing or materially expanding an agent loop, multi-agent workflow, experiment-lineage system, or cross-session graph memory.
user-invocable: false
metadata:
  internal: true
---

# Graph engineering

Use this procedure to select the smallest architecture that makes improvement, memory, and evidence explicit.
Firstmate uses it to brief delegated project work and to evaluate the resulting design rather than taking over project-specific implementation.
This skill is the single owner of Firstmate's measured loop-to-graph design procedure.

## Declare the inputs

Require these inputs before selecting an architecture.

- State one bounded objective and the acceptance condition that ends the work.
- Identify mutable surfaces, protected surfaces, permissions, and any decision that still belongs to the captain.
- Name the current retained artifact or state, its version, and the controlled command or process that evaluates a candidate.
- Define the primary metric or rubric, its direction, tie or noise treatment, and guardrails for correctness, security, cost, latency, and resource use.
- Set limits for iterations, retries, tool calls, workers, concurrency, tokens, cost, wall-clock time, and writes as applicable.
- Define how every candidate is checkpointed, restored, and compared with the retained baseline.
- Checkpoint at durable boundaries, and make retried or resumed side effects idempotent or protect them with an idempotency key or compensation.
- Define the trial record, required sources, final evidence, and escalation boundary.
- Define success, plateau, idea-exhaustion, and budget-exhaustion stopping criteria before the first trial.

Do not authorize an unattended improvement loop when success cannot be checked or candidate changes cannot be reversed safely.
Use a human-reviewed path until both conditions exist.

## Run one measured ratchet

Start with one loop and keep each trial narrow enough to attribute its result.

1. Inspect the retained artifact, recent trials, current baseline, constraints, and unresolved failures.
2. Propose one motivated change with a hypothesis, expected metric effect, and observation that would disconfirm it.
3. Save the candidate as an addressable child of the retained version before evaluation.
4. Run the bounded evaluator in the declared environment and capture the primary result, every guardrail, resource use, and raw evidence location.
5. Correct a mechanical execution failure only when the correction does not alter the hypothesis and remains inside the retry budget.
6. Revert any other failed run and preserve its evidence as a failed trial.
7. Keep the candidate only when it beats the retained baseline under the declared comparison rule and passes every guardrail.
8. Restore the retained baseline when the candidate loses, ties without an explicit tie rule, or produces an unreliable comparison.
9. Append the complete trial record and begin the next trial from the retained state rather than the most recent candidate.

A retained result becomes the next baseline, but a rejected result remains useful evidence.
Never hide a crash, rejection, or partial result behind a fluent summary.

## Preserve the evidence contract

Each trial must make these facts recoverable without replaying a conversation.

- Record the objective, parent version, candidate version, hypothesis, and exact change.
- Record the evaluator and rubric version, environment, inputs, command or procedure, and relevant seed or nondeterminism controls.
- Record baseline and candidate values for the primary measure and every guardrail.
- Record elapsed time, resource or financial cost, outputs, source links, and the worker or run that produced them.
- Record whether the candidate was retained, reverted, crashed, or left unresolved, with the comparison reason.
- Mark every material claim with a source, or label it explicitly as inference or unresolved uncertainty.

Keep artifacts immutable and addressable after they are superseded.
Return task-specific evidence rather than worker transcripts as the handoff surface.

## Add architecture only for a measured failure

Distinguish acyclic execution or lineage DAGs, cyclic state graphs, runtime-generated task graphs, and domain knowledge graphs; multi-agent coordination is orthogonal to all four.
Climb this ladder only when the current rung has exposed the named limitation and the next rung has a measurable exit criterion.

1. Add one tool when a repeated error comes from a missing capability, and give the tool typed inputs, minimum permissions, and result confirmation.
2. Add a chain when the stages and handoff order are stable.
3. Add planning only when valid task paths vary, and require explicit dependencies and success conditions before execution.
4. Add parallel workers only after ruling out dependencies through required data, shared mutable resources, exclusive tools, rate limits, or coupled writes and defining isolation, artifact contracts, a reducer, deduplication, concurrency limits, and a final evaluation.
5. Add a distinct critic or evaluator when its rubric and evidence can catch a demonstrated generator failure rather than merely repeat the generator's opinion.
6. Add a commit or artifact DAG when alternative lineages, parentage, or discarded experiments must remain traversable.
7. Add persistent graph memory only when connected facts, provenance, conflicts, or cross-session queries cannot be served adequately by versioned files or relational tables.
8. Add dynamic swarms only when the workload is safely parallel and measurements show a wall-clock benefit without unacceptable quality or cost loss.

Keep experiment lineage and domain knowledge as separate models even when links connect them.
Retrieve a bounded, task-relevant subgraph with provenance and conflicts rather than dumping shared memory into every worker's context.
Keep execution flow separate from context flow: an execution edge does not pass a whole transcript; hand off only the required versioned artifacts and evidence.
Use reversible, evidence-backed entity resolution because one false merge can contaminate many later queries.
Drop back to the simpler rung when the promised exit criterion is not met.

## Stop and return

Stop the loop at the first applicable condition.

- Stop when the acceptance threshold or evaluator approval is reached.
- Stop when any declared budget is exhausted.
- Stop at the declared plateau or idea-exhaustion condition.
- Stop when crashes, evaluator instability, or irreproducible results make comparison unreliable.
- Stop and escalate before destructive, irreversible, security-sensitive, protected-surface, or contract-expanding action.
- Stop and escalate when contradictory evidence or unresolved uncertainty can materially change what should be built.

Return the best retained artifact rather than the last candidate.
Include the stopping reason, trial ledger, consumed budget, discarded but relevant evidence, and unresolved questions.

## Reject these anti-patterns

- Do not optimize activity, worker count, or a single visible metric while ignoring guardrails.
- Do not combine unrelated changes in one trial when attribution matters.
- Do not fan out work before defining the reducer and final evaluation.
- Do not parallelize coupled writes merely because more workers are available.
- Do not treat conversations as the artifact store, experiment history, or durable world model.
- Do not introduce a graph merely because agents are involved when files or tables answer the required queries.
- Do not collapse experiment lineage into the knowledge graph or mistake either graph for verified truth.
- Do not use an evaluator that shares the same unsupported assumptions, evidence, and prompt as the generator.
- Do not let retries, branches, graph writes, or stored history grow without declared limits and retention policy.

## Source provenance

This procedure is an original operational synthesis of an independently compiled July 2026 *Graph Engineering* paper supplied for this task.
The paper attributes the measured autonomous loop and experiment-DAG direction to Andrej Karpathy's autoresearch and AgentHub work, and it attributes workflow and knowledge-graph patterns to Anthropic materials.
Consult those primary sources before relying on historical, performance, or product-specific claims because this skill retains only the reusable method.
