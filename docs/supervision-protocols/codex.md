Mode: Codex native Stop-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain queued wakes with `bin/fm-wake-drain.sh`, handle the events, and run its exact acknowledgement command.
2. End the turn normally after completing the work or answering the user.
   The native asynchronous Stop hook owns the watcher and queues an actionable wake into this same Codex session, even while idle.
3. On a `Firstmate watcher wake` or lease-renewal message, drain, handle, acknowledge, and end the turn again.
   Do not manually arm or repeat foreground checkpoints.
4. If the Stop guard reports missing supervision or native delivery fails, inspect the hook registration, `state/.codex-autoarm.json`, and the watcher startup path.
   A foreground `bin/fm-watch-checkpoint.sh` remains a bounded diagnostic tool, not proof of supervision after the turn ends.
5. Never start a detached shell watcher or use a model-owned background task to replace the native hook.

The renderer selects this protocol only when the shared capability gate confirms native support; otherwise it emits the legacy foreground checkpoint protocol.
Its verified scope is a running interactive Codex session; exiting the session cancels its background hooks.
The callback ownership and failure contract is defined in [`../watcher-continuity.md`](../watcher-continuity.md).
