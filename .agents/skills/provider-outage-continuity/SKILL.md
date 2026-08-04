---
name: provider-outage-continuity
description: >-
  Agent-only procedure for keeping work moving when a model provider is unavailable.
  Load before classifying a repeated worker or launch failure as a provider outage, before routing new work away from a provider, before moving an in-flight task to another provider, and before switching the primary Firstmate to another provider.
user-invocable: false
metadata:
  internal: true
---

# provider-outage-continuity

This skill is the single owner of the conditional reasoning for provider outages.
`bin/fm-provider-continuity.sh`'s header owns the exact commands, evidence classes, qualification rule, and tunables.
[`docs/configuration.md`](../../../docs/configuration.md) "Crew dispatch profiles" owns the policy schema and "Provider outage continuity" owns the record layout and the primary-switch operator path.
`bin/fm-spawn.sh`'s header owns `--resume-worktree` mechanics.
`quota-array-dispatch` still owns every quota-aware choice among available candidates, and `harness-adapters` still owns harness verification and model/provider discovery.

The guarantee is not zero interruption, which is impossible: an in-progress model response can be lost and provider-dependent work can wait.
The guarantee is no lost local work, no duplicate task owner, safe continuation on another verified provider where the task qualifies, and durable recovery after the primary provider changes.

## Classify before recording

Firstmate classifies; the script never parses agent or provider output.
Record an observation only after the failure is genuinely provider-level and retries are exhausted.

- `provider-5xx`, `provider-connection`, `provider-stream` are the only classes that can qualify an outage.
- `auth` and `config` are credential or configuration problems: report the concrete missing requirement to the captain instead of routing around it.
- `task` is an ordinary task, tool, or local failure and belongs to the task, not the provider.
- `quota` is rate-limit or window exhaustion, a separate concern owned by `quota-axi` and `quota-array-dispatch`; record it for inspection and choose among available candidates there.
- `transient` is a single failure that recovered or was never retried out, including one bare `Error: terminated`.

One observation never qualifies an outage.
Do not record an observation you have not classified, and do not record the same failure twice to reach the threshold faster.
When positive evidence shows a provider recovered before its cooldown ends, use the script's `clear` command rather than waiting.

## Route new work

1. Resolve the task's dispatch rule exactly as usual, producing its concrete `use` profiles.
2. Collect each candidate's declared `provider` token from the profile.
   A profile with no `provider` field is never excluded by outage state; that is what keeps an existing configuration's behavior unchanged.
3. Run the script's `filter` command with those tokens as positional arguments, the rule's `fallback` provider tokens after `--fallback`, and `--exclude <provider>` for a review that must stay independent of the family that produced the work.
4. Dispatch inside the tier the command reports as eligible, then resolve any remaining choice within that tier through `quota-array-dispatch`.
   An outage fallback is not a second quota choice and is consulted only when every primary candidate is unavailable.
5. On `defer`, do not dispatch.
   File the work as a durable backlog item under `decision-hold-lifecycle`'s owner and re-evaluate when the cooldown expires.

An outage never rewrites the captain's dispatch policy: the exclusion is an expiring state over recorded evidence, and eligibility returns on its own.

## Move an in-flight task

Never move a task while its original worker may still own or change it.

1. Read the license with the script's `handoff-check` command for that exact task id.
   It composes the recorded endpoint's own state with the current-code-matched run state, and only `allow` licenses a move.
2. A refusal naming an active or parked validation run means the pipeline still owns that branch.
   Do not change provider during it; follow the ordinary gate flow, and if the gate cannot be answered because the provider is down, report that concrete blocker to the captain.
   A refusal naming an unreadable current state or an unreadable endpoint is a different shape: nothing is proven either way, so resolve that read before considering a move rather than treating it as an absent run.
3. Append a short explicit handoff note to the existing brief: what the previous worker had completed, what remains, and that the branch and uncommitted files are already in place.
   Leave the brief's recorded delivery contract line untouched.
4. Take the license for the actual move with `handoff-attempt`, which records the attempt and applies the same checks plus the repeated-failure cap.
   Relaunch only on `allow`, using `bin/fm-spawn.sh --resume-worktree <recorded worktree>` with the same task id, the same delivery mode and yolo posture, and the alternate profile.
5. A failed relaunch restores the previous record and removes only the endpoint it created; investigate the reported blocker rather than retrying blind.
   Once the cap refuses, stop and report the concrete blocker to the captain.
6. Clear the ledger with `handoff-clear` after a completed handoff.

Never allocate a second isolated copy for a task that already has one, and never let two workers hold the same task.

## Keep the capability fences

Provider continuity moves work between qualified runtimes; it never widens what a runtime may do.

- Preserve cross-family independent review.
  If the only qualified independent family is unavailable, defer that review; a family reviewing its own work is not an acceptable substitute.
- A local model such as Qwen stays inside its already-qualified deterministic text-only scope.
  Continuity never authorizes visual or browser work, production-authenticated work, architecture, security-sensitive, irreversible, ambiguous, migration, or high-stakes work on it.
- A local model is a harness adapter like any other: it must complete `harness-adapters`' verification path before any dispatch, and `bin/fm-spawn.sh` refuses an unverified adapter regardless of outage state.
- When both cloud providers are unavailable, qualified local work and local tests continue.
  Cloud-only, visual, security-sensitive, and independent-review obligations become durable backlog items under `decision-hold-lifecycle`'s owner rather than being downgraded to fit what is still running.

## Switch the primary Firstmate

Keep exactly one live primary per home; never run a standby session against the same home and never remove the session lock by hand.
[`docs/configuration.md`](../../../docs/configuration.md) "Provider outage continuity" owns the exact operator sequence.
Ongoing work is reconciled by the next session start from durable records and live endpoint inventory, so the switch is an ordinary restart rather than a migration.

## Captain-facing wording

Report outcomes, not mechanics (`AGENTS.md` section 9).
Say that a provider is down, which work moved, which work is waiting and why, and what decision or credential is needed.
Do not expose evidence classes, cooldown seconds, record paths, handoff licenses, or isolated-copy mechanics.
