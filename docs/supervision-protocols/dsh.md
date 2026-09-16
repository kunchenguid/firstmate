Mode: DSH background-job wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm the watcher as a DSH background job with `bin/fm-watch-arm.sh` and the bash tool's `run_in_background`, as its own standalone command.
   Never run `bin/fm-watch.sh` directly (the arm seatbelt denies it as `watcher-direct`) and never use shell `&` (a backgrounded child is reaped when the call returns, leaving no watcher and a false "already running").
   `bin/fm-watch-arm.sh` is built for exactly this: it forks the watcher as a tracked child, waits on it, and settles with one status line when the cycle ends.
4. Ordinary wake: the arm settles only when its watcher exits on an actionable wake, so that job's completion opens a turn on this session (DeepSeek Harness delivers an unreported completion to an idle owner as a bounded follow-up turn).
   Read the arm's single status line as the wake; drain queued wakes, handle every emitted wake, then arm the next cycle.
5. If the job settles with no wake, drain queued wakes anyway and arm the next cycle.
6. Never use shell `&` for firstmate watcher supervision.
7. Failure or missing cycle only: drain queued wakes, inspect the failure, then arm a fresh background cycle with `bin/fm-watch-arm.sh`.

DeepSeek Harness offers no asynchronous harness hook, so watcher continuity is owned by the background job plus the bounded Stop guard rather than by a Stop-owned auto-arm.
The guard blocks a turn that would end with work in flight and no live watcher, bounded by `FM_DSH_TURNEND_BLOCK_BUDGET` (default 3) continuations before one attended fail-open.
DeepSeek Harness reports `stop_hook_active=false` on every Stop, so the adapter counts its own continuations instead of trusting that field.
