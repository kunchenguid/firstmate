---
name: specialist-tools
description: >-
  Route one task to the captain-approved ECC, paperthin, or ultrawork specialist path without loading an entire tool catalog into context.
user-invocable: false
metadata:
  internal: true
---

# Specialist tool routing

Load this skill before selecting a specialist path for a task.
Select at most one specialist by default.
Keep Firstmate as the owner of intake, worktree, quota, approval, state, review, delivery, and merge authority.

## Selection

| tool | select for | load behavior |
| --- | --- | --- |
| `ecc` | focused code review, security review, TDD, architecture, or verification workflow | Discover the matching skill in the installed native ECC catalog, then load only that `SKILL.md`. Do not load the catalog, all agents, hooks, MCP definitions, or memory into the prompt. |
| `paperthin` | code hygiene, scope reduction, SSOT, fact checking, memory curation, or repository cleanup | Discover one matching installed paperthin skill such as `re0-*`, `ssotize`, `dedash`, `reorder`, `debloat`, `factchk`, `mandela`, or `readchk`, then load only that skill. |
| `ultrawork` (`lazy codex`) | captain-requested maximum verification or work with an explicit heavy verification need | Invoke the existing `/ultrawork` or `/ulw` path once. Do not additionally load ECC or paperthin unless the captain explicitly requests a comparison. |

If no specialist matches, use the ordinary Firstmate path.
Do not select a specialist merely because it is installed.

## ECC boundary

Use the native `ecc@ecc` Codex plugin installation.
Never run ECC's deprecated legacy sync into `~/.codex`.
Treat ECC hooks, MCP servers, and guided global configuration as separate opt-in surfaces; do not trust, start, or configure them as part of ordinary task intake.
Installing the full package does not authorize those surfaces.

Resolve the ECC skill path from the current plugin registration or its cache; never hardcode a user-specific absolute path.
Search names and descriptions, choose the smallest matching skill, and read its body only after selection.
Record the selected tool and skill in the task brief so review can reproduce the route.
If the plugin is missing or its catalog cannot be resolved, report `MISSING_MANUAL` and stop specialist dispatch rather than falling back silently.

## Cost boundary

Do not preload any specialist catalog, agent collection, reference tree, or full tool description.
Pass the selected skill name and one-sentence reason to the worker.
Reuse the current Firstmate quota and harness gates; specialist selection never bypasses authentication, quota, isolation, or independent review requirements.
