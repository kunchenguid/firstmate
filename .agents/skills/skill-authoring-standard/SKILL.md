---
name: skill-authoring-standard
description: >-
  Agent-only fleet-wide standard for deciding whether work belongs in a skill and producing a focused, durable first draft.
  Use before authoring or substantially editing any skill in firstmate or any project.
  Load it together with the generic `skill-creator`: `skill-creator` owns portable anatomy, bundled resources, and degrees of freedom, while this standard owns whether to author, scope, durability, and triggers.
  Covers the skill gate, single-concern scope, principle-level guidance, concrete load triggers, and an in-draft pre-PR rubric.
user-invocable: false
metadata:
  internal: true
---

# Skill authoring standard

Apply this standard while forming a skill, before prose and resources harden around the wrong artifact or scope.
It is self-contained so a crewmate in any project can read this file directly even when its harness cannot load firstmate skills.
When delegating skill work to a project crewmate, resolve the absolute path to `.agents/skills/skill-authoring-standard/SKILL.md` from the active firstmate repository or instruction root that contains it, not from `FM_HOME`, and pass that path in the brief because project crewmates do not inherit this repository's section 13 or internal skills.

## Gate before drafting

Apply this gate before creating a skill folder or writing frontmatter.
A skill encodes a repeatable practice: in a nameable situation, an agent follows a process, exercises judgment, or uses tools to produce an outcome.
If the proposed payload is primarily a domain fact, invariant, concept, source-of-truth statement, or current-state description, stop and place it in the relevant `AGENTS.md` or docs instead.
Do not wrap a fact in procedural language merely to make it look like a skill.
Keep facts needed by a practice with their authoritative owner and have the skill point there at execution time.
Proceed only if one sentence can name the triggering situation, the repeatable practice, and the outcome it improves.

## Keep one concern

One skill owns one concern, and one PR carries one concern.
Define that concern around one recurring decision or workflow and one coherent outcome.
Every instruction and bundled resource must directly serve that concern.
Keep the PR to that concern plus the minimum trigger, pointer, and validation integration needed to make it work.
Do not carry incidental `AGENTS.md` self-governance, nearby cleanup, unrelated documentation, or another skill's changes in the same PR.
Split any change that can be reviewed, loaded, or reverted independently without breaking this skill.

## Write durable guidance

Teach principles, decisions, and boundaries that survive implementation changes.
Do not freeze component names, transient paths, tool versions, current settings, or moving inventories into the skill when an executable or documented authority owns them.
Point to that authority and require the reader to resolve current detail there when the practice runs.
When exact mechanics must be deterministic, keep them in the authoritative script or tool and make the skill explain when to invoke it.
Retain a specific only when it is itself a stable interface required to perform the practice.

## Make the description route the load

Treat the frontmatter `description` as the routing rule because the body is unavailable until the skill loads.
Name concrete triggering situations with observable actions, artifacts, lifecycle events, or failure modes.
Include creation and substantial-edit triggers when the skill applies to both.
Add a boundary when a neighboring skill could plausibly match the same request.
Do not describe only a topic, summarize the body, or use vague wording such as "helps with" a domain.
Read the description without the skill name or body and rewrite it if an agent still could not decide whether to load it.

## In-draft pre-PR rubric

Apply these questions as each part of the draft is added, and require every answer to be yes before opening a PR.
This rubric improves construction and does not replace independent review-time audit.

- Practice: Does the skill teach a repeatable action or judgment with a concrete trigger and outcome rather than package a fact?
- Scope: Does every changed file and paragraph serve the single concern or its minimum activation and validation integration?
- Authority: Are domain facts, invariants, and current specifics left with `AGENTS.md`, docs, code, or another authoritative owner?
- Durability: Are moving names, paths, versions, and settings replaced by a pointer to their owner?
- Trigger: Can the description alone cause the skill to load for concrete situations and distinguish likely neighbors?
- Economy: Does every remaining line change agent behavior or route it to authoritative detail?
- Validation: Have the repository's applicable skill and hygiene validators passed without reproducing their checks in prose?

## Neighbor ownership

Use the generic `skill-creator` alongside this standard for portable skill anatomy, bundled resources, and degrees of freedom; do not restate those subjects here.
Use `firstmate-coding-guidelines` for knowledge placement, the one-owner rule, inline stubs, and `AGENTS.md` size discipline when changing firstmate itself.
Its decision tree answers where material belongs inside firstmate, while this standard answers whether and how to author a skill anywhere in the fleet.
Use a repository's own review-time skill audit as the independent counterpart when one exists; do not copy its finding taxonomy into this authoring standard.
Leave repository-specific frontmatter extensions and mechanical syntax, metadata, symlink, and literal-reference enforcement with each repository's documented conventions and validators.
