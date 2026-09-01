# pstack principles index

Load only a principle whose trigger changes a concrete decision.
Project rules, current source, live evidence, and Captain authority outrank this index.
These grouped entries preserve the useful pstack vocabulary without installing the upstream principle skills.

## Smallest sufficient change

Use when sizing, refactoring, or feeling pressure to add abstraction.
Delete dead weight and redundant paths before adding structure.
Prefer one end-to-end correction at the owning seam over caller-specific guards, compatibility layers, or speculative configuration.
Keep security, accessibility, public compatibility, and accepted behavior intact.

## Foundational shape and boundaries

Use before new state, cross-module behavior, persistence, network, or third-party data.
Name entities, states, ownership, authoritative sources, and failure modes before spreading conditionals.
Parse and validate untrusted data at the boundary, then keep the core decision path narrow.
Use a registry, table, state machine, or type only when its invariant reduces reader load or invalid states.

## Minimize reader load

Use when code, instructions, or receipts are hard to follow.
Reduce layers, hidden mutable state, and one-caller wrappers that add no policy.
Keep large evidence outside the main conversation and return a pointer, result, and gap.
Do not shorten a real safety boundary merely to reduce line count.

## Explore before committing

Use for novel architecture, material UX direction, or an empirical choice with no trusted precedent.
Build two or three cheap, materially distinct candidates only when the decision warrants it.
Compare them against named observable criteria and keep only verified improvements.
Do not make a human choose a fact that a bounded probe can reveal.

## Idempotence and reconciliation

Use for retries, crashes, jobs, migrations, lifecycle commands, and external writes.
Ask whether two executions and a crash at each boundary converge to one valid state.
Use an idempotency key, dedupe record, or receipt when the outcome may be unknown.
Read back the exact external state instead of treating a successful command return as proof.

## Separate before serializing

Use when workers or processes might share a worktree, output, database, port, branch, or frontend surface.
First remove sharing with isolated copies, outputs, resources, or ownership.
Serialize only when one writer is a real domain invariant, and then use the existing lock or transaction owner.
A read-only brief is not a sandbox; inspect the diff and artifact after delegated work.

## Prove the real outcome

Use before every completion claim.
Run the command, flow, migration, trace, or live readback that matches the requested behavior.
Keep local, remote, merged, deployed, live, and user-verified proof distinct.
Make a repeated check a small rerunnable script or project harness when the same proxy failure recurs.

## Sequence verifiable units

Use for multi-step delivery, migration, and long-running work.
End each unit in a working, reviewable state with its own artifact and check.
Do not start downstream work on an unverified upstream claim.
For shared contracts, isolate the temporary red state or use a compatible migration instead of exposing it to another writer.

## Build the lever and encode lessons

Use when a manual proof or correction will repeat.
Prefer the smallest tested validator, CLI, fixture, receipt, skill patch, or project rule that makes the lesson rerunnable.
Do not build a platform for one narrow case.
Place durable knowledge with its existing owner instead of adding another copy to `AGENTS.md`.
