# PiG

PiG is integrated as a primary-only adapter; worker, scout, and secondmate dispatch through PiG are not supported.
The installed-runtime check on 2026-10-13 used PiG 0.4.1, upstream Pi 1.0.3, Go 1.27.1, and macOS arm64.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `pig`, resolved from `PATH`. |
| Scope | Primary only. `../../../bin/fm-harness.sh crew` refuses an absent or `default` worker choice under PiG; an explicit verified worker adapter remains selectable. |
| Identity | PiG publishes no Firstmate identity marker. Set `FM_PIG_HARNESS=pig` when starting PiG; `../../../bin/fm-harness.sh` trusts it only when the exact `pig` executable is in the process ancestry. |
| Session lock | The session lock names the PiG process. PiG's isolated Node extension process is accepted when the lock owner is an exact live `pig` process and the tracked Pi extension marker names a live descendant of it; this does not require `FM_PIG_HARNESS` in the inspecting process. Pi and pi-signed still require the exact lock owner. OMP's exact-process proof is unchanged. |
| Model | `--model openai-codex/gpt-5.5` produced a live response on the installed runtime. `gpt-5.3-codex-spark` is rejected by PiG with the Codex-with-ChatGPT-account unsupported-model diagnostic. |
| Thinking | `--thinking minimal` is accepted. PiG documents `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`; only `minimal` was exercised in the Firstmate integration check. |
| Primary extensions | Pass `-e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts -e .pi/extensions/fm-branch-supervision.ts` from the Firstmate repository. Configuring these extensions does not verify watcher restoration, wake delivery, lifecycle recovery, background-wake coverage, or direct TUI behavior. The Go commands are separate from these supervision extensions. |
| Go commands | `.pig/extensions/fm-firstmate` auto-registers `/ahoy` and `/bearings`. Install validation succeeds, and an installed PiG 0.4.1 RPC-mode run confirmed both callbacks hand a synthesized user message to their loaded skills and settle a model turn. The direct TUI invocation and a full Bearings data read were not part of that check. |
| Exit and interrupt | Not yet verified for Firstmate lifecycle control. Do not infer Pi's key behavior. |

## Primary integration

PiG's configured Pi supervision path is described in `../../../docs/supervision-protocols/pig.md` and uses the tracked `.pi/extensions/` watcher, turn-end guard, and branch-supervision extension.
Both supervision extensions loaded in an installed PiG TUI run on 2026-10-13, but that check did not prove watcher continuity, a live wake, or turn-end recovery.
Full unattended primary support remains unverified until those supervision lifecycle paths are exercised end to end.

The Go extension synthesizes a next-turn user message that directs PiG to follow the already-loaded `ahoy` or `bearings` skill; it does not reimplement either skill. The callback-to-skill handoff is verified over RPC, while direct TUI invocation remains unverified.
PiG auto-discovers the top-level `.pig/extensions/fm-firstmate` resource in the Firstmate repository, while the Pi supervision files are explicitly loaded with `-e`.

Use a verified non-PiG worker harness in `config/crew-harness` before dispatching crew or scout work from a PiG primary.
`../../../bin/fm-harness.sh secondmate` applies the same primary-only boundary when the secondmate harness is absent or `default`.
