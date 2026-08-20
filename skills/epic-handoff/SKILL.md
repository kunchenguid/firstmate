---
name: epic-handoff
description: Promote a reviewed, captain-signed epic into the home backlog, then guide the ordered next steps it deliberately does not do. Wraps bin/fm-umbrella-promote.sh, which validates the epic and every story's frontmatter, makes the epic canonical in the home's plans (leaving a back-symlink in the umbrella so design continues), and seeds each story into the backlog with ids and tags derived from the frontmatter so nothing orphans. Use after /epic-review passes and the captain signs epic.md. Fifth skill in the epic pipeline; guides toward dispatch and /epic-ship.
user-invocable: true
---

<!-- maintainers: public, installer-facing skill. Keep it standalone and harness-agnostic - no private paths, no tool-specific or single-harness syntax. It is one of six epic-pipeline skills (epic-new -> epic-scaffold -> epic-plan -> epic-review -> epic-handoff -> epic-ship) that share one voice and one output format. This skill DRIVES bin/fm-umbrella-promote.sh; it must not reimplement that script's validation, move, or seed logic - defer to `fm-umbrella-promote.sh --help` for the exact contract. -->

# epic-handoff

Promote a reviewed and signed epic into the home so its stories become queued backlog work, then guide the ordered steps that stay human- and firstmate-owned.
The mechanical promote is done by the engine, not by hand:

    bin/fm-umbrella-promote.sh <umbrella-id>

Run it with `FM_HOME` set to the home that owns the umbrella.
`fm-umbrella-promote.sh --help` is the single owner of the exact contract, flags, and overrides - defer to it rather than duplicating them here.

## Preconditions

- `/epic-review` returned **PASS** - do not promote an epic that failed the gate.
- The captain has signed `epic.md` (a real date in `signed_off:`).
  Nothing is dispatched before sign-off.

## What the engine does (do not reimplement)

`fm-umbrella-promote.sh` is idempotent and fail-closed - all validation runs before any write, a re-run is a safe no-op, and a mismatched prior seed is refused rather than duplicated.
It:

1. Locates the designed epic under the umbrella.
2. Validates the epic slug and repos, and every story's `id:` / `epic:` / `repo:` / `pr_base:`, and that every involved repo is registered - writing nothing if any check fails.
3. Makes the epic canonical in the home's plans (where dispatch reads it) and leaves a back-symlink in the umbrella pointing to it, so the captain keeps designing the epic in the lab with edits writing through to the real files - one source of truth, no separate "materialize on done" step.
4. Seeds each story into the backlog, deriving the backlog id and `[<epic>]` tag from the story frontmatter so they match the story files by construction - the reason standard frontmatter matters.
5. Stops at the sign-off gate and prints the remaining steps.

It NEVER signs the epic, cuts a branch, or dispatches - those are judgment and approval steps, the same boundary the script itself holds.

## The steps it does not do (guide, never auto-run)

After a successful promote, the ordered next steps stay human- and firstmate-owned:

1. The captain reviews the design and signs `epic.md` (if not already signed).
2. Cut one epic branch per involved repo: `bin/fm-epic-branch.sh create <slug> <repo>`.
   Defer to `fm-epic-branch.sh --help` for its exact contract.
3. firstmate dispatches the queued stories - each branches from `epic/<slug>` and ships as a reviewed PR into it.
4. Once the epic is complete, ship it with `/epic-ship`.
5. Tear down the umbrella lab, which keeps `DESIGN.md` and discards the scratch worktrees; the epic stays canonical in the home's plans regardless.

Never auto-sign, auto-branch, or auto-dispatch - name the steps and let the captain and firstmate drive them.

## Output

Report back exactly this shape:

- **Stage:** handoff
- **Epic:** `<slug>` - `<title>`
- **Promote:** the one-line result of `fm-umbrella-promote.sh` (seeded N stories, or the exact refusal it printed)
- **Queued stories:** one line each - `<id>` (repo `<repo>`)
- **Remaining steps:** sign (if pending) -> epic branch per repo -> dispatch -> ship -> teardown
- **next:** dispatch the stories, then /epic-ship once the epic is complete
