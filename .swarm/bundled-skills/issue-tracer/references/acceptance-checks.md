# Acceptance Checks and the Red Checkpoint

Use this reference for Phase 2.5 (freezing the checks) and Phase 4 (proving they flip). The loop replaces ritual TDD with acceptance-test-driven development: every acceptance criterion becomes an executable check, proven to fail on the pre-fix tree for the right reason, frozen before any fix code exists, and independently replayed by the plan critic and the implementation reviewer. Method grounding is cited by title/URL in `references/method-provenance.md`; treat reported figures as reported, not re-derived.

## The loop

1. For every numbered acceptance criterion (`ACn`) in `01-issue-summary.md`, write exactly one row in the `## Acceptance checks` table appended to `02-reproduction.md` (see `references/evidence-artifacts.md` for the exact header and column set). The `argv` cell must never contain a literal `|` - `trace-check.sh` splits each row on `|`, so a pipeline in `argv` corrupts the row; write the pipeline as a small script under `repro/` and put the script's invocation in `argv` instead.
2. Run the executable classes against the pre-fix tree with `repro-check.sh run`. A DISCRIMINATING check that also passes on the buggy tree is vacuous and rejected - it carries no information about whether the bug is fixed (the bug-contrast replay rule below).
3. Freeze the check set with `repro-check.sh checkpoint` before any production fix code exists. The checkpoint tree-id must differ from the Phase 0 tree-id only by paths listed in `repro/checkpoint.manifest` - this is validated mechanically at `trace-check.sh phase 2.5`.
4. Phase 4 re-runs every check against the fixed tree; results are appended to the same table's `post-fix` column and echoed in `08-test-results.md`.

The acceptance-table parser accepts either LF or CRLF line endings by removing
only each record's terminal CR before matching the header and rows. Embedded
C0/DEL control bytes (including controls in `AC`, `class`, `check`, `argv`,
`expect`, or `notes`) and rows without exactly ten pipe-separated fields are
rejected before any cell is used in a diagnostic. This keeps table validation
and the semantic digest deterministic across Windows and POSIX checkouts.

## The three executable classes, plus NON-EXECUTABLE

- **DISCRIMINATING** - behavior the bug breaks. Must be RED on the pre-fix tree for the expected reason (base exit nonzero and output matching `--expect`), GREEN after the fix. This is the class the bug-contrast replay rule applies to hardest.
- **PRESERVING** - behavior that must not change: compatibility, safety negatives, existing callers named by the impact analysis. Must be GREEN before and stay GREEN after.
- **NEW-SURFACE** - the check exercises a symbol, file, or script that does not exist at base, so a RED result is impossible by construction; the base run is an expected ERROR instead. Evidence is GREEN on the fixed tree plus a mandatory Phase 4.5 revert/mutation probe on the new code. A NEW-SURFACE row can never be satisfied by a rule-out - it always needs the probe.
- **NON-EXECUTABLE** - closed reason enum only: `DOCS_ONLY`, `HOST_ONLY`, `PRODUCT_DECISION`, `EXTERNAL_SERVICE_UNAVAILABLE`. Each requires named substitute evidence (a captured manual procedure, a doc diff, or a dry-run transcript) in the `notes` column, and is forbidden whenever an isolated fixture or synthetic instance could make the criterion executable instead. Nondeterministic behavior (flaky timing, races) gets a synthetic-instance DISCRIMINATING check - never a NON-EXECUTABLE row. The plan critic approves every NON-EXECUTABLE row individually before APPROVE.

## Bug-contrast replay

A DISCRIMINATING check only counts once `repro-check.sh run` has shown it failing on the pre-fix tree for the expected reason (`--expect` regex match on the base log). A check that passes on both the buggy and the fixed tree proves nothing about the bug and is rejected - this is the load-bearing finding behind this whole loop: a meaningful share of "test passed" validation events in agentic repair carry no information because the check also passes on unfixed code, and replaying checks against the pre-fix state is what catches it (see `references/method-provenance.md`). A PRESERVING check counts only after it is shown GREEN on the pre-fix tree - a PRESERVING row that is RED at base is not proving preservation, it is a mislabeled DISCRIMINATING row.

## Test-author context (roles only)

Research measured that an agent's own generated tests overfit toward validating that same agent's own patches. Where subagent dispatch is available, use a fresh, independent context to author the checks: it receives the issue summary and the root cause, never a candidate fix, and hands back checks the implementer later receives as a frozen spec it cannot edit. A different model family is preferred where the runner's routing allows one, because a same-family fresh context reduces but does not eliminate the overfitting risk the research measured - this stays a role/tier description, never a named vendor or model. Check authoring is mechanical, so route it to the runner's lowest-cost tier that can plausibly succeed; reserve the strongest independent tier for the plan critic and the review gates. Without dispatch, the orchestrator authors and freezes the checks itself, and the plan critic independently replays them before APPROVE; that limitation is disclosed in `06-critic-review.md` and the final response.

## Red checkpoint manifest and amendment procedure

`repro/checkpoint.manifest` lives in the git-excluded trace directory and is written only by `repro-check.sh checkpoint`; `repro-check.sh verify-checkpoint` replays it. The format is defined by the script itself: a `# issue-tracer checkpoint manifest v1 rows=<N>` header line, where `<N>` is the number of data rows and is restamped on every append, then one tab-separated row per checkpoint event with exactly ten fields - seq, kind (`CHECKPOINT` or `AMEND`), path, blob id, mode, check id, argv, expected regex, base SHA, and reason. Manifest identity is the `(path, check-id)` pair, so distinct checks may share a path when they capture the same current bytes. Files are formatted with the repo's own formatter before hashing, and new checks live in their own new files (never appended to an existing file already at the 500-line test-file cap) so a later formatter pass does not silently change a frozen blob.

Four properties are mechanically enforced, by both `checkpoint` and `verify-checkpoint`. First, **a frozen pair cannot be re-frozen**: once a `(path, check-id)` pair appears in the manifest, a plain `repro-check.sh checkpoint` on that pair exits 2, while a different check id may checkpoint the same path only after hashing the current bytes. `verify-checkpoint` independently rejects any later row for the same pair that is not an `AMEND`, so a forged duplicate `CHECKPOINT` row is refused too, and an `AMEND` must name an existing exact pair. Second, **the effective manifest has one blob per path**: multiple check ids sharing a path are deduplicable only when their latest blobs are identical; divergent effective blobs fail closed instead of becoming path-only last-writer-wins. Third, **the recorded row count is validated**: the header's `rows=<N>` must equal the number of data rows actually present. Fourth, **seq continuity is validated**: the seq column must run 1..N with no gaps and every row must carry exactly ten fields. The count and seq checks are complementary and neither is sufficient alone - seq continuity is only a *prefix* invariant, so truncating the tail (`head -3`, or dropping the last row) leaves the survivors perfectly contiguous; the count is what catches that, and seq is what catches a deletion in the middle. Together they make deleting, truncating, reordering, duplicating, or mangling a row exit 2 in both commands instead of silently dropping that check out of the replay set.

These row-shape properties do not by themselves inspect frozen content. The external checkpoint anchor below binds both content identity and the ordered acceptance-table semantics. Reviewers must retain the literal receipt emitted before implementation and verify it after the fix. The manifest and table remain agent-writable trace artifacts, so an in-place field edit, a semantic-table edit, a delete-and-refreeze, or a restamped state file is not independently authoritative; the old receipt is what makes those changes fail closed. A byte-identical refreeze is valid because it preserves the anchored digests and checkpoint tree id.

So be precise about what is bought. The manifest-only rules close the ACCIDENTAL routes - a partial write, a botched hand edit, a truncating rewrite - and they close the one route that previously needed no editing at all: re-running the sanctioned freeze command to re-baseline a weakened check to green. A deliberate manifest edit or delete-and-refreeze fails when a reviewer verifies the pre-implementation external receipt. The plan critic and implementation reviewer still assess the semantic adequacy of the originally frozen checks; receipt verification does not make a weak check meaningful. Treat the manifest as a record to verify, never as a guarantee that its checks are adequate. A `v1` header with no `rows=` count is rejected outright for the same reason - accepting it for compatibility would itself be a one-line way to switch the count check off.

Amending a frozen check (the check was wrong or the acceptance criterion changed) appends a new manifest entry rather than editing the old one, with a closed reason: `CHECK_WRONG` or `AC_CHANGED_BY_USER`. Both reasons require a fresh RED/GREEN replay before the amendment counts. Formatting changes to a frozen file are not a special exemption: use `CHECK_WRONG` or `AC_CHANGED_BY_USER` only when the check is genuinely being amended, then replay and review the result. The plan critic (before implementation) or the implementation reviewer (after) approves every amendment. Deleting or weakening a check to reach green, instead of amending it with a recorded reason, is a Full-Resolution Contract anti-tampering violation (clause 8).

## External checkpoint anchor

After the final Phase-2.5 checkpoint and before any production edit, run `repro-check.sh anchor --slug <slug>`. It first verifies the manifest and that every executable table row's `check`, `argv`, and `expect` matches the effective manifest, then emits exactly one line in this shape:

```text
issue-tracer-checkpoint-v1 slug=<slug> manifest=<40-hex manifest blob> semantics=<40-hex acceptance-table digest> tree=<40-hex checkpoint-tree-id>
```

The implementation owner publishes that literal in the issue, PR, or other reviewer-visible external conversation and records the artifact location in the trace as a non-authoritative discovery copy. Publication and its before/after timing are human-enforced: `trace-check.sh` cannot observe that external conversation. The owner must not regenerate it after implementation begins. An independent reviewer copies the published literal into `repro-check.sh verify-anchor --slug <slug> --receipt '<literal>'`; verification compares the current manifest digest, the current ordered `AC/class/check/argv/expect` digest, and `state.md`'s recorded `checkpoint-tree-id`. It deliberately does not compare the live working-tree tree, which changes as the fix is implemented. Malformed, stale, tampered, semantic-table-edited, or delete-and-refreeze evidence fails closed; a byte-identical refreeze remains valid because it has the same content identity.

Receipt compatibility is intentionally strict: the pre-semantics receipt
syntax (the same `issue-tracer-checkpoint-v1` prefix without a `semantics=`
field) is rejected as `malformed anchor receipt`. There is no safe migration
or placeholder digest, because that old receipt never bound the acceptance
table's `AC/class/check/argv/expect` semantics. A trace with only an old
receipt must be rechecked and re-anchored before implementation; once
implementation has begun, stop and obtain a new reviewed checkpoint rather
than regenerating the receipt silently.

## Dependency strategy

`repro-check.sh run` defaults to `--deps link`: if the repo root has `node_modules` (or the equivalent) and the temporary worktree does not, it is linked in rather than reinstalled, so checks run fast and against the same dependency tree as the rest of the session. `--deps none` skips this for checks with no such dependency. Never use a live install inside the throwaway worktree for a check that is expected to run repeatedly during Phase 2.5/4/4.5 iteration - that reintroduces the cost the link mode avoids.

## Characterization tests

When the fix touches a code path with no existing test coverage and the change puts existing behavior at regression risk, pin the current behavior with a PRESERVING characterization test before writing the fix - this is a stronger commitment than the general "PRESERVING" class, because its whole purpose is guarding against your own change rather than a pre-existing caller.

## Ranking-after-critic-replay rule

Multi-candidate patch trials (Phase 3, "may" for close calls) rank candidates by which acceptance checks they green, then by minimality - but only after the plan critic has independently replayed the frozen checks. Ranking candidates by self-authored checks before that replay reintroduces exactly the same-agent overfitting risk the separate test-author context exists to avoid.

## Tautology and revert/mutation probe recipes

A tautology check is one that passes regardless of the underlying logic (e.g. asserting a call happened without asserting its result, or asserting a mocked stub's own return value). Scan for these during Phase 4.5: does the check fail if the fix line is reverted? Does it fail if a single boundary condition in the fix is mutated (flip a comparison operator, invert a boolean, off-by-one an index)? A check that survives its own revert/mutation probe unchanged is a tautology and must be rewritten before it can satisfy any class, DISCRIMINATING or NEW-SURFACE.

Minimal recipe: `git stash` the fix hunk (or apply the inverse patch) in the throwaway worktree, re-run the check with `repro-check.sh run` against that reverted tree, and confirm it goes RED; restore the fix and confirm GREEN again. For NEW-SURFACE rows this probe is mandatory, not optional, because the base run can never independently demonstrate discrimination.

## Tier scaling

- **Tier S**: separate check-author context is optional; the revert/mutation probe is optional unless a NEW-SURFACE row or a risk trigger is present.
- **Tier M/L**: a separate check-author context is required when subagent dispatch is available, and the revert/mutation probe is required for every DISCRIMINATING check at tier L, and for any check touching a risk-trigger surface at tier M.

## When the path does not apply

Some issues (pure documentation fixes, non-executable product decisions already resolved by classification) have no meaningful acceptance check at all. Use NON-EXECUTABLE rows with named substitute evidence rather than forcing an artificial executable check, and let the plan critic confirm the justification is real rather than a shortcut around the loop.
