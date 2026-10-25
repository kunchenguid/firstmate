# Quota failover screen matching

## User outcome

Claude's route remains available when a worker screen contains the failover wrapper's `quota exhausted` text; Claude's own usage-limit banner removes the route only after its one-line probe confirms the limit.

## Drive

Run `bash quota-failover/run-proof.sh` from the repository root. It invokes the real failover script against a disposable fixture home twice: first with wrapper text, then with Claude's exact usage-limit banner and a confirming probe. It does not use a real home or credentials.

## Evidence

The journey writes both screen inputs, separate dispatch/log results, and a `result.json` summary under `DONE_DONE_EVIDENCE_ROOT`. The summary records that wrapper text retains `claude-haiku-5-5` and the confirmed banner removes it; `dead-routes.json` contains the removed route.
