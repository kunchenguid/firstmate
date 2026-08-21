---
name: epic-scaffold
description: Turn a settled design or an umbrella DESIGN.md into a STANDARD epic - an epic.md plus one file per story, each carrying the exact required frontmatter (id, epic, repo, pr_base, depends, kind, gate) and a self-contained body, so the epic promotes cleanly with no orphan tasks or doubled epics. The first story is the contract gate that lands the shared contract first. Use after /epic-new, once the design is settled and stories need writing. Second skill in the epic pipeline; hands off to /epic-plan.
user-invocable: true
---

<!-- maintainers: public, installer-facing skill. Keep it standalone and harness-agnostic - no private paths, no tool-specific or single-harness syntax. It is one of six epic-pipeline skills (epic-new -> epic-scaffold -> epic-plan -> epic-review -> epic-handoff -> epic-ship) that share one voice, one output format, and one story-frontmatter contract. The "Required story frontmatter" block below is stated identically in epic-review; keep the two copies byte-identical. -->

# epic-scaffold

Turn a settled design - the captain's decided architecture, or a finished umbrella `DESIGN.md` - into a STANDARD epic that the rest of the pipeline can consume without surprises.
The output is one epic directory: an `epic.md` plus one file per story under `stories/`, every story carrying the exact frontmatter the promotion engine validates and a body a planner and a worker can act on.
This skill's whole job is to make the format impossible to get wrong, because a story with a non-standard key (`story:`, `phase:`) or a missing `id:`/`pr_base:` is exactly what produced orphan tasks and a doubled epic before this pipeline existed.

You are the SCAFFOLDER.
A different agent reviews this epic at `/epic-review`; do not review your own scaffold as if it were signed.

## When to use

- `/epic-new` set up the workspace, the design is settled, and it needs turning into a dispatchable epic.
- Any story frontmatter needs to be written or corrected to the standard shape.

Do not use this to design the architecture itself - that is captain-direct tech-lead work, settled in `/epic-new` before stories are written.
This skill only records a settled design in the standard shape.

## Procedure

1. **Read the source design.**
   If an umbrella lab produced a `DESIGN.md`, read it in full; otherwise work from the captain's settled design.
   Confirm the contract is concrete enough to split into stories - if it is still prose, the design is not finished and belongs back with the captain, not in a scaffold.
   Never copy the design doc into the epic dir.
   The umbrella-root `DESIGN.md` (and any `decisions.md`) stays the ONE canonical design, edited in place; a copy in the epic dir drifts the moment the captain edits the canonical again, and the design agent then refuses to touch a file it does not own.
   If the epic dir should reference the design, make it a symlink to the canonical, never a copy.
   In a firstmate fleet the deterministic way is `fm-umbrella.sh link-design <umbrella-id> <epic-dir>`, which points the epic dir at the umbrella-root design by symlink and refuses a drifting copy; see `fm-umbrella.sh --help`.

2. **Pick the epic slug.**
   Choose one short lower-kebab slug (for example `episk`).
   It is used verbatim in `epic.md`, in every story's `epic:`, and in every story's `pr_base: epic/<slug>`.
   Consistency of this slug is what keeps backlog ids and tags matching the story files by construction.

3. **Mirror your fleet's epic template.**
   If your fleet ships an epic template and convention (commonly `docs/epic-template.md` and `docs/epic-convention.md`), copy that template's shape; it is the single owner of the epic layout.
   State the frontmatter contract inline (below) so the scaffold is still correct where that template file is absent.

4. **Write `epic.md`** with exactly this frontmatter, then fill the body sections (origin, design decisions, delivery contract, ship gate, stories table, sign-off):

        ---
        epic: <slug>
        slug: <slug>
        title: <Epic title>
        created: <YYYY-MM-DD>
        repos: [<repo>, ...]
        homes: [<home>, ...]
        status: draft            # draft -> active -> complete
        signed_off:              # leave EMPTY; the captain fills a real date at sign-off
        ---

   Never pre-fill `signed_off:` - an empty value is the gate that blocks dispatch before the captain signs.

5. **Write one file per story** under `stories/<id>.md`, each starting with the required frontmatter below, then a self-contained body: **Goal**, **Context / dependency**, **Implementation plan** (a POINTER, filled by `/epic-plan` - leave a placeholder here, do not hand-write the plan), **Scope**, **Definition of done**, **Evidence**, **Delivery**.
   The plan `/epic-plan` fills is an upfront skeleton - the DAG, sequencing, and security criteria, not line-accurate steps - that the dispatched worker refreshes against HEAD and, on plan-review approval, promotes back into canonical; `/epic-plan` owns that lifecycle, so keep the scaffold's plan section a placeholder and do not restate it here.

6. **Make the first story the contract gate.**
   The shared contract (API shape, schema, proto, types package) lands first, as its own story, before anything that consumes it.
   Mark that story `gate: true` and give every dependent story a `depends:` on it, so the concrete contract is in place before the per-repo work builds on it.

7. **Self-check before handing off.**
   Every story has a unique `id:`; every `epic:` equals `epic.md`'s slug; every `pr_base:` is `epic/<slug>`; every `repo:` is a real repo; exactly one story is the `gate: true` contract story and dependents `depends:` on it; no story uses `story:`, `phase:`, or any other key in place of the required seven; and no story body assigns work to a repo other than its own `repo:` (one story = one repo - see below).

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
    delivery: no-mistakes   # OPTIONAL: no-mistakes | direct-PR | local-only; omit to resolve the mode at dispatch
    ---

Do not use `story:`, `phase:`, or any other key in place of the seven required keys; the only allowed optional key is `delivery:`, and it may be omitted.
A missing `id:`, a `pr_base:` that is not the epic branch, or an `epic:` that does not match `epic.md` is exactly what produced orphan tasks and a doubled epic before this pipeline existed.
The promotion engine derives each backlog id, `[<epic>]` tag, and repo straight from `id:`/`epic:`/`repo:` (and reads `kind:`, defaulting to `ship`), so that part of the frontmatter IS the contract - get it right here and the backlog matches by construction; `depends:` and `gate:` drive the review gate and dispatch ordering.
The optional `delivery:` records the story's intended delivery mode when it is known at authoring time, so the author's intent is captured once instead of re-decided by judgment at dispatch.
Omit it and firstmate resolves the mode at dispatch from the repo's registered posture, exactly as before.
`fm-epic-lint` validates a present value against those three modes and warns (never fails) when a `no-mistakes-prod-only` repo's story is marked `direct-PR`, since that mode fits only an internal-only surface.
The mode stays overridable by an explicit captain instruction at dispatch - it is never a hard lock.

**One story = one repo = one dispatchable unit.**
A crewmate spawns in ONE worktree, so a story whose body assigns work to a second repo cannot dispatch - it has to be split before it ever reaches a worker.
`fm-epic-lint` scans each story body against the home's registered repos: it WARNS on a bare mention of a repo other than the story's own `repo:` (the author may reference a dependency benignly) and FAILS when that mention shares a line with a deliverable verb (touch, change, modify, update, add, wire, implement, build, ship, patch, create), because that body is assigning work to a second repo.
Split a genuinely cross-repo unit into per-repo stories linked by `depends:` - the producer story lands the shared contract, the consumer story `depends:` on it - never one story that names two repos in prose.
`FM_EPIC_LINT_MULTIREPO` tunes the strictness (`off` disables the scan, `warn` never fails, `strict` fails on any mention); the default layering above is what the review gate and promote-validate run.

## Output

Report back exactly this shape:

- **Stage:** scaffold
- **Epic:** `<slug>` - `<title>`
- **Location:** `<epic-dir>/` (epic.md + N stories)
- **Stories:** one line each - `<id>` (repo `<repo>`, pr_base `epic/<slug>`, kind `<kind>`, gate `<true/false>`, depends `<...>`)
- **Contract gate:** the one `gate: true` story that lands first
- **Frontmatter check:** all stories standard (the seven keys), or name the ones that are not
- **next:** /epic-plan (give each story a real plan directory)
