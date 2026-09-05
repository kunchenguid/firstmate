# Google Antigravity CLI primary

Google's `agy` interactive TUI is distinct from the separate `gemini` CLI.
[README](../../../../../README.md#install-and-launch) owns primary launch setup, the mandatory added home, and the unmonitored-session failure mode.
Antigravity worker and secondmate dispatch are not supported; choose an existing supported worker adapter in `config/crew-harness`.

## Detection and startup

`bin/fm-harness.sh` checks `ANTIGRAVITY_AGENT=1` before inherited Pi markers and recognizes exact `agy` ancestry.
Never use `AI_AGENT` as identity: an Antigravity tool process can retain its launcher's value.
The shared session-lock classifier recognizes the exact `agy` executable.
Antigravity discovers `AGENTS.md`, `.agents/skills/`, and `.agents/hooks.json` through `--add-dir`.
Hook commands run from the directory containing `hooks.json`.
The tracked root hook injects the normal startup reminder with `PreInvocation`.

## Primary safety and supervision

Antigravity's `PreToolUse` input is `.toolCall.name` plus `.toolCall.args.CommandLine`, and deny output is `{"decision":"deny","reason":"..."}`.
The tracked primary hooks adapt that native contract to Firstmate's watcher-arm, persistent-directory-change, and built-in delegation guards.
Antigravity hooks are synchronous and expose no verified asynchronous background-task-to-model wake.
The [primary supervision protocol](../../../../../docs/supervision-protocols/antigravity.md) owns the foreground wait and wake acknowledgement cycle.
Headless `--print` is not a primary host because it has no persistent conversation for later fleet notifications.
[Antigravity verification](../../../../../docs/verification/antigravity.md) records the discovery evidence and verification limits.
