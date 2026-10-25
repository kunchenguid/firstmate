# Quota failover: install in every home, and a real route failure recovers

## User outcome

The watcher runs in Main and every active local secondmate home, and a worker stopped by a provider limit or a 429 moves to the next live route, or the next pool account, with no human; a worker on an account the pool does not name (such as the `ambient` id given to a codex or pi launch) takes the route move.

## Drive

- `FM_TEST_FORK=<Firstmate checkout> bash quota-failover/tests/install.test.sh` (`install.sh --all` on throwaway homes with the fork's own registration) and `bash quota-failover/tests/quota-failover-e2e.sh` (pass 3: the `ambient` worker).
- Live: `FM_CHECKOUT=<Firstmate checkout> done-done run quota-failover-live-route` (`bash quota-failover/run-live-proof.sh`): a disposable lab (Haiku main) with one real pi worker pinned to a local HTTP 429 provider and this checkout's watcher in a lab-only data path; PASS is the lab watcher moving it to Claude Haiku and the worker finishing there. About 10 minutes, Haiku only. It runs the real pi binary, since `pi --help` through the host mise shim hung inside labs.

## Evidence

`route.log`, one readable log in order: setup (including the check that the installed watcher sources only the add-on's own `account-pool/bin/fm-account-pool-lib.sh`), the 429 count with the worker's real `Error: 429` screen line, the watcher's `switched` line, the worker's `done` line on its new route with its commit, lab teardown and `PASS`; and the step record `steps.json`. Raw lab output (lab up/down, pane captures, provider hits) stays in the run's work folder, not the evidence root.
