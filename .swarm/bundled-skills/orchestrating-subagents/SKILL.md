---
name: orchestrating-subagents
audience: swarm-plugin
description: >
  Tiering and economics for delegating to subagents: which agent type, model,
  and effort to use per role (explorer, implementer, reviewer, critic), how many
  agents to launch in parallel, how to write scoped subagent prompts with
  bounded structured returns, and how to keep the main context clean. Use when
  launching subagents, parallel explorers, independent reviewers, or critic
  passes — especially for swarm-mode, qa-sweep, or issue-tracer work.
---

# Orchestrating Subagents

Swarm-mode work in this repo delegates heavily (explorer → reviewer → critic).
This skill defines HOW to delegate so validation gates stay strong while
breadth stays fast and cheap. It complements — never replaces — the gates in
`.claude/session/swarm-mode.md`, qa-sweep, and swarm-implement.

## Role → tier mapping

| Role | Agent type | Model / effort | Rationale |
|---|---|---|---|
| Explorer (mapping, candidate findings) | `Explore` when read-only suffices | Cheaper/faster tier acceptable; low–medium effort | Recall-bound, not reasoning-bound; the reviewer gate catches misses |
| Implementer (scoped edits) | general-purpose | Session model; medium–high effort | Edits need project conventions (CLAUDE.md context) |
| Reviewer (independent validation) | general-purpose, **fresh context** | Session (strongest) model; high effort | Precision-bound; false approvals are the expensive failure |
| Critic (final challenge) | general-purpose, **fresh context** | Session (strongest) model; high effort | Same — this is the last line of defense |

Hard rule: economize on explorers, never on reviewers or critics. If the
harness exposes model or effort overrides for subagents, tier explorers down;
do not tier the reviewer or critic below the session model or below high
effort. If no override is available, tier by agent type (`Explore` is
lightweight: read-only tools, skips CLAUDE.md) and by prompt scope.

## Fan-out discipline

- Launch parallel agents only for **disjoint scopes**. Before launching, write
  one line per agent stating its scope; if two overlap, merge them.
- 2–4 explorers per wave is a heuristic only when the active workflow does
  not define its own fan-out contract. A workflow-specific contract overrides
  this heuristic: PR review, for example, requires all six base dimensions and
  all eleven risk families to be covered on every PR — its capability profiles
  and depth tiers (see swarm-pr-review) govern how many lanes carry that
  coverage, and under the plugin's mechanical controller the tier is computed
  from the bound diff and the matching lane floors are enforced outright. No
  time, cost, repository-size, or simplicity
  rationale may reduce the coverage a workflow mandates.
  Outside fixed-fan-out workflows, more agents than distinct scopes adds token
  cost and synthesis burden without adding recall.
- Launch independent agents **in a single message** so they run concurrently.
- Do not re-run a search an agent is already doing; wait for its report.
- Scale waves, not width: if the first wave surfaces new territory, launch a
  second targeted wave rather than one giant speculative first wave.

## Subagent prompt contract

Every delegation prompt must state:

1. **Scope** — exact directories, files, or question. Name what is out of scope.
2. **Deliverable** — the structure of the report (per-item findings, then a
   ranked summary). The agent's final message is the only thing you receive.
3. **Evidence bar** — exact `file:line` references; no invented paths; verify a
   path exists before citing it.
4. **Status labels** — explorers return CANDIDATE findings only; reviewers
   classify CONFIRMED / DISPROVED / UNVERIFIED / PRE_EXISTING; reviewer and
   critic verdicts are APPROVE / NEEDS_REVISION / BLOCKED.
5. **Output bound** — compact structured returns; no full-file dumps.

For reviewers and critics additionally:
- Give the **claims and locations**, not the author's justification — the
  reviewer must re-derive, not confirm, the reasoning.
- State the adversarial default explicitly: "default to DISPROVED/UNVERIFIED
  unless the code evidence supports the finding."
- A reviewer or critic must be a **fresh agent**, never a continued
  conversation with the agent whose work it judges.

## Independence and staleness

- Reviewer and critic review the **latest diff**, not a description of it. Give
  them the branch state and the validation evidence, and require them to run
  `git diff`/`git log` themselves.
- Any edit after an approval invalidates it. Record what was approved (e.g.
  `git rev-parse HEAD`, `git diff --stat`) so staleness is checkable — see the
  durable-session-state skill.

## Nesting limitation

Whether a subagent can spawn further subagents depends on the harness and
agent type — check whether a subagent tool (`Agent` or `Task`) is actually
available in your context before assuming either way. If a skill mandating
fresh-subagent review (qa-sweep, swarm-implement) executes in a context
**without** a subagent tool:
- perform the same review checklist yourself as a clearly labeled
  **fallback self-review**, and
- disclose in your report that independent review was unavailable in this
  context, so the orchestrator can re-run the gate with a real fresh agent.
Never silently present self-review as independent review.

## Main-context hygiene

- Push reading-heavy work into subagents; keep the main thread for scoping,
  synthesis, and decisions.
- Do not paste subagent transcripts or large tool outputs back into the main
  thread; carry forward only validated findings and verdicts.
- When a subagent report arrives, extract the load-bearing facts into your
  durable task artifacts (see durable-session-state) before moving on.

## When not to delegate

Answer directly, without a subagent, when the task is a single-fact lookup you
can resolve with one or two targeted Grep/Read calls, or when you already know
the file and symbol. Delegation overhead should buy breadth, isolation, or
independence — if it buys none of those, skip it.
