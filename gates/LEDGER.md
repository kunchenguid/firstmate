# Gate Ledger

## Drain list (2)

- [ ] gate-l2-loop-audit-level — loop-audit scores the repo at level L2 or better (score >= 58) (red) **ready**
- [ ] m1-hook-registered — bin/fm-boot-context.sh is registered as a real SessionStart hook (red) **ready**

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
| gate-q3-prcheck-refuses-unverified | green | fm-pr-check refuses to arm the merge poll without a trailing approve verdict |
| gate-q4-reject-roundtrip | green | fm-verify: approve path records approve; reject relays findings to the crewmate and exits 2; non-ship tasks skip |
| gate-q5-attempt-cap | green | Third reject escalates instead of spinning; at-cap tasks escalate without re-running the verifier |
| gate-q6-lens-degrade | green | No Fugu key + no codex -> lens degrades to none loudly; verify still completes |
| gate-q7-fail-closed | green | Verifier infrastructure failure escalates - never approves |
| gate-i1-intake-grammar | green | Intake grammar: only proceed/revise/escalate/panel lines; last-decision ignores panel lines and no-decision files |
| gate-i2-spawn-refuses-unvetted | green | fm-spawn refuses a ship task without a trailing intake proceed; scout exempt; override loud |
| gate-i3-panel-roundtrip | green | fm-intake: both thinkers proceed -> proceed + synthesis; one revise -> revise with count; exit codes 0/2 |
| gate-i4-revise-cap-fail-closed | green | Second revise escalates; at-cap intakes escalate without running the panel; a PANEL-less thinker escalates, never proceeds |
| gate-i5-intake-lens-degrade | green | Intake with no Fugu key + no codex degrades the lens to none loudly; intake still completes |
| gate-l1-drain-instrumented | green | Wake drain appends a run-log JSON line and stamps STATE.md; FM_LOOP_LOG=0 disables; log failure never breaks the drain |
| gate-l2-loop-audit-level | red | loop-audit scores the repo at level L2 or better (score >= 58) |
| g-boot-digest | frozen | Boot-time reconciliation digest in captain context; fm-watch-arm --status read-only |
| m0-ledger-shape | frozen | Gate harness loads: gates/ledger.json is an array, and a broken ledger fails loudly |
| m1-hook-registered | red | bin/fm-boot-context.sh is registered as a real SessionStart hook |
| m2-boot-emitter-is-read-only | frozen | A full boot through bin/fm-boot-context.sh performs zero writes |
| m4-boot-budget-hostile | frozen | Boot holds its budget by enforced deadline and concurrent helpers, leaks nothing, and never elides a peer |
| m5-digest-never-silent | frozen | A section that fails to build says so; failure is never silent |
| gate-ci-declared-red | frozen | CI skips a test only when its gate is red AND declared accepted |
| gate-status-verb | frozen | Status reporting is a verb a crewmate whose redirect is refused can still use |
