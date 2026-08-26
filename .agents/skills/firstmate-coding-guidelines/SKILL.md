---
name: firstmate-coding-guidelines
description: >-
  Agent-only reference for changing firstmate's own shared, tracked material - AGENTS.md, regeln/, bin/, .agents/skills/, docs/, and tests/.
  Use before editing any of it, whether working as firstmate directly or as a crewmate briefed on a firstmate-repo task.
  Covers where a new fact belongs, the one-owner rule, harness-dependent testing, and this repo's style rules.
user-invocable: false
metadata:
  internal: true
---

# firstmate-coding-guidelines

Load this before changing firstmate's own shared, tracked material.
It exists because `AGENTS.md` grew from 585 to 958 lines between two restructures, entirely from conditional detail added inline instead of routed to its right home.

## Where a new fact goes: one question

**Who reads this at the point of action?**

- A gate, hook, or script reads it -> it belongs in that executable's own code and header, as a rule with a named reader. That is the only kind of line `AGENTS.md` accepts, and `regeln/*.yaml` is where a rule with a retrieval or hook reader lives.
- An agent reads it in a nameable situation - a spawn, a recovery, a specific wake, a lifecycle step -> a skill under `.agents/skills/`, whose description line is its entire trigger, stated as a condition ("use before X", "use on Y wake").
- A human reads it - operator setup, maintainer architecture, dated verification evidence -> `docs/`, in the surface classified for that audience in [`docs/documentation-audiences.md`](../../../docs/documentation-audiences.md).
- Nobody reads it at any point of action -> it is task or incident evidence. Keep it in the private task report or PR evidence after distilling every unique current fact into its authoritative owner.

Exact flags, commands, and paths always belong in the script's own header and `--help`, never as prose in a second place, and `AGENTS.md`'s token cost is paid by every session of every fleet member while a skill's is paid only by sessions that load it.
**New skills and new prose duties are on no rung of the post-incident ladder** (`AGENTS.md`, Rule database and drift brake): sharpen an existing gate, amend data, fix a tool, and only then - with the captain's word - add a context rule.

## One-owner rule

Every contract - a data format, a state machine, a decision procedure - is stated in full exactly once, and every other mention is a one-line cross-reference.
A single deliberate reinforcement at a genuine risk point is fine ("don't forget X" placed exactly where forgetting X is costly); restating the substance is not, because two copies drift the moment one is edited.
When you touch a contract, patch or prune the owner's existing language rather than appending a new clause, then grep for its other mentions and update the cross-references.
When content moves out of `AGENTS.md`, what stays behind is only the trigger condition plus any safety fact that fires on a wake the skill is not loaded for - never a partial restatement "just in case".
Skills may cite rule ids; they never restate a rule and never point at a section of `AGENTS.md`.

## Harness-dependent checks

A check is harness-dependent when its verdict comes from something a vendor emits: a process name, rendered output, a spinner or keybind glyph, a banner, or a bound key.
Anything in that class must be proven end to end against the real harness, because a stub can only confirm the assumption already written into the stub; that proof is authorized to spend tokens.
Build on the most structural signal available, prefer a kernel or protocol fact over anything a release note could change, and where a rendered surface is genuinely the only source, read more than one independent signal so no single vendor string is load-bearing - backed by a guard that fails loudly naming the harness and version rather than degrading quietly.

Every such check needs two tests, because they fail for different reasons: a portable regression in `tests/` that pins the logic with real processes and no harness (drive the signals apart deliberately and assert the verdict survives losing one, so the case cannot go quietly vacuous), and a live guard in the `live-harness-optin` family that exercises every installed harness for real, reports an absent harness explicitly, and refuses a pass that checked nothing.
Record the dated per-harness result in `docs/verification/`, naming the live guard as the command that refreshes it.

For critical safety, routing, startup, and supervision infrastructure, prefer deterministic idempotent enforcement over agent memory: keep instructions as the authority and discovery layer, but make repeated execution converge safely and invalid states fail closed wherever the runtime can enforce them.
Before changing shared tracked behavior, review every affected supported primary harness and runtime backend, not only the adapters active in the current fleet.

## Repo style rules

- One full sentence per line in tracked Markdown; never wrap multiple sentences onto one physical line.
- Plain dash `-`, never an em dash.
- Never add an agent name as a commit co-author.
- `bin/*.sh` and `bin/backends/*.sh` must pass `shellcheck`, and every script carries one owner header.
- Run `bin/fm-lint.sh` before treating a script change as done; it is the single owner of the lint definition that CI and the pre-push gate both invoke, and it refuses to run under any other linter version.
- Colocate tests in `tests/`, name them `<subject>.test.sh`, and extend an existing script rather than inventing a new runner.
- Tests exercise behavior through an executable or public interface and never assert implementation-source bytes, including through parsers, regexes, snapshots, or wrappers.
- When a task names a specific tool, implement with that tool or explicitly flag the substitution and its new dependency footprint before shipping.
- A record under `docs/verification/` carries the date, version, exact commands, and exact output needed to support a current guarantee - never assumptions or task chronology.
- Run `bin/fm-doc-audience-check.sh` after touching maintained prose; deleting a documented surface means removing its inventory entry in the same change.
