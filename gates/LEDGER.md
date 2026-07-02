# Gate Ledger

## Drain list (0)


## All gates

| id | status | title |
| --- | --- | --- |
| gate-g1-threshold | green | Threshold selection: captain>=185k and crew>=50% selected; sub-threshold not |
| gate-g2-busy-guard | green | Busy-guard: an over-threshold pane that is busy does NOT fire |
| gate-g3-rehydrate | green | Rehydrate: SessionStart with handoff injects+archives it; no-handoff path unchanged |
| gate-g4-e2e | green | E2E on scratch pane: threshold -> checkpoint -> handoff -> /clear -> rehydrate |
| gate-g5-inject-cap | green | Inject cap: handoff under 10k injected verbatim, over 10k yields a pointer |
| gate-q1-verdict-grammar | green | Verdict grammar: only approve/reject/escalate/lens lines; last-decision and reject-count read correctly |
| gate-q2-merge-refuses-unverified | green | fm-merge-local refuses without a trailing approve verdict; approve merges; override is loud |
