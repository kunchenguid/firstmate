<!-- fm:supervision-protocol:v3 harness=agy -->
Mode: Antigravity Stop-hook-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the Stop hook (`.agents/hooks.json` running `bin/fm-turnend-guard-agy.sh`), never by you.
   Antigravity runs that hook synchronously and awaits it, so every turn end while supervision is needed parks the turn boundary open on one home-scoped watcher cycle, with no model command and no model tokens spent while parked.
3. An actionable close wakes you as a follow-up turn carrying the `watcher` operational kind when the park emits `{"decision":"continue","reason":"..."}`.
   On that wake, run `bin/fm-wake-drain.sh` first and handle it.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end parks again automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` entries, or a real watcher reason line.
4. The Stop-hook park polls at `FM_AGY_PARK_POLL` seconds up to `FM_AGY_PARK_TIMEOUT` (default 330 seconds).
   When a park timeout occurs without a wake, it returns `{"decision":"continue","reason":"..."}` carrying `[supervision-park]` to re-arm the park silently.
   When the fleet is empty or `fm-watch.sh` exits 3, the hook returns `{}` and allows normal turn completion.
   The loop ceiling is enforced when `.executionNum < 4` is exceeded, exiting with `{}` to avoid runaway turns.
   Only normal turn completions with `.terminationReason == "NO_TOOL_CALL"` trigger a park; other termination reasons pass through with `{}`.
5. The captain keeps control while the hook is parked.
   A message sent while parked supersedes the older park through `state/.agy-park-owner`, making the older park stand down cleanly with `{}` without emitting duplicate wakes.
6. On a `turn-end-guard` follow-up, the park could not establish a live cycle.
   Inspect the watcher startup path rather than turning the notice into a repeating manual-arm loop; `bin/fm-turnend-guard.sh --agy` enforces a bounded 3-block repair nag before failing open with `{}`.
7. Treat `watcher: started ...` and `watcher: attached ...` inside park output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
8. The durable wake queue preserves actionable events between a follow-up and the next park.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
9. Waiting on the hook-owned park is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the Stop hook runs as its own tracked child.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
See [`turnend-guard.md`](../turnend-guard.md) for the bounded repair nag and supersession contract.
