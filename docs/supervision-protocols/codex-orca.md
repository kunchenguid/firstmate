Mode: Codex with an Orca-owned continuation.

When this verified primary owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   Handle all emitted wakes, open decisions and unread status, then run the exact generation-bound `WAKE_ACK_REQUIRED` command once.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Run `python3 __FM_ORCA_OWNER_SH__ ensure --home __FM_HOME_SH__` to verify or establish the app-owned cycle.
   A matching healthy owner is reused; do not start another foreground checkpoint or shell background watcher.
4. Ordinary wake: drain, handle and acknowledge, then ensure that same owner.
   The owner establishes the singleton handling successor before notification and leaves fleet decisions and queue consumption to this session.
5. Inspect `python3 __FM_ORCA_OWNER_SH__ status --home __FM_HOME_SH__` when ensure reports failure or unconfirmed delivery.
   Input acceptance alone does not prove a new turn; never create a fresh resend on silence or adopt a different terminal.
   A confirmed turn-started generation whose handling reopens without ACK is re-presented once; after that, ensure refuses until you drain and acknowledge it.
6. The Orca-scoped Stop integration ensures readiness before running the existing turn-end guard.
   Failure is explicit and the generic second-stop safeguard remains intact.

Exact operation, state and bounded-test mechanics are owned by the adapter's header and `--help`.
Other runtimes retain the [foreground Codex protocol](codex.md).
