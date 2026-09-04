Mode: Antigravity foreground tool supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted notifications and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: invoke `bin/fm-watch.sh` as one foreground terminal tool call.
   Do not set a short tool timeout: the command intentionally blocks until an actionable fleet event exists.
3. When that tool call returns, treat its one output line as the notification reason, drain first, handle all emitted work, acknowledge through the printed generation, and invoke the same foreground command again while supervision remains required.
4. Waiting is silent.
5. Never use shell `&`, a pipeline, or command bundling for supervision.
   Antigravity 1.1.26 exposes no verified background-task-to-model wake interface, so `bin/fm-watch-arm.sh` is not a valid substitute here.
6. A failed foreground tool call means supervision is down.
   Inspect the failure and restore the same foreground wait shape before ending a turn with work under way.
7. The tracked `.agents/hooks.json` injects the startup reminder through Antigravity's `PreInvocation` hook in a primary or second-mate home.
   It is a backstop, not a second supervision owner.

Interactive `agy` TUI sessions are the supported primary host.
Headless `agy --prompt` runs do not provide a persistent conversation for subsequent fleet notifications and are not a Firstmate primary.
