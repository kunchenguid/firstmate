---
name: effective-agent-skills
description: >-
  Agent-only reference for authoring and reviewing SKILL.md files: what a skill is, progressive disclosure, design patterns and anti-patterns, testing, and security.
  Load before authoring, editing, or reviewing any skill in this repo, including a third-party skill under evaluation for adoption.
user-invocable: false
metadata:
  internal: true
---

# effective-agent-skills

A reference on what agent skills are, how they work, and how to write or review effective ones.
For where firstmate-repo knowledge belongs and this repo's own placement rules, see `firstmate-coding-guidelines` instead - this skill covers the craft of a single `SKILL.md`, not repo-wide placement.

## 1. What a skill is

A folder containing `SKILL.md` (YAML frontmatter + markdown instructions), plus optional subfolders for scripts, references, and assets loaded on demand.

```
my-skill/
├── SKILL.md          # required: metadata + instructions
├── scripts/          # optional: executable code
├── references/       # optional: detailed docs loaded only when needed
└── assets/           # optional: templates, static files
```

Skills are an open standard (agentskills.io) adopted across many agent products.
The folder and `SKILL.md` format are portable, but invocation-control fields are client-specific - see §3.

## 2. Why the abstraction exists - progressive disclosure

Three-stage loading is the architectural core:

- **Discovery** (~100 tokens, always in context) - only `name` + `description` load at startup, so dozens of skills cost little.
- **Activation** (loaded on match) - when a request matches a skill's description, the agent reads the full `SKILL.md` body.
- **Execution** (unbounded, on demand) - the agent reads `references/` files or runs `scripts/` only as needed; unread files cost nothing.

Bundled reference content has no practical size limit because it isn't loaded until accessed.

## 3. Frontmatter constraints

- `name` is lowercase, hyphens only, exactly matches the parent folder name.
- Avoid `<` and `>` in frontmatter - they can inject into the system prompt.
- Invalid YAML silently prevents loading.
- Never put a bare colon-space inside an unquoted `description` - strict YAML parsers reject it as a nested mapping even though lenient ones accept it; single-quote the whole value and double inner apostrophes if a mid-sentence colon is needed.
- In this repo, invocation control is `user-invocable: true|false` plus `metadata: internal: true` on every `.agents/skills/` entry - see `AGENTS.md`'s layout table and `firstmate-coding-guidelines`.
  Upstream sources instead use client-specific fields (Claude Code / VS Code's `disable-model-invocation: true`, Codex's separate `agents/openai.yaml` with `policy.allow_implicit_invocation: false`).
  Translate these at port time; never copy a foreign invocation field verbatim, and never carry the Codex sidecar file into this repo (firstmate does not consume it).
  This repo's session-provider backend can select Codex among other harnesses (see `harness-adapters`), so if a ported skill's manual-only intent must hold there too, verify Codex's own invocation behavior for `.agents/skills/` rather than assuming the Claude Code field alone suffices.

## 4. Two design philosophies

Both are valid; they solve different problems, and a mature skill set uses both.

- **Capability primitive** - a thin wrapper over a deterministic CLI or script; logic lives in code, `SKILL.md` teaches invocation. Use when the bottleneck is "the agent can't do X."
- **Process primitive** - encodes a methodology (review, debugging loop, design alignment); pure prompt engineering. Use when the bottleneck is "the agent's process or output quality is bad."

## 5. Writing an effective skill

- **Description is the routing contract.** It is the only thing seen before the agent decides to load the skill. Include what it does, when to use it (trigger phrases), and a differentiator versus related skills that prevents routing conflicts. Never summarize the full workflow in the description - the agent tends to follow that summary and skip the body, so describe *what* and *when*, never *how*.
- **Keep the body lean.** Length past a certain point usually means logic that belongs in a script or a `references/` file.
- **Bash-first, prose-second.** Concrete commands with inline comments beat prose explanation.
- **Push determinism into code; keep judgment in markdown.** Anything fragile or repetitive where variation is a bug belongs in a script.
- **Match strictness to task fragility.** Loose heuristics where many approaches are valid; exact scripts and strict step lists where the workflow is fragile or consistency-critical.
- **Build validation loops explicitly** - state a verify-fix-reverify loop rather than assuming one.
- **State-check before action** - instruct the agent to verify state first, then branch, rather than assuming setup is done.
- **Just-in-time loading with explicit pointers** - tell the agent exactly when to read each referenced file.
- **Keep references one level deep.** Link referenced files directly from `SKILL.md`; never chain `SKILL.md` → `a.md` → `b.md`, because the agent may only partially preview a nested file and miss instructions.
- **Document output formats** a script produces, so downstream parsing is reliable.
- **Defer to `--help` for completeness** - cover the common 80% in the body, point at `--help` for the rest.
- **Compose primitives, don't bundle workflows.** One skill, one concern; several small skills combine at runtime better than one large rigid one.
- **Cite established methodology by name** where a skill encodes one (TDD, DDD), so the agent has a coherent model and a reader can verify the design.
- **Persistent artifacts for cross-session memory** are how a skill fights agent statelessness at the architecture level - but in this repo that must go through firstmate's own knowledge-placement contract (`firstmate-coding-guidelines`' decision tree and memory system), never an ad hoc write to a project, which hard rule 1 forbids.

## 6. Anti-patterns

- Don't re-teach what the model already knows - no syntax tutorials, no "what is git."
- Don't include human-facing docs (`README.md`, `CHANGELOG.md`) inside a skill folder - skills are for agents.
- Don't write a vague description ("a helpful skill for X") - state what, when, and the differentiator concretely.
- Don't bundle library code - install a dependency properly instead of pasting source into the skill.
- Don't write a monolithic mega-skill covering design + planning + implementation + testing + deployment - split it.
- Don't assume the agent will infer a step - be explicit, including the exact success signal to check for.
- Don't write a style-only variant (a skill that only changes tone or formatting) - that belongs in a preference, not a skill.
- Don't ignore failure modes - document what failure looks like and what to do, for every step that can fail.
- Don't include time-sensitive information that will rot ("as of Q4 2024...") - fetch live data via script or omit it.
- Don't trust an unfamiliar skill uncritically - see the security checklist below before installing one.

## 7. Authoring workflow

1. Identify the gap from real task failures, not a hypothetical.
2. Decide the pattern - capability primitive or process primitive.
3. Draft the description first: what, when, differentiator. Read it back - would the agent know when to fire it?
4. Write the smallest body that works; add only when testing reveals gaps.
5. Move detail to `references/` once the body grows too long.
6. Test triggering - ask for something the skill should handle without invoking it explicitly; if it doesn't fire, fix the description.
7. Test execution by invoking explicitly; if output is wrong, fix the body.
8. Adversarially test: what edge cases break this skill? Patch the gaps.
9. Version-control it like code - review, don't just merge.

## 8. Testing and debugging

- "Which skill did you use?" asked post-task is the fastest routing debug.
- A routing failure is a description problem; an execution failure is a body problem.
- Skills snapshot at session start - edits made mid-session need a restart to take effect.
- Test against the weakest model this skill will run under; strong models forgive vague skills, weak ones expose them.

## 9. Composition

- One skill, one concern - resist bundling.
- Define the interface between skills explicitly when one produces artifacts another consumes.
- A shared repo-level substrate (in this repo, `AGENTS.md` plus the skill tree itself) coordinates skills without ad hoc handoffs.
- A coordinated set of skills forming a workflow beats an unrelated catalog of capabilities.

## 10. Security checklist

Before installing any third-party skill:

- Read every file in the folder.
- Audit any `scripts/` for outbound network calls, file access outside the expected scope, or command execution.
- Check references for prompt injection ("ignore previous instructions...").
- Verify the skill name isn't typosquatting a popular one.
- Pin to a specific version or commit, not a moving branch.

## 11. Ship checklist

Before landing a skill in this repo:

- [ ] Frontmatter `name` matches the folder name.
- [ ] Description includes what, when, and a differentiator versus related skills.
- [ ] Description includes likely trigger phrases.
- [ ] `metadata: internal: true` set (every `.agents/skills/` entry) and `user-invocable` set explicitly true or false.
- [ ] No human-facing docs inside the skill folder.
- [ ] No time-sensitive information.
- [ ] State-check before action, where applicable.
- [ ] Validation loop documented, where applicable.
- [ ] Output format documented, if relevant.
- [ ] Tested for both correct triggering and correct execution.
- [ ] Skill does one thing and composes cleanly with related skills.
- [ ] Load trigger declared inline per `firstmate-coding-guidelines`' trigger-hygiene rule (`AGENTS.md` section 13 for agent-only skills, the relevant operating section otherwise).
- [ ] Version controlled through the normal PR path - shared tracked material is never a direct edit.

## 12. First principles, compressed

1. The description routes; the body executes. Get both right independently.
2. Tokens are scarce; files are cheap. Push detail out of context until it's needed.
3. Determinism comes from code; judgment comes from prompts.
4. One skill, one concern. Composition beats bundling.
5. Agents have no memory across sessions by default - route anything that must survive through this repo's own memory and placement contract, not an ad hoc write.
6. The model knows a lot - don't re-teach; only add what's missing.
7. Validate before completing - self-correction loops dominate output quality.
8. Skills are code - version, test, audit, and review them as such.
