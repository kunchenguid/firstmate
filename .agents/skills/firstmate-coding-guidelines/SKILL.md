---
name: firstmate-coding-guidelines
description: >-
  Agent-only reference for changing firstmate's shared, tracked material per AGENTS.md section 1.
  Use before editing any of that material, whether working as firstmate directly or as a crewmate briefed on a firstmate-repo task.
  Covers the knowledge-placement decision tree, the one-owner rule for contracts, the inline-stub pattern for content moved into a skill, AGENTS.md size discipline, trigger hygiene for new skills, and repo style rules (one sentence per line, plain dash, no agent co-author, shellcheck-clean bin scripts, colocated tests, and maintainer-verification evidence).
user-invocable: false
metadata:
  internal: true
---

# firstmate-coding-guidelines

Load this before changing firstmate's shared, tracked material, as defined by `AGENTS.md` section 1.
It exists because `AGENTS.md` grew from 585 to 958 lines between its last two restructures, entirely from conditional detail added inline instead of routed to its right home.
Applying the rules below on every change is what keeps that from happening again.

## Knowledge-placement decision tree

Before writing a new fact anywhere in this repo, ask where it belongs, in this order.

1. Does the firstmate AGENT need this on every session or every turn to operate?
   If yes: `AGENTS.md`, inline.
2. Does the agent need it only in a nameable situation - a spawn, a recovery, a specific wake type, a specific lifecycle step?
   If yes: an agent-only skill under `.agents/skills/`, plus a one-line trigger pointer left inline in `AGENTS.md` (usually section 13).
3. Is it public product, setup, or user/operator reference?
   If yes: the surface classified for that audience in [`docs/documentation-audiences.md`](../../../docs/documentation-audiences.md), limited to current behavior, setup, supported limits, stable invariants, concise rationale, and current verification entry points.
4. Is it contributor/maintainer architecture?
   If yes: the classified maintainer-architecture owner for stable ownership, extension points, mechanism boundaries, and safety rationale.
5. Is it active reusable verification for a current guarantee?
   If yes: an explicitly classified maintainer-verification record may keep current dates, versions, exact commands, and exact output.
6. Is it task or incident evidence - chronology, transcripts, branches, temporary paths, failed hypotheses, or delivery proof?
   If yes: keep it in the private task report or PR evidence by default, after distilling every unique current fact into its authoritative owner.
7. Is it mechanics - exact flags, exact commands, exact paths?
   If yes: the script's own header comment plus its `--help` output, not prose in `AGENTS.md`, a skill, or a second documentation owner.

Stop at the first tier that answers yes.
Do not place a fact at a more convenient tier than the one this tree gives you.
The machine-consumed inventory in [`docs/documentation-audiences.json`](../../../docs/documentation-audiences.json) is the single classification owner for maintained prose surfaces; do not add parallel front matter or a second audience list.

## One-owner rule

Every contract - a data format, a state machine, a decision procedure - is stated in full exactly once.
Every other mention of it is a one-line cross-reference, never a restatement.
A single deliberate one-line reinforcement at a genuine risk point is allowed, for example a "don't forget X" placed exactly where forgetting X is costly.
Restating the contract's substance a second time is not allowed: the two copies will drift the moment only one is edited.
When you touch a contract, grep the repo for its other mentions and update the cross-references, not duplicate the change into a second full copy.

## Inline-stub pattern

When content moves out of `AGENTS.md` into a skill, decide what stays behind by asking one question: what must survive with no skill loaded?
That is the trigger condition for loading the skill, plus any safety-critical fact that fires on a wake the skill itself is not loaded for.
Everything else - the procedure, the mechanism, the surrounding detail - moves out completely.
Do not leave a partial restatement behind "just in case".
A partial copy is exactly the duplication the one-owner rule forbids.
The model to copy is `AGENTS.md` section 8's "Away-mode stub": it keeps only the marker format, the ownership-transfer rule, and the exit condition inline, and points everything else at the `/afk` skill.

## Size discipline

Apply the decision tree above to every line you are about to add to `AGENTS.md`.
If an addition needs more than a few lines of conditional detail (detail that matters only in a specific situation) or reference detail (a wire format, an exact schema, historical rationale), you are almost certainly adding it to the wrong file.
`AGENTS.md`'s token cost is paid by every session of every fleet member, every time, whether or not that session ever hits the situation the new lines describe.
A skill's cost is paid only by the sessions that actually load it.
When in doubt, write the fact into the skill or doc first, and add only the one-line trigger to `AGENTS.md`.

## Trigger hygiene

A new skill is dead weight if nothing loads it.
Every new skill needs its load trigger declared inline: section 13 for agent-only reference skills, or the relevant operating section for anything else.
State the trigger as a condition ("load before X", "load on Y wake"), never as a vague pointer.
Briefs for tasks that touch firstmate's own tracked material should tell the crewmate to load this skill.
`bin/fm-brief.sh`'s `REPO` argument is a caller-supplied string with no reliable signal that it names firstmate's own repo, unlike a project registered in `data/projects.md`, so there is no clean point inside the scaffold to detect this case automatically.
Firstmate adds this skill's load instruction to firstmate-repo briefs by hand instead.
`CONTRIBUTING.md`'s "Development" section carries the same instruction as a durable reminder.

## Compatibility and enforcement

Before changing shared tracked behavior, review every affected supported primary harness and runtime backend rather than checking only the adapters active in the current fleet.
Mark an axis not applicable only after inspecting its integration surface, and update the corresponding verification evidence when behavior changes.

For critical safety, routing, startup, and supervision infrastructure, prefer deterministic and idempotent enforcement over relying on agent memory alone.
Keep instructions as the authority and discovery layer, but make repeated execution converge safely and make invalid or unsafe states fail closed wherever the runtime can enforce them.

## Documentation change review

For every changed maintained prose surface, identify its inventory audience, authoritative owner, current-behavior relevance, destination for supporting evidence, and any unique safety fact that removal could lose.
Move or delete evidence only after the current owner and regression pointer are verified.
After all documentation, review-fix, and lint-fix commits, review the complete branch diff again against those criteria rather than reviewing only the latest commit.
Run `bin/fm-doc-audience-check.sh`; it enforces classification, README setup routing, local link targets, and owner pointers without keyword-linting legitimate evidence prose.

## Repo style rules

- Put one full sentence per line in tracked Markdown.
- Never wrap multiple sentences onto one physical line.
- Plain dash `-`, never an em dash.
- Never add an agent name as a commit co-author.
- `bin/*.sh` and `bin/backends/*.sh` must pass `shellcheck`.
- Run `bin/fm-lint.sh` before treating a script change as done; it is the single owner of the lint definition (file set, config, and pinned shellcheck version) that CI and the no-mistakes pre-push gate both invoke, and it refuses to run under any other shellcheck version.
- Colocate tests with the existing pattern in `tests/`, name them `<subject>.test.sh`, and extend an existing script rather than inventing a new runner.
- A maintainer-verification record under `docs/verification/` records active empirical facts, not assumptions or task chronology.
- Include the date, version, exact commands run, and exact output needed to support the current guarantee.
- Keep incident chronology and delivery evidence in private task reports or PR evidence unless a concise rationale is required to maintain a current safety boundary.
