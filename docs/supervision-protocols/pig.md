Mode: PiG primary adapter; the supervision lifecycle is partially verified on PiG 0.4.1+1.0.3, with gaps still open.
The installed 0.5.3+1.4.0.74f46864 has not had its supervision lifecycle verified live.

The 2026-10-19 live run verified session-start digest delivery, direct `/ahoy` and `/bearings` invocation, pre-tool denials, actionable wake delivery to main, a healthy-cycle turn-end check, and `fm-control` interrupt, relaunch refusal, and exit. The live evidence is recorded in [supervision verification](../verification/supervision.md#pig-primary-recheck-live-verification-2026-10-19).
Automatic watcher recovery in a second home did not pass its live assertion. Dispatch intake, worker briefing or spawn, ship-ready landing, section 9 escalation wording, and wake-drain acknowledgement remain unverified.

PiG requires explicit `-e` paths; configure the Pi supervision path when launching from the Firstmate repository:

```sh
pig --approve \
  -e .pi/extensions/fm-primary-turnend-guard.ts \
  -e .pi/extensions/fm-primary-pi-watch.ts \
  -e .pi/extensions/fm-branch-supervision.ts
```

The `/afk` and `/quiet` routes are configured to use the Pi branch and skip the away daemon, but PiG has no verified managed background branch. Configuring these extensions does not verify watcher restoration, background-wake coverage, or lifecycle recovery. Do not arm or repair the watcher based on Pi guidance. Do not infer watcher health or `can_receive=true` from extension loading.
