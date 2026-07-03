# loop-budget.md — wake and token discipline

The watcher spends zero tokens; budget = wake discipline + council spend.

- Max unprompted wakes handled autonomously per day: 48 (heartbeat cadence
  bound; more than that means a runaway status channel — investigate).
- Council calls per task (bounded by design): intake ≤ 3 runs (2 revises then
  escalate), verify ≤ 3 attempts (then escalate). No unbounded retry anywhere.
- Foreign lens spend: Fugu is prepaid-credit-capped at the account level;
  codex rides the subscription; `lens: none` degrade is free and loud.
- Kill switch: do not arm the watcher (`bin/fm-watch-arm.sh`); an unarmed
  watcher means the loop is OFF and `bin/fm-guard.sh` banners it on every
  script run. Away-mode daemon stops with presence.
- Token cap per autonomous (supervise-daemon) turn: keep under the context
  watchdog thresholds (captain 185k / crew 50%) — the watchdog is the
  enforcement, not this document.
