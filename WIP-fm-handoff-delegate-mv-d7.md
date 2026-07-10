# WIP: delegate fm-backlog-handoff.sh move mechanics to `tasks-axi mv`

Status: PARKED, blocked on a `tasks-axi mv` enhancement (escalated upstream).
No production code changed yet; `bin/fm-backlog-handoff.sh` is still the working awk version so this branch stays functional.
This note preserves the verified design and evidence so the refactor can be finished without re-deriving anything once the enhanced `tasks-axi` is installed.
Delete this file as part of finalizing the real refactor.

## The blocker (why this is parked)

`tasks-axi mv` (v0.2.1) cannot atomically relocate a set of items that reference each other via `blocked-by` across backlog files.
It deadlocks in both possible orders:

- `tasks-axi mv <blocker>` is refused with `"Task \"<blocker>\" is still blocking active tasks: <dependent>"` while the dependent still sits in the source backlog.
- `tasks-axi mv <dependent>` is refused with `"blocker \"<blocker>\" not found"` because the dependent's blocker is not yet present in the destination backlog.

So the dependent must leave the source before the blocker can move, but the dependent cannot land in the destination until the blocker is already there.
There is no escape hatch: `mv` rejects two positional ids (`"Expected 1 positional argument, got 2"`), rejects `--force` and `--no-check` (`"Unknown flag"`), and exposes only `--json`.

This is a required capability, not a corner case.
`tests/fm-secondmate-lifecycle-e2e.test.sh` (`phase_handoff`) hands off `feat-x` + `feat-y` together, where `feat-y` is `blocked-by: feat-x`, and asserts `feat-y` arrives verbatim.
A secondmate domain naturally contains items that depend on each other, so handing the domain off must move them together with the relationship intact.
The old awk did this because it moved lines as plain text; the delegated path cannot until `tasks-axi mv` learns connected-set moves.

Per the task's hard constraint, the format logic was NOT forked back into bash, and no `unblock -> mv -> reblock` orchestration was added (that would re-introduce dependency logic into the helper, which is exactly what this refactor removes).

### Required `tasks-axi` enhancement (separate task in that repo)

`tasks-axi mv` should relocate a dependency-connected set atomically, for example by accepting multiple ids (`tasks-axi mv <id>... --to <dest>`) and validating referential integrity against the combined post-move state rather than per-single-id, so intra-set `blocked-by` edges are preserved.
When that interface exists, revisit whether the helper passes the whole `TO_MOVE` list to one `mv` call (batch form) or keeps a loop.

## Verified `tasks-axi mv` semantics (v0.2.1)

Command shape: `tasks-axi mv <id> --file <source-backlog> --to <dest-backlog>`.
Empirically confirmed against the exact fixtures the regression matrix uses:

- Moves the full item block byte-exact: header, body lines, blank separators inside a multi-paragraph body, and indented pseudo-headings (`  ## Intent`, `  ## Acceptance`) all move whole and stay body, not section boundaries.
- Preserves destination section placement: a queued item lands under `## Queued`.
- Preserves the source's untouched-item terminator: a final item with no trailing newline keeps no trailing newline after the move.
- Canonicalizes destination whitespace differently from the old awk: `tasks-axi` puts the blank separator before the following `## Done` heading rather than after the `## Queued` heading, and normalizes a non-canonical destination toward the standard section set.
  This is fine because `tasks-axi` now owns the format; it only means two whole-file `cmp` fixtures in the test must be regenerated (see below).
- Does not add missing sections to the source; it only removes the moved block.

## Design of the refactored `bin/fm-backlog-handoff.sh`

KEEP (fleet-level validation `tasks-axi` cannot know):

- `secondmate_home` resolution from `data/secondmates.md`.
- `validate_secondmate_home` and `validate_operational_dirs` (the `.fm-secondmate-home` marker check, AGENTS.md/bin presence, and the ancestor/containment safety checks) so the destination is proven a genuine seeded secondmate home and never a project clone.
- `validate_backlog_file` (reject symlink / non-regular-file backlog paths).
- `backlog_key_section` classification and the `TO_MOVE` / `ALREADY` / `MISSING` / `IN_FLIGHT` loop, including the `## In flight` refusal (complementary to, not equivalent to, `tasks-axi mv`'s dependency guard) and the atomic "abort with no changes if any key is missing or in-flight".
- Idempotent per-key reporting: a key already present in the destination is reported and skipped, so re-running converges.
- Seeding the destination backlog with `## In flight\n\n## Queued\n\n## Done\n` when it does not yet exist, so a fresh secondmate home starts from the standard scaffold.

DELETE (second parser of the backlog format; the source of the PR #401 body-orphaning drift):

- Pass 1 awk that drops each matched block from the main backlog.
- Pass 2 awk that re-inserts blocks into the destination.
- The `file_ends_with_lf` helper and the surrounding temp-file / backup / manual-rollback machinery that existed only to make the awk edits atomic.

REPLACE the move with delegation:

- For the `TO_MOVE` keys, call `tasks-axi mv "$key" --file "$MAIN_BACKLOG" --to "$SUB_BACKLOG"` (single-id form today; batch form once the enhancement lands).
- Let `tasks-axi mv`'s own dependency guard stand as the complementary safety check.

## Test changes needed (once the enhanced `tasks-axi` is installed)

`tests/fm-backlog-handoff.test.sh`:

- Add a skip guard at the top matching the repo idiom: `command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the delegated handoff path)"; exit 0; }`.
- The `extract_item_block` block-equality tests and the grep/no-grep orphan checks pass unchanged (the block content moves byte-exact).
- `test_untouched_eof_line_preserves_terminator` asserts only the SOURCE via `cmp`; it passes unchanged (source terminator is preserved).
- Two whole-file destination `cmp` fixtures must be regenerated to `tasks-axi`'s canonical whitespace (blank before `## Done`, not after `## Queued`): `test_eof_body_before_seeded_destination_section_keeps_boundary` and `test_body_moves_when_last_lines_of_file`.
  For `test_body_moves_when_last_lines_of_file`, also seed the destination with the full `## In flight` / `## Queued` / `## Done` scaffold (what the script actually creates) instead of a bare `## Queued`, so the assertion reflects real usage rather than a malformed destination.

`.github/workflows/ci.yml`:

- The `tests` job does not install `tasks-axi` today, and no current test needs a real one (the bootstrap suite stubs it).
- Add `npm install -g tasks-axi` (a recent version that has `mv`) to the `tests` job so the delegated path is genuinely exercised in CI; the skip guard keeps local/other environments without it green.
- This is consistent with acceptance criterion 3: bootstrap requires `tasks-axi` on PATH fleet-wide regardless of the `config/backlog-backend=manual` knob (which governs firstmate's own hand-editing, not this validated helper).

`tests/fm-secondmate-lifecycle-e2e.test.sh` and `tests/fm-secondmate-safety.test.sh`:

- The safety refusal cases (unmatched, in-flight, unregistered, unsafe homes) abort inside the pure-bash validation layer and are unaffected.
- The successful-move cases (`phase_handoff` moving `feat-x` + `feat-y`; safety's `archive shipped-task`) exercise `tasks-axi mv` and need the same skip guard; `phase_handoff` is the connected-set case that requires the enhancement before it can pass.

## Documentation changes needed (acceptance criterion 3)

- `bin/fm-backlog-handoff.sh` header: rewrite to state that the block move is delegated to `tasks-axi mv` (the one owner of the backlog format) and that the helper keeps only the fleet-level validation `tasks-axi` cannot know.
- Confirm `AGENTS.md` line ~859 stays accurate: "do not call bare `tasks-axi mv` for this path, because the helper resolves and validates the secondmate home before moving anything."
- Confirm `docs/configuration.md` line ~12 stays accurate: the helper keeps secondmate transfers behind its validation while delegating the move.
- State (header and/or `docs/configuration.md`) that `config/backlog-backend=manual` governs firstmate's own hand-editing, not this validated helper, and that bootstrap requires `tasks-axi` on PATH regardless, so delegation works fleet-wide.

## Resume checklist

1. Confirm the enhanced `tasks-axi` is installed and learn its exact connected-set / multi-id `mv` interface (`tasks-axi mv --help`).
2. Re-run the deadlock fixtures to confirm a `blocked-by` pair now moves; capture the exact command form that works.
3. Refactor `bin/fm-backlog-handoff.sh` per the design above.
4. Update the tests and CI per the sections above; regenerate the two `cmp` fixtures from real `tasks-axi` output.
5. Run `tests/fm-backlog-handoff.test.sh`, `tests/fm-secondmate-lifecycle-e2e.test.sh`, `tests/fm-secondmate-safety.test.sh`, and `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`.
6. Delete this WIP note, commit, and proceed to `/no-mistakes`.
