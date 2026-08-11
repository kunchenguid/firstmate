# Disk reclamation accounting - 2026-08-08

A content-based audit identified 88 unowned scratch worktrees totaling 127.004 GiB as potential reclamation candidates on a heavily loaded macOS host.

The cleanup removed 78 candidates and retained 10 that were owned, leased, in use, or dirty when their batch reached the deletion edge.

The retained 33.498 GiB was the correct safety outcome, not an incomplete cleanup.

## Safety contract

The candidate inventory was not treated as timeless.

Exact `worktree=` ownership was reread from every Firstmate home's task metadata immediately before every batch and again before each deletion.

No process command-line pattern search was used for ownership because an agent can mention an unrelated path in its arguments.

Treehouse preview was run for every exact path.

No in-use or leased override was used.

A dirty worktree, a worktree with a stash, or a worktree whose content proof no longer matched the audit was retained.

Clean commits were judged by audited file content already present in shipped code rather than by commit reachability because squash merges intentionally replace the source commits.

The final action-scoped proof compared the exact missing-path set with the exact intended-removal set and separately asserted that every withheld path still existed.

## Result

| Batch | Inventory rows | Paths removed | Audit `du` GiB | Current `du` GiB | Treehouse exact freed GiB |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1-16 | 13 | 0.808 | 0.808 | 0.781 |
| 2 | 17-20 | 4 | 14.563 | 14.563 | 13.100 |
| 3 | 21-24 | 3 | 8.247 | 8.247 | 7.671 |
| 4 | 25-29 | 4 | 4.410 | 4.409 | 3.960 |
| 5 | 30-34 | 5 | 15.826 | 15.826 | 14.446 |
| 6 | 35-41 | 4 | 0.801 | 0.802 | 0.738 |
| 7 | 42-51 | 10 | 10.666 | 10.667 | 9.810 |
| 8 | 52-59 | 7 | 7.082 | 7.083 | 6.478 |
| 9 | 60-71 | 12 | 4.475 | 4.475 | 4.009 |
| 10 | 72-78 | 7 | 11.051 | 11.053 | 10.389 |
| 11 | 79-84 | 6 | 9.461 | 9.460 | 8.798 |
| 12 | 85-88 | 3 | 6.116 | 6.116 | 5.726 |
| **Total** | **1-88** | **78** | **93.506** | **93.509** | **85.906** |

The exact metadata population grew during the cleanup.

A 9.735 GiB candidate acquired an owner before batch 12 and was withheld by the repeated ownership check.

The final state contained 78 intended missing paths, the same 78 actual missing paths, and all 10 withheld paths still present.

There were no unexplained deletion failures and no forced deletions.

## Three accounting numbers, not one

**Audit `du` is the inventory estimate.**

It records the size seen when the candidate content was audited and is useful for planning batch boundaries and stating how much inventoried tree content was selected.

It can differ slightly from deletion-time size because of measurement timing and per-path rounding.

**Current `du` is the deletion-edge tree measurement.**

It verifies how much tree content existed immediately before removal and catches material drift from the audited candidate.

It still does not promise the same increase in filesystem free space because APFS can share physical extents between copies.

**Treehouse exact freed is the deletion tool's per-path result.**

It is tied to each exact destroy operation and is therefore the closest accounting number to the action that actually ran.

It can differ from both `du` totals because Treehouse and APFS account shared data differently from a tree walk.

These three values answer different questions and must never be collapsed into one claimed measurement.

The cleanup removed 93.506 GiB of audit-accounted content, measured 93.509 GiB with deletion-edge `du`, and received 85.906 GiB in summed Treehouse exact-freed results.

That difference is expected evidence about accounting semantics, not evidence that an owned path was removed.

## Why `df` was the wrong gate

`df` measures free space for the whole filesystem, not space attributable to one deletion command.

The host was simultaneously running more than twenty processes that wrote logs, temporary files, validation artifacts, caches, and APFS metadata.

The first batch removed 0.808 GiB by current `du`, while system-wide `df` reported 1.383 GiB more free space during the same interval.

Stopping because the `df` delta was 71 percent larger was a category error.

More free space could have come from unrelated concurrent deletion, cache turnover, snapshot behavior, or the release of a last APFS shared-extent reference.

Less free space could likewise be hidden by unrelated concurrent writes.

Neither direction proves what the exact deletion did.

A filesystem-wide free-space sample can be useful background telemetry on an idle host, but it is not a correctness gate on a busy host.

## Correct stop conditions

Stop when a path outside the intended removal set disappears.

Stop when a path withheld for ownership, lease, in-use state, dirtiness, stash content, or failed shipped-content proof is touched.

Stop when an exact deletion fails for a reason that cannot be explained and classified safely.

Do not stop merely because `df` differs from audit `du`, current `du`, or Treehouse exact-freed accounting.

The correctness proof must stay scoped to the action: exact owners before deletion, exact targets passed to the tool, exact intended paths absent afterward, and exact withheld paths still present.
