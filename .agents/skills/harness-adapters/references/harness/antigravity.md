# Antigravity CLI

The `antigravity` adapter uses the installed `agy` CLI through the persistent worker bridge owned by `../../../bin/fm-worker-bridge.py` and its shell launcher.
It supports crewmate and scout tasks only, never a primary or secondmate.
This adapter does not automate the Antigravity desktop UI.

## Operating facts

The bridge executes headless turns and binds every follow-up to the exact `conversation_id` returned by the preceding successful JSON result.
Until a conversation id exists, every turn carries the task brief, so an interrupted or failed opening turn followed by a steer still runs with the brief and role scope.
It requires both exit code zero and `status=SUCCESS` with a conversation id; a failed turn writes a blocked status wake instead of claiming completion.
Turns carry an explicit 24h `--print-timeout` because agy's five-minute default returns partial output and exits zero when it expires, and a run whose stderr carries agy's truncated-response note is recorded as a failed turn even when its JSON result says SUCCESS.
A truncated turn still binds the conversation id it returned, so the follow-up continues that same conversation instead of restarting one.
A result stream that breaks the 1 MiB limit or the JSON result contract is also a failed turn with a blocked status wake; the endpoint stays alive and keeps its composer.
Diagnostics that break the same limit are truncated for display with a notice and do not change the verdict, so a completed turn keeps its conversation id however noisy its stderr was.
The opening brief is delivered in the canonical `launch-brief` envelope owned by `../../../bin/fm-operational-input.sh`, the same typed envelope every other adapter's launch command carries.
The bridge owns the stable readline composer, generation-bound busy events, turn-end wake, cancellation, and process cleanup; native TUI glyphs and Herdr's idle observations are not semantic state sources.
On Herdr, the bridge reports native working/idle state through a generation-scoped lifecycle source and releases that source on exit.
A failed first report is fatal because an unregistered pane reads as a dead agent; once registration succeeds, a later publication failure only prints, so the semantic record and completion wake still land.
Its `❯` prompt uses the existing bare-agent composer classifier.
`../../../bin/fm-control-lib.sh` owns lifecycle keys and commands; `../../../bin/fm-spawn.sh` owns dispatch, model and effort flags, and secondmate refusal.
The bridge creates a new private native conversation on deterministic relaunch; the durable brief and inbox remain the recovery authority.
Models are discovered with `agy models`; no model or provider is substituted by the bridge.
Antigravity accepts low, medium, and high effort; unsupported explicit levels are refused before dispatch.
Run the live guard in `../../../tests/fm-worker-bridge-live-e2e.test.sh` after upgrades; current evidence is in `../../../docs/verification/runtime-backends.md`.
