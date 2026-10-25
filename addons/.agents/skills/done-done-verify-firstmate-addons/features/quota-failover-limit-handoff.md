# Quota failover limit handoff

## User outcome

A running Claude worker that stops on its pool account's usage limit is moved by quota-failover to another account of the same tool without a human, in the same worktree, and continues the same work there; the full account rests until its window resets.

## Drive

`bash quota-failover/tests/quota-failover-e2e.sh` (passes 3 and 8) covers the move with stubs. For a live check, in a guarded Herdr lab home under `/tmp` with this checkout's `claude-accounts` installed: spawn one Haiku worker, relaunch it with `--account <a real account at or below 15%>`, give it a two-step brief that writes `step 1` to a file in its worktree and stops on the usage-limit line, wait past `QUOTA_FAILOVER_STALL_SECS`, run `quota-failover/quota-failover <lab home>` once, and let the moved worker write `step 2`. Send no keys to the worker: Claude's limit screen offers `/usage-credits`, which must never be accepted.

## Evidence

Keep the worker screen with the limit lines, the `quota-failover.log` line `moved ... off account <id> to the next claude account (its screen shows a provider limit error)`, the meta's `account=` before and after with the same `worktree=`, the lab pool's rest marker, and the work file before and after the move. Say whether the limit text was Claude's own or a scripted line.
