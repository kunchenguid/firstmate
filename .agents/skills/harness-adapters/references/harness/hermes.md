# Hermes Agent

The `hermes` adapter implements crewmate and scout dispatch through `../../../bin/fm-worker-bridge.py` and its shell launcher.
It cannot supervise as a primary or secondmate.
Credentialed live verification is still required before dispatching production work: the current host has no configured inference provider, as recorded in `../../../docs/verification/runtime-backends.md`.

## Operating facts

The bridge runs the actual Hermes classic CLI in quiet one-shot mode and uses a unique named conversation per endpoint incarnation.
Follow-up turns target that same name, while deterministic relaunch creates a new name and reloads the durable brief.
Hermes loads project instructions from the supplied worktree; the bridge does not ask Hermes to create another worktree.
A successful turn requires exit zero, a nonempty response, and Hermes's post-conversation `session_id` line on stderr, so a successful process exit during first-run setup cannot masquerade as completed work.
Output that breaks the 1 MiB limit is a failed turn with a blocked status wake; the endpoint stays alive and keeps its composer.
The opening brief is delivered in the canonical `launch-brief` envelope owned by `../../../bin/fm-operational-input.sh`, the same typed envelope every other adapter's launch command carries.
The bridge owns generation-bound busy events, the existing `❯` bare composer, turn-end wakes, and child process-group cleanup.
`../../../bin/fm-spawn.sh` owns model and effort arguments, and `../../../bin/fm-control-lib.sh` owns lifecycle keys and commands.
Choose the provider and model through Hermes's own authenticated configuration; the bridge does not copy credentials or substitute models.
The applicable credentialed check is `../../../tests/fm-worker-bridge-live-e2e.test.sh`.
