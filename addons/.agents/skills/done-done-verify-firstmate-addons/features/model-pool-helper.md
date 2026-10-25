# Shared model pool helper

## User outcome

A model-calling tool can ask `fm-model-pool` for the next eligible Claude account (or Sol / Goat / Cursor fallover) without caching a stale pick or enabling usage credits.

## Drive

Run `bash account-pool/tests/model-pool.test.sh`, or seal it with `done-done run pool-helper` (`bash account-pool/run-model-pool-proof.sh`).
Fixture registry accounts Umer A/B, synthetic quota readings, and a recording stand-in pool command; no real login folder is copied and no real model CLI runs.

## Capture

Keep `result.log` and `steps.json` under `$DONE_DONE_EVIDENCE_ROOT` (screen: none).
Assertions: A wins at 70% over B at 40%; A quota limit yields B; all Claude under the 15% eligibility floor reaches Sol then Goat then Cursor; credits-enabled accounts are refused and logged; a past deadline refuses; attempted ids are not repeated; omitted `pool_config` uses `$FM_HOME/config/account-pool` when readable; an explicit `pool_config` still wins; omitted `pool_config` with no default file refuses.
