Mode: Kimi foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_KIMI_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Kimi, then start the next checkpoint.
6. Never use shell `&` for firstmate watcher supervision; Kimi has no verified tracked background-task mechanism that survives the tool call and wakes the model on process exit.
7. Do not run `bin/fm-watch-arm.sh` as Kimi's normal supervision command; use it only as a manual recovery probe after inspecting a failed checkpoint.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Kimi 0.29.0 runs without a firstmate turn-end hook: `~/.kimi-code/config.toml` is shared Kimi state and stays untouched until a safe, idempotent global `Stop`-hook merger is verified, so there is no push-based turn-end backstop.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on unverified background-task wake semantics.
