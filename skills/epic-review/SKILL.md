---
name: epic-review
description: The independent design-review GATE for a scaffolded and planned epic. Reviews epic.md, its stories, and each story's plan directory BEFORE handoff - is every story's frontmatter standard (else FAIL), is the contract concrete and landable-first, are dependencies and gates sound, does each story's plan cover its scope and edge cases. Produces a standard REVIEW.md with a clear PASS or FAIL verdict and a numbered fix list; FAIL blocks handoff. Run as a DIFFERENT agent than the one that scaffolded or planned. Fourth skill in the epic pipeline; on PASS hands off to /epic-handoff.
user-invocable: true
---

<!-- maintainers: public, installer-facing skill. Keep it standalone and harness-agnostic - no private paths, no tool-specific or single-harness syntax. It is one of six epic-pipeline skills (epic-new -> epic-scaffold -> epic-plan -> epic-review -> epic-handoff -> epic-ship) that share one voice, one output format, and one story-frontmatter contract. The "Required story frontmatter" block below is stated identically in epic-scaffold; keep the two copies byte-identical. -->

# epic-review

The independent review gate that a scaffolded and planned epic must pass before it is handed off.
It reads `epic.md`, every story, and every story's plan directory, checks them against the standard, and writes a `REVIEW.md` beside the epic with a single **PASS** or **FAIL** verdict and a numbered fix list.
A **FAIL** blocks handoff - `/epic-handoff` should not run until the fixes land and this gate passes.

You are the REVIEWER, and you must be a DIFFERENT agent than the one that scaffolded or planned.
Self-review defeats the gate: the whole reason this stage exists is a second, independent read.

## When to use

- An epic has been scaffolded (`/epic-scaffold`) and planned (`/epic-plan`) and needs the gate before the captain signs and firstmate promotes.
- A previously-FAILed epic has had its fix list addressed and needs re-checking.

## What to check

1. **Story frontmatter is standard - this is a hard gate.**
   Verify every `stories/<id>.md` against the contract below.
   Any missing `id:`, non-unique `id:`, `epic:` that does not match `epic.md`, missing or wrong `pr_base:`, missing `repo:`, or use of `story:`/`phase:`/any other ad-hoc key in place of the required seven is an automatic **FAIL**.
   This is the failure the whole pipeline exists to prevent, so it is checked first and it is not negotiable.

2. **The contract is concrete and landable-first.**
   The shared contract (API shape, schema, proto, types package) must be concrete enough to land as its own story before dependent per-repo stories.
   Exactly one story is the `gate: true` contract story, and the stories that consume it `depends:` on it.
   If the contract is still prose, the epic is not ready - **FAIL** and say so.

3. **Dependencies and gates are sound.**
   Every `depends:` id names a real story in this epic; there is no dependency cycle; the `gate: true` contract story is a dependency of the stories that consume it.
   The delivery contract (stories PR into `epic/<slug>` with evidence and review) and the ship gate (full-epic no-mistakes before shipping) are present in `epic.md`.

4. **Each story has a real plan that covers its scope.**
   Every story's implementation-plan section points at a plan directory (`plans/<epic>/stories/<id>-plan/`) produced by the planner, not a hand-written paragraph.
   Read each plan and confirm its phases cover the story's stated scope and definition of done.
   Where a plan's edge-case coverage looks thin, point the planner at an edge-case decomposition pass (for example `ck:ck-scenario`) rather than inventing scope here.

5. **Risks are surfaced.**
   Note the architectural, ordering, and blast-radius risks of the plan.
   For a risky or expensive epic, point at a pre-implementation red-team pass (for example `ck:ck-predict`).

### Required story frontmatter (identical in epic-scaffold and epic-review)

Every `stories/<id>.md` file starts with exactly this YAML frontmatter and nothing ad-hoc:

    ---
    id: <lower-kebab, unique across the epic>
    epic: <slug>            # must equal epic.md's `epic:` value
    repo: <repo-name>       # a repo registered in the home's projects
    pr_base: epic/<slug>    # the epic branch stories PR into (a production branch only for a bootstrap epic)
    depends: []             # ids of stories that must land first, or [] for none
    kind: ship              # ship (produces a PR) or scout (produces a report); defaults to ship
    gate: false             # true only on the one contract-gate story that must land before its dependents
    ---

Do not use `story:`, `phase:`, or any other key in place of these seven.
A missing `id:`, a `pr_base:` that is not the epic branch, or an `epic:` that does not match `epic.md` is exactly what produced orphan tasks and a doubled epic before this pipeline existed.
The promotion engine derives each backlog id, `[<epic>]` tag, and repo straight from `id:`/`epic:`/`repo:` (and reads `kind:`, defaulting to `ship`), so that part of the frontmatter IS the contract - get it right here and the backlog matches by construction; `depends:` and `gate:` drive the review gate and dispatch ordering.

## Output

Write `REVIEW.md` beside `epic.md`, and report back exactly this shape:

- **Stage:** review
- **Epic:** `<slug>` - `<title>`
- **Verdict:** PASS or FAIL
- **Frontmatter:** all N stories standard, or list every non-standard one with the exact problem
- **Plans:** every story points at a real plan directory that covers its scope, or name the gaps
- **Findings:** numbered fix list (empty on a clean PASS) - each item concrete and actionable
- **next:** on PASS, the captain signs `epic.md`, then /epic-handoff; on FAIL, return to the scaffolder or planner to fix the numbered list, then re-run /epic-review
