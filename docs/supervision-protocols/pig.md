Mode: PiG primary adapter; supervision lifecycle is unverified.

Verified support is limited to registration of `/ahoy` and `/bearings` and their handoff to the loaded skills. Direct TUI invocation is unverified.

PiG requires explicit `-e` paths; configure the Pi supervision path when launching from the Firstmate repository:

```sh
pig --approve \
  -e .pi/extensions/fm-primary-turnend-guard.ts \
  -e .pi/extensions/fm-primary-pi-watch.ts \
  -e .pi/extensions/fm-branch-supervision.ts
```

The `/afk` and `/quiet` routes are configured to use the Pi branch and skip the away daemon, but branch processing is unverified. Configuring these extensions does not verify watcher restoration, wake delivery, background-wake coverage, or lifecycle recovery. Do not arm or repair the watcher based on Pi guidance. Treat PiG readiness as unknown until its live supervision lifecycle is verified; do not infer watcher health or `can_receive=true` from extension loading.
