# Fleet-pulse newest retro across homes

## User outcome

Fleet-pulse wakes for a fleet retro only when the newest `data/*retro*/report.md` across known homes is missing or at least 60 hours old, so a retro that finished in another home does not look overdue.

## Drive

Run `bash fleet-pulse/tests/newest-retro.test.sh` from the repository root (done-done journey `fleet-pulse-newest-retro` via `fleet-pulse/run-proof.sh`). It uses disposable fixture homes only: older report in main with a newer sibling report must stay quiet; none or all-old must be due; install must retarget an old-style pulse check onto `bin/fleet-retro-due.sh`.

## Evidence

Keep `newest-retro.txt` and `steps.json` under `$DONE_DONE_EVIDENCE_ROOT` (screen: none). Do not write into a live home's `state/.fleet-retro.last`.
