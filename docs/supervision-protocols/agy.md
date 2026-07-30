Mode: Agy foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds __FM_AGY_CHECKPOINT__`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Agy, then start the next checkpoint.
6. Never use shell `&` or an untracked process for Firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Agy's normal supervision command.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Agy cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly without relying on an unverified background-task completion wake.
The primary `.agents/hooks.json` Stop hook invokes `bin/fm-turnend-guard-agy.sh` as a backstop.
The adapter can force one same-session continuation when supervision is missing, then allows the next Stop through by checking Agy's `executionNum`.
