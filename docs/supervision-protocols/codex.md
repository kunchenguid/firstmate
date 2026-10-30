Mode: Codex asynchronous Stop-hook-owned supervision.

This mode is selected only in a home that opts in with `config/codex-stop-park`, for the native session registered by `bin/fm-codex-stop-park.sh` on a verified Codex CLI version.
Other sessions retain [the foreground checkpoint protocol](codex-checkpoint.md) unchanged.

When this session owns supervision:
1. Drain first with `bin/fm-wake-drain.sh`.
   Handle every presented wake, open decision and unread status, then run the exact `WAKE_ACK_REQUIRED` acknowledgement command.
2. End the turn when handling is complete.
   The asynchronous Stop hook owns one home-scoped watcher arm outside the model; never poll or manually re-arm a healthy park.
3. A real event arrives through Codex's native thread queue as a `Firstmate watcher wake` message.
   Drain first, handle the event and acknowledge it; the next Stop re-arms automatically.
   Quiet watcher polls and supervision-host cycle boundaries remain inside the hook and cost no model calls.
4. New user input runs immediately while the asynchronous hook stays parked.
   The single-flight claim and watcher's existing singleton prevent a second watcher when that turn ends.
5. A park recovery or failure message is actionable: drain and inspect `state/.codex-park.json`.
   One failed arm is retried automatically; a repeated failure or failed queue delivery selects the existing foreground checkpoint protocol for the rest of this session.
   The synchronous turn-end guard reports a missing owner or failed delivery, including on the next turn after the parked process dies.
6. Away and quiet daemons retain supervision while `state/.afk` exists.
   On a supervision-host home, the same hook parks on that host and preserves its existing posture and wake-routing decisions.

The hook never consumes or acknowledges a durable wake record.
`bin/fm-codex-stop-park.sh` owns capability selection, native queue delivery, single-flight identity and bounded failure behavior.
