# loop-budget.md — wake and token discipline

The watcher spends zero tokens; budget = wake discipline + council spend.

- Wake volume alarm threshold (a chosen operational alarm, NOT a code-enforced
  cap): investigate if autonomous wake handling exceeds ~50/day. For scale:
  the heartbeat base is 600s (144/day ceiling, and it backs off exponentially
  when idle, so real heartbeat traffic is far lower); signal/stale/check wakes
  are event-driven and uncapped by design.
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
