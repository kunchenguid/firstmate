Mode: DSH background-job wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm the watcher as a DSH background job - run `bin/fm-watch.sh` with the bash tool's `run_in_background`, never shell `&`.
4. Ordinary wake: the watcher exits only on an actionable wake, and that job's completion opens a turn on this session (DeepSeek Harness delivers an unreported completion to an idle owner as a bounded follow-up turn). Drain queued wakes, handle every emitted wake, then arm the next cycle.
5. If the job settles with no wake, drain queued wakes anyway and arm the next cycle.
6. Never use shell `&` for firstmate watcher supervision.
7. Failure or missing cycle only: drain queued wakes, inspect the failure, then arm a fresh background cycle.

DeepSeek Harness offers no asynchronous harness hook, so watcher continuity is owned by the background job plus the bounded Stop guard rather than by a Stop-owned auto-arm.
The guard blocks a turn that would end with work in flight and no live watcher, bounded by `FM_DSH_TURNEND_BLOCK_BUDGET` (default 3) continuations before one attended fail-open.
DeepSeek Harness reports `stop_hook_active=false` on every Stop, so the adapter counts its own continuations instead of trusting that field.
