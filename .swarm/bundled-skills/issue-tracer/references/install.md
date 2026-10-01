# Install and Version Reconciliation

This skill is distributed as ONE canonical source with thin per-agent adapters. This reference documents where each of the five supported agents discovers the skill, how user-level installs can shadow the project copy, and how to reconcile a stale copy against the canonical version stamp.

The canonical version is the `metadata.version` field in the canonical `SKILL.md` frontmatter. Treat that stamp as the source of truth: when two resolvable copies disagree on `metadata.version`, the lower one is stale and must be reconciled.

## Discovery per agent (project-level)

| Agent | Loads (project-level) | Resolves to |
|---|---|---|
| OpenCode | `.opencode/skills/issue-tracer/SKILL.md` | canonical |
| Claude Code | `.claude/skills/issue-tracer/SKILL.md` | adapter shim -> canonical |
| OpenAI Codex | `.agents/skills/issue-tracer/SKILL.md` | adapter shim -> canonical |
| ZCode | `.agents/skills/issue-tracer/SKILL.md` | adapter shim -> canonical |
| GitHub coding agent | repo-root `AGENTS.md` pointer | canonical |

The adapter shims point to `../../../.opencode/skills/issue-tracer/SKILL.md` as the canonical workflow and add only short per-agent execution notes (tool bindings, fallback labels, publish routing); the protocol itself lives in the single canonical body, so a project checkout always executes one protocol.

### Agent Adapter table - capability-first

The canonical SKILL.md's Agent Adapter table maps each role (file-edit tool, plan/tasklist tool, web tool, subagent/delegation) to your runner's own current tool surface - detect it from the session's actual tool list, never from the runner's name. Do not hardcode a fixed tool-name table here: tool surfaces change across runner versions, and a stale hardcoded mapping is worse than an explicit "verify against your own tool docs" instruction. Use each runner's own current documentation to fill the cells at session start.

### Delegating-shim pattern

Each per-agent adapter (`.claude/skills/issue-tracer/SKILL.md`, `.agents/skills/issue-tracer/SKILL.md`) is a thin shim, not a copy of the protocol: it names the canonical file with the exact relative reference `../../../.opencode/skills/issue-tracer/SKILL.md` and the phrase "canonical workflow", adds only short per-runner execution notes (tool bindings, fallback labels, publish routing), and stays under 60 lines with no `## Phase ` heading of its own. A user-level shim intended to delegate rather than fork should declare `shim: true` and a `version:` matching the canonical `metadata.version` in its own frontmatter - that pair is exactly what the handshake in `references/phase-0-setup.md` checks for, and it is what turns a user-level copy from a shadowing risk into a safe, self-updating pointer.

## Per-runner discovery precedence (as observed, not guaranteed)

Precedence between a project-level skill copy and a user-level (home-directory) copy of the same slug varies by runner and runner version, and the safe assumption is "verify, don't guess":

- **ZCode**: user-level wins over project-level for ZCode skills (evidenced: a user-level `issue-tracer` fork was observed running instead of this repo's canonical, across many trace directories, on a real host).
- **Claude Code**: personal (user-level) skills are documented to take precedence over project-level skills of the same name.
- **Codex**: project-level skills are documented as resolved first in current secondary sources; treat this as unverified against Codex's own primary docs until checked against your installed version.

Do not assume "project wins" as a universal default - verify with the version-stamp comparison below for whichever runner you are actually using.

## User-level installs can SHADOW the project copy

Several CLIs also search a user-level (home-directory) skills root in addition to the project root, for example:

- Claude Code: `~/.claude/skills/issue-tracer/`
- ZCode: `~/.zcode/skills/issue-tracer/`
- Codex: `~/.codex/skills/issue-tracer/` (or the runtime's configured user skills root)
- OpenCode: the user-level OpenCode config skills root

Resolution precedence between the project copy and a same-named user-level copy **varies by CLI and CLI version**, and some resolve the user-level copy first. That makes a **stale user-level copy the dangerous case**: it can silently shadow the up-to-date project canonical, so the agent runs an old protocol (missing, e.g., the Full-Resolution Contract or the Phase 4.2 sweep) while the repository looks correct. Do not assume project-wins; verify with the version stamp.

## Reconcile against `metadata.version`

Read the canonical stamp first:

```sh
grep -A2 '^metadata:' .opencode/skills/issue-tracer/SKILL.md | grep 'version:'
```

Then, for each CLI you use, compare the user-level copy's stamp to the project canonical and remove or refresh the user-level copy if it is older or absent-of-stamp (a legacy fork with no `metadata.version` is by definition stale):

```sh
# Claude Code
diff <(grep 'version:' ~/.claude/skills/issue-tracer/SKILL.md 2>/dev/null || echo 'version: none') \
     <(grep 'version:' .opencode/skills/issue-tracer/SKILL.md) \
  && echo 'in sync' || echo 'STALE user-level copy - remove ~/.claude/skills/issue-tracer or re-sync it'

# ZCode
diff <(grep 'version:' ~/.zcode/skills/issue-tracer/SKILL.md 2>/dev/null || echo 'version: none') \
     <(grep 'version:' .opencode/skills/issue-tracer/SKILL.md) \
  && echo 'in sync' || echo 'STALE user-level copy - remove ~/.zcode/skills/issue-tracer or re-sync it'

# Codex
diff <(grep 'version:' ~/.codex/skills/issue-tracer/SKILL.md 2>/dev/null || echo 'version: none') \
     <(grep 'version:' .opencode/skills/issue-tracer/SKILL.md) \
  && echo 'in sync' || echo 'STALE user-level copy - remove ~/.codex/skills/issue-tracer or re-sync it'
```

The safest default is to keep no user-level `issue-tracer` copy at all and let each project ship its own canonical, so version drift cannot occur. If you do keep a user-level copy, reconcile it whenever the project canonical's `metadata.version` changes.

Maintainer rule: bump `metadata.version` (canonical SKILL.md plus both adapter shims, in lockstep) in the same changeset as any canonical content edit - the stamp is the only reconciliation signal user-level copies have, and an unbumped edit silently defeats it.

GitHub coding agents load the repository's checked-in `AGENTS.md` and `.opencode/skills/issue-tracer/SKILL.md` directly, with no user-level home directory, so shadowing does not apply to that surface; their sessions can spawn fresh-context subagents, so the independent critic/review gates run as the preferred path there too.

## Handshake semantics (automated, advisory)

`trace-check.sh handshake` automates the reconciliation above for the four user-level roots it can see (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, `~/.zcode/skills`), reading only the `version:`/`shim:` lines - never full content, never a directory listing. It reports `MATCH`/`SHIM`/`STALE`/`ABSENT` per root and always exits 0, because it can never detect the dangerous case (a copy that shadows the canonical before this skill is even loaded). Treat a `STALE` result as a signal to run the manual reconcile commands above for that specific root, and treat `ABSENT` as informational, not an error.

## Capability-first, not vendor-first

This skill is model-agnostic. Wherever a role is needed (independent critic, implementation reviewer, final critic, cross-CLI invocation), use your runner's own equivalents at the strongest tier your session allows - never a hardcoded vendor or model name. If your runner's own instructions (a user-level AGENTS.md, an agent-definition file) already mandate a specific external critic or model, follow those instructions; this skill does not override them, and it does not invent a mandate of its own.
