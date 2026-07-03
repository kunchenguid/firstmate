# loop-run-log.md — append-only wake-drain log

One JSON line per wake drain, appended by `bin/fm-wake-drain.sh`
(`FM_LOOP_LOG=0` disables). Schema (loop-engineering convention):
`{"run_id","pattern","duration_s","items_found","actions_taken","escalations","tokens_estimate","outcome","ts"}`
with `outcome` one of `no-op|report-only|fix-proposed|escalated`. Drain
entries are `report-only` (the drain reports wakes; the firstmate session
acts). Runtime churn here is normal; feature branches must not edit this file.

---
