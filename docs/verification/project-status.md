# Project status projection verification

Maintainer-verification record for the `fm-project-status.v1` projection and the cache-write-free fleet snapshot mode described in [`architecture.md`](../architecture.md).
The script headers in [`fm-project-status.sh`](../../bin/fm-project-status.sh) and [`fm-fleet-snapshot.sh`](../../bin/fm-fleet-snapshot.sh) own the exact schemas, limits, and mechanics.

## What was run

Date: 2026-09-10.
Tree: this change's branch on macOS with Bash 3.2 and jq 1.8.2.
Command: `bash tests/fm-project-status.test.sh`.

The fixture invokes the project-status executable through a sibling fake snapshot producer for deterministic resolution and failure boundaries, then invokes the real fleet snapshot against isolated local and remote-home records for its project-status source behavior.
The remote cache case uses a valid pre-existing `fm-secondmate-home-summary.v1` record and a failing SSH transport, proving that the no-write path can select the cache without changing its digest.
The no-cache case proves that the same mode neither creates its configured cache directory nor invokes a terminal backend or consumes parent status events.

## Exact output

```text
ok - project status resolves exact local and secondmate owners without trusting parent history
ok - project status exposes bad schema, oversized output, process failure, and timeout
ok - project status caps all collections, disclosures, and final JSON while preserving totals
ok - project-status source reads cache without writes or terminal observation
All fm-project-status tests passed.
```

## Guarantees covered

- Exact case-insensitive local and secondmate resolution, explicit unknown and ambiguous outcomes, and no fuzzy match.
- Absolute structured-home precedence over contradictory parent event history.
- Partial DofuMax behavior with unknown current state, two reliable queued items, and two reliable recent deliveries.
- Five active items, five captain calls, five queued items, three recent deliveries, ten combined warnings and omissions, 64 KiB JSON limits, and an eight-second subprocess deadline.
- Explicit unavailable results for malformed schema, oversized output, subprocess failure, and timeout.
- Existing-cache reads with byte-identical cache content, no cache-directory creation, and no terminal or parent-event observation under `--project-status-source`.
