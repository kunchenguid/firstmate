# RSI operations

The locked RSI workflow consensus is the policy owner and is retained in the active firstmate home at `data/rsi-workflow-consensus-LOCKED-2026-08-01.md`.
`bin/fm-rsi-classify-diff.sh` emits the computed W1 fast-lane classification for an immutable base and candidate SHA.
`bin/fm-rsi-canary-bcs.sh` records one bounded BCS production observation using the supplied SHA-specific positive marker and a negative regression pattern.
`bin/fm-rsi-ledger-append.sh` appends one event to `FM_HOME/data/rsi-events.jsonl` without changing previous rows.
Firstmate is the sole policy-authorized ledger writer, while workers emit claims only through their task status files.
