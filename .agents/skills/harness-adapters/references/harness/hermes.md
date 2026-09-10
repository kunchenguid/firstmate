# Hermes Agent

The `hermes` adapter implements crewmate and scout dispatch through `../../../bin/fm-worker-bridge.py` and its shell launcher.
It cannot supervise as a primary or secondmate.
Credentialed live verification is still required before dispatching production work: the current host has no configured inference provider, as recorded in `../../../docs/verification/runtime-backends.md`.

## Operating facts

The bridge runs the actual Hermes classic CLI in quiet one-shot mode and uses a unique named conversation per endpoint incarnation.
Follow-up turns target that same name, while deterministic relaunch creates a new name and reloads the durable brief.
Unverified gap, deliberately left open: every turn passes only its own payload with `--continue <name> --create-if-missing`, so if the opening brief turn is interrupted or fails before Hermes persists the named session, the next steer may create that session from the steer alone and run without the brief or worker-role contract; the Antigravity path re-carries the brief until a conversation id exists, and Hermes has no equivalent yet.
Hermes loads project instructions from the supplied worktree; the bridge does not ask Hermes to create another worktree.
A successful turn requires exit zero, a nonempty response, and Hermes's post-conversation `session_id` line on stderr, so a successful process exit during first-run setup cannot masquerade as completed work.
A response that breaks the 1 MiB limit is a failed turn with a blocked status wake; the endpoint stays alive and keeps its composer.
Diagnostics that break the same limit keep their last 1 MiB with a notice, so the verdict still rests on the response and on the `session_id` line Hermes writes after it, which the retained tail carries however noisy the turn was.
The opening brief is delivered in the canonical `launch-brief` envelope owned by `../../../bin/fm-operational-input.sh`, the same typed envelope every other adapter's launch command carries.
The bridge owns generation-bound busy events, the existing `❯` bare composer, turn-end wakes, and child process-group cleanup.
A raw launch command replaces the generated bridge wiring, so that unverified escape hatch arms no busy record and has no trusted busy state.
The native CLI runs once per turn, and its whole process group is reaped when that turn ends, so a process the worker leaves running in the background does not outlive the turn that started it; a service that must stay up belongs in its own task.
`../../../bin/fm-spawn.sh` owns model and effort arguments, and `../../../bin/fm-control-lib.sh` owns lifecycle keys and commands.
Effort becomes `hermes chat --reasoning`, whose own help on hermes 0.21.1 lists none, minimal, low, medium, high, xhigh, max and ultra; firstmate propagates the five levels its profile axis shares with that list, and no credentialed run has exercised any of them.
Choose the provider and model through Hermes's own authenticated configuration; the bridge does not copy credentials or substitute models.
The applicable credentialed check is `../../../tests/fm-worker-bridge-live-e2e.test.sh`.
