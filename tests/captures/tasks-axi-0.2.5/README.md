# tasks-axi list captures

These files own recorded `tasks-axi list` stdout for the adapter cases in `../../fm-fleet-snapshot-view.test.sh`.
They were captured on 2026-10-02 with `tasks-axi 0.2.5` and the Beads backend (`br 0.7.3`) in an isolated fixture home with fixture-only rows.
They are replay inputs for shapes a real adapter cannot be made to emit on demand, not evidence that the composed scenarios were driven live; the same test file also drives the real installed `tasks-axi` and `br` when both are present.

## Capture provenance

Every list file is unchanged stdout from `tasks-axi list --fields blocked,blocked_by,closed,created,deps,held,hold_kind,hold_reason,hold_until,links,priority` run from the fixture home that holds the Beads workspace.
The snapshot reader asks for exactly these fields, so the header columns are `id,state,kind,repo,title` followed by them in that order.
Stderr was empty and the exit status was zero for every list capture.

| File | Observed state |
| --- | --- |
| `list-all-states.toon` | Seven rows: in flight, queued with a blocker and a PR link, a captain hold with a long reason, a done row with a PR link, a long truncated title, two PR links, and a PR URL and report path that both contain commas |
| `list-limited.toon` | The same home read with `--limit 3`, which prints `count: 3 of 7 total` |
| `list-empty.toon` | A genuinely empty initialized backend |
| `error-unavailable.toon` | A configured Beads binary that is not on `PATH`: TOON diagnostic on stdout, exit status 1 |

The test edits copies of `list-all-states.toon` to build malformed and unparseable-link cases; the captures themselves stay unchanged.
