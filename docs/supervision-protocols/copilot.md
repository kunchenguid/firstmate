Mode: GitHub Copilot CLI typed wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Start supervision once per session, as soon as work is under way, with `bin/fm-copilot-wake.sh start` as one ordinary foreground command, and confirm it printed `copilot wake: running`.
   It needs a live tmux or Herdr pane for this session, starts one detached process that keeps `bin/fm-watch-arm.sh` running, and returns at once; never add shell `&` and never run `bin/fm-watch-arm.sh` yourself.
3. Do not wait inside the turn. End the turn normally; the pane stays free for the captain.
4. A wake arrives as a typed line that names a record under `state/operational-inbox/`.
   Read that record, then run `bin/fm-wake-drain.sh` first and handle the wake.
   Do not re-arm after an ordinary wake; the wake process keeps the watcher running.
5. The wake is typed only into an idle pane with an empty composer, so a running turn or a half-written line delays it and loses nothing.
   An unacknowledged wake is typed again with a growing delay until the `--ack-through` command removes it, so a repeated wake line after a finished handling turn means that command did not run.
   Checks keep running during a long turn, but their wakes wait in the queue and arrive when the turn ends; delivery during a turn is a limit, because a wake can only be typed into an idle composer.
6. On a `turn-end-guard` follow-up, supervision is missing: run `bin/fm-copilot-wake.sh start` again and read `state/.copilot-wake.log` if it reports a failure.
   The guard blocks at most once per turn.
7. Waiting on the wake process is silent: do not send idle progress.

The mechanism, its idle proof, and its limits are owned by the header of `bin/fm-copilot-wake.sh`.
`bin/fm-turnend-guard-copilot.sh` is the turn-end guard, and [`turnend-guard.md`](../turnend-guard.md) owns its contract.
A persistent secondmate runs this same protocol in its own home, with its own wake process, queue, and watcher.
[`sessionstart-nudge.md`](../sessionstart-nudge.md#github-copilot-cli) owns how to open a hand-started Copilot primary.
