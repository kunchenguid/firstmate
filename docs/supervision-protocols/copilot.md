Mode: Copilot tracked-background supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run `bin/fm-watch-arm.sh` as one standalone Bash task with `mode=async` and `detach=false`.
4. Copilot reports completion of that tracked Bash task as a system notification.
5. On an actionable completion (`signal:`, `stale:`, `check:`, or `heartbeat`), drain queued wakes, handle the wake, then start exactly one new tracked Bash task the same way.
6. Never use shell `&`, `nohup`, a pipeline, or an untracked terminal command for watcher supervision.
7. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
8. On `watcher: FAILED ...`, drain, inspect the failure, and repair with one fresh standalone tracked Bash task before ending the turn.
9. The Copilot `agentStop` hook runs the shared turn-end guard and forces one bounded continuation when supervision is needed but missing.
10. Waiting on a healthy tracked task is silent.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper.
