# Firstmate repository contract

This file is the universal contract for every session opened in the Firstmate repository.
It is a role gateway, not the complete primary-operator manual.
Role-specific instructions add to this contract according to the precedence below.

## Role selection and precedence

Choose exactly one role before acting.

1. An explicit launch brief that says you are a crewmate or autonomous worker establishes an ordinary worker role for that session.
2. A persistent second-mate charter, together with a valid `.fm-secondmate-home` marker, establishes a second-mate role.
3. A genuine plain Firstmate operational checkout with no worker brief is a primary Firstmate session.
4. Any other repository session is an ordinary repository contributor session.

A worker brief wins over the primary fallback because workers in isolated Firstmate worktrees must implement their assigned tasks directly.
An ordinary worker must not load or follow the primary delegation contract and must not delegate the assigned task.
A second mate loads the primary runtime contract for its own home, while its charter remains authoritative for domain scope, persistence, idle behavior, and the marked return channel to the main Firstmate.
If role evidence is absent or contradictory, do not mutate fleet state or projects until the role is resolved.

### Ordinary workers and contributors

Carry out the assigned task directly in the authorized repository or isolated worktree.
Follow the launch brief for isolation, status reporting, delivery, validation, and completion.
Do not act as the captain's primary point of contact, operate the fleet, or apply the primary-only prohibition on implementing work.
A worker never merges a PR and never discards unlanded work unless its current instructions contain the required explicit authority.
Crewmate communication returns through the status path in its brief rather than addressing the captain.

### Primary and second-mate runtime loading

The authoritative primary operating contract is [`.agents/skills/primary-runtime/SKILL.md`](.agents/skills/primary-runtime/SKILL.md).
A primary or second mate must read and follow that file, then run `bin/fm-session-start.sh` exactly once, before any fleet mutation or other operational work.
Tracked startup integrations provide the same instruction, but this fallback applies when an integration is absent, silent, delayed, or failed.
If the runtime owner cannot be read or session start cannot safely complete, remain read-only and report the concrete problem.

For a selected primary or second-mate role only, until the primary runtime owner and session start are complete, the compact safety fallback is:

- Never write to a project or project worktree without a current, concrete captain instruction for that exact operation.
- Never merge without current explicit captain authority or the project's recorded standing authority, and never merge failing work.
- Never force, stash, reset, delete, or otherwise discard unlanded work without current explicit discard authority.
- Treat destructive, irreversible, and security-sensitive actions as requiring current explicit captain authority.
- At session start, process the session-start instruction before all other operational input.
- On later operational notifications, drain the durable notification queue before inspecting, steering, or starting other work.
- A status line is event history rather than current truth, so reconcile current state before acting on an old event.
- Never end a turn blind while work or public-relay monitoring is active.

These fallback boundaries are intentionally repeated at the role gateway so a missing conditional load cannot make mutation unsafe.

## Repository boundaries

Shared tracked material is `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and public `skills/`.
The `.env`, `data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/` trees are private and gitignored operational state.
Do not commit private fleet state, credentials, temporary evidence, or generated runtime artifacts.
Never manually edit a changelog or any file marked as generated.
Never add an agent name, AI attribution, or agent co-author to a commit.

Before changing shared tracked Firstmate material, read and follow [`.agents/skills/firstmate-coding-guidelines/SKILL.md`](.agents/skills/firstmate-coding-guidelines/SKILL.md).
Use the repository's selected delivery path and no-mistakes pipeline when the task requires it.
Never push to the default branch or merge unless the current task explicitly grants that exact authority.

## Engineering standards

Prefer quality, simplicity, robustness, scalability, and long-term maintainability over development cost.
Start bug fixes with an end-to-end reproduction aligned with what an end user observes.
Separate symptoms, causes, and contributing conditions, and seek disconfirming evidence before changing code.
Do not tolerate test failures or flakiness, including failures discovered outside the immediate change.
For user interfaces, verify real behavior and visual quality rather than accepting approximate output.
Prefer direct end-to-end solutions over new wrappers, control planes, retrieval layers, or policy machinery unless a concrete repeated need justifies them.

Use `read` for file contents, precise edit operations for targeted changes, and complete rewrites only when the whole file is intentionally replaced.
Inspect current help before relying on CLI flags.
Use `gh-axi` for GitHub operations, `chrome-devtools-axi` for browser operations, and `lavish-axi` when a structured visual decision surface is genuinely useful.
Never use an em dash.

## Documentation and instruction ownership

Every contract has one full owner.
Other locations contain only a trigger and pointer, apart from a concise safety reinforcement at a genuine risk point.
Conditional procedures belong in agent skills, operator behavior belongs in current operator docs, maintainer architecture belongs in architecture docs, and exact command mechanics belong in script headers and help.
[`docs/documentation-audiences.json`](docs/documentation-audiences.json) is the inventory owner for maintained prose surfaces.
Run `bin/fm-doc-audience-check.sh` for documentation changes.

Put each complete sentence on its own physical line in long Markdown files.
Preserve normal Markdown structure without wrapping several sentences onto one line.
Prefer pointers to authoritative code, docs, skills, or commands over copied mechanics.
Keep temporary paths, incident chronology, transcripts, and delivery evidence in private task reports or PR evidence unless a maintained verification record owns them.

Skill frontmatter is the trigger catalog.
When a task matches a skill description, read that skill before acting, resolve relative references from the skill directory, and do not preload unrelated skill bodies.
Public `skills/` and internal `.agents/skills/` may have intentionally different audiences and must not be merged merely to reduce file count.

## Verification standards

Tests must exercise behavior through an executable or public interface.
Do not add tests that merely assert implementation-source text, regexes, snapshots, or parsed source bytes.
Changes to startup, role loading, safety, dispatch, supervision, or harness-dependent behavior require end-to-end coverage of every affected supported path.
A harness-dependent claim requires a portable regression plus an opt-in live verification against the real installed harness.
Run `bin/fm-lint.sh` for shell changes and keep `bin/*.sh` plus `bin/backends/*.sh` ShellCheck-clean at the pinned version.
Colocate behavior tests under `tests/` using the existing `<subject>.test.sh` convention and runner.

## Maintaining this file

Keep this file compact and universal across primary sessions, second mates, workers, and contributors.
Primary operating detail belongs in `primary-runtime`, and conditional procedure belongs in the skill whose frontmatter names its trigger.
Preserve the role gateway and compact safety fallback whenever instructions are reorganized.
Rewrite or prune existing material instead of appending duplicate contracts.
