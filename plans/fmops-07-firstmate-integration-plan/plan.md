---
plan: fmops-07-firstmate-integration-plan
epic: fmeng-taskops
story: fmops-07-firstmate-integration
kind: implementation-plan
created: 2026-08-24
author: crewmate (task-time ak:plan)
sources:
  - plans/260824-1046-epic-fmeng-taskops/stories/fmops-07-firstmate-integration.md
  - plans/260824-1046-epic-fmeng-taskops/REDESIGN-NOTES.md
  - plans/260824-1046-epic-fmeng-taskops/architecture.md
  - plans/260824-1046-epic-fmeng-taskops/playbook-draft.md
  - plans/260823-2058-epic-fmops-taskmodel/stories/fmops-04-native-engine-plan/plan.md
  - nphattai/tasks-axi@0.3.0 (merged, branch epic/fmeng-taskops)
base: epic/fmeng-taskops
---

# fmops-07 - Firstmate integration task-time plan

Refresh of PR-2 of the approved plan (`fmops-04-native-engine-plan`), folding in the four extra workstreams the captain locked on 2026-08-24: injectable playbooks, dropped `/epic-plan`, config two-layer split, decisions register.
All five workstreams land in ONE PR against `epic/fmeng-taskops`.

## 0. Scope contract

Five workstreams from story fmops-07 §1-5.
Deliver every scoped item; ponytail governs HOW (smallest reused-first diff, colocated tests, one runnable check per non-trivial logic).
Cross-cutting invariant: no secret is ever committed; every skill loader/pointer contract keeps one owner.

## 1. HEAD reality vs plan anchors (current worktree)

Anchors from the story validate cleanly against HEAD; line numbers drifted by 20-40 lines in a few files, so the plan below uses symbol/context matches instead of raw line refs.

- `bin/fm-umbrella-promote.sh` - `manual_add` at L696 (awk render), `tasks_axi add` at L722, `tasks_axi update` at L262: intact.
  Verified `manual_add`'s current line does NOT emit `parent:` today.
- `bin/fm-brief.sh` - scout report path at L369 (`Write your findings to \`$DATA/$ID/report.md\``); a separate ship-brief DoD lower down needs the same native-path change and the render-from-story extension.
  No `## Skill workflow` block exists yet (was never added since `fmops-07-worker-skill-playbook` was superseded by this story's SOFT-layer redesign).
- `bin/fm-teardown.sh` - `bridge_report_into_epic()` at L906, `--note "report: …"` workaround at L934: intact.
- `bin/fm-epic-status-lib.sh` - `epic_report_symlink` helper at L304: intact.
- `bin/fm-spawn.sh` - no `parent:` / `[epic]` admission assert today; needs adding.
- `bin/fm-tasks-axi-lib.sh` - `FM_TASKS_AXI_MIN=0.2.4` at L37; two capability probes (`--archive-body`, `mv [<id>...]`) already exist as the reuse pattern for a new `--epic` probe.
- `bin/fm-captain-hold.sh` - the TWO `tasks_axi add` sites are at L548 and L551 (unchanged from the story's citation).
  A larger set of `tasks_axi hold` / `answer` / `unhold` / `done` calls live throughout - `fm-captain-hold.sh` is the current owner of the captain-hold primitive, `fm-decision-hold.sh` (232 lines) is a one-release shim over it.
- `bin/fm-session-start.sh` - context digest section 8 emits `print_file_or_absent` for projects.md, secondmates.md, captain.md, captain-shared.md, learnings.md at L901-905.
  This is the natural injection site for `docs/firstmate-playbook.md` (+ `config/firstmate-playbook.md` override).
- `.agents/skills/decision-hold-lifecycle/SKILL.md` is ALREADY a redirect stub to `captain-hold-lifecycle`.
  The real captain-hold policy owner is `.agents/skills/captain-hold-lifecycle/SKILL.md`.
- `skills/epic-plan/` exists as its own directory; `bin/fm-epic-plan-promote.sh` exists (146 lines).
- `.gitignore` currently has a whole-`config/` gitignore at L13; `AGENTS.md` L43 states `config/` is captain-private/gitignored, and L67-79 enumerate individual config files each marked LOCAL/gitignored.
  `docs/cross-repo-workspaces.md` and `bin/fm-umbrella.sh` L317/319 reference `/epic-plan`.
- Existing `docs/full-flow.md`-equivalent is `docs/cross-repo-workspaces.md`; there is no separate `full-flow.md` in firstmate.
  The plan's `full-flow.md` reference in story fmops-07 is the epic's shared design doc at `plans/260824-1046-epic-fmeng-taskops/full-flow.md`, which is design-time material and stays as-is.

## 2. Sequencing (dependency-ordered, one PR)

The five workstreams have real dependencies that force this order:

1. **W5 - decisions register** (narrows W1's F1 wiring: captain-hold `add` call sites disappear).
2. **W1 - native-engine integration + F1** (with W5 done, F1 reduces to updating documentation on the retired call sites; the `manual_add` awk + engine `add` still need `--epic` wiring).
3. **W4 - config two-layer split** (creates the SHARED committed layer that W2 lives in).
4. **W2 - injectable playbooks** (adds `docs/*-playbook.md`, `config/*-playbook.md` override hooks, `fm-brief.sh` HARD/SOFT split, `fm-session-start.sh` loader, AGENTS.md pointer).
5. **W3 - drop `/epic-plan` + promote helper** (orthogonal cleanup; do last so no unrelated churn earlier).

Each workstream is a self-contained commit (or a small commit chain) so the review can walk them one at a time.

## 3. Workstream W5 - decisions register (captain-holds leave the backlog)

### 3.1 Data model

`state/decisions/` per-home holds one file per open captain-hold, keyed by the task id / composed decision id that used to appear in the backlog.
Rationale: firstmate-private, per-home, existing gitignored `state/` tree already scoped to runtime records; parallels `state/pending-replies/`, `state/procevent/`, `state/decision-bindings/` that already live there.
Each file records: `key` (task id), `origin` (originating task, may be empty), `reason`, `until` (deferral date, if any), `created`, `body` (question + options + provenance), and any `bound-source` reference the `bind` command already writes.

Alternative rejected: `data/decisions.md` (a single append/rewrite file) - concurrency-hostile, and the per-file layout matches how firstmate stores every other structured runtime record.

### 3.2 New library

`bin/fm-decision-register-lib.sh` (new) - the single owner of register CRUD: `open`, `read`, `list`, `close`, `defer`, `divergence-scan`, atomic write with `mktemp` + `mv` (mirrors `fm-captain-hold.sh`'s existing atomic patterns).
Test: colocated `tests/fm-decision-register-lib.test.sh` exercising open/list/close idempotency + concurrent-open race with `flock`.

### 3.3 fm-captain-hold.sh rewrite

Replace the `tasks_axi add` (L548/L551) + `tasks_axi hold ... --kind captain` (L556/L559) minting path with `fm_decision_register_open`.
Keep the "hold an existing work item" path (`tasks-axi hold <existing-id> --kind captain` when the question gates an already-existing task) intact: story §5 keeps the invariant `backlog task == story`, and an existing work item is a story, so holding it is legitimate.
The change is only for the MINT path (no existing task to gate).

Rewrite the read paths (`verify`, `answers`, `answer`, `complete`, `divergence-scan`) to consult BOTH the backlog (for existing-task holds) AND the register (for mint-path decisions).
Preserve keys, idempotency, `resolve`/`decline`/`repair`, and the no-lost-decision guarantee.

The `--kind captain` capability probe in `fm-tasks-axi-lib.sh` stays - existing-task holds still use it.
`fm-decision-hold.sh` (the shim) keeps mapping legacy `<origin>-decision-<key>` commands onto the new register directly.

Tests: colocated `tests/fm-captain-hold-register.test.sh` covering open, answer, defer, resolve-with-routed-work, complete, and RECORD DIVERGENCE across register + backlog.

### 3.4 Bearings + wake drain

`bin/fm-bearings-board.sh` and `bin/fm-bearings-snapshot.sh` today read the backlog for Captain's Call.
Wire them to also read the register.
`bin/fm-classify-lib.sh`'s `status_open_decisions_incremental` and `OPEN DECISIONS` presentation stay unchanged (they read status log, not the backlog); the RECORD DIVERGENCE section extends to compare status keys against register + backlog.

Test: extend the existing bearings test (whichever colocated file covers the board) with a register entry and confirm it appears in Captain's Call with origin grouping.

### 3.5 Skill + AGENTS.md updates

- `.agents/skills/captain-hold-lifecycle/SKILL.md`: replace `tasks-axi hold <id> --kind captain` with "the captain-held task or register entry, whichever the primitive selects", document the mint-path -> register invariant, keep the completion gate + recorded-answer rule verbatim; the file already owns this policy.
- `.agents/skills/decision-hold-lifecycle/SKILL.md`: the shim stays (still a redirect stub), no substantive change; update its description to mention the register alongside the collapsed task-hold primitive.
- `AGENTS.md` §10: add ONE sentence in the "A decision is simply a task held for the captain" paragraph stating the invariant "backlog task == story; mint-path captain decisions live in the firstmate-private register (`state/decisions/`), not the backlog", and cross-reference `captain-hold-lifecycle`.
  Update the config layout §2 later, in W4, when the register is added to the enumerated `state/` list.
- `docs/captain-hold-lifecycle.md`: update the mechanism section to describe the register + how existing-task and mint-path holds share one closure surface.

### 3.6 Migration note (out of PR scope)

The existing backlog decision-holds (distro + aimica) are migrated by the fmops-06 PR-3 migration ops, not by this PR.
Firstmate PR-2 ships the code; migration is a separate ops step.
This plan records the boundary explicitly so reviewers do not expect a data-migration script here.

## 4. Workstream W1 - native-engine integration + F1

### 4.1 `bin/fm-umbrella-promote.sh` - --epic + parent: stamping

- L722 `add` call: append `--epic "$EPIC_SLUG"` and `--child-of` when the id is a follow-up child (none exist in the current seed path, so add only `--epic`).
- L696 `manual_add`: extend the awk output to append ` parent: $epic` at end-of-line so the manual backend matches engine output byte-identically.
- L262 `update` call: no `--epic` needed (id already exists).

Test: colocated `tests/fm-umbrella-promote-epic.test.sh` runs promote on a fixture epic, asserts every seeded row has `[epic]` + `parent:`, and diffs the manual-backend output against the engine output for the same story set.

### 4.2 `bin/fm-brief.sh` - native report path + render-from-story

- Change the scout DoD line at L369 and the equivalent ship-brief DoD line to name the native report path.
- Obtain the path by shelling `tasks-axi report path "$ID"` (no bash string-building; single owner of the path is the engine).
  If the engine call fails at brief-generation time (e.g. task not yet added to backlog), fall back to a computed native path only if the epic slug is derivable from the current epic branch, else fail loudly with a clear message; scout briefs that predate `--epic` seeding stay legacy.
- Render-from-story extension: `fm-brief.sh` writes `data/plans/<epic>/briefs/<id>.md` derived from `stories/<id>.md` (frontmatter + body wrapped in the dispatch scaffold), replacing the `{TASK}` placeholder pattern.
  Keep the legacy `data/<id>/brief.md` path for briefs that have no story (secondmate charters, ad-hoc scouts) - render-from-story fires only when a story file exists.
- HARD skeleton: the phase intents + plan-review GATE + native report path go in the skeleton verbatim; skeleton names NO skill.
  See W2 for the splice.

Test: colocated `tests/fm-brief-native-report-path.test.sh` scaffolds a scout brief for a task with a real epic and asserts the report path line == `tasks-axi report path <id>`; a second case with no epic asserts the legacy path.
`tests/fm-brief-render-from-story.test.sh` scaffolds against a fixture story and asserts the brief body carries the story frontmatter + body under the scaffold, no `{TASK}` residue.

### 4.3 `bin/fm-teardown.sh` - delete the dcen-11 bridge

- Delete `bridge_report_into_epic()` (L906-923), its final call (L2608), and `epic_report_symlink()` in `fm-epic-status-lib.sh` (L304-326).
- Upgrade the scout `done_cmd` at L934 from `--note "report: $report_path"` to `--report $native_path` now that PR-1's out-of-title `report:` token (F2b) makes `done --report` safe.
- Grep-assert zero remaining callers of `bridge_report_into_epic` and `epic_report_symlink` after deletion.

Test: colocated `tests/fm-teardown-native-report.test.sh` runs teardown against a fixture task-with-epic and asserts no symlink was created + the emitted done suggestion uses `--report` with the native path.

### 4.4 `bin/fm-spawn.sh` - admission assert

- Add a cheap pre-dispatch grep against the backlog row: refuse to spawn an id whose row lacks a `parent:` edge / `[epic]` tag.
- Use `fm-crew-state.sh` / existing metadata helpers for the read; no new grammar.

Test: colocated `tests/fm-spawn-admission-assert.test.sh` plants a hand-edited orphan row and asserts spawn refuses with a clear message; a normal seeded id spawns unchanged.

### 4.5 `bin/fm-tasks-axi-lib.sh` - version floor + probe

- Bump `FM_TASKS_AXI_MIN` L37 from `0.2.4` to `0.3.0`.
- Add `fm_tasks_axi_add_has_epic()` mirroring the two existing probes; wire it into `fm_tasks_axi_compatible_probe` chain right after `fm_tasks_axi_mv_has_multi_id`.
- Keep `config/backlog-backend=manual` opt-out working.

Test: colocated `tests/fm-tasks-axi-lib-epic-probe.test.sh` stubs `tasks-axi --version` + `tasks-axi add --help` and confirms the probe passes on 0.3.0 with `--epic` in help and fails on 0.2.5.

### 4.6 F1 reconciliation

With W5 done, the `fm-captain-hold.sh:548/551` add sites are DELETED (mint path moves to the register).
F1's original wiring problem (add without `--epic`) no longer exists there; F1 acceptance folds into W5's tests.

## 5. Workstream W4 - config two-layer split

### 5.1 `.gitignore`

- Remove the whole-`config/` entry at L13.
- Add explicit entries for the LOCAL-SECRET files: `.env` (already listed), `config/backend`, `config/crew-harness`, `config/*-password`, and the machine-local `config/x-mode.env`, `config/calm`, `config/watched-tools.json`, `config/wedge-alarm`, `config/trace-context`, `config/herdr-presentation-spaces`, `config/cmux-socket-password`, `config/startup-memory-budget`.
  SHARED files (`config/crew-dispatch.json`, `config/backlog-backend`, `config/worker-playbook.md`, `config/firstmate-playbook.md`, `config/secondmate-harness`) are NOT gitignored.

Rationale for classification: LOCAL-SECRET is nature-based per architecture.md §10 - anything with a secret, credential, or per-machine dependency stays gitignored; anything a shared setup should inherit is committed.

### 5.2 `AGENTS.md`

- L43: rewrite the "captain-private and gitignored" list to remove `config/` and add a new sentence describing the two-layer split.
- L67-79: for each enumerated config file, correct the "LOCAL, gitignored" label to the file's actual layer (SHARED committed vs LOCAL-SECRET gitignored).
- §10 addition from W5 folds in here.

### 5.3 `docs/configuration.md`

- New section "Config layers (shared vs local-secret)" near the top of the "Operational home layout and state" section.
- Update each existing per-file section to reflect its layer.

### 5.4 Test

Colocated `tests/config-layer-classification.test.sh` reads `.gitignore` + `AGENTS.md` §2 and asserts every listed `config/*` file's classification agrees between the two files; refuses to run without both.
This is the trigger-hygiene check the docs-audience script does not cover.

## 6. Workstream W2 - injectable playbooks (symmetric)

### 6.1 `docs/worker-playbook.md` (Part A ship)

Verbatim from `plans/260824-1046-epic-fmeng-taskops/playbook-draft.md` Part A.
Add a one-line owner comment at the top pointing back to the epic playbook-draft for the derivation.

### 6.2 `docs/firstmate-playbook.md` (Part B ship)

Verbatim from playbook-draft.md Part B.
Same owner comment.

### 6.3 `bin/fm-brief.sh` - HARD skeleton + SOFT splice

- Add a new function `emit_soft_playbook` that reads `$CONFIG/worker-playbook.md` when present, else `$FM_ROOT/docs/worker-playbook.md`, else emits nothing (fail loudly if both are missing when the code enters the splice path).
- Splice its output into the generated ship-brief and scout-brief after the HARD skeleton block.
- HARD skeleton edit: replace any existing baked-in skill-name text with style-neutral phase intents (ground-reality -> plan -> GATE -> implement -> test -> review -> ship) + explicit plan-review GATE + native report path.
  This is the SAME set of instructions the current brief carries under different phrasing; the diff is renaming to phase intents and removing skill names.

Test: colocated `tests/fm-brief-hard-soft-splice.test.sh` scaffolds three cases: (1) no override -> default playbook spliced, (2) override present -> only override spliced (full replacement), (3) both missing -> loud failure with clear message.

### 6.4 `bin/fm-session-start.sh` - firstmate-playbook loader

- Add a print step in section 8 (context digest) after `learnings.md` and before section 9 (closing reminder):
  `print_file_or_absent` on `$CONFIG/firstmate-playbook.md` if present else `$FM_ROOT/docs/firstmate-playbook.md`, labeled "firstmate playbook (SOFT dispatch grammar)".
- Header comment at L7-8 gets updated to reflect the new digest section.
- Read-once contract text (section 5 emit) references the added file.

Safety-boundary note (playbook cannot relax `AGENTS.md`): enforce by prose in `AGENTS.md` §10 addition ("A playbook is guidance, not a safety override; `config/firstmate-playbook.md` cannot relax hard rules, merge authority, or destructive/irreversible/security boundaries") and by NOT loading the playbook before `AGENTS.md` in the digest, so `AGENTS.md`'s later assertions always overwrite in reader memory.

Test: colocated `tests/fm-session-start-firstmate-playbook.test.sh` runs the digest with fixture playbook + fixture override and asserts the correct one is emitted with the labeled marker.

### 6.5 `AGENTS.md` pointer

- Add ONE sentence in the identity/prime-directives section stating "Session start loads `docs/firstmate-playbook.md` (override `config/firstmate-playbook.md`) as the SOFT dispatch grammar; it never relaxes safety boundaries.
  See `docs/firstmate-playbook.md` for the current grammar."
- Skip the file's substance in AGENTS.md (one-owner rule).

## 7. Workstream W3 - drop /epic-plan + promote helper

### 7.1 Deletes

- `git rm skills/epic-plan/` (whole dir).
- `git rm bin/fm-epic-plan-promote.sh`.

### 7.2 References

Remove or reword `/epic-plan` / `fm-epic-plan-promote.sh` references in:

- `skills/README.md` (row + "6 skills" -> "5 skills").
- `skills/epic-new/SKILL.md`, `skills/epic-scaffold/SKILL.md`, `skills/epic-review/SKILL.md`, `skills/epic-handoff/SKILL.md`, `skills/epic-ship/SKILL.md` (the 5 sibling skills; each has the "It is one of six epic-pipeline skills" maintainer comment naming `/epic-plan` - correct to five).
- `skills/epic-scaffold/SKILL.md` L60-61, L109 (plan-section is now a POINTER placeholder authored fresh at task-time under the plan-review GATE; the `/epic-plan` next-step edge disappears -> next-step becomes `/epic-review`).
- `bin/fm-umbrella.sh` L317-319 (rewrite the pipeline sentence to five skills).
- `docs/cross-repo-workspaces.md` L107-113 (same rewrite; drop the "promote back into canonical" flow entirely - the task-time plan lives with the worker's HEAD).
- `.agents/skills/umbrella-lab/SKILL.md` L54 (five skills).
- `docs/documentation-audiences.json` L444 (remove the `skills/epic-plan/SKILL.md` row).

### 7.3 Lint stays green

`bin/fm-epic-lint.sh` already treats an absent/templated plan pointer as not-yet-planned (verified in the story).
Test: colocated `tests/fm-epic-lint-no-upfront-plan.test.sh` scaffolds a fresh epic with no plan directories and asserts `fm-epic-lint.sh` exits 0.

## 8. Cross-cutting

### 8.1 Compatibility axes (per firstmate-coding-guidelines)

- Primary harnesses: `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, `muse` (scout/crewmate only), `omp`.
  None of them are dependency-relevant to these changes (all changes are in shared bash tooling + docs).
- Runtime backends: `tmux`, `herdr`, `zellij`, `orca`, `cmux`, `codex-app`.
  No backend-specific code path changes.
- The `docs/verification/runtime-backends.md` evidence needs no refresh (no harness-dependent classifier changed).

### 8.2 One-owner rule (per firstmate-coding-guidelines)

- Playbook draft is the derivation source; `docs/*-playbook.md` are the ship owners; `config/*-playbook.md` overrides are full replacements.
  `AGENTS.md` pointer is a trigger, not a restatement.
- Native report path: engine's `tasks-axi report path` is the ONE owner; `fm-brief.sh` and `fm-teardown.sh` both shell out to it.
- Decisions register: `fm-decision-register-lib.sh` is the ONE owner; `fm-captain-hold.sh`, bearings, and the wake drain all call through it.
- Config layer classification: `.gitignore` + `AGENTS.md` §2 stay byte-consistent via the colocated test.

### 8.3 Firstmate-repo tests

Each changed bin script gets a colocated `tests/<script>.test.sh` (or extends an existing one) per the coding guidelines.
No new test runners; extend `bin/fm-test-run.sh` if a new test suite name is needed.

### 8.4 Rollback

Everything ships in one PR against `epic/fmeng-taskops`; `git revert` on the PR merge restores the pre-integration state.
The floor bump is the one cross-cutting line - reverting drops `FM_TASKS_AXI_MIN` back to `0.2.4`.

## 9. Definition of done (mirrors story fmops-07 §DoD)

- W1: fm-* pipeline honors the native engine; F1 folded into W5's register; symlink bridge + `--note` workaround gone.
- W2: `fm-brief.sh` emits HARD skeleton + splices SOFT worker playbook; `fm-session-start.sh` loads firstmate playbook; `AGENTS.md` pointer added; overrides work as full replacements; safety boundary documented + structurally enforced.
- W3: `/epic-plan` + `fm-epic-plan-promote.sh` gone; five sibling skills + README + docs no longer reference them; lint green on a scaffolded not-yet-planned epic.
- W4: `config/` is a two-layer split in `.gitignore`, `AGENTS.md` §2, `docs/configuration.md`; no secret committed; both SOFT playbook overrides live in the SHARED committed layer.
- W5: `fm-captain-hold.sh` mint-path writes the firstmate-private register instead of `tasks-axi add + hold --kind captain`; keys, completion gate, resolve/decline/repair, no-lost-decision guarantee preserved; Bearings + wake drain read the register; `captain-hold-lifecycle` skill + `AGENTS.md` §10 updated; invariant "backlog task == story" recorded.
- Every non-trivial changed bin script has a colocated test; `bin/fm-lint.sh` green; `bin/fm-doc-audience-check.sh` green.

## 10. Open questions for plan-review

1. **Decisions register file layout.** Proposed `state/decisions/<key>.md` per-home (one file per open decision, mirroring `state/pending-replies/`, `state/procevent/`).
   Story wording says "e.g. `data/decisions.md` / `state/decisions/`" - captain preferred single-file `data/decisions.md`?
   Ponytail bias: per-file `state/decisions/` (concurrency-safe, matches existing runtime record convention; append-heavy single-file is race-prone with the wake drain's concurrent writers).

2. **F1 wiring under W5.** With mint-path decisions moving to the register, `fm-captain-hold.sh:548/551` `tasks_axi add` calls are DELETED, not `--epic`-wired.
   The story confirms F1 narrows; the plan reads that as "delete those two call sites entirely."
   Confirm this reading; if instead the captain wants a belt-and-suspenders `--epic` wiring even though the call is retired, the plan grows a fallback-branch commit.

3. **Render-from-story boundary.** The plan renders from `stories/<id>.md` when it exists; secondmate charters + ad-hoc scouts (no story) keep the current `{TASK}` placeholder flow.
   Confirm this split, or does W2 require every brief to have an authored story?

4. **Backwards compat for existing captain-holds in the backlog.** Distro + aimica have live `<origin>-decision-<key>` rows in their backlogs today; the fmops-06 PR-3 migration ops moves them into the new register.
   This PR ships the code; PR-3 does the data move.
   Does firstmate-repo need a one-shot in-place reader that also handles legacy backlog decision-holds during the soak period, or is the strict "old shim writes new register; distro/aimica migrated separately" boundary acceptable?

5. **Playbook safety-boundary enforcement.** The plan enforces "playbook cannot relax `AGENTS.md`" by (a) prose in AGENTS.md §10 and (b) load order (AGENTS.md loads first, playbook after, reader's latest-write wins for `AGENTS.md`).
   No mechanical parser refuses a playbook that tries to relax a hard rule.
   Ponytail: prose + load order is sufficient because the model reads both files and AGENTS.md's assertions take precedence.
   Confirm no code-level enforcement is required.

6. **`fm-brief.sh` render-from-story vs the render-from-story deferred plan §2.2.** The approved base plan §2.2 folds render-from-story into PR-2 with the same-commit acceptance.
   The plan puts it in W1 (§4.2) as a single fm-brief.sh change; the SOFT splice (W2 §6.3) is a subsequent edit to the same file.
   Two commits on one file are fine; confirm no preference for a single unified commit.

7. **`docs/full-flow.md`.** Story wording says "update `full-flow.md`-equivalent pipeline docs".
   Firstmate has no `full-flow.md`; the equivalent is `docs/cross-repo-workspaces.md`.
   Plan updates that.
   The epic's own `full-flow.md` (in the epic plan dir) is design-time material and stays put.
