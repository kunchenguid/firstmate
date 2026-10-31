---
name: project-brain
description: Load before completing a work unit for a project with a configured private brain, or when entering a project through the folder-entry client.
user-invocable: false
metadata:
  internal: true
---

# Project entry and private brain

`docs/configuration.md` owns the [folder-entry](../../../docs/configuration.md#project-folder-entry-configproject-entryjson) and [private brain](../../../docs/configuration.md#project-brains-configproject-brainsjson) contracts.
Use each executable's help for exact commands.

A folder-entry conversation is a client of the registered primary, not a competing supervisor.
Resolve the folder through `fm-entry.sh`, relay its request with a stable request id, and let the primary validate scope and use its existing secondmate parent channel.
An inbox receipt proves durable capture, not model attention or completed delegation.

For each completed work unit in a configured project, the knowledge-owning home records a concise evidence-backed summary with `fm-brain.sh complete` before reporting completion.
Use only the approved source ids; separate observations, recommendations and unresolved questions in the summary body, retaining source chronology rather than presenting a rewritten claim as new evidence.
The writer may be a delegated worker in that same owning home; cross-home outcomes return to their parent for capture through the existing report path.
The executable snapshots explicit inputs, updates interlinked Markdown and rebuilds its structural Connections graph in one atomic generation.
A failure retains the prior generation: report the concrete error and retry the same completion command after correction, without claiming fresh wiki/graph state.
`check` verifies current source fingerprints; `status` also exposes a failed last attempt and stale units.
Teardown's `complete-task` safeguard preserves a richer recorded summary, or adds an evidence-only task reference if none was recorded.
It does not replace the per-unit synthesis step or invent a successful outcome for discarded work.

Keep task state, decisions, preferences and model selection in their existing authoritative owners.
The private wiki is neither public project memory nor a replacement for AGENTS.md/CLAUDE.md.
Read index/source references on demand; do not add the full corpus to startup context.
Graph relationships are exact extracted links, not semantic inference or proof of a claim.
Use the built-in literal query or an independently verified compatible Graphify query interface; no extraction, provider call, global merge or timer is authorized by this workflow.
