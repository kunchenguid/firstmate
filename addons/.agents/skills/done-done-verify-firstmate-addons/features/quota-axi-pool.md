# quota-axi-pool

## User outcome

Dispatch `quota-axi --json` Claude runway matches `fm-model-pool`'s account reading. Install over an existing foreign `~/.local/bin/quota-axi` symlink records its resolved target as upstream and restores that link on uninstall.

## Drive

`bash quota-axi-pool/tests/quota-axi-pool.test.sh` or `done-done run quota-axi-pool` (`bash quota-axi-pool/run-proof.sh`). Fixture Umer A/B, stub upstream ambient 11%; temp-HOME install over a fake foreign symlink (never real `~/.local/bin`); no login copy, no network.

## Capture

`result.log` and `steps.json` under `$DONE_DONE_EVIDENCE_ROOT` (screen: none). Assert A=70 then B=40 after A attempted; ambient without pool; unknown under floor; refuse with no upstream; install records resolved upstream and original link target; reinstall keeps them; uninstall restores the original link.
