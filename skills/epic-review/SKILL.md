---
name: epic-review
description: The independent design-review GATE for a scaffolded epic. Reviews epic.md and its stories BEFORE handoff - is every story's frontmatter standard (else FAIL), is the contract concrete and landable-first, are dependencies and gates sound, is each story's scope and definition of done complete. Produces a standard REVIEW.md with a clear PASS or FAIL verdict and a numbered fix list; FAIL blocks handoff. Run as a DIFFERENT agent than the one that scaffolded. Third skill in the epic pipeline; on PASS hands off to /epic-handoff.
user-invocable: true
---

<!-- maintainers: public, installer-facing skill. Keep it standalone and harness-agnostic - no private paths, no tool-specific or single-harness syntax. It is one of five epic-pipeline skills (epic-new -> epic-scaffold -> epic-review -> epic-handoff -> epic-ship) that share one voice, one output format, and one story-frontmatter contract. The "Required story frontmatter" block below is stated identically in epic-scaffold; keep the two copies byte-identical. -->

# epic-review

The independent review gate that a scaffolded epic must pass before it is handed off.
It reads `epic.md` and every story, checks them against the standard, and writes a `REVIEW.md` beside the epic with a single **PASS** or **FAIL** verdict and a numbered fix list.
A **FAIL** blocks handoff - `/epic-handoff` should not run until the fixes land and this gate passes.
There is no upfront per-story plan to review: each story carries a plan-section pointer placeholder, and the dispatched worker produces the plan at task-time against current HEAD, gated by firstmate's plan-review before any code.

You are the REVIEWER, and you must be a DIFFERENT agent than the one that scaffolded.
Self-review defeats the gate: the whole reason this stage exists is a second, independent read.

## When to use

- An epic has been scaffolded (`/epic-scaffold`) and needs the gate before the captain signs and firstmate promotes; each story carries a plan-section pointer placeholder (the worker plans at task-time under the firstmate plan-review gate, so there is no upfront per-story plan to review here).
- A previously-FAILed epic has had its fix list addressed and needs re-checking.

## What to check

1. **Story frontmatter is standard - this is a hard gate, and it is executable.**
   Run `bin/fm-epic-lint.sh <epic-dir>` on the epic directory; it is the single owner of the epic/story contract and the same check `fm-umbrella-promote.sh` runs at promote time.
   A non-zero exit is an automatic **FAIL**: copy its numbered problem list into your findings verbatim and stop treating the epic as passable until they are fixed and the lint is green.
   It enforces, mechanically, exactly the contract in the block below - the seven required keys plus an optional `delivery:` mode and nothing else ad-hoc (`story:`/`phase:` are rejected), lower-kebab unique ids that match their filenames, matching `epic:`, registered `repo:`, valid `pr_base:`, exactly one `gate: true`, `depends:` naming real stories with no cycle, a resolving plan pointer, a known `delivery:` value when that optional key is present, and no story body that assigns work to a second repo (one story = one repo) - so this is the failure the whole pipeline exists to prevent, checked first and not negotiable.
   `fm-epic-lint.sh --help` documents the full contract; run it, do not re-derive the rules by eye.
   Any multi-repo story is a FAIL-to-split: it can never dispatch as a single unit (a worker gets ONE worktree), so it must be split into per-repo stories linked by `depends:` before handoff - see the one-story-one-repo note below.
   The lint FAILS when a body assigns work to a second repo and only WARNS on a bare cross-repo mention; treat a warning as your cue to judge whether the story is actually a bundled cross-repo unit hiding behind prose, and if it is, FAIL it to split even though the lint let it pass.

2. **The contract is concrete and landable-first.**
   The shared contract (API shape, schema, proto, types package) must be concrete enough to land as its own story before dependent per-repo stories.
   Exactly one story is the `gate: true` contract story, and the stories that consume it `depends:` on it.
   If the contract is still prose, the epic is not ready - **FAIL** and say so.

3. **Dependencies and gates are sound - the judgment beyond the lint.**
   Check 1's lint already proved, mechanically, that every `depends:` id resolves, there is no cycle, and exactly one story is `gate: true`; here you make the judgment it cannot - that the one gate story is the RIGHT contract story and that the stories consuming it actually `depends:` on it.
   The delivery contract (stories PR into `epic/<slug>` with evidence and review) and the ship gate (full-epic no-mistakes before shipping) are present in `epic.md`.

4. **Each story's scope and definition of done are complete.**
   There is no upfront plan directory to review - the plan is produced at task-time under the firstmate plan-review gate - so the review is of the STORY: its Goal, Scope, and Definition of done must be concrete and self-contained enough that a worker can plan against them.
   `bin/fm-epic-lint.sh` already treats the story's implementation-plan section as a pointer placeholder (not-yet-planned) and stays green, so do not FAIL a story merely for lacking an upfront plan.
   Where a story's scope or edge-case coverage looks thin, say so in the fix list so the scaffolder tightens the story, rather than inventing scope here.

5. **Risks are surfaced.**
   Note the architectural, ordering, and blast-radius risks of the epic.
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

Write `REVIEW.md` beside `epic.md`, and report back exactly this shape:

- **Stage:** review
- **Epic:** `<slug>` - `<title>`
- **Verdict:** PASS or FAIL
- **Frontmatter:** `fm-epic-lint.sh` green (all N stories standard), or its numbered problem list copied verbatim
- **Scope:** every story's Goal, Scope, and Definition of done are concrete and self-contained, or name the gaps
- **Findings:** numbered fix list (empty on a clean PASS) - each item concrete and actionable
- **next:** on PASS, the captain signs `epic.md`, then /epic-handoff; on FAIL, return to the scaffolder to fix the numbered list, then re-run /epic-review
