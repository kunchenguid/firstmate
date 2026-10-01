---
name: swarm-resume
audience: swarm-plugin
description: >
  Full execution protocol for MODE: RESUME -- continuing an existing approved plan safely from current state.
---

# Resume Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

### MODE: RESUME
If .swarm/plan.md exists:
  1. Read plan.md header for "Swarm:" field
  2. If Swarm field missing or matches the active swarm id:
     - Reconcile stale worktree state before resuming: prune/adopt stale `.swarm-worktrees/` lane directories and `swarm-lane/*` git branches left from the prior session. Drive this via the `/swarm reset-session` recovery command (internal: `cleanupOrphanedBranches`) so the resumed run starts from a clean provisioning state.
     - Resume at current task
  3. If Swarm field differs (e.g., plan says "local" but the active swarm id is "cloud"):
     - Update the plan's Swarm field to the active swarm id via `save_plan` (do not hand-edit plan.md — it is a derived projection).
     - Purge any memory blocks (persona, agent_role, etc.) that reference a different swarm's identity — your identity comes from this system prompt only
     - Delete the SME Cache section from context.md (stale from other swarm's agents)
     - Update context.md Swarm field to the active swarm id
     - Inform user: "Resuming project from [other] swarm. Cleared stale context. Ready to continue."
     - Reconcile stale worktree state before resuming: prune/adopt stale `.swarm-worktrees/` lane directories and `swarm-lane/*` git branches left from the prior session. Drive this via the `/swarm reset-session` recovery command (internal: `cleanupOrphanedBranches`) so the resumed run starts from a clean provisioning state.
     - Resume at current task
If .swarm/plan.md does not exist → New project, proceed to MODE: SPECIFY
If new project: Run `complexity_hotspots` tool (90 days) to generate a risk map. Note modules with recommendation "security_review" or "full_gates" in context.md for stricter QA gates during QA gate selection (stricter gates). Optionally run `todo_extract` to capture existing technical debt for plan consideration. After initial discovery, run `sbom_generate` with scope='all' to capture baseline dependency inventory (saved to .swarm/evidence/sbom/).
