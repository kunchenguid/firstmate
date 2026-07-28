# Link-intake verification

This record owns active empirical verification for private durable link intake.

Verification date: 2026-07-28.
The implementation was verified by the focused behavior suite after the current change.

```sh
tests/fm-link-intake.test.sh
```

Observed guarantees:

```text
ok - lock claims use portable replacement, atomic quarantine, and process-start identity
ok - lock identity is timezone-stable and legacy recovery is upgrade-safe
ok - retrieval dates are real calendar dates and remain path-safe
ok - one process-crash atomic switch survives failures and process death
ok - validation rejects record, index, and transcript divergence
```

The focused suite covers canonical duplicate convergence, searchable title and summary fields, inaccessible records, transaction-staged transcripts, an atomic initialized lock claim, UTC-normalized process-start ownership, upgrade-safe legacy lock recovery, stale-lock quarantine, BSD and GNU symlink replacement, real calendar dates, a process-crash atomic state switch, conservative retained state, bidirectional consistency, odd URLs with query slashes, and the one-line `AGENTS.md` trigger.
Filesystem sync barriers and power-loss durability are explicitly outside this focused process-crash guarantee.
