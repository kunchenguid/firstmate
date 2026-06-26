# Gate Ledger

## Drain list (2)

- [ ] gate-g1-threshold — Threshold selection: captain>=185k and crew>=50% selected; sub-threshold not (red) **ready**
- [ ] gate-g2-busy-guard — Busy-guard: an over-threshold pane that is busy does NOT fire (red) **ready**

## All gates

| id | status | title |
| --- | --- | --- |
| gate-g1-threshold | red | Threshold selection: captain>=185k and crew>=50% selected; sub-threshold not |
| gate-g2-busy-guard | red | Busy-guard: an over-threshold pane that is busy does NOT fire |
| gate-g3-rehydrate | green | Rehydrate: SessionStart with handoff injects+archives it; no-handoff path unchanged |
| gate-g4-e2e | green | E2E on scratch pane: threshold -> checkpoint -> handoff -> /clear -> rehydrate |
| gate-g5-inject-cap | green | Inject cap: handoff under 10k injected verbatim, over 10k yields a pointer |
