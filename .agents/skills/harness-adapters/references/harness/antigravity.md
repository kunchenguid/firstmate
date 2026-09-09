# Antigravity CLI

The `antigravity` adapter uses the installed `agy` CLI through the persistent worker bridge owned by `../../../bin/fm-worker-bridge.py` and its shell launcher.
It supports crewmate and scout tasks only, never a primary or secondmate.
This adapter does not automate the Antigravity desktop UI.

## Operating facts

The bridge executes headless turns and binds every follow-up to the exact `conversation_id` returned by the preceding successful JSON result.
It requires both exit code zero and `status=SUCCESS` with a conversation id; a failed turn writes a blocked status wake instead of claiming completion.
The bridge owns the stable readline composer, generation-bound busy events, turn-end wake, cancellation, and process cleanup; native TUI glyphs and Herdr's idle observations are not semantic state sources.
On Herdr, the bridge reports native working/idle state through a generation-scoped lifecycle source and releases that source on exit.
Its `❯` prompt uses the existing bare-agent composer classifier.
`../../../bin/fm-control-lib.sh` owns lifecycle keys and commands; `../../../bin/fm-spawn.sh` owns dispatch, model and effort flags, and secondmate refusal.
The bridge creates a new private native conversation on deterministic relaunch; the durable brief and inbox remain the recovery authority.
Models are discovered with `agy models`; no model or provider is substituted by the bridge.
Antigravity accepts low, medium, and high effort; unsupported explicit levels are refused before dispatch.
Run the live guard in `../../../tests/fm-worker-bridge-live-e2e.test.sh` after upgrades; current evidence is in `../../../docs/verification/runtime-backends.md`.
