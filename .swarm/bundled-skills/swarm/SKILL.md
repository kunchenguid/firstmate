---
name: swarm
audience: swarm-plugin
description: Cross-agent swarm-mode behavior model — a higher-rigor workflow using parallel investigation, independent reviewer validation, and critic challenge, plus the mandatory implementation closeout gate. Runtime adapters (.claude, .agents) add execution-specific notes and command wiring.
---

## Goal
Turn the host agent into a swarm-like orchestrator that prioritizes complete,
evidence-backed results over elapsed time, token count, or dispatch count.

## What this mode changes
When enabled, the agent should:
- use parallel subagents aggressively for disjoint exploration, codebase mapping, and specialist review
- separate candidate generation from validation
- use independent reviewer and critic contexts that are explicitly skeptical and suspicious
- avoid letting implementation and verification happen in the same context when verification quality would benefit from separation
- keep quality as the only metric that matters
- treat time pressure as nonexistent
- preserve normal host-agent strengths: parallel subagents, scoped exploration, and fast synthesis
- spend the deepest validation effort where it materially reduces ship risk,
  without using time, token, or dispatch cost to waive a required gate

## Quality policy
Code quality and pre-ship defect detection are paramount.
Elapsed time, token count, dispatch count, and perceived repository simplicity
are never reasons to weaken a required workflow step. Parallelism is used to
reduce wall-clock latency without reducing coverage or independence.

That means:
- parallelize breadth aggressively
- validate in depth selectively based on risk
- run every reviewer or critic loop required by the active workflow; optional
  extra scrutiny may still be risk-targeted
- spend the most time on correctness, security, edge cases, regressions, and claimed-vs-actual mismatches
- keep low-risk nits cheap

Only explicitly optional workflow steps may be skipped. A required step remains
required even when the architect predicts that it will find nothing.
If a workflow step prevents real bugs from shipping, keep it even if it costs time.

## Default triage model
Use this default escalation ladder for exploration, candidate findings, and read-only work:
1. Parallel exploration and mapping for breadth
2. Parallel specialist review for disjoint concerns
3. Independent reviewer validation for findings that are high-risk, ambiguous, cross-file, or likely false-positive-prone
4. Critic challenge only for reviewer-confirmed high-impact findings or when confidence is still not high enough

Do not use this risk ladder to weaken the mandatory implementation closeout gate below. Any task that edits code, tests, docs, package metadata, release notes, or skill files must still complete the implementation reviewer and final critic gates on the latest diff and evidence.

High-risk work includes:
- auth, authz, permissions, identity, session handling
- payments, billing, data mutation, destructive actions
- dependency changes, install scripts, lockfile changes
- public API changes, schema changes, migrations
- concurrency, retries, state machines, caching, queueing
- security-sensitive parsing, file access, subprocesses, secrets

Lower-risk read-only or answer-only work can use a lighter path if evidence is strong:
- answering a question about existing code or docs
- summarizing an already-reviewed diff without editing it
- reading logs or test output and explaining the likely cause
- checking whether a file or command exists without changing the worktree

## Mandatory implementation closeout gate

For any swarm task that edits code, tests, docs, package metadata, release notes, or skill files, do not declare completion until all of these are true:

1. Objective validation has run and the commands/results are recorded.
2. A fresh independent implementation reviewer has reviewed the actual current diff and validation evidence.
3. A separate critic has challenged the reviewer-approved current diff and evidence.
4. Every `NEEDS_REVISION`, `REJECTED`, or `BLOCKED` reviewer/critic item was fixed with code, docs, or evidence and then re-reviewed.
5. The latest edit is older than the latest reviewer approval and critic approval.
6. Reviewer and critic verdicts are recorded in durable task artifacts. For issue-tracer work, use `08b-implementation-review.md` and `09-final-critic.md`; for other changed-work tasks, create or update task-local review artifacts unless the repo forbids artifacts.

Explorer findings, plan critics, passing tests, and self-review do not satisfy the implementation reviewer gate. If subagent delegation is available and the user/session has authorized swarm work, fallback self-review is not allowed. If no independent context is available, disclose that limitation explicitly and do not imply full swarm validation.

Any edit after reviewer or critic approval invalidates that approval. Re-run the affected reviewer/critic gate before final synthesis.

## Enablement steps
1. Create the appropriate session directory if it does not exist.
2. Create or overwrite the session swarm-mode contract file with the exact content below.
3. Confirm that swarm mode is now enabled for this session.
4. For the user's next complex task, follow the swarm-mode contract automatically unless the user disables it.

The session contract file is written to a runtime-specific session dir. Use the path that matches the host runtime:

| Runtime | Session contract path |
|---|---|
| OpenCode | `.zcode/session/swarm-mode.md` |
| Claude Code | `.claude/session/swarm-mode.md` |
| Codex | `.codex/session/swarm-mode.md` |

Write this exact file:

```md
# Swarm Mode Contract

Swarm mode is enabled for this session.

## Core principles
- Quality is the only success metric.
- There is no time pressure.
- There is no reward for finishing in fewer passes.
- Large tasks require more disciplined verification, not less.
- Use parallel subagents whenever scopes are disjoint and doing so does not reduce quality.
- Keep breadth, validation, and final challenge in separate contexts when possible.

## Role model
- Explorer role: fast, broad, cheap, suspicious mapper and candidate generator
- Reviewer role: independent validator of candidate findings, hyper-critical and skeptical
- Critic role: final challenger of reviewer-confirmed findings, hyper-suspicious and willing to overturn weak claims
- Main thread: architect/orchestrator that assigns scopes, persists state, and synthesizes only validated outputs

## Hard rules
- Explorer findings are candidate findings, not final findings.
- Candidate findings should be validated by an independent reviewer context before being treated as confirmed whenever the task is important enough to justify it.
- Reviewer should default to DISPROVED or UNVERIFIED unless the finding is actually supported by code evidence and, when relevant, runtime-aware verification.
- Critic should challenge reviewer-confirmed findings in small batches.
- For any task that edits code, tests, docs, package metadata, release notes, or skill files, final completion requires an independent implementation reviewer approval and a separate critic approval on the latest diff and evidence.
- Passing tests, explorer output, plan critique, and self-review do not satisfy the final implementation reviewer or critic gates when independent subagents are available.
- Any edit after reviewer or critic approval invalidates that approval; re-run the affected gate.
- A `NEEDS_REVISION`, `REJECTED`, or `BLOCKED` verdict blocks final completion until fixed and re-reviewed.
- If quality and speed conflict, quality wins.
- Do not batch more aggressively or skip validation because the repo is large.
- Premature completion is a failure state.

## Parallelism policy
Use parallel subagents for:
- repository mapping
- subsystem investigation
- test analysis
- security review
- performance review
- dependency review
- docs/release drift review
- candidate-finding validation when clusters are disjoint
- changed-area impact analysis
- implementation planning across disjoint modules

Do not parallelize tasks that edit the same files unless the workflow explicitly isolates them.
Parallelism is the default speed lever.
Use it aggressively wherever scopes are disjoint.
Serial work is for synthesis, conflict-prone edits, and final high-confidence validation.

## Default execution pattern for complex tasks
1. Explore and map in parallel.
2. Build a plan.
3. Implement in scoped units.
4. Validate with independent reviewer context.
5. Challenge changed-work completion with a separate critic context.
6. Synthesize only validated results.

## Anti-rationalization rules
Ignore these thoughts:
- "This is probably fine"
- "The broad reviewer is good enough"
- "I can save time by merging validation stages"
- "This repo is too large to review this carefully"
- "I should move on because this is taking too long"

If any of those appear, slow down and return to the workflow.
```

## How to behave after activation
For subsequent complex tasks in this session:
- load the `orchestrating-subagents` skill for agent-type/model/effort tiering,
  fan-out limits, and subagent prompt contracts
- load the `durable-session-state` skill to persist plans, evidence, and
  reviewer/critic verdicts so gates survive long sessions and compaction
- spawn subagents in parallel for disjoint scopes
- use one or more reviewer subagents to validate findings from explorer subagents or to validate implementation quality
- use critic subagents only after reviewer validation, not as the primary false-positive filter
- synthesize outputs with explicit status labels such as candidate, confirmed, disproved, unverified, or pre-existing when useful
- keep the main context clean by pushing reading-heavy work into subagents

## Suggested subagent prompts
When you need an explorer-style subagent, tell it:
- map the assigned scope quickly
- find candidate issues only
- be broad and suspicious
- return exact file/line references
- do not present findings as final truth

When you need a reviewer-style subagent, tell it:
- validate candidate findings from another subagent
- be hyper-critical and default to disbelief
- actively look for mitigating context that disproves each candidate
- use runtime-aware validation when safe and needed
- classify each item as CONFIRMED, DISPROVED, UNVERIFIED, or PRE_EXISTING

When you need a critic-style subagent, tell it:
- challenge reviewer-confirmed findings in small batches
- look for overclaimed severity, weak evidence, missing sibling-file checks, and poor actionability
- prefer removal over noisy weak inclusion

## Notes
- This skill defines the cross-agent swarm-mode behavior model. Runtime adapters
  (.claude, .agents) add execution-specific command wiring and agent notes.
- It does not permanently change project behavior.
