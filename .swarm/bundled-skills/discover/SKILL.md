---
name: discover
audience: swarm-plugin
description: >
  Full execution protocol for MODE: DISCOVER -- read-only repository discovery and governance/context mapping.
---

# Discover Protocol

This protocol is loaded on demand by the architect runtime. The architect prompt keeps only activation, action, and hard safety constraints; the full execution details live here.

### MODE: DISCOVER
Delegate to the active swarm's explorer agent. Wait for response.
For complex tasks, make a second explorer call focused on risk/gap analysis:
- Hidden requirements, unstated assumptions, scope risks
- Existing patterns that the implementation must follow
After explorer returns:
- Run `symbols` tool on key files identified by explorer to understand public API surfaces
- For multi-file module surveys: prefer `batch_symbols` over sequential single-file symbols calls
- Run `complexity_hotspots` if not already run during project discovery (check context.md for existing analysis). Note modules with recommendation "security_review" or "full_gates" in context.md.
- Check for project governance files using the `glob` tool with patterns `project-instructions.md`, `docs/project-instructions.md`, `CONTRIBUTING.md`, `INSTRUCTIONS.md`, `AGENTS.md`, and `CLAUDE.md` (process all matches found). For each file found: read it and extract all MUST (mandatory constraints) and SHOULD (recommended practices) rules. Write the extracted rules to `.swarm/context.md` under a `## Project Governance` section — append if the section exists, create it if not — PRESERVING PROVENANCE for every rule (issue #2131 finding 9): each entry records (a) its source file, (b) the subtree scope the file declares or implies (repo-wide when undeclared), (c) precedence — `AGENTS.md`/`project-instructions.md` outrank `CONTRIBUTING.md`/`INSTRUCTIONS.md`/`CLAUDE.md` when rules conflict, (d) strength (MUST vs SHOULD), and (e) a conflict flag naming the other file whose rule it contradicts, if any. Never flatten conflicting rules into one; surface the conflict. If no MUST or SHOULD rules are found in the file, skip writing. If no governance file is found: skip silently. Existing DISCOVER steps are unchanged.
