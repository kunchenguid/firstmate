# Quota failover pre-limit account move

## User outcome

A worker on a pool account that is about to run out moves to another account of the same tool while it is idle between turns, before it stops on the limit; a worker mid-turn, on a healthy account, or judged on a stale reading stays, and a tool whose terms bar an automatic move (Codex, OpenCode Go) wakes the home instead.

## Drive

Run `bash quota-failover/tests/quota-failover-e2e.sh` from the repository root; passes 11 to 13 use a fixture home with `claude-accounts.json` and `codex-accounts.json` readings and a stubbed busy source. For a live check, in a guarded Herdr lab home with this checkout's `claude-accounts` installed, spawn one Haiku worker with `--account <a real account at or below 15%>`, let it write a `working` status and end its turn, then run `quota-failover/quota-failover <lab home>` once.

## Evidence

Capture the e2e output. A live run keeps the lab's `quota-failover.log` line `moved idle ... off low account`, the worker's meta before and after (the `account=` changes), the lab pool's rest marker for the low account, and the relaunched worker's reply.
