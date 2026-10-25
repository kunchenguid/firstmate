# Persisted pipeline route

## User outcome

With a pool, `fm-model-pool` pick/next chooses the Claude account (A=70% before B=40%) or Sol → Goat → Cursor auto when every Claude account is under the eligibility floor; without a pool the chain stays Claude Haiku through claude-bridge. A limit moves inside the same call and never falls back to the default login.

## Drive

Run `bash pipeline-quota-failover/run-proof.sh` from the repository root (the done-done journey `pipeline-route`). It drives the real wrapper `pipeline-quota-failover/pi-quota-failover` against a stub pi and a stub quota-axi in a throwaway HOME and captures the chain it holds, the fixture journey `pipeline-quota-failover/tests/pi-quota-failover-route.test.sh` and their exit codes in `$DONE_DONE_EVIDENCE_ROOT`.

Live: `done-done run pipeline-route-live` (`bash pipeline-quota-failover/run-live-proof.sh`) sends a review, a test and a fix prompt through this checkout's wrapper with no-mistakes' argv shape, on the real Claude account pool with rests in a throwaway pool state folder. A pi shim answers claude-bridge's own limit text for the first account each call lands on, and the next account answers with real Haiku through the real pi and bridge. Evidence: `roles.txt` (each role's account move and answer), `wrapper.log` (account ids only) and the step record `steps.json`.

The same wrapper's longer journey is `pipeline-quota-failover/tests/pi-quota-failover-e2e.sh`. `pipeline-quota-failover/README.md`, the root `README.md` and `.github/workflows/addons-ci.yml` name the same commands.

## Evidence

Capture the test command's output and exit status in done-done's run evidence directory. Never use a real home, a real pi or a real config.
