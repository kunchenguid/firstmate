# evidence/epwf-02 - encode the hybrid plan-workflow into the epic pipeline

The epwf-01 audit found aimica's real behavior was refresh + captain-gated expansion (only 1/10 stories diverged, correctly), and that the plan-review gate plus an ad-hoc plan-promotion loop are what kept the epic coherent.
This story formalizes that hybrid standard into the epic pipeline: the upfront plan is a skeleton, the worker refreshes it against HEAD behind the plan-review gate, always commits it, and on approval it is promoted back into the canonical epic so downstream stories read the fresh plan.

## What changed

- **Promotion mechanism (NEW: `bin/fm-epic-plan-promote.sh`).** `fm-epic-plan-promote.sh <epic-slug> <story-id>` promotes a worker's committed task-time plan over the epic's canonical `stories/<id>-plan/` draft. It locates the epic by its canonical `epic:` slug (reusing `bin/fm-epic-status-lib.sh`), resolves the source from the home's clone (`projects/<repo>/plans/<id>-plan/`) or an explicit `--from` (the worker's worktree plan, for pre-merge promotion at gate-approval time), swaps it in atomically (staged sibling + `mv`, idempotent), and re-runs `bin/fm-epic-lint.sh` so a promotion can never leave the epic contract broken. It writes only under the home's `data/plans/` (firstmate-private state) - never into a project.
- **Always-commit + refresh contract (`bin/fm-brief.sh`).** `--base` is the epic-story signal, so an epic ship brief now carries a `# Epic plan workflow` section instructing the worker to START from the attached upfront plan and REFRESH it against current HEAD (not re-author), when the refresh is MANDATORY (HEAD moved materially / security-sensitive / a scout supersedes the plan) vs. SKIPPED (frozen-contract mechanical), to ALWAYS commit the task-time plan under `plans/<id>-plan/`, to gate a material divergence at `needs-decision: [key=plan-review]`, and to escalate an epic-breaking discovery to epic-level plan-review rather than silently re-planning around it. An ordinary (no-`--base`) brief is byte-identical to before - the section is scoped to epic stories only.
- **Docs.** `skills/epic-plan/SKILL.md` gains a "plan lifecycle" section (upfront = skeleton + coherence, task-time refresh, plan-review firewall, promotion back to canonical) and `skills/epic-scaffold/SKILL.md` gets a one-line pointer to it (one-owner rule: `epic-plan` owns the lifecycle). `docs/cross-repo-workspaces.md` names the firstmate-side promotion helper and the gate-approval step that runs it.

The plan-review gate (#3) already existed as the norm; this story documents it explicitly and formalizes the promotion (#4) and always-commit (#5) that were previously ad-hoc (lh-14: plan committed 17:44 -> promoted to canonical 17:47 -> lh-15/16 consumed the promoted plan).

## Run

- `evidence/epwf-02/demo.sh` - a hermetic fixture epic (throwaway home under `$TMPDIR`, no real project) that proves the Definition-of-done end to end: the epic ship brief carries the plan workflow; a stale canonical draft is replaced by the worker's refreshed plan on promotion; the downstream story then reads a green epic; and an ordinary brief carries none of it.
- `transcript.txt` - the demo output.

## What the transcript proves matches the DoD

- **Refresh, not re-author, in the brief.** Step 1 shows the generated epic brief's `# Epic plan workflow`: START from the upfront plan and REFRESH against HEAD, the mandatory/skip condition, ALWAYS commit under `plans/svc-01-plan/`, the `key=plan-review` divergence gate, and the escalate-to-epic-level rule.
- **Promotion replaces the stale draft.** Steps 2->4: canonical `svc-01-plan/plan.md` goes from the stale design-time draft ("Button importers: 35") to the refreshed HEAD-bound plan ("16, not 35") after `fm-epic-plan-promote.sh demo svc-01`.
- **Downstream reads the fresh plan on a green epic.** Step 5: the epic lints green after promotion (`epic lint OK: "demo" - 2 stories`), so svc-02 (depends on svc-01) dispatches against the promoted, valid plan.
- **Scoped to epic stories.** Step 6: an ordinary brief with no `--base` carries no `# Epic plan workflow` section, so non-epic dispatch is unchanged.

## Tests

- `tests/fm-epic-plan-promote.test.sh` (NEW): the worked example (promote from the clone; the stale draft's files are gone, the refreshed plan is in, and the downstream epic stays green), plus `--from` pre-merge promotion, replace-not-merge, idempotency, and the guardrails (unknown epic, story not in the epic, missing/planless source, refused self-promotion, and the post-promote lint gate failing loudly).
- `tests/fm-brief.test.sh`: a new case asserts the epic plan-workflow section (refresh, mandatory/skip, always-commit under the story's own plan dir, plan-review gate, escalate-epic) appears with `--base` and is absent without it.
- No epflow gate regressed: `tests/fm-epic-lint.test.sh`, `tests/fm-epic-status.test.sh`, `tests/fm-epic-branch.test.sh`, and `tests/fm-epic-ship.test.sh` stay green.
