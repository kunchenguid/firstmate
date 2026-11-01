# PiG

PiG is integrated as a primary-only adapter; worker, scout, and secondmate dispatch through PiG are not supported.
The primary live verification on 2026-10-17 used PiG 0.4.1+1.0.3 on macOS arm64 with Go 1.27.2.
PiG 0.5.3+1.4.0.74f46864 passed token-free extension registration validation; its supervision lifecycle has not been verified live.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `pig`, resolved from `PATH`. |
| Scope | Primary only. `../../../bin/fm-harness.sh crew` refuses an absent or `default` worker choice under PiG; an explicit verified worker adapter remains selectable. |
| Identity | PiG publishes no Firstmate identity marker. Set `FM_PIG_HARNESS=pig` when starting PiG; `../../../bin/fm-harness.sh` trusts it only when the exact `pig` executable is in the process ancestry. |
| Session lock | The session lock names the PiG process. PiG's isolated Node extension process is accepted when the lock owner is an exact live `pig` process and the tracked Pi extension marker names a live descendant of it; this does not require `FM_PIG_HARNESS` in the inspecting process. Pi and pi-signed still require the exact lock owner. OMP's exact-process proof is unchanged. |
| Model | `--model openai-codex/gpt-6-luna` produced live responses at medium effort in the 2026-10-17 primary verification. `openai-codex/gpt-5.5` was also exercised in an earlier smoke, and PiG rejects `gpt-5.3-codex-spark` with the Codex-with-ChatGPT-account unsupported-model diagnostic. |
| Thinking | `--thinking medium` was exercised live on 2026-10-17. PiG documents `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`; the earlier integration check also exercised `minimal`. |
| Primary extensions | The Pi supervision path uses `.pi/extensions/fm-primary-turnend-guard.ts`, `.pi/extensions/fm-primary-pi-watch.ts`, and `.pi/extensions/fm-branch-supervision.ts`, loaded with `-e` from the Firstmate repository. Session-start delivery, both pre-tool denials, watcher continuity across tested turns, actionable wake delivery, and healthy and unhealthy turn-end behavior were verified live on 2026-10-17; background branch delivery is not available through PiG's current SDK. |
| Go runtime extension | `.pig/extensions/firstmate` builds and tests against the released PiG v0.4.1 SDK v0.3.1. It provides session-start, watcher, turn-end/pre-tool guards, and Calm's working-row widget. PiG's SDK cannot filter host transcript rows or create managed agent sessions, so host rows remain visible and actionable wakes go to the main conversation rather than an in-process supervision branch. |
| Go commands | `.pig/extensions/fm-firstmate` auto-registers `/ahoy` and `/bearings`. Direct TUI invocation and the full Bearings data read were verified live on 2026-10-17. |
| Lifecycle control | `bin/fm-control.sh` interrupt and exit were verified live on 2026-10-17 after a clean completed turn. A PiG primary-only worker relaunch was refused before stopping the live agent. After the recovery prompt, exit also safely refused when Herdr could not prove the composer empty; cleanup used the isolated lab teardown. |
| Background wake coverage | Unverified beyond delivery to the idle main TUI conversation. PiG cannot create an in-process supervision branch or filter host transcript rows, so no background-session workaround is claimed. |

## Primary integration

PiG's primary supervision instructions are in `../../../docs/supervision-protocols/pig.md`.
The Go extension synthesizes a next-turn user message that directs PiG to follow the already-loaded `ahoy` or `bearings` skill; it does not reimplement either skill.
PiG auto-discovers the top-level `.pig/extensions/fm-firstmate` resource in the Firstmate repository, while the Pi supervision files are explicitly loaded with `-e`.

Run the credentialed end-to-end verification only in a throwaway `FM_HOME` and named Herdr lab, using `openai-codex/gpt-6-luna` at medium effort:

```sh
FM_PIG_PRIMARY_LIVE_E2E=1 \
FM_PIG_PRIMARY_LIVE_MODEL=openai-codex/gpt-6-luna \
FM_PIG_PRIMARY_LIVE_THINKING=medium \
FM_PIG_PRIMARY_LIVE_CODE_ROOT=<Firstmate-repository> \
bash tests/fm-pig-primary-supervision-live-e2e.test.sh
```

The test must not point `FM_HOME` at the primary home or a secondmate home.
Use a verified non-PiG worker harness in `config/crew-harness` before dispatching crew or scout work from a PiG primary.
`../../../bin/fm-harness.sh secondmate` applies the same primary-only boundary when the secondmate harness is absent or `default`.
