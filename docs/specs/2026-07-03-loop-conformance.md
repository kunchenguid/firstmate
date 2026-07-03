# Loop Conformance — Design Spec (Agent OS Phase 3)

Date: 2026-07-03
Status: approved
Parent: docs/specs/2026-07-01-agent-os-council.md (Phase 3 outline)
Prereq: Phases 1–2 shipped (Quarterdeck q1–q7, Wardroom i1–i5; ledger green:17).
Bible: cobusgreyling/loop-engineering (loop-audit v1.5.2 is the scoring gate).

## Problem

firstmate IS a loop operation — the zero-token watcher, the wake queue, the
supervise daemon, the context watchdog — but scores **29 / L0** on the bible's
own audit because none of it is legible to the loop-engineering conventions:
no LOOP.md, no STATE.md, no budget/run-log/constraints files, and the
Quarterdeck verifier is invisible to the tool's detection.

## The change

Make the real loops legible and machine-scored, honestly. Target **L2 (≥58)**
now; L3 arrives only when `loopActivity` is earned by real instrumented runs —
never by faking a timestamp. (Signal math: base 10 + agentsMd 9 + github 6+4
[today] + stateFile 18 + verifier 14 + constraints 4 + budget 3 + runLog 3 +
loopMdBudget 2 = 73 honest points without activity.)

### Deliverables

1. **Loop docs at repo root** (all describing what actually runs, no aspiration):
   - `LOOP.md` — the standing loops (watcher wake loop, supervise daemon,
     context watchdog), their cadence, wake reasons (`signal|stale|check|heartbeat`),
     and a Budget section (tokens are spent by the firstmate session the watcher
     wakes, not by the watcher itself — the budget is wake discipline).
   - `STATE.md` — the loop's memory: watch list (in-flight tasks), a
     `Last run:` line stamped by instrumentation (seeded `never`).
   - `loop-budget.md` — daily wake/token caps + kill switch (`fm-watch-arm.sh`
     not armed = loop off).
   - `loop-run-log.md` — append-only run log, one JSON line per wake drain
     (loop-engineering's schema: run_id/pattern/items_found/outcome/ts).
   - `loop-constraints.md` — binding rules distilled from AGENTS.md prime
     directives (never state-changing git in projects/ except fm-merge-local;
     verdict/intake gates may not be bypassed silently; watcher stays zero-token).
2. **`.claude/agents/loop-verifier.md`** — the Quarterdeck verifier role made
   legible to loop-audit's detection (basename contains "verifier"): documents
   the default-REJECT contract fm-verify.sh enforces. No new behavior.
3. **Wake-drain instrumentation** (`bin/fm-wake-drain.sh`): after a successful
   drain, best-effort append a run-log JSON line + stamp `Last run:` in
   STATE.md. Guarded by `FM_LOOP_LOG=0`, wrapped `|| true` — the drain contract
   (locking, dedup output, exit codes) is untouched. This is what earns
   `loopActivity` for L3 later, honestly.
4. **Gates** (red-first + mutation, as before):
   - `gate-l1-drain-instrumented` — a drain with queued records appends a valid
     run-log line and stamps STATE.md; FM_LOOP_LOG=0 disables; a failing log
     write never breaks the drain. Mutation: FM_LOOP_LOG=0 while asserting the
     log line appears.
   - `gate-l2-loop-audit-level` — `loop-audit` (globally installed, like
     `ledger`) scores the repo ≥ L2/58. Mutation: audits a stripped temp copy
     (no STATE.md/LOOP.md) and asserts ≥ L2 — a correct audit refuses.
5. **AGENTS.md**: short "Loop observability" note (where the files live, that
   STATE.md/loop-run-log.md churn is normal runtime state, self-update commits
   them periodically).

### Deliberate decisions

- **Tool availability follows the `ledger` precedent:** `npm i -g
  @cobusgreyling/loop-audit` (MIT); the l2 gate test exits 2 with an install
  hint when the binary is missing (fail closed, like gates/verify.sh does for
  ledger).
- **STATE.md / loop-run-log.md are tracked and churn at runtime.** That is the
  loop-engineering model (their repo dogfoods it). Feature branches must not
  edit them (avoids the dirty-merge trap); self-update flows commit the churn.
- **No L3 claim in this phase.** loopActivity must accumulate from real wake
  drains; the gate pins ≥ L2 so honest growth never flaps the ledger.
- loop-cost / loop-sync adoption: deferred (patterns/registry are for repo
  loops shaped like PR-babysitting; firstmate's loops are custom — LOOP.md
  documents them directly).

## Non-goals

Scaffolding the 7 loop-engineering patterns; the loop-engineering MCP server;
retrofitting jarvis-talk or other projects (firstmate first); L3 promotion.
