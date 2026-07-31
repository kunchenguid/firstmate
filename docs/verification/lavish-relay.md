# Pi Lavish feedback relay verification

Audience: maintainer verification.

This record supports the active completion-aware Lavish feedback guarantee for Pi-family Firstmate primary sessions.
Stable ownership and runtime boundaries live in [`architecture.md`](../architecture.md#completion-aware-lavish-feedback-in-pi), while model-facing usage guidance lives on the `fm_lavish_poll` tool registered by [`.pi/extensions/fm-lavish-poll.ts`](../../.pi/extensions/fm-lavish-poll.ts).

## Current deterministic evidence

The focused deterministic pass ran on 2026-07-31 with Pi 0.83.0, Lavish AXI 0.1.45, Node.js 22.22.3, and TypeScript 7.0.2.

Exact commands:

```sh
pi --version
lavish-axi --version
node --version
tsc --version
tests/fm-pi-lavish-poll-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed output:

```text
0.83.0
0.1.45
v22.22.3
Version 7.0.2
ok - Pi Lavish relay is completion-aware, argv-safe, bounded, exactly-once, and generation-owned
ok - Pi Lavish relay reports fatal command failure exactly once without residue
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.83.0
```

The executable-level test uses a fake poll command with no browser or network.
It covers immediate start return, status responsiveness while the child waits, typed custom-message delivery, optional agent reply as one literal argument, canonical duplicate suppression, nonzero command failure, missing-executable failure, explicit stop, terminal review end, output and DOM bounds, private diagnostic permissions, same-session reload, session-generation replacement, shutdown cleanup, process-exit listener cleanup, and late-close suppression.
Strict no-emit checking uses the installed Pi declarations and passed in the output shown above.

## Current real-session smoke

The credentialed isolated TUI smoke is the active maintainer entry point:

```sh
FM_PI_LAVISH_LIVE_E2E=1 tests/fm-pi-lavish-poll-live-e2e.test.sh
```

The smoke uses the installed real Pi primary and provider credentials, but replaces only `lavish-axi poll` with a local fake executable so feedback timing is deterministic and no browser or network is needed for the review loop itself.
It starts the relay through the model-facing tool, submits plain `/bearings` and a second normal prompt while the first child remains alive, releases one synthetic feedback result, requires an `--agent-reply` re-arm, releases terminal feedback, verifies idle relay ownership, and exits Pi cleanly.

Observed output on 2026-07-31:

```text
ok - Pi 0.83.0 with Lavish AXI 0.1.45 kept Bearings and a normal prompt responsive during feedback wait, delivered one synthetic result, re-armed with agent reply, and ended cleanly
```

## Pi-family and other-runtime applicability

Plain Pi and pi-signed load the same tracked TypeScript extension and expose the same extension CLI surface.
The current machine has Pi 0.83.0 but no `pi-signed` executable; the signed wrapper's shared extension API and CLI shape were last real-process verified on 2026-07-27 at version 0.82.0, and `fm-spawn.sh` now passes the same relay extension path to either selected executable without normalization.
The current session-start and spawn regressions prove that both recorded identities require and launch that shared path.

The other supported primary runtimes remain unchanged after inspecting their registered integration surfaces:

| Runtime | Inspected completion surface | Applicability result |
| --- | --- | --- |
| Claude | Native background jobs plus project hooks. | Not compatible with Pi's `session_shutdown` and `pi.sendMessage` API; existing Lavish behavior remains unchanged. |
| Codex | Stop hooks and bounded foreground watcher checkpoints. | Completed background work is not guaranteed to resume the conversation; existing Lavish foreground guidance remains unchanged. |
| OpenCode | Plugin lifecycle and `client.session.promptAsync`. | A separate plugin implementation would be required; no Pi extension code is loaded. |
| Grok | Stop hooks and background-notify watcher cycles. | A separate Grok completion callback would be required; no Pi extension code is loaded. |
| Kimi | Global hooks without a Pi extension runtime. | Standalone Kimi is unchanged; Kimi models running behind Pi inherit the Pi relay because the harness is Pi. |

This relay is intentionally independent of fleet watcher supervision.
