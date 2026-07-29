# Task report archive

The normative policy for when a report is required, how investigations complete, and how teardown behaves is owned by `AGENTS.md` and `.agents/skills/decision-hold-lifecycle/SKILL.md`.
This document owns the archive layout, finalization command, and teardown integration only.

## Layout

During a task, scouts write their working copy to `data/<task-id>/report.md` under the active `FM_HOME`.
That path is private home data, never inside the project worktree.

When a task is ready for cleanup, `bin/fm-report-finalize.sh` captures the deliverable into the canonical archive:

- `data/reports/<project>/` holds one project namespace.
- `data/reports/<project>/<task-id>.md` is the stable archived artifact name.
- `data/reports/<project>/INDEX.md` is regenerated on every finalize and lists archived task ids.

Task metadata records `report_archive=data/reports/<project>/<task-id>.md` and `report_finalized=1` after a successful finalize.

## Finalization

```text
bin/fm-report-finalize.sh <task-id>
```

Scout tasks require the working report, a completed unresolved-decision inventory (`bin/fm-decision-hold.sh verify`), and unambiguous task metadata including `project=`.

Ship tasks accept an optional working report.
When none exists, finalize synthesizes a short structured delivery receipt from task metadata and the terminal `done:` or `failed:` status line.

The command is idempotent for identical content, refuses conflicting archive bytes, and never mass-moves historical reports.

## Teardown integration

`bin/fm-teardown.sh` calls finalize for ordinary ship and scout tasks before destructive cleanup.
The `--force` discard path skips finalization, matching the existing scout-report escape hatch.

Secondmate retirement is unchanged; secondmate homes are not archived through this command.

## Brief contract

`bin/fm-brief.sh` scaffolds scouts to write only to the private home path `data/<task-id>/report.md`.
Ship briefs do not require a verbose report; delivery evidence lives in branch, PR, or local-only status until finalize archives the receipt.
