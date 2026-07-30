---
name: code-intelligence-routing
description: >-
  Agent-only routing for CodeGraph and Graphify during coding and code-focused investigation.
  Use before repository inspection or edits to choose the proportionate graph tool and preserve project authority.
user-invocable: false
metadata:
  internal: true
---

# code-intelligence-routing

Use this procedure before coding work or a code-focused investigation.
This skill is the single owner of Firstmate's CodeGraph and Graphify routing policy.

## Choose the proportionate tool

Use CodeGraph by default for bounded coding work and code-focused investigation.
Use the installed `graphify` skill instead when a large architecture or research investigation needs a persistent, broader knowledge graph to connect code with substantial documentation or other source material.
Do not use Graphify for an ordinary bounded implementation, bug fix, or narrow code question.

## CodeGraph

Call the CodeGraph MCP `codegraph_explore` tool first with a focused query and the absolute project path.
Use the returned source, call paths, and blast-radius summary to guide the next inspection or edit.
If CodeGraph is unavailable, the project has no `.codegraph/` index, or the query cannot be served, continue with ordinary repository inspection using available read, search, and file-listing tools.
Do not block the task, run `codegraph init`, or otherwise create or commit `.codegraph/` data without explicit project authority.

## Graphify

Use the installed `graphify` skill for the selected larger investigation and follow its procedure.
Run it only in the authorized isolated task copy, never in a project's primary local copy.
Treat `graphify-out/` and other generated graph material as investigation output, not source changes to commit, unless the task and project authority explicitly require retaining it.
