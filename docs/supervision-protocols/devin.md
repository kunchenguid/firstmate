Mode: Devin quiet-daemon supervision.

A Devin primary has no way to be woken from inside the model, so it is always supervised by the quiet (or away) daemon, never by an in-turn watcher.
Its `SessionStart` hook (`bin/fm-devin-primary.sh session-start`) takes the session lock and starts the quiet daemon before the first turn; the daemon runs the watcher outside the model and types wakes into this pane.

When this session owns supervision:
1. Never run `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, a foreground wait, shell `&`, or a background subagent to keep watching.
   The daemon owns watcher continuity; any of those either fight its singleton or die silently.
2. A marked daemon injection (the `FM_INJECT_MARK` prefix) is a wake: load `away-quiet-supervision`, drain with `bin/fm-wake-drain.sh`, handle every record plus its `OPEN DECISIONS`, `UNREAD STATUS`, and `RECORD DIVERGENCE` sections, run the exact `WAKE_ACK_REQUIRED` line, and end the turn.
3. Never open `ask_user_question`; the hook blocks it because a held dialog wedges the turn and the daemon's delivery with it.
   Ask the captain in plain chat and end the turn instead.
4. In quiet mode, never type `/quiet off` or otherwise leave daemon supervision: there is no other supervision path on this harness.
   If the captain asks for normal supervision, explain that quiet mode is the only posture that keeps a Devin primary supervised, and keep it.
   In away mode, the captain's return still goes through `bin/fm-afk-return.sh` and its catch-up gate, as `away-quiet-supervision` says.
   The daemon stays down while that gate is pending, and the `Stop` hook lets turns end meanwhile; once `bin/fm-afk-return.sh check` clears the gate, the next `Stop` (or `bin/fm-devin-primary.sh ensure`) puts the home back under quiet daemon supervision.
5. The `Stop` hook refuses a turn end while the daemon is unhealthy and tries to restart it itself.
   Manual repair is `bin/fm-devin-primary.sh ensure`; if that fails, tell the captain plainly rather than improvising another watcher.
